import Testing
import Foundation
import AVFoundation
import DictationCore
@testable import DictationAudio

struct AudioTests {
    @Test func healthyEngineConfigurationNotificationDoesNotInterruptRecording() {
        #expect(AudioConfigurationPolicy.action(engineRunning: true, microphoneAvailable: true) == .ignore)
    }

    @Test func bluetoothRouteChangeRestartsEngineWhileMicrophoneIsStillConnected() {
        #expect(AudioConfigurationPolicy.action(engineRunning: false, microphoneAvailable: true) == .restart)
    }

    @Test func actualMicrophoneDisconnectionStillReportsInterruption() {
        #expect(AudioConfigurationPolicy.action(engineRunning: false, microphoneAvailable: false) == .interrupt)
    }
    @Test func stereoCaptureConvertsToMonoPCM16AndPreservesDuration() throws {
        let workspace = try SessionWorkspace()
        defer { workspace.cleanup() }
        try makeStereoFixture(at: workspace.captureURL)
        try AudioConversion.toWhisperWAV(source: workspace.captureURL, destination: workspace.audioURL)
        let file = try AVAudioFile(forReading: workspace.audioURL)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(abs(Int(file.length) - 16000) <= 2)
    }

    @Test func cancellationDuringConversionDeletesPartialWAV() throws {
        let workspace = try SessionWorkspace()
        defer { workspace.cleanup() }
        try makeStereoFixture(at: workspace.captureURL)
        var checks = 0
        var cancelled = false
        do {
            try AudioConversion.toWhisperWAV(source: workspace.captureURL, destination: workspace.audioURL, isCancelled: {
                checks += 1
                return checks >= 3
            })
        } catch { cancelled = error as? DictationError == .cancelled }
        #expect(cancelled)
        #expect(!FileManager.default.fileExists(atPath: workspace.audioURL.path))
    }

    private func makeStereoFixture(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for i in 0..<48000 {
            let sample = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.2
            buffer.floatChannelData![0][i] = sample
            buffer.floatChannelData![1][i] = sample
        }
        var settings = format.settings
        settings.removeValue(forKey: "AVLinearPCMIsNonInterleaved")
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }
}
