import Foundation

/// Whether an App ID's existing development profile can sign this build as it is.
///
/// A device keeps every profile it is given, so making a new profile on every build
/// piles them up: one iPhone held 702 on 3 November 2026, one per build since October,
/// when its profile service stopped and every app it had from xtool showed "No Longer
/// Available" until the phone was restarted.
public enum ProfileReuse: Equatable, Sendable {
    case reuse
    case replace(String)

    /// What the existing profile says about itself.
    public struct Profile {
        public var state: String?
        public var type: String?
        public var expiry: Date
        public var certificateSerials: [String]
        public var devices: [String]
        public var entitlements: [String: Any]

        public init(
            state: String?,
            type: String?,
            expiry: Date,
            certificateSerials: [String],
            devices: [String],
            entitlements: [String: Any]
        ) {
            self.state = state
            self.type = type
            self.expiry = expiry
            self.certificateSerials = certificateSerials
            self.devices = devices
            self.entitlements = entitlements
        }
    }

    /// What this build needs from a profile.
    public struct Build {
        public var certificateSerial: String
        public var certificateExpiry: Date
        public var devices: Set<String>
        public var entitlements: [String: Any]

        public init(certificateSerial: String, certificateExpiry: Date, devices: Set<String>, entitlements: [String: Any]) {
            self.certificateSerial = certificateSerial
            self.certificateExpiry = certificateExpiry
            self.devices = devices
            self.entitlements = entitlements
        }
    }

    public static func decide(_ profile: Profile, for build: Build) -> ProfileReuse {
        guard profile.state == "ACTIVE" else {
            return .replace("Apple lists it as \(profile.state ?? "having no state")")
        }
        guard profile.type == "IOS_APP_DEVELOPMENT" else {
            return .replace("its type is \(profile.type ?? "missing")")
        }
        guard profile.certificateSerials.contains(build.certificateSerial) else {
            return .replace("it does not carry the signing certificate \(build.certificateSerial)")
        }
        // Invariant: UDIDs are compared without case, since the profile and the
        // device list are written by different services.
        let missingDevices = Set(build.devices.map { $0.uppercased() })
            .subtracting(profile.devices.map { $0.uppercased() }).count
        guard missingDevices == 0 else {
            return .replace("it lacks \(missingDevices) of the team's \(build.devices.count) devices")
        }
        // A profile made after its certificate outlives it; one that would expire
        // first is the only case a new profile lasts longer.
        guard profile.expiry >= build.certificateExpiry else {
            return .replace("it expires before the signing certificate does")
        }
        let ungranted = build.entitlements.keys.sorted().filter { key in
            !grants(profile.entitlements[key], build.entitlements[key])
        }
        guard ungranted.isEmpty else {
            return .replace("it does not grant \(ungranted.joined(separator: ", "))")
        }
        return .reuse
    }

    /// Reads a profile's value against a signed one the way a device does: a Boolean the
    /// app sets to true must be true in the profile (one set to false, like an empty list,
    /// claims nothing), and
    /// every string the app claims must match one of the profile's, where a profile string
    /// ending in `*` is a prefix. Any other value must be equal.
    static func grants(_ granted: Any?, _ claimed: Any?) -> Bool {
        if let claimed = claimed as? Bool, !claimed { return true }
        if let claimed = claimed as? [String], claimed.isEmpty { return true }
        guard let granted, let claimed else { return false }
        if claimed is Bool {
            return (granted as? Bool) == true
        }
        if let claimed = claimed as? String {
            return strings(granted)?.contains { matches($0, claimed) } ?? false
        }
        if let claimed = claimed as? [String] {
            guard let granted = strings(granted) else { return false }
            return claimed.allSatisfy { value in granted.contains { matches($0, value) } }
        }
        return plist(granted) != nil && plist(granted) == plist(claimed)
    }

    /// An entitlements list as the plist dictionary a device reads, so the signed
    /// entitlements and the profile's are compared in the same form.
    public static func dictionary(_ entitlements: Entitlements) throws -> [String: Any] {
        let data = try PropertyListEncoder().encode(entitlements)
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }

    private static func plist(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: [value], format: .xml, options: 0)
    }

    private static func strings(_ value: Any) -> [String]? {
        if let value = value as? String { return [value] }
        return value as? [String]
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        pattern == value || (pattern.hasSuffix("*") && value.hasPrefix(pattern.dropLast()))
    }
}
