import Foundation
import DeveloperAPI

/// Finds or creates each iCloud container an app signs with, then assigns them to its App ID.
public struct DeveloperServicesAssignCloudContainersOperation: DeveloperServicesOperation {

    public enum Error: LocalizedError {
        case invalidIdentifier(String)

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifier(let identifier):
                return "Not creating an iCloud container for \(identifier): an identifier must be iCloud. followed by a reverse-DNS name, and Apple never deletes a container"
            }
        }
    }

    public let context: SigningContext
    public let containerIDs: [DeveloperServicesCloudContainer.Identifier]
    public let appID: Components.Schemas.BundleId
    public let assignedContainerIDs: Set<DeveloperServicesCloudContainer.Identifier>?
    public let xcodeAuthData: XcodeAuthData

    private let client: DeveloperServicesClient

    public init?(
        context: SigningContext,
        containerIDs: [DeveloperServicesCloudContainer.Identifier],
        appID: Components.Schemas.BundleId,
        assignedContainerIDs: Set<DeveloperServicesCloudContainer.Identifier>? = nil
    ) {
        self.context = context
        self.containerIDs = containerIDs
        self.appID = appID
        self.assignedContainerIDs = assignedContainerIDs

        guard case .xcode(let authData) = context.auth else { return nil }
        self.xcodeAuthData = authData

        self.client = DeveloperServicesClient(authData: authData)
    }

    /// Returns the containers' identifiers in the order they were given. Invariant: they are
    /// assigned only when they differ from the ones the App ID's active profile was made with,
    /// since assigning them again, like assigning app groups again, would mark that profile
    /// invalid and make every build need a new one.
    public func perform() async throws -> [DeveloperServicesCloudContainer.Identifier] {
        if let invalid = containerIDs.first(where: { !ProvisioningIdentifiers.isContainerID($0) }) {
            throw Error.invalidIdentifier(invalid.rawValue)
        }
        var existing = try await client.send(DeveloperServicesListCloudContainersRequest(
            teamID: xcodeAuthData.teamID
        ))

        var containers: [DeveloperServicesCloudContainer] = []
        for containerID in containerIDs {
            let sanitized = ProvisioningIdentifiers.sanitize(containerID: containerID)
            let identifier = ProvisioningIdentifiers.containerID(fromSanitized: sanitized, context: context)
            // The team's own renamed container first, then one named exactly as the app asks,
            // then any other with the same name, so two similar containers resolve the same way
            // on every build.
            if let container = existing.first(where: { $0.identifier == identifier })
                ?? existing.first(where: { $0.identifier == containerID })
                ?? existing.first(where: { ProvisioningIdentifiers.sanitize(containerID: $0.identifier) == sanitized }) {
                containers.append(container)
                continue
            }
            print("Creating the iCloud container \(identifier.rawValue); Apple keeps a container for good once it is made")
            let container = try await client.send(DeveloperServicesAddCloudContainerRequest(
                teamID: xcodeAuthData.teamID,
                name: ProvisioningIdentifiers.containerName(fromSanitized: sanitized),
                identifier: identifier
            ))
            existing.append(container)
            containers.append(container)
        }

        if !containers.isEmpty && Set(containers.map(\.identifier)) != assignedContainerIDs {
            print("Assigning \(containers.count) iCloud containers to \(appID.attributes?.identifier ?? appID.id)")
            _ = try await client.send(DeveloperServicesAssignCloudContainersRequest(
                teamID: xcodeAuthData.teamID,
                appIDID: appID.id,
                containerIDs: containers.map(\.id)
            ))
        }

        return containers.map(\.identifier)
    }

}
