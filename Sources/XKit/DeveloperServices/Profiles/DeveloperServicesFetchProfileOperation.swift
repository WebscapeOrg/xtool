//
//  DeveloperServicesFetchProfileOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils
import DeveloperAPI

public struct DeveloperServicesFetchProfileOperation: DeveloperServicesOperation {

    public enum Errors: Error {
        case bundleIDNotFound
        case tooManyMatchingBundleIDs
        case invalidProfileData
        case invalidDeviceData
        case invalidReplacementProfile(String)
        case signingCertificateNotFound
    }

    public let context: SigningContext
    public let bundleID: String
    public let signingInfo: SigningInfo
    /// The entitlements the app is signed with, after its app groups are renamed,
    /// which an existing profile has to grant before it is reused.
    public let entitlements: Entitlements
    public init(context: SigningContext, bundleID: String, signingInfo: SigningInfo, entitlements: Entitlements) {
        self.context = context
        self.bundleID = bundleID
        self.signingInfo = signingInfo
        self.entitlements = entitlements
    }

    public func perform() async throws -> Mobileprovision {
        let bundleIDs = try await context.developerAPIClient
            .bundleIdsGetCollection(query: .init(filter_lbrack_identifier_rbrack_: [bundleID]))
            .ok.body.json

        // filter[identifier] is a prefix filter so we need to manually upgrade to equality
        let filtered = bundleIDs.data.filter { $0.attributes?.identifier == self.bundleID }

        let bundleID: Components.Schemas.BundleId
        switch filtered.count {
        case 0:
            throw Errors.bundleIDNotFound
        case 1:
            bundleID = filtered[0]
        default:
            throw Errors.tooManyMatchingBundleIDs
        }

        let client = context.developerAPIClient
        let devices = try await DeveloperAPIPages {
            try await client.devicesGetCollection().ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)
        .filter {
            $0.attributes?.deviceClass?.value1?.supportsIOSApps == true
                && $0.attributes?.status?.value1 == .enabled
        }
        guard devices.allSatisfy({ $0.attributes?.udid != nil }) else { throw Errors.invalidDeviceData }

        let profiles = try await DeveloperAPIPages {
            try await client.bundleIdsProfilesGetToManyRelated(
                path: .init(id: bundleID.id),
                query: .init(limit: 200)
            ).ok.body.json
        } next: {
            $0.links.next
        }
        .map(\.data)
        .reduce(into: [], +=)

        var replacedDevelopmentProfiles: [String] = []
        for profile in profiles {
            let assessment = try await assessProfile(id: profile.id, devices: devices)
            if let reusable = assessment.profile { return reusable }
            if assessment.type == "IOS_APP_DEVELOPMENT" {
                replacedDevelopmentProfiles.append(profile.id)
            }
        }

        let mobileprovision = try await createProfile(bundleID: bundleID, devices: devices)
        // A valid replacement exists before any old development profile is removed.
        for id in replacedDevelopmentProfiles {
            _ = try await client.profilesDeleteInstance(path: .init(id: id)).noContent
        }
        return mobileprovision
    }

    private struct ProfileAssessment {
        let type: String
        let uuid: String
        let profile: Mobileprovision?
        let replacementReason: String?
    }

    private func createProfile(
        bundleID: Components.Schemas.BundleId,
        devices: [Components.Schemas.Device]
    ) async throws -> Mobileprovision {
        let serialNumber = signingInfo.certificate.serialNumber()
        let certificates = try await context.developerAPIClient.certificatesGetCollection(
            query: .init(filter_lbrack_serialNumber_rbrack_: [serialNumber])
        ).ok.body.json.data
        guard !certificates.isEmpty else { throw Errors.signingCertificateNotFound }

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(.init(data: .init(
                _type: .profiles,
                attributes: .init(
                    name: "XTL profile \(bundleID.id) \(UUID().uuidString)",
                    profileType: .init(.iosAppDevelopment)
                ),
                relationships: .init(
                    bundleId: .init(data: .init(_type: .bundleIds, id: bundleID.id)),
                    devices: .init(data: devices.map { .init(_type: .devices, id: $0.id) }),
                    certificates: .init(data: certificates.map { .init(_type: .certificates, id: $0.id) })
                )
            )))
        ).created.body.json.data

        let assessment = try assess(profile: response, devices: devices)
        guard let profile = assessment.profile else {
            throw Errors.invalidReplacementProfile(assessment.replacementReason ?? "its type is \(assessment.type)")
        }
        print("Created profile \(assessment.uuid) for \(self.bundleID)")
        return profile
    }

    /// Whether one of the App ID's profiles can sign this build as it is.
    private func assessProfile(
        id: String,
        devices: [Components.Schemas.Device]
    ) async throws -> ProfileAssessment {
        // An uncertain API read must not authorize deletion or replacement.
        let profile = try await context.developerAPIClient.profilesGetInstance(
            path: .init(id: id),
            query: .init(fields_lbrack_profiles_rbrack_: [.profileState, .profileType, .profileContent, .uuid])
        ).ok.body.json.data
        let assessment = try assess(profile: profile, devices: devices)
        if assessment.type != "IOS_APP_DEVELOPMENT" {
            print("Keeping profile \(assessment.uuid) for \(bundleID): its type is \(assessment.type)")
        } else if assessment.profile != nil {
            print("Reusing profile \(assessment.uuid) for \(bundleID)")
        } else {
            print("Replacing profile \(assessment.uuid) for \(bundleID): \(assessment.replacementReason ?? "unknown")")
        }
        return assessment
    }

    private func assess(
        profile: Components.Schemas.Profile,
        devices: [Components.Schemas.Device]
    ) throws -> ProfileAssessment {
        guard let attributes = profile.attributes,
              let rawType = attributes.profileType,
              let type = rawType.value1?.rawValue ?? rawType.value2,
              !type.isEmpty else {
            throw Errors.invalidProfileData
        }
        let listedUUID = attributes.uuid ?? profile.id
        guard type == "IOS_APP_DEVELOPMENT" else {
            return ProfileAssessment(type: type, uuid: listedUUID, profile: nil, replacementReason: nil)
        }
        guard let rawState = attributes.profileState,
              let state = rawState.value1?.rawValue ?? rawState.value2,
              !state.isEmpty,
              let content = attributes.profileContent.flatMap({ Data(base64Encoded: $0) }),
              let mobileprovision = try? Mobileprovision(data: content),
              let digest = try? mobileprovision.digest(),
              let grantedEntitlements = try? ProfileReuse.dictionary(digest.entitlements),
              let signedEntitlements = try? ProfileReuse.dictionary(entitlements) else {
            throw Errors.invalidProfileData
        }
        let udids = devices.compactMap { $0.attributes?.udid }

        let decision = ProfileReuse.decide(
            ProfileReuse.Profile(
                state: state,
                type: type,
                expiry: digest.expirationDate,
                certificateSerials: digest.certificates.map { $0.serialNumber() },
                devices: digest.devices,
                entitlements: grantedEntitlements
            ),
            for: ProfileReuse.Build(
                certificateSerial: signingInfo.certificate.serialNumber(),
                certificateExpiry: signingInfo.certificate.raw.notValidAfter,
                devices: Set(udids),
                entitlements: signedEntitlements
            )
        )
        switch decision {
        case .reuse:
            return ProfileAssessment(type: type, uuid: digest.uuid, profile: mobileprovision, replacementReason: nil)
        case .replace(let reason):
            return ProfileAssessment(type: type, uuid: digest.uuid, profile: nil, replacementReason: reason)
        }
    }

}

extension Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload {
    fileprivate var supportsIOSApps: Bool {
        switch self {
        case .ipad, .iphone, .ipod: true
        default: false
        }
    }
}
