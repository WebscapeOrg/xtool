//
//  ProvisioningIdentifiers.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum ProvisioningIdentifiers {}

extension ProvisioningIdentifiers {

    static let idPrefix = "XTL-"
    static let groupPrefix = "group."
    static let cloudContainerPrefix = "iCloud."
    static let namePrefix = "XTool "

    static func sanitize(identifier: String) -> String {
        guard identifier.hasPrefix(Self.idPrefix) else { return identifier }
        return identifier.split(separator: ".").dropFirst().joined(separator: ".")
    }

    static func identifier(fromSanitized sanitized: String, context: SigningContext) -> String {
        let uuid = context.auth.identityID.split(separator: "-")[0].uppercased()
        return "\(Self.idPrefix)\(uuid).\(sanitized)"
    }

    static func safeify(identifier: String) -> String {
        identifier.replacingOccurrences(of: ".", with: " ")
    }

    static func sanitize(groupID: DeveloperServicesAppGroup.GroupID) -> String {
        var id = groupID.rawValue
        if id.hasPrefix(Self.groupPrefix) { id.removeFirst(Self.groupPrefix.count) }
        return sanitize(identifier: id)
    }

    static func groupID(fromSanitized sanitized: String, context: SigningContext) -> DeveloperServicesAppGroup.GroupID {
        .init(rawValue: "\(Self.groupPrefix)\(identifier(fromSanitized: sanitized, context: context))")
    }

    static func groupName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)group \(safeify(identifier: sanitized))"
    }

    static func sanitize(containerID: DeveloperServicesCloudContainer.Identifier) -> String {
        var id = containerID.rawValue
        if id.hasPrefix(Self.cloudContainerPrefix) { id.removeFirst(Self.cloudContainerPrefix.count) }
        return sanitize(identifier: id)
    }

    static func containerID(
        fromSanitized sanitized: String,
        context: SigningContext
    ) -> DeveloperServicesCloudContainer.Identifier {
        .init(rawValue: "\(Self.cloudContainerPrefix)\(identifier(fromSanitized: sanitized, context: context))")
    }

    /// Whether an identifier is `iCloud.` followed by a reverse-DNS name, the only form xtool
    /// creates a container for. Apple never deletes a container, so a misspelt prefix or a build
    /// variable left unexpanded must not become one.
    static func isContainerID(_ containerID: DeveloperServicesCloudContainer.Identifier) -> Bool {
        let id = containerID.rawValue
        guard id.hasPrefix(Self.cloudContainerPrefix) else { return false }
        let labels = id.dropFirst(Self.cloudContainerPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func containerName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)iCloud \(safeify(identifier: sanitized))"
    }

    static func appName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)\(safeify(identifier: sanitized))"
    }

}
