import Foundation
import ConcurrencyExtras
import Dependencies

public struct ServedIdentity: Codable, Sendable, Hashable {
    public let deviceID: String
    public let serialNumber: String
}

public struct RemoteAnisette: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case identityNotFetched
        case missingHeader(String)

        public var description: String {
            switch self {
            case .identityNotFetched:
                "The device identity from the anisette server was needed before it was fetched."
            case .missingHeader(let name):
                "The anisette server's answer has no \(name)."
            }
        }
    }

    public static let urlEnvironmentKey = "XTL_ANISETTE_URL"
    public static let urlFileName = "anisette-url"

    public let url: URL

    public static let configured: RemoteAnisette? = {
        let environment = ProcessInfo.processInfo.environment[urlEnvironmentKey]
            .flatMap { $0.isEmpty ? nil : $0 }
        let filePath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/xtool")
            .appendingPathComponent(urlFileName)
            .path
        let setting: String
        if let environment {
            setting = environment
        } else if FileManager.default.fileExists(atPath: filePath) {
            guard let text = try? String(contentsOfFile: filePath, encoding: .utf8) else {
                refuse("xtool cannot read \(filePath).")
            }
            setting = text
        } else {
            return nil
        }
        let text = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil
        else { refuse("The anisette server address \"\(text)\" is not an http or https URL.") }
        return RemoteAnisette(url: url)
    }()

    private static func refuse(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(78)
    }

    static let served = LockIsolated<ServedIdentity?>(nil)

    static func deviceInfo() throws -> DeviceInfo {
        guard let identity = served.value else { throw Failure.identityNotFetched }
        return DeviceInfo(served: identity)
    }
}

public struct RemoteAnisetteDataProvider: AnisetteDataProvider {
    @Dependency(\.httpClient) private var httpClient

    private let remote: RemoteAnisette

    public init(remote: RemoteAnisette) {
        self.remote = remote
    }

    public var providerID: String? { "remote-v1 \(remote.url.absoluteString)" }

    public func fetchAnisetteData() async throws -> AnisetteData {
        let requestTime = Date()
        let (_, body) = try await httpClient.makeRequest(HTTPRequest(url: remote.url))
        let headers = try JSONDecoder().decode([String: String].self, from: body)

        func header(_ name: String) throws -> String {
            guard let value = headers[name], !value.isEmpty else { throw RemoteAnisette.Failure.missingHeader(name) }
            return value
        }

        let identity = ServedIdentity(
            deviceID: try header(DeviceInfo.deviceIDKey),
            serialNumber: headers[DeviceInfo.serialNumberKey] ?? "0"
        )
        RemoteAnisette.served.setValue(identity)

        let routingText = try header(AnisetteData.routingInfoKey)
        guard let routingInfo = UInt64(routingText) else {
            throw RemoteAnisette.Failure.missingHeader(AnisetteData.routingInfoKey)
        }
        return AnisetteData(
            clientTime: requestTime,
            routingInfo: routingInfo,
            machineID: try header(AnisetteData.machineIDKey),
            localUserID: try header(AnisetteData.localUserIDKey),
            oneTimePassword: try header(AnisetteData.oneTimePasswordKey),
            deviceID: identity.deviceID
        )
    }
}
