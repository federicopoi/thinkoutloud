import AVFoundation
import AudioToolbox
import DictationCore

enum AudioConfigurationPolicy {
    enum Action { case ignore, restart, interrupt }
    static func action(engineRunning: Bool, microphoneAvailable: Bool) -> Action {
        guard microphoneAvailable else { return .interrupt }
        return engineRunning ? .ignore : .restart
    }
}

/// The audio callback owns the writer under this lock; stopping capture closes it safely.
private final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var duration: Double = 0
    private var voiced: Double = 0
    private var failure: Error?
    private var lastMeterTime: Double = 0
    private var converter: AVAudioConverter?
    private let meter: (Double) -> Void

    init(file: AVAudioFile, meter: @escaping (Double) -> Void) { self.file = file; self.meter = meter }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let file else { lock.unlock(); return }
        do {
            if buffer.format == file.processingFormat { try file.write(from: buffer) }
            else {
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
                }
                guard let converter else { throw DictationError.message("The microphone's new format cannot be converted.") }
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * file.processingFormat.sampleRate / buffer.format.sampleRate)) + 128
                let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                if let error { throw error }
                if status == .error { throw DictationError.message("The microphone format changed and conversion failed.") }
                if converted.frameLength > 0 { try file.write(from: converted) }
            }
        }
        catch { failure = error }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        duration += seconds
        var rms: Double = 0
        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            // Take the loudest channel so stereo microphones work with either channel.
            for channel in 0..<Int(buffer.format.channelCount) {
                var sum: Double = 0
                for index in 0..<Int(buffer.frameLength) { let sample = Double(channels[channel][index]); sum += sample * sample }
                rms = max(rms, sqrt(sum / Double(buffer.frameLength)))
            }
        }
        if rms > 0.003 { voiced += seconds }
        let shouldMeter = duration - lastMeterTime >= 0.045
        if shouldMeter { lastMeterTime = duration }
        lock.unlock()
        if shouldMeter { meter(min(1, max(0, (20 * log10(max(rms, 0.00001)) + 60) / 54))) }
    }

    func close() throws -> RecordingStats {
        lock.lock()
        defer { lock.unlock() }
        file = nil
        if let failure { throw failure }
        return RecordingStats(duration: duration, voicedDuration: voiced)
    }
}

public final class Recorder {
    private var engine: AVAudioEngine?
    private var sink: CaptureSink?
    private var configurationObserver: NSObjectProtocol?
    private var selectedUID: String?
    private var recoveryScheduled = false
    private var generation = UUID()

    public init() {}

    public func start(device: AudioDevice?, destination: URL, meter: @escaping (Double) -> Void, interrupted: @escaping () -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            guard let unit = input.audioUnit else { throw DictationError.message("The microphone could not be opened.") }
            var id = device.deviceID
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard result == noErr else { throw DictationError.message("Could not select \(device.name) (\(result)). Reconnect it or choose another microphone.") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.message("The microphone is unavailable. Reconnect it or choose another input.") }
        var fileSettings = format.settings
        fileSettings.removeValue(forKey: "AVLinearPCMIsNonInterleaved")
        let writer = try AVAudioFile(forWriting: destination, settings: fileSettings)
        let sink = CaptureSink(file: writer, meter: meter)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        self.engine = engine
        self.sink = sink
        self.selectedUID = device?.id
        generation = UUID()
        // Apple's notification may come from the engine's internal queue. Never
        // stop or destroy the engine within the notification delivery itself.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self, weak engine] _ in
            DispatchQueue.main.async { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
                self.configurationChanged(engine: engine, interrupted: interrupted)
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { cancel(); throw error }
    }

    public func stop() throws -> RecordingStats {
        guard let engine, let sink else { throw DictationError.message("No recording is active.") }
        removeObserver()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.sink = nil
        return try sink.close()
    }

    public func cancel() {
        removeObserver()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        _ = try? sink?.close()
        sink = nil
    }

    private func removeObserver() {
        generation = UUID()
        recoveryScheduled = false
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    private var microphoneAvailable: Bool {
        let devices = AudioDevices.list(input: true)
        if let selectedUID { return devices.contains { $0.id == selectedUID } }
        return !devices.isEmpty
    }

    private func configurationChanged(engine: AVAudioEngine, interrupted: @escaping () -> Void) {
        switch AudioConfigurationPolicy.action(engineRunning: engine.isRunning, microphoneAvailable: microphoneAvailable) {
        case .ignore: return
        case .interrupt: interrupted()
        case .restart:
            guard !recoveryScheduled else { return }
            recoveryScheduled = true
            restartAfterRouteChange(engine: engine, generation: generation, attempt: 0, interrupted: interrupted)
        }
    }

    private func restartAfterRouteChange(engine: AVAudioEngine, generation: UUID, attempt: Int, interrupted: @escaping () -> Void) {
        // Bluetooth devices can briefly report no format while switching to
        // their microphone profile. Bound retries and let the route settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine, self.generation == generation, let sink = self.sink else { return }
            guard self.microphoneAvailable else { self.recoveryScheduled = false; interrupted(); return }
            if engine.isRunning { self.recoveryScheduled = false; return }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            do {
                guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.message("Waiting for microphone format") }
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
                engine.prepare()
                try engine.start()
                self.recoveryScheduled = false
            } catch {
                if attempt < 4 { self.restartAfterRouteChange(engine: engine, generation: generation, attempt: attempt + 1, interrupted: interrupted) }
                else { self.recoveryScheduled = false; interrupted() }
            }
        }
    }
}

public enum AudioConversion {
    public static func toWhisperWAV(source: URL, destination: URL, isCancelled: @escaping () -> Bool = { false }) throws {
        if isCancelled() { throw DictationError.cancelled }
        let input = try AVAudioFile(forReading: source)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
            throw DictationError.message("This microphone's audio format cannot be converted for Whisper.")
        }
        let output = try AVAudioFile(forWriting: destination, settings: outputFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096)!
        var readFailure: Error?
        while true {
            if isCancelled() { throw DictationError.cancelled }
            var failure: NSError?
            let status = converter.convert(to: outputBuffer, error: &failure) { requestedFrames, inputStatus in
                if isCancelled() { readFailure = DictationError.cancelled; inputStatus.pointee = .endOfStream; return nil }
                guard input.framePosition < input.length else { inputStatus.pointee = .endOfStream; return nil }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: requestedFrames) else { inputStatus.pointee = .endOfStream; return nil }
                do { try input.read(into: buffer, frameCount: requestedFrames) }
                catch { readFailure = error; inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return buffer
            }
            if let readFailure { throw readFailure }
            if let failure { throw failure }
            if isCancelled() { throw DictationError.cancelled }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
            if status == .endOfStream { break }
            if status == .error { throw DictationError.message("Audio conversion failed. Please record again.") }
        }
        succeeded = true
    }
}
