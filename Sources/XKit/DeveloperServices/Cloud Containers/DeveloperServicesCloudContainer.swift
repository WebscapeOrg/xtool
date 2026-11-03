import Foundation

/// An iCloud container on the team, as the developer services list and create it.
/// Apple never deletes a container once it is made, so xtool creates one only for an
/// identifier an app signs with.
public struct DeveloperServicesCloudContainer: Decodable, Sendable {
    public struct ID: RawRepresentable, Hashable, Decodable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let id: ID

    public let name: String

    public struct Identifier: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public let identifier: Identifier

    private enum CodingKeys: String, CodingKey {
        case id = "cloudContainer"
        case name
        case identifier
    }
}

/// An answer without the field a request reads. It names the keys that came back, never their
/// values, so the error can be shown without printing the team's data.
public struct DeveloperServicesUnexpectedResponse: LocalizedError {
    public let action: String
    public let keys: [String]
    public var errorDescription: String? {
        "\(action) answered with \(keys.isEmpty ? "no fields" : keys.joined(separator: ", "))"
    }
}

struct DeveloperServicesAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Lists the team's iCloud containers. Containers belong to the team rather than a platform,
/// so the action has no platform prefix: `ios/listCloudContainers` does not exist (seen
/// 3 November 2026), while `cloudContainer/listCloudContainers` answers with the list.
public struct DeveloperServicesListCloudContainersRequest: DeveloperServicesRequest {

    public struct Response: Decodable, Sendable {
        let containers: [DeveloperServicesCloudContainer]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DeveloperServicesAnyKey.self)
            let key = DeveloperServicesAnyKey(stringValue: "cloudContainerList")
            guard container.contains(key) else {
                throw DeveloperServicesUnexpectedResponse(
                    action: "listCloudContainers",
                    keys: container.allKeys.map(\.stringValue).sorted()
                )
            }
            containers = try container.decode([DeveloperServicesCloudContainer].self, forKey: key)
        }
    }
    public typealias Value = [DeveloperServicesCloudContainer]

    public let teamID: DeveloperServicesTeam.ID

    public var action: String { "cloudContainer/listCloudContainers" }
    public var parameters: [String: Any] { ["teamId": teamID.rawValue] }

    public func parse(_ response: Response) -> [DeveloperServicesCloudContainer] {
        response.containers
    }

    public init(teamID: DeveloperServicesTeam.ID) {
        self.teamID = teamID
    }

}

/// Creates an iCloud container on the team. Apple never deletes a container, so this is sent
/// only for an identifier an app signs with that the team does not have yet.
public struct DeveloperServicesAddCloudContainerRequest: DeveloperServicesRequest {

    public struct Response: Decodable, Sendable {
        let cloudContainer: DeveloperServicesCloudContainer
    }
    public typealias Value = DeveloperServicesCloudContainer

    public let teamID: DeveloperServicesTeam.ID
    public let name: String
    public let identifier: DeveloperServicesCloudContainer.Identifier

    public var action: String { "cloudContainer/addCloudContainer" }
    public var parameters: [String: Any] {
        [
            "teamId": teamID.rawValue,
            "name": name,
            "identifier": identifier.rawValue,
        ]
    }

    public func parse(_ response: Response) -> DeveloperServicesCloudContainer {
        response.cloudContainer
    }

    public init(teamID: DeveloperServicesTeam.ID, name: String, identifier: DeveloperServicesCloudContainer.Identifier) {
        self.teamID = teamID
        self.name = name
        self.identifier = identifier
    }

}

/// Assigns iCloud containers to an App ID. Like the app group request, it is sent with every
/// container the app needs at once. The action sits under `ios/identifiers/`, unlike the
/// group one: `ios/assignCloudContainerToAppId` does not exist (seen 3 November 2026).
public struct DeveloperServicesAssignCloudContainersRequest: DeveloperServicesRequest {

    public struct Response: Decodable, Sendable {}
    public typealias Value = Response

    public let teamID: DeveloperServicesTeam.ID
    public let appIDID: String
    public let containerIDs: [DeveloperServicesCloudContainer.ID]

    public var action: String { "ios/identifiers/assignCloudContainerToAppId" }
    public var parameters: [String: Any] {
        [
            "teamId": teamID.rawValue,
            "appIdId": appIDID,
            "cloudContainers": containerIDs.map(\.rawValue),
        ]
    }

    public init(teamID: DeveloperServicesTeam.ID, appIDID: String, containerIDs: [DeveloperServicesCloudContainer.ID]) {
        self.teamID = teamID
        self.appIDID = appIDID
        self.containerIDs = containerIDs
    }

}
