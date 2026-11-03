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
            .bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [bundleID],
                fields_lbrack_profiles_rbrack_: [.bundleId],
                include: [.profiles]
            ))
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
                && $0.attributes?.status?.value1 != .disabled
        }

        let profiles = bundleID.relationships?.profiles?.data ?? []
        switch profiles.count {
        case 0:
            // we're good
            break
        case 1:
            if let profile = try await reusableProfile(id: profiles[0].id, devices: devices) {
                return profile
            }
            _ = try await client.profilesDeleteInstance(path: .init(id: profiles[0].id)).noContent
        default:
            // if the user has >1 profile, it's probably okay to add another one (acceptable for non-free accounts?)
            print("Keeping the \(profiles.count) profiles for \(self.bundleID) and adding another")
        }

        let serialNumber = signingInfo.certificate.serialNumber()
        let certs = try await context.developerAPIClient.certificatesGetCollection(
            query: .init(
                filter_lbrack_serialNumber_rbrack_: [serialNumber]
            )
        )
        .ok.body.json.data

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(
                .init(
                    data: .init(
                        _type: .profiles,
                        attributes: .init(
                            name: "XTL profile \(bundleID.id)",
                            profileType: .init(.iosAppDevelopment)
                        ),
                        relationships: .init(
                            bundleId: .init(
                                data: .init(_type: .bundleIds, id: bundleID.id)
                            ),
                            devices: .init(data: devices.map {
                                .init(_type: .devices, id: $0.id)
                            }),
                            certificates: .init(data: certs.map {
                                .init(_type: .certificates, id: $0.id)
                            })
                        )
                    )
                )
            )
        )
        .created.body.json.data

        guard let contentString = response.attributes?.profileContent,
              let contentData = Data(base64Encoded: contentString)
              else { throw Errors.invalidProfileData }

        let mobileprovision = try Mobileprovision(data: contentData)
        if let uuid = try? mobileprovision.digest().uuid {
            print("Created profile \(uuid) for \(self.bundleID)")
        }
        return mobileprovision
    }

    /// The App ID's one profile, when it can sign this build as it is. A device
    /// keeps every profile it is given, so a profile made on every build piles up
    /// on it (see ProfileReuse).
    private func reusableProfile(
        id: String,
        devices: [Components.Schemas.Device]
    ) async throws -> Mobileprovision? {
        let profile = try await context.developerAPIClient.profilesGetInstance(
            path: .init(id: id),
            query: .init(fields_lbrack_profiles_rbrack_: [.profileState, .profileType, .profileContent, .uuid])
        )
        .ok.body.json.data
        let attributes = profile.attributes
        let uuid = attributes?.uuid ?? id

        guard let content = attributes?.profileContent.flatMap({ Data(base64Encoded: $0) }),
              let mobileprovision = try? Mobileprovision(data: content),
              let digest = try? mobileprovision.digest(),
              let grantedEntitlements = try? ProfileReuse.dictionary(digest.entitlements),
              let signedEntitlements = try? ProfileReuse.dictionary(entitlements)
              else {
            print("Replacing profile \(uuid) for \(bundleID): its content could not be read")
            return nil
        }

        let decision = ProfileReuse.decide(
            ProfileReuse.Profile(
                state: attributes?.profileState.map { $0.value1?.rawValue ?? $0.value2 ?? "" },
                type: attributes?.profileType.map { $0.value1?.rawValue ?? $0.value2 ?? "" },
                expiry: digest.expirationDate,
                certificateSerials: digest.certificates.map { $0.serialNumber() },
                devices: digest.devices,
                entitlements: grantedEntitlements
            ),
            for: ProfileReuse.Build(
                certificateSerial: signingInfo.certificate.serialNumber(),
                certificateExpiry: signingInfo.certificate.raw.notValidAfter,
                devices: Set(devices.compactMap { $0.attributes?.udid }),
                entitlements: signedEntitlements
            )
        )
        switch decision {
        case .reuse:
            print("Reusing profile \(uuid) for \(bundleID)")
            return mobileprovision
        case .replace(let reason):
            print("Replacing profile \(uuid) for \(bundleID): \(reason)")
            return nil
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
