import Foundation
import CryptoKit

public enum SetupDiscovery {
    public static let modelName = "ggml-large-v3-turbo.bin"
    public static let modelSHA1 = "4af2b29d7ec73d781377bfd1758ca957a807e941"
    public static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    public static var modelDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ThinkOutLoud/models")
    }
    public static var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [modelDirectory] + ["Library/Application Support/github.com.thewh1teagle.vibe", "Downloads", "Documents", "whisper.cpp/models"].map { home.appendingPathComponent($0) }
    }
    // A cheap header check avoids mistaking HTML responses or empty files for models.
    public static func isModel(_ path: String) -> Bool {
        guard path.hasSuffix(".bin"), let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(), size > 1024 else { return false }
        try? file.seek(toOffset: 0)
        return (try? file.read(upToCount: 4)) == Data([0x6c, 0x6d, 0x67, 0x67])
    }
    public static func model(saved: String, roots: [URL] = roots) -> String {
        if isModel(saved) { return saved }
        var candidates: [String] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                if entry.lastPathComponent.hasPrefix("ggml-"), isModel(entry.path) { candidates.append(entry.path) }
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                   let children = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    candidates += children.filter { $0.lastPathComponent.hasPrefix("ggml-") && isModel($0.path) }.map(\.path)
                }
            }
        }
        return candidates.first { URL(fileURLWithPath: $0).lastPathComponent == modelName } ?? candidates.sorted().first ?? ""
    }
    public static func engine(saved: String) -> String {
        ([saved, "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
            .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    public static var homebrew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum SetupError: LocalizedError {
    case invalidDownload, checksum, server(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidDownload: return "The download is not a Whisper model. Please try again."
        case .checksum: return "The model download is incomplete or damaged. Please try again."
        case .server(let status): return "The download server returned \(status). Please try again later."
        }
    }
}

public enum VerifiedModel {
    public static func install(source: URL, destination: URL, sha1: String, isCancelled: () -> Bool = { false }) throws {
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var hash = Insecure.SHA1()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            if isCancelled() { throw CancellationError() }
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha1 else { throw SetupError.checksum }
        guard SetupDiscovery.isModel(source.path) else { throw SetupError.invalidDownload }
        if isCancelled() { throw CancellationError() }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Don't replace a pre-existing model. A download is never written to the final path until verified.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: source, to: destination)
        } else if !SetupDiscovery.isModel(destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        }
    }
}

public final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private let sourceURL: URL
    private let destination: URL
    private let checksum: String
    private let progress: (Double) -> Void
    private let completion: (Result<URL, Error>) -> Void
    public init(url: URL = SetupDiscovery.modelURL, destination: URL = SetupDiscovery.modelDirectory.appendingPathComponent(SetupDiscovery.modelName), sha1: String = SetupDiscovery.modelSHA1, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.sourceURL = url; self.destination = destination; self.checksum = sha1
        self.progress = progress; self.completion = completion
    }
    public func start() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session!.downloadTask(with: sourceURL)
        task?.resume()
    }
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        task?.cancel()
    }
    private func isCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; lock.unlock()
        session?.finishTasksAndInvalidate()
        session = nil; task = nil
        DispatchQueue.main.async { self.completion(result) }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress(value) }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, status == 200 else {
                throw SetupError.server((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            // URLSession's temporary file has no .bin extension; stage it privately before checking its header.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkOutLoud-\(UUID().uuidString).bin")
            try FileManager.default.moveItem(at: location, to: staging)
            defer { try? FileManager.default.removeItem(at: staging) }
            try VerifiedModel.install(source: staging, destination: destination, sha1: checksum, isCancelled: isCancelled)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
