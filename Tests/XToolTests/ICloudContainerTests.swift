import Foundation
import Testing
@testable import XKit
import DeveloperAPI

private let team = "ABCDE12345"

private func decode(_ body: String) throws -> Entitlements {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>\(body)</dict></plist>
    """
    return try PropertyListDecoder().decode(Entitlements.self, from: Data(plist.utf8))
}

/// What Magpie for iPhone signs with to keep its sender pictures in iCloud.
private let magpieICloud = """
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.net.anotherdave.magpie</string></array>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
"""

@Test func containersAskForICloudWithCloudKit() throws {
    let entitlements = try decode(magpieICloud)
    let containers = try #require(
        entitlements.entitlements().compactMap { $0 as? ICloudContainerIdentifiersEntitlement }.first
    )
    #expect(containers.rawValue == [.init(rawValue: "iCloud.net.anotherdave.magpie")])

    let capability = containers.capability
    #expect(capability.capabilityType == .init(.icloud))
    #expect(!capability.isFree)
    #expect(capability.settings == [
        .init(key: .init(.icloudVersion), options: [.init(key: .init(.xcode6))])
    ])

    let capabilities = try entitlements.entitlements().compactMap(\.anyCapability)
    #expect(capabilities.map(\.capabilityType) == [.init(.icloud)])
}

@Test func renamedContainersAreSignedAndTheServicesKeptAsWritten() throws {
    var entitlements = try decode(magpieICloud)
    try entitlements.updateEntitlements { list in
        let index = try #require(list.firstIndex { $0 is ICloudContainerIdentifiersEntitlement })
        list[index] = ICloudContainerIdentifiersEntitlement(rawValue: [
            .init(rawValue: "iCloud.XTL-\(team).net.anotherdave.magpie")
        ])
    }
    let signed = try ProfileReuse.dictionary(entitlements)
    #expect(signed[ICloudContainerIdentifiersEntitlement.identifier] as? [String] == ["iCloud.XTL-\(team).net.anotherdave.magpie"])
    #expect(signed["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"])
}

@Test func containerIdentifiersAreMatchedWithoutTheTeamPrefix() {
    #expect(ProvisioningIdentifiers.sanitize(containerID: .init(rawValue: "iCloud.net.anotherdave.magpie")) == "net.anotherdave.magpie")
    #expect(
        ProvisioningIdentifiers.sanitize(containerID: .init(rawValue: "iCloud.XTL-\(team).net.anotherdave.magpie"))
            == "net.anotherdave.magpie"
    )
    #expect(ProvisioningIdentifiers.containerName(fromSanitized: "net.anotherdave.magpie") == "XTool iCloud net anotherdave magpie")
}

/// A development profile lists the assigned containers and grants every iCloud service; the
/// keys and shapes are those of an Xcode development profile with CloudKit, with the team masked.
private func profileEntitlements(containers: [String]) throws -> [String: Any] {
    let list = containers.map { "<string>\($0)</string>" }.joined()
    return try ProfileReuse.dictionary(decode("""
    <key>application-identifier</key><string>\(team).XTL-\(team).net.anotherdave.magpie</string>
    <key>com.apple.developer.icloud-container-identifiers</key><array>\(list)</array>
    <key>com.apple.developer.icloud-container-development-container-identifiers</key><array>\(list)</array>
    <key>com.apple.developer.icloud-container-environment</key><array><string>Development</string><string>Production</string></array>
    <key>com.apple.developer.icloud-services</key><string>*</string>
    <key>com.apple.developer.team-identifier</key><string>\(team)</string>
    <key>get-task-allow</key><true/>
    """))
}

@Test func containersAreReadFromTheOneActiveProfile() throws {
    let id = "iCloud.XTL-\(team).net.anotherdave.magpie"
    let active = ProfileReuse.ListedProfile(state: "ACTIVE", entitlements: try profileEntitlements(containers: [id]))
    #expect(ProfileReuse.assigned(ICloudContainerIdentifiersEntitlement.identifier, in: [active]) == .known([id]))
    #expect(ProfileReuse.assignedGroups([active]) == .known([]))

    let before = ProfileReuse.ListedProfile(state: "ACTIVE", entitlements: try profileEntitlements(containers: []))
    #expect(ProfileReuse.assigned(ICloudContainerIdentifiersEntitlement.identifier, in: [before]) == .known([]))
    #expect(
        ProfileReuse.assigned(ICloudContainerIdentifiersEntitlement.identifier, in: [.init(state: "INVALID", entitlements: nil)])
            == .unknown("Apple lists its profile as INVALID")
    )
}

@Test func aProfileWithTheContainerGrantsCloudKit() throws {
    let id = "iCloud.XTL-\(team).net.anotherdave.magpie"
    let granted = try profileEntitlements(containers: [id])
    #expect(ProfileReuse.grants(granted["com.apple.developer.icloud-services"], ["CloudKit"]))
    #expect(ProfileReuse.grants(granted[ICloudContainerIdentifiersEntitlement.identifier], [id]))
    #expect(!ProfileReuse.grants(granted[ICloudContainerIdentifiersEntitlement.identifier], ["iCloud.XTL-\(team).net.anotherdave.other"]))
    #expect(ProfileReuse.grants(granted["com.apple.developer.icloud-container-environment"], "Development"))
}

private func appleSettings(_ json: String) throws -> [Components.Schemas.CapabilitySetting] {
    try JSONDecoder().decode([Components.Schemas.CapabilitySetting].self, from: Data(json.utf8))
}

private let iCloudWithCloudKit = ICloudContainerIdentifiersEntitlement(rawValue: []).capability.settings ?? []

/// Apple returns settings in a fuller shape than xtool sends, so they are compared by what they
/// grant: comparing with `==` sent ICLOUD's setting again on every build and made a new profile.
@Test func iCloudsSettingAsAppleReturnsItIsNotSentAgain() throws {
    let echoed = try appleSettings("""
    [{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_6"}]}]
    """)
    #expect(echoed != iCloudWithCloudKit, "the decoded keys fill both halves, so == alone would differ")
    #expect(DeveloperServicesAddAppOperation.settings(echoed, cover: iCloudWithCloudKit))

    let full = try appleSettings("""
    [{"key":"ICLOUD_VERSION","name":"iCloud","description":"Choose the iCloud version","enabledByDefault":true,"visible":true,
      "options":[{"key":"XCODE_5","name":"Xcode 5","enabled":false},{"key":"XCODE_6","name":"Include CloudKit support","enabled":true,"supportsWildcard":false}]}]
    """)
    #expect(DeveloperServicesAddAppOperation.settings(full, cover: iCloudWithCloudKit))
    #expect(DeveloperServicesAddAppOperation.settings(nil, cover: iCloudWithCloudKit), "no setting returned: nothing is known to differ")
    #expect(DeveloperServicesAddAppOperation.settings([], cover: iCloudWithCloudKit))
    #expect(DeveloperServicesAddAppOperation.settings(try appleSettings("""
    [{"key":"DATA_PROTECTION_PERMISSION_LEVEL","options":[{"key":"COMPLETE_PROTECTION"}]}]
    """), cover: iCloudWithCloudKit))
}

@Test func iCloudWithoutCloudKitIsUpdated() throws {
    let documentsOnly = try appleSettings("""
    [{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_5","enabled":true},{"key":"XCODE_6","enabled":false}]}]
    """)
    #expect(!DeveloperServicesAddAppOperation.settings(documentsOnly, cover: iCloudWithCloudKit))
    let missing = try appleSettings("""
    [{"key":"ICLOUD_VERSION","options":[{"key":"XCODE_5"}]}]
    """)
    #expect(!DeveloperServicesAddAppOperation.settings(missing, cover: iCloudWithCloudKit))
}

@Test func anotherDataProtectionLevelIsUpdated() throws {
    let wanted = DataProtectionEntitlement.complete.capability.settings ?? []
    let held = try appleSettings("""
    [{"key":"DATA_PROTECTION_PERMISSION_LEVEL","options":[{"key":"PROTECTED_UNLESS_OPEN"}]}]
    """)
    #expect(!DeveloperServicesAddAppOperation.settings(held, cover: wanted))
    let same = try appleSettings("""
    [{"key":"DATA_PROTECTION_PERMISSION_LEVEL","options":[{"key":"COMPLETE_PROTECTION","enabled":true}]}]
    """)
    #expect(DeveloperServicesAddAppOperation.settings(same, cover: wanted))
}

/// Apple never deletes a container, so only `iCloud.` and a reverse-DNS name is ever created.
@Test func onlyWellFormedContainerIdentifiersAreCreated() {
    for good in ["iCloud.net.anotherdave.magpie", "iCloud.XTL-\(team).net.anotherdave.magpie"] {
        #expect(ProvisioningIdentifiers.isContainerID(.init(rawValue: good)), "\(good)")
    }
    for bad in ["icloud.net.anotherdave.magpie", "iCloud.$(CFBundleIdentifier)", "iCloud.magpie", "iCloud.net..magpie",
                "iCloud.net.anotherdave.magpie.", "net.anotherdave.magpie", "iCloud.net.another dave.magpie", "iCloud.net.anotherdavé.magpie"] {
        #expect(!ProvisioningIdentifiers.isContainerID(.init(rawValue: bad)), "\(bad)")
    }
}
