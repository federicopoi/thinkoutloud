import Testing
import Foundation
import CryptoKit
@testable import DictationCore

struct SetupTests {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }
    func model(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try (Data([0x6c, 0x6d, 0x67, 0x67]) + Data(repeating: 0, count: 2048)).write(to: url)
        return url
    }
    @Test func discoveryPreservesSelectionAndPrefersTurboOtherwise() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try model(root, "ggml-small.bin")
        let turbo = try model(root, "ggml-large-v3-turbo.bin")
        #expect(SetupDiscovery.model(saved: small.path, roots: [root]) == small.path)
        #expect(URL(fileURLWithPath: SetupDiscovery.model(saved: "/missing.bin", roots: [root])).resolvingSymlinksInPath() == turbo.resolvingSymlinksInPath())
    }
    @Test func discoveryFindsNestedModelsAndRejectsPartialOrHTMLFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<html>error</html>".utf8).write(to: root.appendingPathComponent("ggml-large-v3-turbo.bin"))
        _ = try model(root, "ggml-large-v3-turbo.bin.partial")
        let nested = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let base = try model(nested, "ggml-base.bin")
        #expect(URL(fileURLWithPath: SetupDiscovery.model(saved: "", roots: [root])).resolvingSymlinksInPath() == base.resolvingSymlinksInPath())
        #expect(!SetupDiscovery.isModel(root.appendingPathComponent("ggml-large-v3-turbo.bin").path))
    }
    @Test func downloadedFileIsOnlyInstalledAfterChecksumMatches() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try model(root, "download.bin")
        let target = root.appendingPathComponent("installed.bin")
        do {
            try VerifiedModel.install(source: source, destination: target, sha1: "incorrect")
            Issue.record("Corrupt download was accepted")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let digest = Insecure.SHA1.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        try VerifiedModel.install(source: source, destination: target, sha1: digest)
        #expect(SetupDiscovery.isModel(target.path))
    }
    @Test func cancellationDoesNotInstallAndRetryReplacesDamagedFile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try model(root, "download.bin")
        let target = root.appendingPathComponent("installed.bin")
        let digest = Insecure.SHA1.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined()
        do {
            try VerifiedModel.install(source: source, destination: target, sha1: digest, isCancelled: { true })
            Issue.record("Cancelled download was installed")
        } catch is CancellationError {} catch { throw error }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try Data("damaged".utf8).write(to: target)
        try VerifiedModel.install(source: source, destination: target, sha1: digest)
        #expect(SetupDiscovery.isModel(target.path))
    }
    @Test func emptyInstallHasNoModelAndSavedExecutableIsPreserved() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SetupDiscovery.model(saved: "", roots: [root]) == "")
        let engine = root.appendingPathComponent("whisper-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: engine)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        #expect(SetupDiscovery.engine(saved: engine.path) == engine.path)
    }

}
