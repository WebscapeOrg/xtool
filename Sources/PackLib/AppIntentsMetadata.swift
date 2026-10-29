import Foundation
import XUtils
import Subprocess
import Superutils

/// Xcode's "Extract App Intents Metadata" build step, for xtool builds.
///
/// iOS runs an App Intent (a button in a widget or a Live Activity, a shortcut) only when the bundle carries
/// `Metadata.appintents`, which Xcode writes with `appintentsmetadataprocessor`. Without it the button is drawn but
/// the tap fails with "There is no metadata for <Intent> in <bundle id>". The Darwin SDK that xtool builds on Linux
/// has no such tool, so xtool runs the executable named by `XTOOL_APPINTENTS_PROCESSOR` (on macOS, Xcode's own by
/// default) for the app and for each extension whose own module declares App Intents types. It runs after packing
/// and before any signing, so the signature covers the metadata. Products without App Intents are left as they were.
public struct AppIntentsMetadata: Sendable {
    public static let processorVariable = "XTOOL_APPINTENTS_PROCESSOR"

    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.buildSettings = buildSettings
        self.plan = plan
    }

    public func generate(inApp app: URL) async throws {
        // The processor reads the compiler's const values, which only Swift Build writes.
        guard buildSettings.buildSystem == .swiftBuild else { return }

        let jobs = try plan.allProducts.compactMap { try job(for: $0, inApp: app) }
        warnAboutIntentsInDependencies()
        guard !jobs.isEmpty, let processor = try await processor(for: jobs) else { return }

        let tools = try await Tools.current(for: buildSettings)
        for job in jobs {
            try await run(processor, for: job, tools: tools)
        }
    }

    private struct Job {
        var product: Plan.Product
        var module: CompiledModule
        var intentTypes: [String]
        var output: URL
    }

    private var platformName: String {
        buildSettings.triple.contains("simulator") ? "iphonesimulator" : "iphoneos"
    }

    private var configurationDirectory: String {
        "\(buildSettings.configuration.swiftBuildValue)-\(platformName)"
    }

    private func job(for product: Plan.Product, inApp app: URL) throws -> Job? {
        var modulesWithIntents: [(CompiledModule, [String])] = []
        for module in product.modules where module.isProductTarget {
            guard let compiled = compiledModule(module) else {
                throw StringError("""
                xtool could not find Swift Build's output file map for module '\(module.name)' under \
                .build/out/Intermediates.noindex/*/\(configurationDirectory)/\(module.name)-t.build, so it cannot \
                tell whether \(product.product) declares App Intents.
                """)
            }
            let types = try compiled.appIntentsTypes()
            if !types.isEmpty {
                modulesWithIntents.append((compiled, types))
            }
        }
        guard let (module, types) = modulesWithIntents.first else { return nil }
        guard modulesWithIntents.count == 1 else {
            throw StringError("""
            \(product.product) declares App Intents in more than one of its own modules \
            (\(modulesWithIntents.map(\.0.name).joined(separator: ", "))), and xtool writes App Intents metadata \
            for one module per app or extension. Move the App Intents types into one of these targets.
            """)
        }
        return Job(
            product: product,
            module: module,
            intentTypes: types,
            output: product.directory(inApp: app).standardizedFileURL
        )
    }

    /// Intents in a dependency get no metadata (Xcode would need `--static-metadata-file-list` for those),
    /// so say so rather than ship buttons that do nothing.
    private func warnAboutIntentsInDependencies() {
        let productModules = Set(plan.allProducts.flatMap { $0.modules.filter(\.isProductTarget).map(\.name) })
        var checked: Set<String> = []
        for module in plan.allProducts.flatMap(\.modules) where !productModules.contains(module.name) {
            guard checked.insert(module.name).inserted,
                  let compiled = compiledModule(module),
                  let types = try? compiled.appIntentsTypes(),
                  !types.isEmpty
                  else { continue }
            print("""
            warning: Module '\(module.name)' declares App Intents types (\(types.joined(separator: ", "))), but xtool \
            writes App Intents metadata only for the app's and each extension's own module, so iOS will not run \
            intents declared only in '\(module.name)'. Declare them in the app or extension target instead.
            """)
        }
    }

    private func compiledModule(_ module: Plan.Module) -> CompiledModule? {
        let intermediates = URL(fileURLWithPath: ".build/out/Intermediates.noindex", isDirectory: true)
        let arch = buildSettings.triple.split(separator: "-").first.map(String.init) ?? "arm64"
        let path = "\(configurationDirectory)/\(module.name)-t.build/Objects-normal/\(arch)"
        func compiled(inPackageFolder folder: String) -> CompiledModule? {
            let candidate = CompiledModule(name: module.name, directory: intermediates.appendingPathComponent("\(folder)/\(path)"))
            return FileManager.default.fileExists(atPath: candidate.outputFileMap.path) ? candidate : nil
        }
        // Swift Build names the folder after the package that declares the target. If that name is spelled
        // differently, use the other package folders, newest output file map first, since folders of packages
        // that were renamed stay behind in .build.
        if let declared = compiled(inPackageFolder: "\(module.package).build") {
            return declared
        }
        let packageFolders = (try? FileManager.default.contentsOfDirectory(atPath: intermediates.path)) ?? []
        return packageFolders
            .filter { $0.hasSuffix(".build") }
            .compactMap(compiled(inPackageFolder:))
            .max { $0.outputFileMapDate < $1.outputFileMapDate }
    }

    private func processor(for jobs: [Job]) async throws -> Executable? {
        let setting = ProcessInfo.processInfo.environment[Self.processorVariable] ?? ""
        let declared = jobs
            .map { "\($0.module.name) (\($0.intentTypes.joined(separator: ", ")))" }
            .joined(separator: " and ")
        if setting == "none" {
            print("""
            warning: \(Self.processorVariable)=none, so xtool wrote no App Intents metadata for \(declared). \
            iOS will not run these intents.
            """)
            return nil
        }
        if !setting.isEmpty {
            return setting.contains("/") ? .path(FilePath(setting)) : .name(setting)
        }
        #if os(macOS)
        if let path = try? await Tools.xcrun(["--find", "appintentsmetadataprocessor"]), !path.isEmpty {
            return .path(FilePath(path))
        }
        #endif
        throw StringError("""
        The build declares App Intents in \(declared), and iOS runs an intent from a widget, a Live Activity or a \
        shortcut only when the app carries the App Intents metadata that Xcode's appintentsmetadataprocessor writes, \
        so without it those buttons would do nothing. xtool found no such tool. Set \(Self.processorVariable) to an \
        executable that takes appintentsmetadataprocessor's arguments: on Linux, the \
        appintentsmetadataprocessor-over-ssh script in xtool's scripts folder, with XTOOL_MAC_HOST set to the ssh \
        name of a Mac that has Xcode; on macOS, Xcode's own tool. To build without the metadata anyway, set \
        \(Self.processorVariable)=none.
        """)
    }

    /// Swift Build compiles for e.g. `arm64-apple-ios26.0-simulator`; xtool's own triple has no OS version.
    static func processorTriple(_ triple: String, deploymentTarget: String) -> String {
        var parts = triple.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[2] == "ios" {
            parts[2] += deploymentTarget
        }
        return parts.joined(separator: "-")
    }

    private func run(_ processor: Executable, for job: Job, tools: Tools) async throws {
        let workDirectory = URL(
            fileURLWithPath: ".build/xtool-appintents/\(configurationDirectory)/\(job.module.name)",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: workDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let constValuesList = workDirectory.appendingPathComponent("\(job.module.name).SwiftConstValuesFileList")
        let constValuesFiles = try job.module.constValuesFiles()
        try Data(constValuesFiles.map { "\($0.path)\n" }.joined().utf8).write(to: constValuesList)

        print("Generating App Intents metadata for \(job.product.product)...")
        let arguments = [
            "--toolchain-dir", tools.toolchainDirectory,
            "--module-name", job.module.name,
            "--sdk-root", tools.sdkRoot,
            "--xcode-version", tools.xcodeVersion,
            "--platform-family", "iOS",
            "--deployment-target", job.product.deploymentTarget,
            "--target-triple", Self.processorTriple(buildSettings.triple, deploymentTarget: job.product.deploymentTarget),
            "--output", job.output.path,
            "--source-file-list", job.module.sourceFileList.path,
            "--swift-const-vals-list", constValuesList.path,
            "--stringsdata-file", workDirectory.appendingPathComponent("ExtractedAppShortcutsMetadata.stringsdata").path,
            "--deployment-aware-processing",
            "--force",
        ]
        let status = try await Subprocess.run(
            processor,
            arguments: .init(arguments),
            output: .currentStandardOutput,
            error: .currentStandardError
        ).terminationStatus
        switch status {
        case .exited(0):
            break
        case .exited(let code):
            throw StringError("App Intents metadata for module '\(job.module.name)' failed: the processor exited \(code).")
        case .signaled(let signal):
            throw StringError("App Intents metadata for module '\(job.module.name)' failed: the processor got signal \(signal).")
        }
        let written = job.output.appendingPathComponent("Metadata.appintents/extract.actionsdata")
        guard FileManager.default.fileExists(atPath: written.path) else {
            throw StringError("""
            The App Intents metadata processor exited successfully but wrote no Metadata.appintents into \
            \(job.output.path).
            """)
        }
    }
}

/// A Swift module as Swift Build compiled it for this build's configuration and platform.
struct CompiledModule {
    var name: String
    /// `Objects-normal/<arch>` in the module's intermediates.
    var directory: URL

    var outputFileMap: URL { directory.appendingPathComponent("\(name)-OutputFileMap.json") }
    var sourceFileList: URL { directory.appendingPathComponent("\(name).SwiftFileList") }

    var outputFileMapDate: Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputFileMap.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    /// The const-values files of this build, as the compiler's output file map lists them (one per source file
    /// in Debug, one per module when compiling the whole module). Reading the map rather than the folder skips
    /// files left behind by earlier builds. The compiler writes one for every file it lists, App Intents or not,
    /// so a missing one means the build is not what xtool expects, and guessing "no intents" could ship buttons
    /// that do nothing.
    func constValuesFiles() throws -> [URL] {
        let data = try Data(contentsOf: outputFileMap)
        guard let map = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StringError("Unexpected output file map format at \(outputFileMap.path)")
        }
        let files = map.values
            .compactMap { ($0 as? [String: Any])?["const-values"] as? String }
            .sorted()
            .map { URL(fileURLWithPath: $0) }
        if let missing = files.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            throw StringError("""
            Swift Build's output file map for module '\(name)' lists \(missing.path), which does not exist, so xtool \
            cannot tell whether '\(name)' declares App Intents. A clean build (removing .build) should restore it.
            """)
        }
        return files
    }

    /// The types this module declares with a conformance to an App Intents protocol (intents, entities, enums,
    /// queries, shortcuts providers). The const values also list types for unrelated protocols such as
    /// `AppExtension`, which do not count.
    func appIntentsTypes() throws -> [String] {
        try constValuesFiles().flatMap { file in
            guard let types = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] else {
                throw StringError("Unexpected const values format at \(file.path)")
            }
            return types
                .filter { type in
                    (type["conformances"] as? [String] ?? []).contains { $0.hasPrefix("AppIntents.") }
                }
                .map { $0["typeName"] as? String ?? "?" }
        }
    }
}

/// The SDK, toolchain and Xcode version to name to the processor. On Linux these are the Darwin SDK's own paths,
/// which a drop-in that runs Apple's tool elsewhere replaces with that machine's.
private struct Tools {
    var toolchainDirectory: String
    var sdkRoot: String
    var xcodeVersion: String

    static func current(for buildSettings: BuildSettings) async throws -> Tools {
        let simulator = buildSettings.triple.contains("simulator")
        #if os(macOS)
        // What Xcode itself passes: its default toolchain and its own build version. `xcode-select -p` honours
        // DEVELOPER_DIR, like xcrun.
        let developer = URL(fileURLWithPath: try await run("/usr/bin/xcode-select", ["-p"]), isDirectory: true)
        return Tools(
            toolchainDirectory: developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain").path,
            sdkRoot: try await xcrun(["--sdk", simulator ? "iphonesimulator" : "iphoneos", "--show-sdk-path"]),
            xcodeVersion: productBuildVersion(at: developer.deletingLastPathComponent().appendingPathComponent("version.plist"))
        )
        #else
        let sdk = try DarwinSDK.current().orThrow(StringError("No Darwin SDK configured. Please run `xtool setup`."))
        let developer = sdk.bundle.appendingPathComponent("Developer", isDirectory: true)
        let platform = simulator ? "iPhoneSimulator" : "iPhoneOS"
        let sdkRoot = developer.appendingPathComponent("Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk")
        return Tools(
            toolchainDirectory: developer.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain").path,
            sdkRoot: sdkRoot.path,
            // Only an SDK that keeps a copy of Xcode.app knows which Xcode it came from. A drop-in that runs
            // Apple's tool elsewhere passes that machine's own Xcode version instead.
            xcodeVersion: productBuildVersion(at: sdk.bundle.appendingPathComponent("Xcode.app/Contents/version.plist"))
        )
        #endif
    }

    private static func productBuildVersion(at versionPlist: URL) -> String {
        (try? Data(contentsOf: versionPlist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
            .flatMap { $0["ProductBuildVersion"] as? String }
            ?? "unknown"
    }

    #if os(macOS)
    static func xcrun(_ arguments: [String]) async throws -> String {
        try await run("/usr/bin/xcrun", arguments)
    }

    private static func run(_ path: FilePath, _ arguments: [String]) async throws -> String {
        let result = try await Subprocess.run(
            .path(path),
            arguments: .init(arguments),
            output: .string(limit: .max)
        ).checkSuccess()
        return result.standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    #endif
}
