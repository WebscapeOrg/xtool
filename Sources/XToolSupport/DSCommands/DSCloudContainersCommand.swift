import Foundation
import ArgumentParser
import XKit

struct DSCloudContainersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloud-containers",
        abstract: "Interact with iCloud containers",
        subcommands: [
            DSCloudContainersListCommand.self
        ],
        defaultSubcommand: DSCloudContainersListCommand.self
    )
}

struct DSCloudContainersListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the team's iCloud containers"
    )

    func run() async throws {
        let token = try AuthToken.saved()
        guard case let .xcode(authData) = token.authData() else {
            throw Console.Error("This command requires password-based authentication")
        }
        let client = DeveloperServicesClient(authData: authData)
        let containers = try await client.send(DeveloperServicesListCloudContainersRequest(
            teamID: authData.teamID
        ))
        if containers.isEmpty {
            print("No iCloud containers")
        }
        for container in containers {
            print("- \(container.identifier.rawValue) (\(container.name)): \(container.id.rawValue)")
        }
    }
}

