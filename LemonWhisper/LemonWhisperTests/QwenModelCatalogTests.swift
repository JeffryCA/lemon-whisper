import Foundation
import XCTest
@testable import LemonWhisper

final class QwenModelCatalogTests: XCTestCase {
    func testDownloadIsNotUsableUntilManifestAndFileSizesMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(QwenModelCatalog.isComplete(at: directory))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(QwenModelCatalog.isComplete(at: directory))
        let manifest = ["config.json": 2, "model.safetensors": 3]
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("download-manifest.json"))
        XCTAssertTrue(QwenModelCatalog.isComplete(at: directory))
        try Data([1]).write(to: directory.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(QwenModelCatalog.isComplete(at: directory))
    }

    func testLanguageHintsUseQwenNamesAndAutoOmitsHint() {
        XCTAssertEqual(QwenModelCatalog.transcriptionLanguage(for: "nl"), "Dutch")
        XCTAssertEqual(QwenModelCatalog.transcriptionLanguage(for: "de"), "German")
        XCTAssertEqual(QwenModelCatalog.transcriptionLanguage(for: "es"), "Spanish")
        XCTAssertNil(QwenModelCatalog.transcriptionLanguage(for: "auto"))
    }

    func testManifestWithoutWeightsCannotEnableRecording() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JSONEncoder().encode(["config.json": 2]).write(to: directory.appendingPathComponent("download-manifest.json"))
        XCTAssertFalse(QwenModelCatalog.isComplete(at: directory))
    }
}
