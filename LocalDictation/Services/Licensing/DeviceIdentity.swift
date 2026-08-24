import CryptoKit
import Foundation
import IOKit

/// Answers "which Mac is this" for the two-device limit.
///
/// A protocol because the real answer comes out of IOKit, and a test that asks
/// IOKit is a test that measures the machine it runs on.
protocol DeviceIdentityProviding: Sendable {
    /// Stable for the life of the Mac, opaque, and the same on every launch.
    var deviceID: String { get }
}

/// The hardware UUID, salted and hashed.
///
/// The raw `IOPlatformUUID` is a permanent, cross-product identifier for a
/// specific Mac, and this product does not get to hold one. Hashing it with a
/// salt that belongs to this app produces something that is stable here,
/// useless anywhere else, and impossible to turn back into a serial number.
/// The first 16 bytes are kept, which is 128 bits of a SHA-256 — far past the
/// point where two Macs collide.
struct HardwareDeviceIdentity: DeviceIdentityProviding {
    /// Part of the identifier's definition. Changing it re-identifies every
    /// installed Mac and invalidates every issued key.
    private static let salt = "LocalDictation.device.v1"

    let deviceID: String

    init() {
        deviceID = Self.derive(from: Self.platformUUID())
    }

    init(platformUUID: String) {
        deviceID = Self.derive(from: platformUUID)
    }

    static func derive(from platformUUID: String) -> String {
        let digest = SHA256.hash(data: Data((salt + platformUUID).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Falls back to a description rather than a random value: an identifier
    /// that changes every launch would burn a device slot on every launch, and
    /// a user with a broken IOKit deserves a refusal they can read rather than
    /// a licence that mysteriously stops matching.
    private static func platformUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "unavailable" }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )
        guard let uuid = property?.takeRetainedValue() as? String else { return "unavailable" }
        return uuid
    }
}
