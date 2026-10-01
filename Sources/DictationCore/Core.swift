import Foundation
import Darwin

public enum DictationError: LocalizedError, Equatable {
    case cancelled
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Recording cancelled."
        case .message(let text): return text
        }
    }
}

public enum SessionEvent { case start, ready, stop, success, failure, retry, cancel }

public enum SessionState: String, Equatable {
    case idle, starting, recording, transcribing, copied, failed

    public var isBusy: Bool { self == .starting || self == .recording || self == .transcribing }

    @discardableResult public mutating func apply(_ event: SessionEvent) -> Bool {
        switch (self, event) {
        case (_, .cancel): self = .idle
        case (.idle, .start), (.copied, .start), (.failed, .start): self = .starting
        case (.starting, .ready): self = .recording
        case (.recording, .stop), (.failed, .retry): self = .transcribing
        case (.transcribing, .success): self = .copied
        case (_, .failure): self = .failed
        default: return false
        }
        return true
    }
}

public struct Shortcut: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var label: String

    public init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public static let defaultShortcut = Shortcut(keyCode: 49, modifiers: 512, label: "⇧ Space")
    public var isValid: Bool {
        keyCode <= 126 && keyCode != 53 && (modifiers & (256 | 2048 | 4096) != 0 || (keyCode == 49 && modifiers == 512))
    }
}

public struct RecordingStats {
    public let duration: Double
    public let voicedDuration: Double
    public init(duration: Double, voicedDuration: Double) {
        self.duration = duration; self.voicedDuration = voicedDuration
    }
    public func validate() throws {
        guard duration >= 0.3 else { throw DictationError.message("Recording was too short. Start again and speak for a moment.") }
        guard voicedDuration >= 0.15 else { throw DictationError.message("No voice detected. Check your microphone and try again.") }
    }
}

public func cleanTranscript(_ text: String) throws -> String {
    let cleaned = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let silence = ["[blank_audio]", "[silence]", "(silence)", "[no speech]"]
    guard !cleaned.isEmpty, !silence.contains(cleaned.lowercased()) else {
        throw DictationError.message("Whisper returned no speech. Your clipboard was left unchanged.")
    }
    return cleaned
}

public final class SessionWorkspace {
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.fedepoi.localdictation", isDirectory: true)
    }
    public let url: URL
    public var audioURL: URL { url.appendingPathComponent("recording.wav") }
    public var captureURL: URL { url.appendingPathComponent("capture.caf") }

    public init(root: URL = SessionWorkspace.defaultRoot) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    public func cleanup() { try? FileManager.default.removeItem(at: url) }

    /// Only UUID-named session directories inside this app's private root are eligible.
    public static func cleanupStaleSessions() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: defaultRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for url in urls where UUID(uuidString: url.lastPathComponent) != nil {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// One runner per transcription. File-backed output avoids filling a Pipe and deadlocking.
public final class WhisperRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel(force: Bool = false) {
        lock.lock()
        cancelled = true
        let running = process
        if let running, running.isRunning {
            if force { Darwin.kill(running.processIdentifier, SIGKILL) }
            else { running.terminate() }
        }
        lock.unlock()
        if let running, !force {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
            }
        }
    }

    public func transcribe(executable: URL, model: URL, audio: URL, language: String, workspace: URL) throws -> String {
        lock.lock()
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw DictationError.cancelled }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw DictationError.message("whisper-cli was not found. Choose its executable in Settings; on this Mac it is /opt/homebrew/bin/whisper-cli.")
        }
        guard fm.isReadableFile(atPath: model.path) else {
            throw DictationError.message("Whisper model was not found. Choose your downloaded ggml model in Settings.")
        }
        guard fm.isReadableFile(atPath: audio.path) else { throw DictationError.message("The recording could not be read. Please record again.") }

        let output = workspace.appendingPathComponent("transcript")
        let log = workspace.appendingPathComponent("engine.log")
        fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["-m", model.path, "-l", language, "-nt", "-np", "-otxt", "-f", audio.path, "-of", output.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = handle
        child.standardError = handle

        lock.lock()
        if cancelled { lock.unlock(); throw DictationError.cancelled }
        process = child
        do { try child.run() }
        catch { process = nil; lock.unlock(); throw error }
        lock.unlock()
        child.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw DictationError.cancelled }
        guard child.terminationStatus == 0 else {
            let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw DictationError.message("Local transcription failed (\(child.terminationStatus)). \(String(details.suffix(1800)).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let resultURL = output.appendingPathExtension("txt")
        guard let text = try? String(contentsOf: resultURL, encoding: .utf8) else {
            throw DictationError.message("Whisper produced no transcript. Retry or choose a compatible ggml model in Settings.")
        }
        return try cleanTranscript(text)
    }
}

public enum AutomaticPreferences {
    public static func useShiftSpaceShortcut(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: "shiftSpaceShortcutV1"),
              let encoded = try? JSONEncoder().encode(Shortcut.defaultShortcut) else { return }
        defaults.set(encoded, forKey: "shortcut")
        defaults.set(true, forKey: "shiftSpaceShortcutV1")
    }

    public static func migrate(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: "automaticDefaultsV1") else { return }
        defaults.set("auto", forKey: "language")
        defaults.set("", forKey: "inputUID")
        defaults.set("", forKey: "outputUID")
        defaults.set(true, forKey: "automaticDefaultsV1")
    }
}

extension SessionState {
    public var usesSpaceToStop: Bool { self == .recording }
}
