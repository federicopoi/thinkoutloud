import AppKit
import SwiftUI
import AVFoundation
import DictationCore
import DictationAudio

// Native visual checks: no microphone, clipboard or simulated key events.
func renderPreview<V: View>(_ view: V, size: NSSize, destination: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: view)
    let rect = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = rect
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    do {
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
        print("Rendered: \(destination)")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppController!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let identifier = Bundle.main.bundleIdentifier ?? "com.fedepoi.localdictation"
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if duplicate { NSApp.terminate(nil); return }
        model = AppController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = brandMenuIcon()
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Think Out Loud · \(model.shortcut.label)"
        model.onStateChanged = { [weak self] in self?.updateMenu() }
        updateMenu()
        model.registerShortcut()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--settings") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            model.showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model?.showSettings(); return true }
    func menuWillOpen(_ menu: NSMenu) { model.refreshDevices(); rebuild(menu) }

    private func updateMenu() {
        statusItem.button?.image = model.state == .transcribing ? NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Transcribing") : brandMenuIcon()
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = "Think Out Loud · \(model.shortcut.label)"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild(menu)
        statusItem.menu = menu
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let heading = menu.addItem(withTitle: "Think Out Loud · On-device", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        let title = model.state == .recording ? "Stop and Copy" : model.state == .transcribing ? "Transcribing…" : model.state == .starting ? "Preparing Microphone…" : "Start Recording"
        let toggle = menu.addItem(withTitle: "\(title)    \(model.shortcut.label)", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = model.state != .starting && model.state != .transcribing
        if model.state.isBusy || model.canRetry {
            let cancel = menu.addItem(withTitle: "Cancel", action: #selector(cancelRecording), keyEquivalent: "")
            cancel.target = self
        }
        menu.addItem(.separator())
        addDevices(menu, title: "Microphone", devices: model.inputDevices, selected: model.inputUID, action: #selector(selectInput(_:)))
        addDevices(menu, title: "Speakers", devices: model.outputDevices, selected: model.outputUID, action: #selector(selectOutput(_:)))
        menu.addItem(.separator())
        if !model.lastTranscript.isEmpty { menu.addItem(withTitle: "Copy Last Dictation", action: #selector(copyAgain), keyEquivalent: "").target = self }
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Think Out Loud", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func addDevices(_ parent: NSMenu, title: String, devices: [AudioDevice], selected: String, action: Selector) {
        let item = parent.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        item.submenu = submenu
        item.isEnabled = !model.state.isBusy
        let defaultItem = submenu.addItem(withTitle: "System Default", action: action, keyEquivalent: "")
        defaultItem.representedObject = ""; defaultItem.target = self; defaultItem.state = selected.isEmpty ? .on : .off
        for device in devices {
            let choice = submenu.addItem(withTitle: device.name, action: action, keyEquivalent: "")
            choice.representedObject = device.id; choice.target = self; choice.state = selected == device.id ? .on : .off
        }
    }

    @objc private func toggleRecording() { model.toggle() }
    @objc private func cancelRecording() { model.cancel() }
    @objc private func selectInput(_ item: NSMenuItem) { model.inputUID = item.representedObject as? String ?? "" }
    @objc private func selectOutput(_ item: NSMenuItem) { model.outputUID = item.representedObject as? String ?? "" }
    @objc private func settings() { model.showSettings() }
    @objc private func copyAgain() { model.copyAgain() }
    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--check-shortcut-options") {
    for shortcut in [Shortcut.defaultShortcut, Shortcut(keyCode: 49, modifiers: 2048, label: "Option + Space"), Shortcut(keyCode: 36, modifiers: 4096, label: "Control + Return"), Shortcut(keyCode: 36, modifiers: 2048, label: "Option + Return")] {
        do {
            let manager = HotkeyManager(onPress: {})
            try manager.register(shortcut)
            withExtendedLifetime(manager) { print("Available: \(shortcut.label)") }
        } catch { print("Unavailable: \(shortcut.label): \(error.localizedDescription)") }
    }
} else if CommandLine.arguments.contains("--check-stop-space") {
    do {
        var first: HotkeyManager? = HotkeyManager(onPress: {})
        try first!.registerRecordingStop()
        let second = HotkeyManager(onPress: {})
        var conflicted = false
        do { try second.registerRecordingStop() } catch { conflicted = true }
        guard conflicted else { throw DictationError.message("Space collision was not detected") }
        first = nil
        try second.registerRecordingStop()
        print("PASS: plain Space registered, collision detected, released and registered again")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--render-panel" {
    guard let state = SessionState(rawValue: CommandLine.arguments[2]), [.starting, .recording, .transcribing, .copied, .failed].contains(state) else {
        fputs("Choose starting, recording, transcribing, copied or failed.\n", stderr); exit(1)
    }
    renderPreview(RecordingPanelContent(state: state, levels: [0.1, 0.3, 0.7, 0.9, 0.4, 0.2, 0.4, 0.8, 0.6, 0.3, 0.2, 0.1], clock: "00:08", message: "Your microphone disconnected. Reconnect it or choose another microphone. Retry transcribes the audio already recorded; Dismiss deletes it.", canRetry: true), size: Brand.panelSize(failed: state == .failed), destination: CommandLine.arguments[3])
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-logo" {
    renderPreview(BrandMark(size: 300).foregroundStyle(.black).frame(maxWidth: .infinity, maxHeight: .infinity).background(.white), size: NSSize(width: 512, height: 512), destination: CommandLine.arguments[2])
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-design" {
    // Render the actual settings view without recording, clipboard writes or visible windows.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: .aqua)
    let model = AppController()
    let host = NSHostingView(rootView: SettingsView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Brand.settingsSize.width, height: Brand.settingsSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: Brand.settingsSize.width, height: Brand.settingsSize.height)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    do {
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("Rendered settings: \(CommandLine.arguments[2])")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-recording") {
    // Local, ephemeral hardware check; never requests or changes OS permission.
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
        fputs("Microphone permission must be granted to Think Out Loud before this check.\n", stderr)
        exit(2)
    }
    do {
        let workspace = try SessionWorkspace()
        defer { workspace.cleanup() }
        let recorder = Recorder()
        let uid = UserDefaults.standard.string(forKey: "inputUID") ?? ""
        let selected = AudioDevices.list(input: true).first { $0.id == uid }
        var interruptions = 0
        var meterUpdates = 0
        try recorder.start(device: selected, destination: workspace.captureURL, meter: { _ in meterUpdates += 1 }, interrupted: { interruptions += 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let stats = try recorder.stop()
        guard stats.duration >= 2.5, interruptions == 0 else {
            throw DictationError.message("Capture failed: \(stats.duration) seconds of audio, \(interruptions) interruptions")
        }
        print("PASS: \(selected?.name ?? "system default"), \(String(format: "%.2f", stats.duration)) seconds, \(meterUpdates) real meter updates, no interruptions")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-hotkey") {
    do {
        let first = HotkeyManager(onPress: {})
        try first.register(.defaultShortcut)
        let second = HotkeyManager(onPress: {})
        var conflicted = false
        do { try second.register(.defaultShortcut) }
        catch { conflicted = true }
        guard conflicted else { throw DictationError.message("Collision was not detected") }
        withExtendedLifetime((first, second)) { print("PASS: Global shortcut registered; collision rejected") }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--check-devices") {
    for device in AudioDevices.list(input: true) { print("Input: \(device.name)") }
    for device in AudioDevices.list(input: false) { print("Output: \(device.name)") }
} else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--check-audio" {
    do {
        try AudioConversion.toWhisperWAV(source: URL(fileURLWithPath: CommandLine.arguments[2]), destination: URL(fileURLWithPath: CommandLine.arguments[3]))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[3]))
        guard file.fileFormat.sampleRate == 16000, file.fileFormat.channelCount == 1, file.fileFormat.commonFormat == .pcmFormatInt16 else { throw DictationError.message("Wrong WAV format") }
        print("PASS: \(file.length) frames, 16000 Hz, mono, PCM16")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
