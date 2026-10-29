import Foundation
import Testing
@testable import PackLib

/// A module's intermediates as Swift Build writes them: const-values files and the output file map naming them.
private final class ModuleFixture {
    let directory: URL
    let module: CompiledModule

    /// `constValues` maps a file name to its JSON. With `wholeModule`, the one file is listed under the map's ""
    /// key, as a Release build writes it; otherwise each is listed under its own source file, as in Debug.
    init(constValues: [String: String], wholeModule: Bool = false, unwritten: [String] = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppIntentsMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        module = CompiledModule(name: "Widget", directory: directory)

        var map: [String: [String: String]] = ["": ["diagnostics": directory.appendingPathComponent("x.dia").path]]
        for (fileName, json) in constValues {
            let file = directory.appendingPathComponent(fileName)
            if !unwritten.contains(fileName) {
                try Data(json.utf8).write(to: file)
            }
            if wholeModule {
                map[""]?["const-values"] = file.path
            } else {
                map["/src/\(fileName).swift"] = ["const-values": file.path, "object": "/obj/\(fileName).o"]
            }
        }
        try JSONSerialization.data(withJSONObject: map).write(to: module.outputFileMap)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private let intentType = """
[{"typeName": "Widget.Increment", "kind": "struct", "file": "/src/Shared.swift", \
"conformances": ["AppIntents.AppIntent", "Swift.Sendable"], "properties": []}]
"""

@Test func findsAppIntentsInPerFileConstValues() throws {
    let fixture = try ModuleFixture(constValues: ["Shared.swiftconstvalues": intentType, "Views.swiftconstvalues": "[]"])
    #expect(try fixture.module.appIntentsTypes() == ["Widget.Increment"])
    #expect(try fixture.module.constValuesFiles().count == 2)
}

@Test func findsAppIntentsInWholeModuleConstValues() throws {
    let fixture = try ModuleFixture(constValues: ["Widget-primary.swiftconstvalues": intentType], wholeModule: true)
    #expect(try fixture.module.appIntentsTypes() == ["Widget.Increment"])
}

@Test func otherExtractedProtocolsAreNotAppIntents() throws {
    let appExtension = """
    [{"typeName": "Widget.Ext", "conformances": ["ExtensionFoundation.AppExtension"]}]
    """
    let fixture = try ModuleFixture(constValues: ["Ext.swiftconstvalues": appExtension, "Views.swiftconstvalues": "[]"])
    #expect(try fixture.module.appIntentsTypes().isEmpty)
}

@Test func missingConstValuesFileIsAnError() throws {
    let fixture = try ModuleFixture(
        constValues: ["Shared.swiftconstvalues": intentType, "Views.swiftconstvalues": "[]"],
        unwritten: ["Shared.swiftconstvalues"]
    )
    #expect(throws: StringError.self) { try fixture.module.appIntentsTypes() }
}

@Test func processorTripleCarriesTheDeploymentTarget() {
    #expect(AppIntentsMetadata.processorTriple("arm64-apple-ios", deploymentTarget: "26.0") == "arm64-apple-ios26.0")
    #expect(
        AppIntentsMetadata.processorTriple("arm64-apple-ios-simulator", deploymentTarget: "26.0")
            == "arm64-apple-ios26.0-simulator"
    )
    #expect(AppIntentsMetadata.processorTriple("arm64-apple-ios17.0", deploymentTarget: "26.0") == "arm64-apple-ios17.0")
}
