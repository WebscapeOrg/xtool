//
//  DeveloperServicesAddAppOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI

public struct DeveloperServicesAddAppOperation: DeveloperServicesOperation {

    public enum Error: LocalizedError {
        case invalidApp(URL)

        public var errorDescription: String? {
            switch self {
            case .invalidApp(let url):
                return url.path.withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "add_app_operation.error.invalid_app", value: "Invalid app: %s", comment: ""
                        ), $0
                    )
                }
            }
        }
    }

    public let context: SigningContext
    public let signingInfo: SigningInfo
    public let root: URL
    public init(context: SigningContext, signingInfo: SigningInfo, root: URL) {
        self.context = context
        self.signingInfo = signingInfo
        self.root = root
    }

    /// Registers the app with the given entitlements
    private func upsertApp(
        bundleID: String,
        entitlements: Entitlements,
        isFreeTeam: Bool
    ) async throws -> Components.Schemas.BundleId {
        let newBundleID = ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: self.context)

        let existing = try await context.developerAPIClient
            .bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [bundleID]
            ))
            .ok.body.json.data
            // filter[identifier] is a prefix filter so we need to manually upgrade to equality
            .first(where: { $0.attributes?.identifier == newBundleID })

        let appID: Components.Schemas.BundleId
        if let existing {
            appID = existing
        } else {
            let name = ProvisioningIdentifiers.appName(fromSanitized: bundleID)
            let createResponse = try await context.developerAPIClient.bundleIdsCreateInstance(
                body: .json(
                    .init(
                        data: .init(
                            _type: .bundleIds,
                            attributes: .init(
                                name: name,
                                platform: .init(.ios),
                                identifier: newBundleID
                            )
                        )
                    )
                )
            )
            appID = try createResponse.created.body.json.data
        }

        let existingCapabilitiesList = try await context.developerAPIClient
            .bundleIdsBundleIdCapabilitiesGetToManyRelated(.init(path: .init(id: appID.id)))
            .ok.body.json.data
        let existingCapabilities = [Components.Schemas.CapabilityType: Components.Schemas.BundleIdCapability](
            existingCapabilitiesList.compactMap { cap in
                Self.capabilityType(of: cap, appID: appID).map { ($0, cap) }
            },
            uniquingKeysWith: { $1 }
        )

        let wantedCapabilitiesList = try entitlements.entitlements().compactMap(\.anyCapability)
        let wantedCapabilities = [Components.Schemas.CapabilityType: [Components.Schemas.CapabilitySetting]](
            wantedCapabilitiesList.map { ($0.capabilityType.normalized, $0.settings ?? []) },
            uniquingKeysWith: { $1 }
        )

        for (typ, cap) in existingCapabilities {
            if let wantedSettings = wantedCapabilities[typ] {
                // Invariant: without attributes the settings Apple holds are unknown, so they
                // are left as they are; sending them again would invalidate every profile. A
                // changed setting therefore does not reach an existing App ID, and says so.
                guard let attributes = cap.attributes else {
                    if !wantedSettings.isEmpty {
                        print("Leaving the settings of \(typ.logName) on \(newBundleID) as they are: Apple did not return them to compare")
                    }
                    continue
                }
                if !Self.settings(attributes.settings, cover: wantedSettings) {
                    print("Updating \(typ.logName) on \(newBundleID): Apple has \(attributes.settings ?? []), the app wants \(wantedSettings)")
                    _ = try await context.developerAPIClient.bundleIdCapabilitiesUpdateInstance(
                        path: .init(id: cap.id),
                        body: .json(
                            .init(
                                data: .init(
                                    _type: .bundleIdCapabilities,
                                    id: cap.id,
                                    attributes: .init(
                                        capabilityType: typ,
                                        settings: wantedSettings
                                    )
                                )
                            )
                        )
                    )
                    .ok
                }
            } else {
                // DeveloperServices doesn't allow deleting these capabilities.
                // Invariant: a capability Apple returns without attributes is never removed, as
                // before. Typed from its id instead, any capability Apple holds that the app does
                // not sign for would be removed, changing the App ID on every build.
                let requiredCapabilities: Set<Components.Schemas.CapabilityType.Value1Payload> = [.inAppPurchase]
                if let capType = cap.attributes?.capabilityType?.value1, !requiredCapabilities.contains(capType) {
                    print("Removing \(typ.logName) from \(newBundleID)")
                    _ = try await context.developerAPIClient
                        .bundleIdCapabilitiesDeleteInstance(path: .init(id: cap.id))
                        .noContent
                }
            }
        }
        for (typ, settings) in wantedCapabilities {
            guard existingCapabilities[typ] == nil else { continue }
            print("Adding \(typ.logName) to \(newBundleID)")
            _ = try await context.developerAPIClient.bundleIdCapabilitiesCreateInstance(
                body: .json(.init(data: .init(
                    _type: .bundleIdCapabilities,
                    attributes: .init(
                        capabilityType: typ,
                        settings: settings
                    ),
                    relationships: .init(
                        bundleId: .init(
                            data: .init(
                                _type: .bundleIds,
                                id: appID.id
                            )
                        ),
                        // not public but required iff using ds2 API
                        capability: context.auth.isPublicAPI ? nil : .init(
                            data: .init(
                                _type: .capabilities,
                                id: typ
                            )
                        )
                    )
                )))
            )
            .created.body
        }

        return appID
    }

    /// Registers the app and creates a profile. Returns the resultant entitlements as well as
    /// the profile (note that the profile does not necessarily include all of the entitlements
    /// that the app has).
    private func addApp(
        _ app: URL,
        isFreeTeam: Bool
    ) async throws -> ProvisioningInfo {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            let executable = dict["CFBundleExecutable"] as? String else {
            throw Error.invalidApp(app)
        }
        let executableURL = app.appendingPathComponent(executable)

        var entitlements: Entitlements
        // if the executable doesn't already have entitlements, that's
        // okay. We don't have to throw an error.
        if let entitlementsData = try? await context.signer.analyze(executable: executableURL),
            let decodedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            entitlements = decodedEntitlements

            if isFreeTeam {
                // re-assign rather than using updateEntitlements since the latter will
                // retain unrecognized entitlements
                let filtered = try entitlements.entitlements().filter { $0.anyCapability?.isFree != false }
                entitlements = try Entitlements(entitlements: filtered)
            }
        } else {
            entitlements = try Entitlements(entitlements: [])
        }

        let appID = try await upsertApp(bundleID: bundleID, entitlements: entitlements, isFreeTeam: isFreeTeam)
        let newBundleID = appID.attributes!.identifier!

        let teamID = try signingInfo.certificate.teamID()
        try entitlements.update(
            teamID: .init(rawValue: teamID),
            bundleID: newBundleID
        )
        // set get-task-allow to YES, required for dev certs
        try entitlements.updateEntitlements { ents in
            if let getTaskAllow = ents.firstIndex(where: { $0 is GetTaskAllowEntitlement }) {
                ents[getTaskAllow] = GetTaskAllowEntitlement(rawValue: true)
            } else {
                ents.append(GetTaskAllowEntitlement(rawValue: true))
            }
        }

        if var entitlementsArray = try? entitlements.entitlements(),
            entitlementsArray.contains(where: { $0 is AppGroupEntitlement || $0 is ICloudContainerIdentifiersEntitlement }) {
            // Read before anything is assigned: assigning groups marks the profile invalid,
            // while the containers it was made with are still the App ID's.
            let profiles = await listedProfiles(appID: appID)

            if let groupsIdx = entitlementsArray.firstIndex(where: { $0 is AppGroupEntitlement }),
                let groupsEntitlement = entitlementsArray[groupsIdx] as? AppGroupEntitlement,
                let operation = DeveloperServicesAssignAppGroupsOperation(
                    context: self.context,
                    groupIDs: groupsEntitlement.rawValue,
                    appID: appID,
                    assignedGroupIDs: assigned(AppGroupEntitlement.identifier, "app groups", in: profiles, appID: appID)
                        .map { Set($0.map(DeveloperServicesAppGroup.GroupID.init(rawValue:))) }
                ) {
                let newGroups = try await operation.perform()
                entitlementsArray[groupsIdx] = AppGroupEntitlement(rawValue: newGroups)
            }

            if let containersIdx = entitlementsArray.firstIndex(where: { $0 is ICloudContainerIdentifiersEntitlement }),
                let containersEntitlement = entitlementsArray[containersIdx] as? ICloudContainerIdentifiersEntitlement,
                let operation = DeveloperServicesAssignCloudContainersOperation(
                    context: self.context,
                    containerIDs: containersEntitlement.rawValue,
                    appID: appID,
                    assignedContainerIDs: assigned(
                        ICloudContainerIdentifiersEntitlement.identifier, "iCloud containers", in: profiles, appID: appID
                    ).map { Set($0.map(DeveloperServicesCloudContainer.Identifier.init(rawValue:))) }
                ) {
                let newContainers = try await operation.perform()
                entitlementsArray[containersIdx] = ICloudContainerIdentifiersEntitlement(rawValue: newContainers)
            }

            try entitlements.setEntitlements(entitlementsArray)
        }

        let mobileprovision = try await DeveloperServicesFetchProfileOperation(
            context: self.context,
            bundleID: newBundleID,
            signingInfo: signingInfo,
            entitlements: entitlements
        ).perform()

        return ProvisioningInfo(
            newBundleID: newBundleID,
            entitlements: entitlements,
            mobileprovision: mobileprovision
        )
    }

    /// The App ID's profiles with their states and entitlements, or why Apple did not return them.
    private func listedProfiles(appID: Components.Schemas.BundleId) async -> Result<[ProfileReuse.ListedProfile], any Swift.Error> {
        do {
            return .success(try await context.developerAPIClient.bundleIdsProfilesGetToManyRelated(
                path: .init(id: appID.id),
                query: .init(fields_lbrack_profiles_rbrack_: [.profileState, .profileContent])
            ).ok.body.json.data.map { profile in
                ProfileReuse.ListedProfile(
                    state: profile.attributes?.profileState.map { $0.value1?.rawValue ?? $0.value2 ?? "" },
                    entitlements: profile.attributes?.profileContent
                        .flatMap { Data(base64Encoded: $0) }
                        .flatMap { try? Mobileprovision(data: $0).digest() }
                        .flatMap { try? ProfileReuse.dictionary($0.entitlements) }
                )
            })
        } catch {
            return .failure(error)
        }
    }

    /// What the App ID already has under `key` (see ProfileReuse.assigned), or nil, which
    /// assigns it again, with the reason printed.
    private func assigned(
        _ key: String,
        _ what: String,
        in profiles: Result<[ProfileReuse.ListedProfile], any Swift.Error>,
        appID: Components.Schemas.BundleId
    ) -> Set<String>? {
        let name = appID.attributes?.identifier ?? appID.id
        let listed: [ProfileReuse.ListedProfile]
        switch profiles {
        case .success(let value):
            listed = value
        case .failure(let error):
            print("The \(what) of \(name) are not known: Apple did not return its profiles (\(error.localizedDescription))")
            return nil
        }
        switch ProfileReuse.assigned(key, in: listed) {
        case .known(let values):
            return values
        case .unknown(let reason):
            print("The \(what) of \(name) are not known: \(reason)")
            return nil
        }
    }

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform() async throws -> [URL: ProvisioningInfo] {
        var apps: [URL] = [root]

        for pluginsDir in ["PlugIns", "Extensions"] {
            let plugins = root.appendingPathComponent(pluginsDir)
            guard plugins.dirExists else { continue }
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }

        let isFreeTeam = try await context.auth.team()?.isFree == true

        return try await withThrowingTaskGroup(
            of: (URL, ProvisioningInfo).self,
            returning: [URL: ProvisioningInfo].self
        ) { group in
            for app in apps {
                group.addTask {
                    let info = try await addApp(app, isFreeTeam: isFreeTeam)
                    return (app, info)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

}

extension DeveloperServicesAddAppOperation {
    /// Invariant: Apple's Xcode API returns an App ID's capabilities without attributes,
    /// each with an id of the form "<App ID id>_<CAPABILITY_TYPE>" (seen 3 November 2026),
    /// so the type is read from the id when the attributes are missing. Without this every
    /// capability looked new on every build and was added again, and Apple then marked the
    /// App ID's profiles invalid, so no profile could ever be reused.
    static func capabilityType(
        of capability: Components.Schemas.BundleIdCapability,
        appID: Components.Schemas.BundleId
    ) -> Components.Schemas.CapabilityType? {
        if let type = capability.attributes?.capabilityType { return type.normalized }
        let prefix = "\(appID.id)_"
        guard capability.id.hasPrefix(prefix) else { return nil }
        let name = String(capability.id.dropFirst(prefix.count))
        return Components.Schemas.CapabilityType(value1: .init(rawValue: name), value2: nil).normalized(or: name)
    }
}

extension DeveloperServicesAddAppOperation {
    /// Whether the settings Apple holds for a capability already give the app what it asks for.
    /// Invariant: Apple returns a setting in a fuller shape than xtool sends (names, descriptions,
    /// every option with its flags, and keys filled in both halves of their anyOf), so comparing
    /// them with `==` found a difference on every build and sent the setting again each time,
    /// which marks the App ID's profile invalid. A wanted option is covered when Apple's setting
    /// with the same key lists it and does not mark it disabled. When Apple returns no setting with
    /// that key, nothing is known to differ, so nothing is sent, as for a capability Apple returns
    /// without attributes.
    static func settings(
        _ held: [Components.Schemas.CapabilitySetting]?,
        cover wanted: [Components.Schemas.CapabilitySetting]
    ) -> Bool {
        wanted.allSatisfy { want in
            guard let have = (held ?? []).first(where: { name(of: $0.key) == name(of: want.key) }) else { return true }
            return (want.options ?? []).allSatisfy { option in
                (have.options ?? []).contains { name(of: $0.key) == name(of: option.key) && $0.enabled != false }
            }
        }
    }

    private static func name(of key: Components.Schemas.CapabilitySetting.KeyPayload?) -> String? {
        key?.value1?.rawValue ?? key?.value2
    }

    private static func name(of key: Components.Schemas.CapabilityOption.KeyPayload?) -> String? {
        key?.value1?.rawValue ?? key?.value2
    }
}

extension Components.Schemas.CapabilityType {
    fileprivate var logName: String { value1?.rawValue ?? value2 ?? "a capability" }

    /// One form per type, so a type Apple sends (which may fill in both halves of the
    /// anyOf) and one xtool builds compare equal.
    var normalized: Self { normalized(or: value2 ?? "") }

    func normalized(or name: String) -> Self {
        value1.map { Self(value1: $0, value2: nil) } ?? Self(value1: nil, value2: name)
    }
}
