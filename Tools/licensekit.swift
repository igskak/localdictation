#!/usr/bin/env swift
//
// The issuing half of licensing. Run with `swift Tools/licensekit.swift`.
//
//   init                              generate a keypair; print the line to
//                                     paste into LicenseAuthority, and write
//                                     the private half outside this repository
//   issue --device <id> --email <a>   sign a key for one Mac
//         [--kind trial|annual|lifetime] [--days N]
//
// The private key never enters the repository and never enters the app. The
// app carries the public half and can only check signatures, which is what
// makes it safe to ship the verifier to everyone and keep the issuer here.
//
// This is the server side of the product, running by hand until there is a
// server. It reimplements the token's JSON — deliberately, and safely: the
// signature covers the exact bytes this file emits, so the app verifies what
// was signed rather than a re-encoding of it. What the two sides must agree on
// is only the field *names*, which is why they are listed once, here, and in
// `LicenseKey.Payload`.

import CryptoKit
import Foundation

// `$HOME` rather than `NSHomeDirectory()`, which reads the password database
// and therefore ignores an override. The test that runs this tool has to be
// able to point it at a throwaway directory — a test that writes the real
// signing key is a test that destroys the ability to issue licenses.
let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let keyURL = URL(fileURLWithPath: home)
    .appendingPathComponent(".localdictation", isDirectory: true)
    .appendingPathComponent("license-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("licensekit: \(message)\n".utf8))
    exit(1)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func loadSigningKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else {
        fail("no signing key at \(keyURL.path). Run `swift Tools/licensekit.swift init` first.")
    }
    return key
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"),
          index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

func runInit() {
    if FileManager.default.fileExists(atPath: keyURL.path) {
        fail("a signing key already exists at \(keyURL.path). Issuing a second one invalidates every key issued with the first; move it aside by hand if that is what you want.")
    }
    let key = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(
        at: keyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    do {
        try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    } catch {
        fail("could not write the signing key: \(error.localizedDescription)")
    }

    print("""
    Signing key written to \(keyURL.path) — back it up somewhere safe and never commit it.
    Losing it means no further key can ever be issued for the licenses already sold.

    Paste this into LocalDictation/Services/Licensing/LicenseKey.swift:

        static let productionPublicKeyBase64 = "\(key.publicKey.rawRepresentation.base64EncodedString())"
    """)
}

func runIssue() {
    guard let device = argument("device") else {
        fail("--device is required. The Mac's identifier is in Settings → License → This Mac.")
    }
    guard let email = argument("email"), email.contains("@") else {
        fail("--email is required and must be an address.")
    }
    let kind = argument("kind") ?? "lifetime"
    guard ["trial", "annual", "lifetime"].contains(kind) else {
        fail("--kind must be trial, annual, or lifetime.")
    }

    // Whole seconds, deliberately. `docs/PHASE_8.md` freezes the payload, and a
    // fractional value encodes differently in Swift and in JavaScript — the
    // service that will take this tool's place has to be able to emit the same
    // bytes, and the signature is over the bytes.
    let issued = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    var expires: Date?
    switch kind {
    case "trial":
        expires = issued.addingTimeInterval(Double(argument("days") ?? "14")! * 86_400)
    case "annual":
        expires = issued.addingTimeInterval(Double(argument("days") ?? "365")! * 86_400)
    default:
        // A lifetime key with an expiry is refused by the app as malformed,
        // which is the same rule read from the other end.
        expires = nil
    }

    var fields: [String] = [
        "\"device\":\"\(device)\"",
        "\"email\":\"\(email)\"",
        "\"id\":\"\(UUID().uuidString.lowercased())\"",
        "\"issued\":\(Int(issued.timeIntervalSince1970))",
        "\"kind\":\"\(kind)\""
    ]
    if let expires { fields.append("\"expires\":\(Int(expires.timeIntervalSince1970))") }
    let payload = Data("{\(fields.sorted().joined(separator: ","))}".utf8)

    let signingKey = loadSigningKey()
    guard let signature = try? signingKey.signature(for: payload) else {
        fail("signing failed")
    }

    print("LD1.\(base64URL(payload)).\(base64URL(signature))")
}

switch CommandLine.arguments.dropFirst().first {
case "init":
    runInit()
case "issue":
    runIssue()
default:
    print("""
    usage:
      swift Tools/licensekit.swift init
      swift Tools/licensekit.swift issue --device <id> --email <address> [--kind trial|annual|lifetime] [--days N]
    """)
}
