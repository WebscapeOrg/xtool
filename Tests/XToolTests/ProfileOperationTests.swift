import Foundation
import Testing
import Dependencies
import ConcurrencyExtras
import Crypto
import DeveloperAPI
import HTTPTypes
import OpenAPIRuntime
@testable import XKit

private let profileDevice = "00008120-000000000000000A"

private struct ProfileFixtureError: Error {}

private func fixture(_ name: String) throws -> Data {
    guard let directory = Bundle.module.resourceURL?.appendingPathComponent("Fixtures") else {
        throw ProfileFixtureError()
    }
    return try Data(contentsOf: directory.appendingPathComponent(name))
}

private func fixtureBase64(_ name: String) throws -> String {
    try fixture(name).base64EncodedString()
}

private func performProfileOperation(fake: ProfileAPIFake) async throws -> Mobileprovision {
    try await withDependencies {
        $0.developerAPIClientOverride = DeveloperAPIClient(
            serverURL: URL(string: "https://example.test")!,
            transport: fake,
            middlewares: [DeveloperAPIASCAuthMiddleware(key: ASCKey(
                id: "test",
                issuerID: "test",
                pem: P256.Signing.PrivateKey().pemRepresentation
            ))]
        )
    } operation: {
        let auth = DeveloperAPIAuthData.xcode(XcodeAuthData(
            loginToken: DeveloperServicesLoginToken(adsid: "test", token: "test", expiry: .distantFuture),
            teamID: DeveloperServicesTeam.ID(rawValue: "ABCDE12345")
        ))
        let context = try SigningContext(auth: auth)
        let certificate = try Certificate(data: fixture("ProfileCertificate.der"))
        let signingInfo = SigningInfo(privateKey: PrivateKey(data: Data()), certificate: certificate)
        let entitlements = try Entitlements(entitlements: [GetTaskAllowEntitlement(rawValue: true)])
        return try await DeveloperServicesFetchProfileOperation(
            context: context,
            bundleID: "com.example.app",
            signingInfo: signingInfo,
            entitlements: entitlements
        ).perform()
    }
}

@Test func aValidDevelopmentProfileAmongOthersIsReusedWithoutMutations() async throws {
    let fake = try ProfileAPIFake(
        profileIDs: ["DIST", "DEV"],
        types: ["DIST": "IOS_APP_ADHOC"],
        paginateProfiles: true
    )
    let profile = try await performProfileOperation(fake: fake)
    #expect(try profile.digest().uuid == "79E74FFA-AD5D-4A44-B89D-92BE53C1B91D")
    let calls = fake.recordedCalls()
    #expect(calls.contains { $0.hasPrefix("profiles_getInstance") && $0.contains("DIST") })
    #expect(calls.filter { $0.hasPrefix("bundleIds_profiles_getToManyRelated") }.count == 2, "\(calls)")
    #expect(calls.contains { $0.hasPrefix("profiles_getInstance") && $0.contains("DEV") }, "\(calls)")
    #expect(!calls.contains { $0.hasPrefix("profiles_createInstance") })
    #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
}

@Test func aDistributionProfileIsNeverDeletedDuringDevelopmentProvisioning() async throws {
    let fake = try ProfileAPIFake(profileIDs: ["DIST"], types: ["DIST": "IOS_APP_ADHOC"])
    _ = try await performProfileOperation(fake: fake)
    let calls = fake.recordedCalls()
    #expect(calls.contains { $0.hasPrefix("profiles_createInstance") })
    #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
}

@Test func anUncertainProfileReadDoesNotDeleteOrCreateAnything() async throws {
    let fake = try ProfileAPIFake(profileIDs: ["DEV"], readFailures: ["DEV"])
    do {
        _ = try await performProfileOperation(fake: fake)
        Issue.record("An uncertain profile read must fail the operation")
    } catch {
        let calls = fake.recordedCalls()
        #expect(calls.contains { $0.hasPrefix("profiles_getInstance") && $0.contains("DEV") })
        #expect(!calls.contains { $0.hasPrefix("profiles_createInstance") })
        #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
    }
}

@Test func anEmptyCertificateLookupFailsBeforeCreationOrDeletion() async throws {
    let fake = try ProfileAPIFake(profileIDs: ["DEV"], states: ["DEV": "INVALID"], certificateFound: false)
    do {
        _ = try await performProfileOperation(fake: fake)
        Issue.record("A missing signing certificate must fail the operation")
    } catch {
        guard case DeveloperServicesFetchProfileOperation.Errors.signingCertificateNotFound = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        let calls = fake.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("profiles_createInstance") })
        #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
    }
}

@Test func aValidReplacementIsCreatedBeforeTheOldDevelopmentProfileIsDeleted() async throws {
    let fake = try ProfileAPIFake(profileIDs: ["OLD"], states: ["OLD": "INVALID"])
    _ = try await performProfileOperation(fake: fake)
    let calls = fake.recordedCalls()
    let created = try #require(calls.firstIndex { $0.hasPrefix("profiles_createInstance") })
    let deleted = try #require(calls.firstIndex { $0.hasPrefix("profiles_deleteInstance") })
    #expect(created < deleted)
}

@Test func anInvalidReplacementDoesNotDeleteTheOldDevelopmentProfile() async throws {
    let fake = try ProfileAPIFake(
        profileIDs: ["OLD"],
        states: ["OLD": "INVALID"],
        createdState: "INVALID"
    )
    do {
        _ = try await performProfileOperation(fake: fake)
        Issue.record("An invalid replacement must fail before deletion")
    } catch {
        guard case DeveloperServicesFetchProfileOperation.Errors.invalidReplacementProfile = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        let calls = fake.recordedCalls()
        #expect(calls.contains { $0.hasPrefix("profiles_createInstance") })
        #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
    }
}

@Test func incompleteProfileContentDoesNotAuthorizeReplacement() async throws {
    let fake = try ProfileAPIFake(profileIDs: ["DEV"], missingContent: ["DEV"])
    do {
        _ = try await performProfileOperation(fake: fake)
        Issue.record("An incomplete profile response must fail before mutation")
    } catch {
        guard case DeveloperServicesFetchProfileOperation.Errors.invalidProfileData = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        let calls = fake.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("profiles_createInstance") })
        #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
    }
}

@Test func aDeviceWithoutAUDIDDoesNotAuthorizeReplacement() async throws {
    let fake = try ProfileAPIFake(
        profileIDs: [],
        devices: [.init(status: "ENABLED", udid: nil)]
    )
    do {
        _ = try await performProfileOperation(fake: fake)
        Issue.record("An incomplete device response must fail before mutation")
    } catch {
        guard case DeveloperServicesFetchProfileOperation.Errors.invalidDeviceData = error else {
            Issue.record("Unexpected error: \(error)")
            return
        }
        let calls = fake.recordedCalls()
        #expect(!calls.contains { $0.hasPrefix("profiles_createInstance") })
        #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
    }
}

@Test func unknownAndDisabledDeviceStatusesAreNotIncludedInReuse() async throws {
    let fake = try ProfileAPIFake(
        profileIDs: ["DEV"],
        devices: [
            .init(status: "ENABLED", udid: profileDevice),
            .init(status: "DISABLED", udid: "DISABLED-DEVICE"),
            .init(status: "UNKNOWN", udid: "UNKNOWN-DEVICE"),
            .init(status: nil, udid: "MISSING-STATUS"),
        ]
    )
    _ = try await performProfileOperation(fake: fake)
    let calls = fake.recordedCalls()
    #expect(!calls.contains { $0.hasPrefix("profiles_createInstance") })
    #expect(!calls.contains { $0.hasPrefix("profiles_deleteInstance") })
}

private final class ProfileAPIFake: ClientTransport, @unchecked Sendable {
    struct Device {
        let status: String?
        let udid: String?
    }

    let profileIDs: [String]
    let types: [String: String]
    let states: [String: String]
    let readFailures: Set<String>
    let missingContent: Set<String>
    let certificateFound: Bool
    let createdState: String
    let paginateProfiles: Bool
    let devices: [Device]
    let profileContent: String
    private let calls = LockIsolated<[String]>([])

    init(
        profileIDs: [String],
        types: [String: String] = [:],
        states: [String: String] = [:],
        readFailures: Set<String> = [],
        missingContent: Set<String> = [],
        certificateFound: Bool = true,
        createdState: String = "ACTIVE",
        paginateProfiles: Bool = false,
        devices: [Device] = [.init(status: "ENABLED", udid: profileDevice)]
    ) throws {
        self.profileIDs = profileIDs
        self.types = types
        self.states = states
        self.readFailures = readFailures
        self.missingContent = missingContent
        self.certificateFound = certificateFound
        self.createdState = createdState
        self.paginateProfiles = paginateProfiles
        self.devices = devices
        self.profileContent = try fixtureBase64("Development.mobileprovision")
    }

    func recordedCalls() -> [String] { calls.withValue { $0 } }

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        calls.withValue { $0.append("\(operationID) \(path)") }
        switch operationID {
        case "bundleIds_getCollection":
            return json(#"{"data":[{"type":"bundleIds","id":"BUNDLE","attributes":{"identifier":"com.example.app"}}],"links":{"self":"https://example.test/v1/bundleIds"}}"#)
        case "bundleIds_profiles_getToManyRelated":
            let cursor = URLComponents(string: path)?.queryItems?.first { $0.name == "cursor" }?.value
            let pageIDs = paginateProfiles
                ? (cursor == nil ? Array(profileIDs.prefix(1)) : Array(profileIDs.dropFirst()))
                : profileIDs
            let records = pageIDs.map { #"{"type":"profiles","id":"\#($0)"}"# }.joined(separator: ",")
            let next = paginateProfiles && cursor == nil && profileIDs.count > 1
                ? #","next":"https://example.test/v1/bundleIds/BUNDLE/profiles?cursor=second&limit=1""#
                : ""
            return json(#"{"data":[\#(records)],"links":{"self":"https://example.test/v1/bundleIds/BUNDLE/profiles"\#(next)}}"#)
        case "devices_getCollection":
            let records = devices.map { device -> String in
                let status = device.status.map { #","status":"\#($0)""# } ?? ""
                let udid = device.udid.map { #","udid":"\#($0)""# } ?? ""
                return #"{"type":"devices","id":"\#(device.udid ?? "MISSING-UDID")","attributes":{"deviceClass":"IPHONE"\#(status)\#(udid)}}"#
            }.joined(separator: ",")
            return json(#"{"data":[\#(records)],"links":{"self":"https://example.test/v1/devices"}}"#)
        case "profiles_getInstance":
            let resourcePath = URLComponents(string: path)?.path ?? path
            let id = resourcePath.split(separator: "/").last.map(String.init) ?? ""
            if readFailures.contains(id) {
                return json(#"{"errors":[]}"#, status: .internalServerError)
            }
            return json(profile(id: id))
        case "certificates_getCollection":
            let certificate = #"{"type":"certificates","id":"CERT","attributes":{"serialNumber":"5A1B"}}"#
            return json(#"{"data":[\#(certificateFound ? certificate : "")],"links":{"self":"https://example.test/v1/certificates"}}"#)
        case "profiles_createInstance":
            return json(profile(id: "NEW"), status: .created)
        case "profiles_deleteInstance":
            return (HTTPResponse(status: .noContent), nil)
        default:
            throw ProfileFixtureError()
        }
    }

    private func profile(id: String) -> String {
        let type = types[id] ?? "IOS_APP_DEVELOPMENT"
        let state = states[id] ?? (id == "NEW" ? createdState : "ACTIVE")
        let content = missingContent.contains(id) ? "" : #","profileContent":"\#(profileContent)""#
        return """
        {"data":{"type":"profiles","id":"\(id)","attributes":{"profileState":"\(state)",\
        "profileType":"\(type)"\(content),\
        "uuid":"79E74FFA-AD5D-4A44-B89D-92BE53C1B91D"}},"links":{"self":"https://example.test/v1/profiles/\(id)"}}
        """
    }

    private func json(
        _ string: String,
        status: HTTPResponse.Status = .ok
    ) -> (HTTPResponse, HTTPBody?) {
        let response = HTTPResponse(status: status, headerFields: [.contentType: "application/json"])
        return (response, HTTPBody(Data(string.utf8)))
    }
}
