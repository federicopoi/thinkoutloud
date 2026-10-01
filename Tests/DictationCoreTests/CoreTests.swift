import Testing
import Foundation
@testable import DictationCore

struct CoreTests {
    // App launch removes abandoned production sessions; tests use a separate root.
    private static let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakTests-\(UUID().uuidString)")

    @Test func automaticDefaultsMigrateOldSelectionsAndPreserveOtherSettings() {
        let name = "SpeakTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("en", forKey: "language")
        defaults.set("old-headset", forKey: "inputUID")
        defaults.set("old-speaker", forKey: "outputUID")
        defaults.set("my-model.bin", forKey: "modelPath")
        AutomaticPreferences.migrate(in: defaults)
        #expect(defaults.string(forKey: "language") == "auto")
        #expect(defaults.string(forKey: "inputUID") == "")
        #expect(defaults.string(forKey: "outputUID") == "")
        #expect(defaults.string(forKey: "modelPath") == "my-model.bin")
        // An intentional choice made after migration must survive the next launch.
        defaults.set("es", forKey: "language")
        defaults.set("external-mic", forKey: "inputUID")
        AutomaticPreferences.migrate(in: defaults)
        #expect(defaults.string(forKey: "language") == "es")
        #expect(defaults.string(forKey: "inputUID") == "external-mic")
    }

    @Test func newInstallStartsWithAutomaticLanguageAndAudio() {
        let name = "SpeakTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        AutomaticPreferences.migrate(in: defaults)
        #expect(defaults.string(forKey: "language") == "auto")
        #expect(defaults.string(forKey: "inputUID") == "")
        #expect(defaults.string(forKey: "outputUID") == "")
    }

    @Test func spaceStopIsOnlyActiveWhileRecording() {
        for state in [SessionState.idle, .starting, .transcribing, .copied, .failed] {
            #expect(!state.usesSpaceToStop)
        }
        #expect(SessionState.recording.usesSpaceToStop)
        var state = SessionState.recording
        state.apply(.stop)
        #expect(!state.usesSpaceToStop)
        state = .recording
        state.apply(.cancel)
        #expect(!state.usesSpaceToStop)
        state = .recording
        state.apply(.failure)
        #expect(!state.usesSpaceToStop)
    }

    @Test func testLifecycleRejectsDoubleStartAndStopWhileTranscribing() {
        var state = SessionState.idle
        expectTrue(state.apply(.start))
        #expect(state == .starting)
        expectFalse(state.apply(.start))
        expectTrue(state.apply(.ready))
        expectTrue(state.apply(.stop))
        #expect(state == .transcribing)
        expectFalse(state.apply(.stop))
        expectTrue(state.apply(.success))
        #expect(state == .copied)
        expectTrue(state.apply(.start))
    }

    @Test func testFailureCanRetryButCancellationReturnsToIdle() {
        var state = SessionState.recording
        expectTrue(state.apply(.failure))
        #expect(state == .failed)
        expectTrue(state.apply(.retry))
        #expect(state == .transcribing)
        expectTrue(state.apply(.cancel))
        #expect(state == .idle)
    }

    @Test func testSilenceAndAccidentalTapAreRejected() throws {
        expectError(try RecordingStats(duration: 4, voicedDuration: 0).validate())
        expectError(try RecordingStats(duration: 0.1, voicedDuration: 0.1).validate())
        try (RecordingStats(duration: 3, voicedDuration: 0.8).validate())
    }

    @Test func testTranscriptWhitespaceIsCleanedAndEmptyResultRejected() throws {
        #expect(try cleanTranscript("  Hello there.\n\n  This is a test. \n") == "Hello there. This is a test.")
        expectError(try cleanTranscript("\n \t"))
    }

    @Test func shiftSpaceMigrationChangesTheShortcutOnceAndPreservesPreferences() throws {
        let name = "SpeakTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("auto", forKey: "language")
        let old = Shortcut(keyCode: 49, modifiers: 4096 | 512, label: "⌃ ⇧ Space")
        defaults.set(try JSONEncoder().encode(old), forKey: "shortcut")
        AutomaticPreferences.useShiftSpaceShortcut(in: defaults)
        let saved = try JSONDecoder().decode(Shortcut.self, from: defaults.data(forKey: "shortcut")!)
        #expect(saved == Shortcut.defaultShortcut)
        #expect(defaults.string(forKey: "language") == "auto")
        defaults.set(try JSONEncoder().encode(old), forKey: "shortcut")
        AutomaticPreferences.useShiftSpaceShortcut(in: defaults)
        #expect(try JSONDecoder().decode(Shortcut.self, from: defaults.data(forKey: "shortcut")!) == old)
    }

    @Test func shiftSpaceIsAcceptedWithoutAllowingOrdinaryTypingKeys() {
        #expect(Shortcut(keyCode: 49, modifiers: 512, label: "⇧ Space").isValid)
        #expect(!Shortcut(keyCode: 0, modifiers: 512, label: "⇧ A").isValid)
        #expect(!Shortcut(keyCode: 49, modifiers: 0, label: "Space").isValid)
        #expect(Shortcut.defaultShortcut == Shortcut(keyCode: 49, modifiers: 512, label: "⇧ Space"))
    }

    @Test func testShortcutRequiresModifierAndRejectsReservedPlainEscape() {
        #expect(!Shortcut(keyCode: 49, modifiers: 0, label: "Space").isValid)
        #expect(!Shortcut(keyCode: 53, modifiers: 512, label: "⌥Esc").isValid)
        #expect(Shortcut.defaultShortcut.isValid)
    }

    @Test func testWorkspaceIsPrivateUniqueAndCleanupOnlyDeletesItsSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try SessionWorkspace(root: root)
        let second = try SessionWorkspace(root: root)
        #expect(first.url != second.url)
        let perms = try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o700)
        try Data("audio".utf8).write(to: first.audioURL)
        first.cleanup()
        #expect(!FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        second.cleanup()
    }

    @Test func testRunnerProducesTextWithPathsContainingSpaces() throws {
        let workspace = try SessionWorkspace(root: Self.testRoot)
        defer { workspace.cleanup() }
        let executable = try script("for last; do :; done\nprintf ' A local transcript.\\n' > \"$last.txt\"\n", workspace: workspace)
        let model = workspace.url.appendingPathComponent("model with spaces.bin")
        try Data([1]).write(to: model)
        try Data([1]).write(to: workspace.audioURL)
        let result = try WhisperRunner().transcribe(executable: executable, model: model, audio: workspace.audioURL, language: "en", workspace: workspace.url)
        #expect(result == "A local transcript.")
    }

    @Test func testRunnerRejectsNonzeroExitAndEmptyResult() throws {
        let workspace = try SessionWorkspace(root: Self.testRoot)
        defer { workspace.cleanup() }
        let model = workspace.url.appendingPathComponent("model.bin")
        try Data([1]).write(to: model)
        try Data([1]).write(to: workspace.audioURL)
        let failed = try script("printf 'bad model' >&2\nexit 3\n", workspace: workspace)
        expectError(try WhisperRunner().transcribe(executable: failed, model: model, audio: workspace.audioURL, language: "en", workspace: workspace.url)) { error in
            #expect(error.localizedDescription.contains("bad model"))
        }
        let empty = try script("for last; do :; done\nprintf '  \\n' > \"$last.txt\"\n", workspace: workspace)
        expectError(try WhisperRunner().transcribe(executable: empty, model: model, audio: workspace.audioURL, language: "en", workspace: workspace.url))
    }

    @Test func testRunnerCancellationBeforeLaunchDoesNotStartProcess() throws {
        let workspace = try SessionWorkspace(root: Self.testRoot)
        defer { workspace.cleanup() }
        let runner = WhisperRunner()
        runner.cancel()
        expectError(try runner.transcribe(executable: URL(fileURLWithPath: "/usr/bin/true"), model: workspace.audioURL, audio: workspace.audioURL, language: "en", workspace: workspace.url)) { error in
            #expect(error as? DictationError == .cancelled)
        }
    }

    @Test func testRunnerMissingDependenciesHaveHelpfulErrors() throws {
        let workspace = try SessionWorkspace(root: Self.testRoot)
        defer { workspace.cleanup() }
        expectError(try WhisperRunner().transcribe(executable: workspace.audioURL, model: workspace.audioURL, audio: workspace.audioURL, language: "en", workspace: workspace.url)) { error in
            #expect(error.localizedDescription.contains("whisper-cli"))
        }
    }

    @Test func testRunningTranscriptionCanBeCancelled() async throws {
        let workspace = try SessionWorkspace(root: Self.testRoot)
        defer { workspace.cleanup() }
        let model = workspace.url.appendingPathComponent("model.bin")
        try Data([1]).write(to: model)
        try Data([1]).write(to: workspace.audioURL)
        let marker = workspace.url.appendingPathComponent("started")
        let executable = try script("touch '\(marker.path)'\nexec /bin/sleep 30\n", workspace: workspace)
        let runner = WhisperRunner()
        let task = Task.detached { () -> DictationError? in
            do { _ = try runner.transcribe(executable: executable, model: model, audio: workspace.audioURL, language: "en", workspace: workspace.url); return nil }
            catch { return error as? DictationError }
        }
        defer { runner.cancel() }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path))
        runner.cancel()
        let result = await task.value
        #expect(result == .cancelled)
    }

    @Test func testWhisperSilenceMarkersNeverBecomeClipboardText() {
        expectError(try cleanTranscript("[BLANK_AUDIO]"))
        expectError(try cleanTranscript("[Silence]"))
    }

    @Test(arguments: ["en", "auto"]) func testRealLocalWhisperModel(language: String) throws {
        guard ProcessInfo.processInfo.environment["LOCAL_DICTATION_REAL_MODEL_TEST"] == "1" else { return }
        let workspace = try SessionWorkspace(root: Self.testRoot)
        defer { workspace.cleanup() }
        let model = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/github.com.thewh1teagle.vibe/ggml-large-v3-turbo.bin")
        let fixture = URL(fileURLWithPath: "/opt/homebrew/Cellar/whisper-cpp/1.8.4/share/whisper-cpp/jfk.wav")
        let text = try WhisperRunner().transcribe(executable: URL(fileURLWithPath: "/opt/homebrew/bin/whisper-cli"), model: model, audio: fixture, language: language, workspace: workspace.url)
        #expect(text.lowercased().contains("ask not"))
        #expect(text.lowercased().contains("country"))
    }

    private func expectTrue(_ value: Bool) { #expect(value) }
    private func expectFalse(_ value: Bool) { #expect(!value) }

    private func expectError<T>(_ body: @autoclosure () throws -> T, check: ((Error) -> Void)? = nil) {
        do { _ = try body(); Issue.record("Expected an error") }
        catch { check?(error) }
    }

    private func script(_ body: String, workspace: SessionWorkspace) throws -> URL {
        let url = workspace.url.appendingPathComponent("test engine \(UUID().uuidString).sh")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
