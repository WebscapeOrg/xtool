import Foundation
import DeveloperAPI

/// Finds or creates each iCloud container an app signs with, then assigns them to its App ID.
public struct DeveloperServicesAssignCloudContainersOperation: DeveloperServicesOperation {

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
        let existing = try await client.send(DeveloperServicesListCloudContainersRequest(
            teamID: xcodeAuthData.teamID
        ))
        var bySanitizedID = Dictionary(
            existing.map { (ProvisioningIdentifiers.sanitize(containerID: $0.identifier), $0) },
            uniquingKeysWith: { $1 }
        )

        var containers: [DeveloperServicesCloudContainer] = []
        for containerID in containerIDs {
            let sanitized = ProvisioningIdentifiers.sanitize(containerID: containerID)
            if let container = bySanitizedID[sanitized] {
                containers.append(container)
                continue
            }
            let identifier = ProvisioningIdentifiers.containerID(fromSanitized: sanitized, context: context)
            print("Creating the iCloud container \(identifier.rawValue); Apple keeps a container for good once it is made")
            let container = try await client.send(DeveloperServicesAddCloudContainerRequest(
                teamID: xcodeAuthData.teamID,
                name: ProvisioningIdentifiers.containerName(fromSanitized: sanitized),
                identifier: identifier
            ))
            bySanitizedID[sanitized] = container
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
