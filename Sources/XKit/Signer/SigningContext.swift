//
//  SigningContext.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI
import Dependencies

public struct SigningContext: Sendable {

    public struct TargetDevice: Sendable, Hashable {
        public var udid: String
        public var name: String
    }

    public var auth: DeveloperAPIAuthData
    public var targetDevice: TargetDevice?
    public var signer: Signer

    public var developerAPIClient: DeveloperAPIClient {
        @Dependency(\.developerAPIClientOverride) var clientOverride
        return clientOverride ?? DeveloperAPIClient(auth: auth)
    }

    public init(
        auth: DeveloperAPIAuthData,
        targetDevice: TargetDevice? = nil,
        signer: Signer? = nil
    ) throws {
        self.auth = auth
        self.targetDevice = targetDevice
        self.signer = try signer ?? .first()
    }

}

private enum DeveloperAPIClientOverrideKey: DependencyKey {
    static let liveValue: DeveloperAPIClient? = nil
    static let testValue: DeveloperAPIClient? = nil
}

extension DependencyValues {
    var developerAPIClientOverride: DeveloperAPIClient? {
        get { self[DeveloperAPIClientOverrideKey.self] }
        set { self[DeveloperAPIClientOverrideKey.self] = newValue }
    }
}

#if canImport(UIKit)
import UIKit
#endif
extension SigningContext {
    @MainActor public static var hostName: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "XTool Client"
        #endif
    }
}
