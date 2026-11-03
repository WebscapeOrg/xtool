import Foundation
import Testing
@testable import XKit
import DeveloperAPI

private let team = "ABCDE12345"
private let phone = "00008120-000000000000000A"
private let ipad = "00008103-000000000000000B"
private let certificateExpiry = Date(timeIntervalSince1970: 1_822_500_000)

private func entitlements(_ body: String) throws -> [String: Any] {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>\(body)</dict></plist>
    """
    return try ProfileReuse.dictionary(PropertyListDecoder().decode(Entitlements.self, from: Data(plist.utf8)))
}

/// The entitlements of the profile xtool made for Marmalade on 2 November 2026: the same keys and
/// shapes, with the team masked.
private func profileEntitlements(extra: String = "") throws -> [String: Any] {
    try entitlements("""
    <key>aps-environment</key><string>development</string>
    <key>com.apple.security.application-groups</key><array><string>group.XTL-\(team).net.anotherdave.family</string></array>
    <key>application-identifier</key><string>\(team).XTL-\(team).net.anotherdave.marmalade</string>
    <key>keychain-access-groups</key><array><string>\(team).*</string><string>com.apple.token</string></array>
    <key>get-task-allow</key><true/>
    <key>com.apple.developer.team-identifier</key><string>\(team)</string>
    \(extra)
    """)
}

/// What xtool signs Marmalade with: its entitlements file after the team rewrite and the app-group rename.
private func signedEntitlements(extra: String = "") throws -> [String: Any] {
    try entitlements("""
    <key>aps-environment</key><string>development</string>
    <key>com.apple.security.application-groups</key><array><string>group.XTL-\(team).net.anotherdave.family</string></array>
    <key>application-identifier</key><string>\(team).XTL-\(team).net.anotherdave.marmalade</string>
    <key>keychain-access-groups</key><array><string>\(team).XTL-\(team).net.anotherdave.marmalade</string></array>
    <key>get-task-allow</key><true/>
    <key>com.apple.developer.team-identifier</key><string>\(team)</string>
    \(extra)
    """)
}

private func profile(
    state: String? = "ACTIVE",
    type: String? = "IOS_APP_DEVELOPMENT",
    expiry: Date = certificateExpiry.addingTimeInterval(26 * 24 * 3600),
    serials: [String] = ["5A1B"],
    devices: [String] = [phone, ipad],
    entitlements: [String: Any]? = nil
) throws -> ProfileReuse.Profile {
    ProfileReuse.Profile(
        state: state, type: type, expiry: expiry, certificateSerials: serials,
        devices: devices, entitlements: try entitlements ?? profileEntitlements()
    )
}

private func build(devices: Set<String> = [phone, ipad], entitlements: [String: Any]? = nil) throws -> ProfileReuse.Build {
    ProfileReuse.Build(
        certificateSerial: "5A1B", certificateExpiry: certificateExpiry,
        devices: devices, entitlements: try entitlements ?? signedEntitlements()
    )
}

@Test func profileThatCoversTheBuildIsReused() throws {
    #expect(ProfileReuse.decide(try profile(), for: try build()) == .reuse)
}

@Test func deviceIDsAreComparedWithoutCase() throws {
    #expect(ProfileReuse.decide(try profile(devices: [phone.lowercased(), ipad]), for: try build()) == .reuse)
}

@Test func profileAppleNoLongerListsAsActiveIsReplaced() throws {
    #expect(ProfileReuse.decide(try profile(state: "INVALID"), for: try build()) == .replace("Apple lists it as INVALID"))
}

@Test func profileOfAnotherTypeIsReplaced() throws {
    #expect(ProfileReuse.decide(try profile(type: "IOS_APP_ADHOC"), for: try build()) == .replace("its type is IOS_APP_ADHOC"))
}

@Test func profileWithoutTheSigningCertificateIsReplaced() throws {
    #expect(
        ProfileReuse.decide(try profile(serials: ["77"]), for: try build())
            == .replace("it does not carry the signing certificate 5A1B")
    )
}

@Test func profileMissingARegisteredDeviceIsReplaced() throws {
    #expect(
        ProfileReuse.decide(try profile(devices: [phone]), for: try build())
            == .replace("it lacks 1 of the team's 2 devices")
    )
}

@Test func profileThatExpiresBeforeTheCertificateIsReplaced() throws {
    #expect(
        ProfileReuse.decide(try profile(expiry: certificateExpiry.addingTimeInterval(-1)), for: try build())
            == .replace("it expires before the signing certificate does")
    )
}

@Test func profileThatDoesNotGrantASignedEntitlementIsReplaced() throws {
    let signed = try signedEntitlements(extra: "<key>com.apple.developer.usernotifications.time-sensitive</key><true/>")
    #expect(
        ProfileReuse.decide(try profile(), for: try build(entitlements: signed))
            == .replace("it does not grant com.apple.developer.usernotifications.time-sensitive")
    )
    let granted = try profileEntitlements(extra: "<key>com.apple.developer.usernotifications.time-sensitive</key><true/>")
    #expect(ProfileReuse.decide(try profile(entitlements: granted), for: try build(entitlements: signed)) == .reuse)
}

@Test func booleansGrantOnlyTrue() {
    #expect(ProfileReuse.grants(true, true))
    #expect(!ProfileReuse.grants(false, true))
    #expect(!ProfileReuse.grants(nil, true))
    #expect(ProfileReuse.grants(nil, false))
}

@Test func keychainWildcardGrantsTheTeamsGroups() {
    #expect(ProfileReuse.grants(["\(team).*", "com.apple.token"], ["\(team).XTL-\(team).net.anotherdave.marmalade"]))
    #expect(!ProfileReuse.grants(["\(team).*"], ["OTHER12345.net.anotherdave.marmalade"]))
}

@Test func appGroupsAreComparedByTheirRenamedNames() {
    let granted = ["group.XTL-\(team).net.anotherdave.harmony", "group.XTL-\(team).net.anotherdave.family"]
    #expect(ProfileReuse.grants(granted, ["group.XTL-\(team).net.anotherdave.family"]))
    #expect(!ProfileReuse.grants(granted, ["group.net.anotherdave.family"]))
    #expect(!ProfileReuse.grants(granted, ["group.XTL-\(team).net.anotherdave.family", "group.XTL-\(team).net.anotherdave.other"]))
}

@Test func stringsMustMatchAndMissingKeysGrantNothing() {
    #expect(ProfileReuse.grants("development", "development"))
    #expect(!ProfileReuse.grants("development", "production"))
    #expect(!ProfileReuse.grants(nil, "development"))
    #expect(!ProfileReuse.grants(nil, ["group.XTL-\(team).net.anotherdave.family"]))
    #expect(ProfileReuse.grants(nil, [String]()))
}

@Test func otherValuesMustBeEqual() {
    #expect(ProfileReuse.grants(2, 2))
    #expect(!ProfileReuse.grants(2, 3))
}

@Test func profileThatHasExpiredIsReplaced() throws {
    let expired = try profile()
    #expect(ProfileReuse.decide(expired, for: try build(), now: expired.expiry) == .replace("it has expired"))
    #expect(ProfileReuse.decide(expired, for: try build(), now: expired.expiry.addingTimeInterval(-1)) == .reuse)
}

/// Apple's Xcode API sent Marmalade's capabilities on 3 November 2026 with these ids and no
/// attributes; read as untyped, each looked new on every build, was added again, and Apple
/// marked the profile invalid before the next build could reuse it.
@Test func capabilityWithoutAttributesIsTypedByItsID() {
    let appID = Components.Schemas.BundleId(_type: .bundleIds, id: "44N3N8QMR4")
    let push = Components.Schemas.BundleIdCapability(_type: .bundleIdCapabilities, id: "44N3N8QMR4_PUSH_NOTIFICATIONS")
    let unknown = Components.Schemas.BundleIdCapability(_type: .bundleIdCapabilities, id: "44N3N8QMR4_SOMETHING_NEW")
    let foreign = Components.Schemas.BundleIdCapability(_type: .bundleIdCapabilities, id: "OTHERAPPID_APP_GROUPS")

    #expect(DeveloperServicesAddAppOperation.capabilityType(of: push, appID: appID) == .init(.pushNotifications))
    #expect(DeveloperServicesAddAppOperation.capabilityType(of: unknown, appID: appID) == .init(value1: nil, value2: "SOMETHING_NEW"))
    #expect(DeveloperServicesAddAppOperation.capabilityType(of: foreign, appID: appID) == nil)
}

@Test func aCapabilityTypeAppleFillsInBothWaysEqualsTheOneXtoolBuilds() {
    let fromApple = Components.Schemas.CapabilityType(value1: .appGroups, value2: "APP_GROUPS")
    #expect(fromApple.normalized == Components.Schemas.CapabilityType(.appGroups))
}
