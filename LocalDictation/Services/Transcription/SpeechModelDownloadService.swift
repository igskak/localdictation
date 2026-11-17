import CryptoKit
import Foundation

extension DictationEngineChoice {
    var approximateBytes: Int64 {
        switch self {
        case .whisper: 1_638_464_446
        case .whisperLarge: 3_195_115_988
        case .parakeetUltra: 632_314_500
        case .parakeetV3: 483_257_242
        }
    }

    var artifactRepository: String {
        switch self {
        case .whisper, .whisperLarge: "argmaxinc/whisperkit-coreml"
        case .parakeetUltra: "FluidInference/parakeet-ultra-coreml"
        case .parakeetV3: "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        }
    }

    var artifactRevision: String {
        switch self {
        case .whisper, .whisperLarge: "0f63a7800b00dd0226abd051b906c246e1907482"
        case .parakeetUltra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
        case .parakeetV3: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
        }
    }

    var artifactPrefix: String {
        switch self {
        case .whisper: WhisperKitTranscriptionService.defaultModelVariant + "/"
        case .whisperLarge: Self.fullWhisperVariant + "/"
        case .parakeetUltra, .parakeetV3: ""
        }
    }

    var modelBundles: [String] {
        switch self {
        case .whisper, .whisperLarge: ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        case .parakeetUltra, .parakeetV3: ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"]
        }
    }

    func artifactDirectory(base: URL) -> URL {
        switch self {
        case .whisper, .whisperLarge:
            base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/" + String(artifactPrefix.dropLast()), isDirectory: true)
        case .parakeetUltra: base.appendingPathComponent("fluidaudio/parakeet-ultra", isDirectory: true)
        case .parakeetV3: base.appendingPathComponent("fluidaudio/parakeet-tdt-0.6b-v3", isDirectory: true)
        }
    }
}

protocol SpeechModelStorage: Sendable {
    func isInstalled(_ choice: DictationEngineChoice) -> Bool
    func remove(_ choice: DictationEngineChoice) throws
}

struct LocalSpeechModelStorage: SpeechModelStorage {
    let base: URL
    static var live: Self { Self(base: WhisperKitTranscriptionService.modelDirectory() ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Witness-Models")) }

    func isInstalled(_ choice: DictationEngineChoice) -> Bool {
        let folder = choice.artifactDirectory(base: base)
        let required = choice.modelBundles.flatMap { [$0 + "/model.mil", $0 + "/coremldata.bin", $0 + "/weights/weight.bin"] }
            + ["config.json"] + (choice.artifactPrefix.isEmpty ? ["parakeet_v3_vocab.json"] : [])
        return required.allSatisfy {
            let url = folder.appendingPathComponent($0)
            return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
    }

    func remove(_ choice: DictationEngineChoice) throws {
        let folder = choice.artifactDirectory(base: base)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
    }
}

protocol SpeechModelDownloading: Sendable {
    func download(_ choice: DictationEngineChoice, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws
}

protocol SpeechModelTransport: Sendable {
    func manifest(at url: URL) async throws -> Data
    func file(at url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL
}

private final class ModelTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64) -> Void
    init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(totalBytesWritten) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

struct URLSessionSpeechModelTransport: SpeechModelTransport {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    func manifest(at url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelArtifactError.transferFailed }
        return data
    }
    func file(at url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ModelTransferDelegate(progress: progress)
        let (temporary, response) = try await session.download(for: URLRequest(url: url, timeoutInterval: 120), delegate: delegate)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelArtifactError.transferFailed }
        return temporary
    }
}

enum ModelArtifactError: LocalizedError {
    case invalidManifest, transferFailed, invalidFile, insufficientSpace
    var errorDescription: String? {
        switch self {
        case .invalidManifest: L10n.string("The model file list could not be verified. Please try again.")
        case .transferFailed: L10n.string("The model could not be downloaded. Check your connection and try again.")
        case .invalidFile: L10n.string("A model file could not be verified. Please try again.")
        case .insufficientSpace: L10n.string("There is not enough free space for this model. Free some space and try again.")
        }
    }
}

struct ModelArtifactFile: Sendable, Equatable {
    let remotePath: String
    let relativePath: String
    let size: Int64
    let sha256: String?
}

/// Fetches immutable model assets only. In particular, FluidAudio's `download`
/// helper also loads Core ML models, so it cannot be used while another model
/// is serving dictation. No audio, text or user identifier enters this service.
actor RemoteSpeechModelDownloader: SpeechModelDownloading {
    let storage: LocalSpeechModelStorage
    let transport: any SpeechModelTransport
    let availableBytes: @Sendable (URL) -> Int64?
    init(storage: LocalSpeechModelStorage = .live, transport: any SpeechModelTransport = URLSessionSpeechModelTransport(),
         availableBytes: @escaping @Sendable (URL) -> Int64? = { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage }) {
        self.storage = storage; self.transport = transport; self.availableBytes = availableBytes
    }

    static func files(in data: Data, for choice: DictationEngineChoice) throws -> [ModelArtifactFile] {
        struct Entry: Decodable {
            struct LFS: Decodable { let size: Int64; let oid: String }
            let type: String; let path: String; let size: Int64?; let lfs: LFS?
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let files = try entries.filter { $0.type == "file" && $0.path.hasPrefix(choice.artifactPrefix) }.compactMap { entry -> ModelArtifactFile? in
            let path = String(entry.path.dropFirst(choice.artifactPrefix.count))
            guard !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }),
                  !path.contains("\\"), !path.contains("?"), !path.contains("#") else { throw ModelArtifactError.invalidManifest }
            if choice.artifactPrefix.isEmpty {
                guard choice.modelBundles.contains(where: { path.hasPrefix($0 + "/") })
                        || ["config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json"].contains(path) else { return nil }
            }
            let size = max(entry.size ?? 0, entry.lfs?.size ?? 0)
            guard size > 0 else { throw ModelArtifactError.invalidManifest }
            return ModelArtifactFile(remotePath: entry.path, relativePath: path, size: size, sha256: entry.lfs?.oid)
        }
        let names = Set(files.map(\.relativePath))
        guard names.count == files.count, names.contains("config.json"),
              choice.modelBundles.allSatisfy({ names.contains($0 + "/model.mil") && names.contains($0 + "/coremldata.bin") && names.contains($0 + "/weights/weight.bin") }),
              !choice.artifactPrefix.isEmpty || names.contains("parakeet_v3_vocab.json") else { throw ModelArtifactError.invalidManifest }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    func download(_ choice: DictationEngineChoice, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let listURL = URL(string: "https://huggingface.co/api/models/\(choice.artifactRepository)/tree/\(choice.artifactRevision)/\(choice.artifactPrefix)?recursive=true")!
        let files = try Self.files(in: await transport.manifest(at: listURL), for: choice)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let folder = choice.artifactDirectory(base: storage.base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let validFiles = Set(files.filter { Self.valid(folder.appendingPathComponent($0.relativePath), file: $0) }.map(\.relativePath))
        let remaining = files.reduce(Int64(0)) { $0 + (validFiles.contains($1.relativePath) ? 0 : $1.size) }
        let available = availableBytes(folder)
        if let available, available < remaining + 256_000_000 { throw ModelArtifactError.insufficientSpace }
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(file.relativePath)
            if !validFiles.contains(file.relativePath) {
                let before = completed
                let remote = URL(string: "https://huggingface.co/\(choice.artifactRepository)/resolve/\(choice.artifactRevision)/\(file.remotePath)")!
                let temporary = try await transport.file(at: remote) { bytes in
                    progress(ModelDownloadProgress(completedBytes: before + min(bytes, file.size), totalBytes: total))
                }
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard Self.valid(temporary, file: file) else { throw ModelArtifactError.invalidFile }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            }
            completed += file.size
            progress(ModelDownloadProgress(completedBytes: completed, totalBytes: total))
        }
        guard storage.isInstalled(choice) else { throw ModelArtifactError.invalidFile }
    }

    private static func valid(_ url: URL, file: ModelArtifactFile) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), Int64(values.fileSize ?? -1) == file.size else { return false }
        guard let expected = file.sha256 else { return true }
        guard let stream = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? stream.close() }
        var digest = SHA256()
        do {
            while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty {
                if Task.isCancelled { return false }
                digest.update(data: data)
            }
        } catch { return false }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }
}
