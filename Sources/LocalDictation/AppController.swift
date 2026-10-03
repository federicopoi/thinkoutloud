import AppKit
import SwiftUI
import AVFoundation
import DictationCore
import DictationAudio

final class AppController: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published var level: Double = 0
    @Published var levels: [Double] = Array(repeating: 0, count: 25)
    @Published var elapsed: Double = 0
    @Published var message = "Ready when you are"
    @Published var lastTranscript = ""
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var inputUID: String { didSet { defaults.set(inputUID, forKey: "inputUID") } }
    @Published var outputUID: String { didSet { defaults.set(outputUID, forKey: "outputUID") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var modelPath: String { didSet { defaults.set(modelPath, forKey: "modelPath") } }
    @Published var enginePath: String { didSet { defaults.set(enginePath, forKey: "enginePath") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published private(set) var shortcut: Shortcut
    @Published var shortcutError = ""
    @Published var capturingShortcut = false
    @Published private(set) var spaceStopAvailable = false
    @Published private(set) var defaultInputName = "System microphone"
    @Published private(set) var defaultOutputName = "System speakers"
    @Published var setupBusy = false
    @Published var setupProgress: Double = 0
    @Published var setupMessage = ""
    @Published var setupError = ""
    private var modelDownload: ModelDownload?
    private var engineInstall: Process?
    var onStateChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let discoverDependencies: Bool
    private let recorder = Recorder()
    private var workspace: SessionWorkspace?
    private var runner: WhisperRunner?
    private var sessionID = UUID()
    private var timer: Timer?
    private var startTime: Date?
    private var sound: NSSound?
    private var shortcutMonitor: Any?
    private var audioDeviceObserver: AudioDeviceObserver?
    private var recordingStopHotkey: HotkeyManager?
    private var settingsWindow: NSWindow?
    private var panel: NSPanel?
    private lazy var hotkey = HotkeyManager { [weak self] in
        DispatchQueue.main.async { self?.toggle() }
    }

    init(defaults: UserDefaults = .standard, discoverDependencies: Bool = true) {
        self.defaults = defaults
        self.discoverDependencies = discoverDependencies
        AutomaticPreferences.migrate(in: defaults)
        AutomaticPreferences.useShiftSpaceShortcut(in: defaults)
        inputUID = defaults.string(forKey: "inputUID") ?? ""
        outputUID = defaults.string(forKey: "outputUID") ?? ""
        language = defaults.string(forKey: "language") ?? "auto"
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        modelPath = discoverDependencies ? SetupDiscovery.model(saved: defaults.string(forKey: "modelPath") ?? "") : ""
        enginePath = discoverDependencies ? SetupDiscovery.engine(saved: defaults.string(forKey: "enginePath") ?? "") : ""
        if let data = defaults.data(forKey: "shortcut"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data), saved.isValid {
            shortcut = saved
        } else { shortcut = .defaultShortcut }
        SessionWorkspace.cleanupStaleSessions()
        refreshDevices()
        audioDeviceObserver = AudioDeviceObserver { [weak self] in
            self?.refreshDevices()
            self?.onStateChanged?()
        }
    }

    var dependenciesReady: Bool {
        FileManager.default.isExecutableFile(atPath: enginePath) && SetupDiscovery.isModel(modelPath)
    }
    var canRetry: Bool {
        guard state == .failed, let workspace else { return false }
        return FileManager.default.isReadableFile(atPath: workspace.captureURL.path) || FileManager.default.isReadableFile(atPath: workspace.audioURL.path)
    }
    var clock: String { String(format: "%02d:%02d", Int(elapsed) / 60, Int(elapsed) % 60) }

    func registerShortcut() {
        do { try hotkey.register(shortcut) }
        catch { shortcutError = error.localizedDescription; showSettings() }
    }

    func changeShortcut(_ value: Shortcut) {
        do {
            try hotkey.register(value)
            shortcut = value
            defaults.set(try JSONEncoder().encode(value), forKey: "shortcut")
            shortcutError = ""
            onStateChanged?()
        } catch { shortcutError = error.localizedDescription }
    }

    func captureShortcut() {
        if capturingShortcut { stopCapturingShortcut(); return }
        capturingShortcut = true
        shortcutError = ""
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stopCapturingShortcut(); return nil }
            let value = Shortcut.from(event)
            guard value.isValid else { self.shortcutError = "Use Shift + Space, or a key with Control, Option or Command."; return nil }
            self.stopCapturingShortcut()
            self.changeShortcut(value)
            return nil
        }
    }

    func stopCapturingShortcut() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        capturingShortcut = false
    }

    func refreshDevices() {
        inputDevices = AudioDevices.list(input: true)
        outputDevices = AudioDevices.list(input: false)
        defaultInputName = AudioDevices.currentDefault(input: true)?.name ?? "System microphone"
        defaultOutputName = AudioDevices.currentDefault(input: false)?.name ?? "System speakers"
    }

    func toggle() {
        guard !capturingShortcut else { return }
        if state == .recording { stop() }
        else if !state.isBusy { start() }
    }

    func start() {
        guard !state.isBusy else { return }
        if setupBusy { showSettings(); return }
        workspace?.cleanup(); workspace = nil
        runner = nil
        sessionID = UUID()
        let id = sessionID
        _ = state.apply(.start)
        message = "Preparing microphone…"
        elapsed = 0; level = 0; levels = Array(repeating: 0, count: 25)
        notify(); showPanel()
        guard dependenciesReady else {
            fail("Choose your local Whisper engine and model in Settings before recording.")
            showSettings()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: beginRecording(id: id)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == id, self.state == .starting else { return }
                    if granted { self.beginRecording(id: id) }
                    else { self.permissionDenied() }
                }
            }
        default: permissionDenied()
        }
    }

    private func permissionDenied() {
        fail("Microphone access is off. Open System Settings → Privacy & Security → Microphone and enable Think Out Loud, then try again.")
    }

    private func beginRecording(id: UUID) {
        guard sessionID == id, state == .starting else { return }
        do {
            refreshDevices()
            let selected = inputDevices.first { $0.id == inputUID }
            if !inputUID.isEmpty, selected == nil { throw DictationError.message("Your selected microphone is disconnected. Choose another microphone from the menu bar.") }
            let workspace = try SessionWorkspace()
            self.workspace = workspace
            try recorder.start(device: selected, destination: workspace.captureURL, meter: { [weak self] value in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == id, self.state == .recording else { return }
                    self.level = value
                    self.levels.removeFirst(); self.levels.append(value)
                }
            }, interrupted: { [weak self] in
                guard let self, self.sessionID == id, self.state == .recording else { return }
                self.handleInputChange()
            })
            _ = state.apply(.ready)
            message = "Listening"
            startTime = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let startTime = self.startTime, self.state == .recording else { return }
                self.elapsed = Date().timeIntervalSince(startTime)
                if self.elapsed >= 1800 { self.stop() }
            }
            notify(); showPanel()
        } catch { recorder.cancel(); workspace?.cleanup(); workspace = nil; fail(error.localizedDescription) }
    }

    func stop() {
        guard state == .recording else { return }
        recordingStopHotkey = nil; spaceStopAvailable = false
        timer?.invalidate(); timer = nil
        do {
            let stats = try recorder.stop()
            do { try stats.validate() }
            catch { workspace?.cleanup(); workspace = nil; throw error }
            _ = state.apply(.stop)
            transcribe()
        } catch { fail(error.localizedDescription) }
    }

    private func handleInputChange() {
        timer?.invalidate(); timer = nil
        refreshDevices()
        let disconnected = !inputUID.isEmpty && !inputDevices.contains { $0.id == inputUID }
        let explanation = disconnected ? "Your microphone disconnected." : "Your audio device changed during recording."
        do {
            let stats = try recorder.stop()
            try stats.validate()
            fail("\(explanation) Recording stopped. Reconnect it or choose another microphone. Retry transcribes the audio already recorded; Dismiss deletes it.")
        } catch {
            recorder.cancel()
            workspace?.cleanup(); workspace = nil
            fail("\(explanation) Reconnect it or choose another microphone, then start again. \(error.localizedDescription)")
        }
    }

    func retry() {
        guard canRetry, state.apply(.retry) else { return }
        transcribe()
    }

    private func transcribe() {
        guard let workspace else { fail("The recording is unavailable. Please start again."); return }
        let id = sessionID
        let runner = WhisperRunner()
        self.runner = runner
        let engine = URL(fileURLWithPath: enginePath)
        let model = URL(fileURLWithPath: modelPath)
        let language = self.language
        message = "Transcribing on your Mac…"
        level = 0
        notify(); showPanel()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String, Error>
            do {
                if !FileManager.default.fileExists(atPath: workspace.audioURL.path) {
                    try AudioConversion.toWhisperWAV(source: workspace.captureURL, destination: workspace.audioURL, isCancelled: { runner.isCancelled })
                }
                result = .success(try runner.transcribe(executable: engine, model: model, audio: workspace.audioURL, language: language, workspace: workspace.url))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self, self.sessionID == id, self.state == .transcribing else { workspace.cleanup(); return }
                self.runner = nil
                switch result {
                case .success(let text):
                    self.lastTranscript = text
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    _ = self.state.apply(.success)
                    self.message = "Copied · Paste with ⌘V"
                    workspace.cleanup(); self.workspace = nil
                    self.playConfirmation()
                    self.notify(); self.showPanel()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        if self.sessionID == id, self.state == .copied { self.panel?.orderOut(nil) }
                    }
                case .failure(let error): self.fail(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        sessionID = UUID()
        timer?.invalidate(); timer = nil
        recorder.cancel()
        runner?.cancel(); runner = nil
        workspace?.cleanup(); workspace = nil
        _ = state.apply(.cancel)
        level = 0
        message = "Ready when you are"
        panel?.orderOut(nil)
        notify()
    }

    func shutdown() {
        modelDownload?.cancel()
        engineInstall?.terminate()
        runner?.cancel(force: true)
        cancel()
        stopCapturingShortcut()
        audioDeviceObserver = nil
    }

    private func fail(_ text: String) {
        _ = state.apply(.failure)
        message = text
        notify(); showPanel()
    }

    private func notify() {
        if state.usesSpaceToStop {
            if recordingStopHotkey == nil {
                let manager = HotkeyManager { [weak self] in
                    DispatchQueue.main.async { self?.stop() }
                }
                do {
                    try manager.registerRecordingStop()
                    recordingStopHotkey = manager
                    spaceStopAvailable = true
                } catch {
                    spaceStopAvailable = false
                    shortcutError = "Space to stop is unavailable. Use your recording shortcut or the Stop button."
                }
            }
        } else {
            recordingStopHotkey = nil
            spaceStopAvailable = false
        }
        onStateChanged?()
    }

    func copyAgain() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    private func playConfirmation() {
        guard playSound else { return }
        sound = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true)
        if !outputUID.isEmpty { sound?.playbackDeviceIdentifier = outputUID }
        sound?.volume = 0.35
        sound?.play()
    }

    var hasModel: Bool { SetupDiscovery.isModel(modelPath) }
    var hasEngine: Bool { FileManager.default.isExecutableFile(atPath: enginePath) }
    var hasHomebrew: Bool { SetupDiscovery.homebrew != nil }

    func refreshSetup() {
        guard !setupBusy, discoverDependencies else { return }
        modelPath = SetupDiscovery.model(saved: modelPath)
        enginePath = SetupDiscovery.engine(saved: enginePath)
        onStateChanged?()
    }

    func downloadModel() {
        guard !setupBusy, !state.isBusy else { return }
        setupBusy = true; setupProgress = 0; setupError = ""
        setupMessage = "Downloading Large V3 Turbo…"
        modelDownload = ModelDownload(progress: { [weak self] progress in
            self?.setupProgress = progress
            if progress >= 1 { self?.setupMessage = "Checking model…" }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.setupBusy = false; self.modelDownload = nil
            switch result {
            case .success(let url):
                self.modelPath = url.path
                self.setupMessage = "Large V3 Turbo is ready."
            case .failure(let error):
                self.setupMessage = ""
                if (error as NSError).code != NSURLErrorCancelled && !(error is CancellationError) {
                    self.setupError = error.localizedDescription
                }
            }
            self.onStateChanged?()
        })
        modelDownload?.start()
    }

    func cancelModelDownload() { modelDownload?.cancel() }

    func installEngine() {
        guard !setupBusy, !state.isBusy, let brew = SetupDiscovery.homebrew else { return }
        setupBusy = true; setupError = ""; setupProgress = 0
        setupMessage = "Installing the Whisper engine…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "whisper.cpp"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        // A file avoids a full pipe blocking Homebrew while it installs dependencies.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkOutLoud-engine-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: log) else {
            setupBusy = false; setupError = "Could not create an installation log."; return
        }
        process.standardOutput = output; process.standardError = output
        process.terminationHandler = { [weak self] process in
            try? output.close()
            try? FileManager.default.removeItem(at: log)
            DispatchQueue.main.async {
                guard let self else { return }
                self.setupBusy = false; self.engineInstall = nil
                self.refreshSetup()
                self.setupMessage = ""
                if process.terminationStatus == 0 && self.hasEngine {
                    self.setupMessage = "Whisper engine is ready."
                } else {
                    self.setupError = "Engine installation failed. Try running brew install whisper.cpp in Terminal, then click Check again."
                }
            }
        }
        engineInstall = process
        do { try process.run() }
        catch {
            try? output.close(); try? FileManager.default.removeItem(at: log)
            engineInstall = nil; setupBusy = false; setupMessage = ""; setupError = error.localizedDescription
        }
    }

    func openEngineInstructions() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install whisper.cpp", forType: .string)
        NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
        setupMessage = "Install Homebrew from brew.sh, then paste brew install whisper.cpp into Terminal. Click Check again when done."
    }

    func chooseFile(model: Bool) {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.title = model ? "Choose a Whisper ggml model (.bin)" : "Choose whisper-cli"
        chooser.message = model ? "Select an existing local model, such as Vibe's ggml-large-v3-turbo.bin." : "Homebrew usually installs this at /opt/homebrew/bin/whisper-cli."
        if model {
            chooser.directoryURL = URL(fileURLWithPath: modelPath.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : modelPath).deletingLastPathComponent()
        } else { chooser.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin") }
        if chooser.runModal() == .OK, let url = chooser.url {
            if model {
                guard SetupDiscovery.isModel(url.path) else {
                    setupError = "Choose a Whisper ggml model in .bin format."; return
                }
                modelPath = url.path
            } else { enginePath = url.path }
            setupError = ""
            onStateChanged?()
        }
    }

    func showSettings() {
        refreshSetup()
        refreshDevices()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Brand.settingsSize.width, height: Brand.settingsSize.height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = Brand.name
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = NSHostingView(rootView: SettingsView(model: self))
            window.center()
            settingsWindow = window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in self?.stopCapturingShortcut() }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPanel() {
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isMovableByWindowBackground = true
            panel.appearance = NSAppearance(named: .aqua)
            panel.contentView = NSHostingView(rootView: RecordingPanelView(model: self))
            self.panel = panel
        }
        let size = Brand.panelSize(failed: state == .failed)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            panel?.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 16, width: size.width, height: size.height), display: true)
        }
        panel?.orderFrontRegardless()
    }
}
