import SwiftUI
import DictationCore
import DictationAudio

struct SettingsView: View {
    @ObservedObject var model: AppController
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    BrandMark(size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Brand.name).font(.system(size: 26, weight: .semibold)).tracking(-0.7)
                        Text("Press. Speak. Paste.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                }.padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Shortcut")
                    HStack(spacing: 7) {
                        if model.capturingShortcut {
                            Text("Press your new shortcut…").font(.system(size: 13))
                        } else {
                            ForEach(model.shortcut.label.split(separator: " ").map(String.init), id: \.self) { key in
                                Text(key).font(.system(size: 15, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
                            }
                        }
                        Spacer()
                        Button(model.capturingShortcut ? "Cancel" : "Change") { model.captureShortcut() }
                            .buttonStyle(QuietButtonStyle()).disabled(model.state.isBusy)
                    }
                    Text(model.capturingShortcut ? "Shift + Space, or a key with Control, Option or Command. Escape cancels." : "Press to record. Space to stop and copy.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if !model.shortcutError.isEmpty {
                        Label(model.shortcutError, systemImage: "exclamationmark.circle")
                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("Audio")
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Microphone").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            deviceMenu(input: true)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Speakers").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            deviceMenu(input: false)
                        }
                    }
                    Toggle("Sound when copied", isOn: $model.playSound)
                        .font(.system(size: 12)).toggleStyle(MonoToggleStyle())
                }.disabled(model.state.isBusy)
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        sectionTitle("Transcription")
                        Spacer()
                        Label(model.dependenciesReady ? "Ready" : "Setup needed",
                              systemImage: model.dependenciesReady ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    setupControls
                    HStack {
                        Text("Language").font(.system(size: 12))
                        Spacer()
                        let languages = [("auto", "Auto-detect"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("pt", "Portuguese")]
                        Menu {
                            ForEach(languages, id: \.0) { code, name in
                                Button(name) { model.language = code }
                            }
                        } label: {
                            menuLabel(languages.first { $0.0 == model.language }?.1 ?? model.language)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 170, height: 34)
                            .overlay(menuLabel(languages.first { $0.0 == model.language }?.1 ?? model.language).allowsHitTesting(false))
                            .accessibilityLabel("Language")
                    }
                    DisclosureGroup("Local model & engine", isExpanded: $showAdvanced) {
                        VStack(spacing: 10) {
                            fileRow(title: "Model", path: model.modelPath, action: { model.chooseFile(model: true) })
                            fileRow(title: "Engine", path: model.enginePath, action: { model.chooseFile(model: false) })
                        }.padding(.top, 10).disabled(model.setupBusy)
                    }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.disabled(model.state.isBusy)

                Button { model.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.state == .recording ? "stop.fill" : "mic")
                        Text(model.state == .recording ? "Stop and copy" : model.state == .transcribing ? "Transcribing…" : "Start recording")
                    }.font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 13)
                }.buttonStyle(.plain).foregroundStyle(.white).background(.black, in: RoundedRectangle(cornerRadius: 9))
                    .disabled(!model.dependenciesReady || model.setupBusy || model.state == .starting || model.state == .transcribing || model.capturingShortcut)
                    .opacity(model.state == .starting || model.state == .transcribing || model.capturingShortcut ? 0.5 : 1)

                if !model.lastTranscript.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            sectionTitle("Last dictation")
                            Spacer()
                            Button("Copy") { model.copyAgain() }.buttonStyle(QuietButtonStyle())
                        }
                        Text(model.lastTranscript).font(.system(size: 12)).textSelection(.enabled)
                    }
                }
                Label("Your voice stays on this Mac.", systemImage: "lock")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
            }.padding(28)
        }.foregroundStyle(Palette.ink).tint(.black).background(Palette.background)
            .preferredColorScheme(.light)
            .onAppear { model.refreshSetup() }
    }

    private var setupControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.dependenciesReady {
                Text("Set up once. Then dictate offline.")
                    .font(.system(size: 15, weight: .medium))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.hasEngine ? "Whisper engine found" : "1. Install the Whisper engine")
                            .font(.system(size: 12, weight: .medium))
                        if !model.hasEngine {
                            Text(model.hasHomebrew ? "Uses Homebrew to install." : "Homebrew is needed to install the engine.")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                    }
                    Spacer()
                    if !model.hasEngine {
                        Button(model.hasHomebrew ? "Install engine" : "How to install") {
                            if model.hasHomebrew { model.installEngine() } else { model.openEngineInstructions() }
                        }.buttonStyle(QuietButtonStyle()).disabled(model.setupBusy)
                    }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.hasModel ? "Model found" : "2. Large V3 Turbo")
                            .font(.system(size: 12, weight: .medium))
                        Text(model.hasModel ? URL(fileURLWithPath: model.modelPath).lastPathComponent : "Recommended · 1.5 GiB · Multiple languages")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                    Spacer()
                    if !model.hasModel {
                        Button("Download model") { model.downloadModel() }
                            .buttonStyle(QuietButtonStyle()).disabled(model.setupBusy)
                    }
                }
                if model.setupBusy {
                    if model.setupMessage.hasPrefix("Installing") {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: model.setupProgress).tint(.black)
                        HStack {
                            Text(model.setupProgress >= 1 ? "Verifying download" : "\(Int(model.setupProgress * 100))% downloaded")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Spacer()
                            Button("Cancel") { model.cancelModelDownload() }.buttonStyle(QuietButtonStyle())
                        }
                    }
                } else {
                    Button("Check again") { model.refreshSetup() }.buttonStyle(QuietButtonStyle())
                }
            } else {
                Text(URL(fileURLWithPath: model.modelPath).lastPathComponent)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            if !model.setupMessage.isEmpty {
                Text(model.setupMessage).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.setupError.isEmpty {
                Text(model.setupError).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    private func menuLabel(_ title: String) -> some View {
        HStack {
            Text(title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }.font(.system(size: 12)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border))
    }

    private func deviceMenu(input: Bool) -> some View {
        let devices = input ? model.inputDevices : model.outputDevices
        let uid = input ? model.inputUID : model.outputUID
        let currentName = input ? model.defaultInputName : model.defaultOutputName
        let title = uid.isEmpty ? "Automatic" : devices.first { $0.id == uid }?.name ?? "Disconnected"
        return Menu {
            Button("Automatic · " + currentName) { if input { model.inputUID = "" } else { model.outputUID = "" } }
            ForEach(devices) { device in
                Button(device.name) { if input { model.inputUID = device.id } else { model.outputUID = device.id } }
            }
        } label: { menuLabel(title) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: .infinity).frame(height: 34)
            .overlay(menuLabel(title).allowsHitTesting(false))
            .accessibilityLabel(input ? "Microphone" : "Speakers")
            .help(uid.isEmpty ? "Following macOS: " + currentName : title)
    }

    private func fileRow(title: String, path: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 42, alignment: .leading)
            Text(path.isEmpty ? "Choose a local file" : URL(fileURLWithPath: path).lastPathComponent)
                .lineLimit(1).truncationMode(.middle).help(path)
            Spacer(minLength: 0)
            Button("Choose…", action: action).buttonStyle(QuietButtonStyle())
        }.font(.system(size: 11))
    }
}

struct RecordingPanelView: View {
    @ObservedObject var model: AppController
    var body: some View {
        RecordingPanelContent(state: model.state, levels: model.levels, clock: model.clock,
                              message: model.message, canRetry: model.canRetry,
                              stop: model.stop, cancel: model.cancel, retry: model.retry, settings: model.showSettings)
    }
}

private struct MonoSpinner: View {
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0.1, to: 0.8).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .accessibilityLabel("Working")
    }
}

// Pure presentation also lets the preview render all states without recording.
struct RecordingPanelContent: View {
    let state: SessionState
    var levels: [Double] = []
    var clock = "00:00"
    var message = ""
    var canRetry = false
    var stop: () -> Void = {}
    var cancel: () -> Void = {}
    var retry: () -> Void = {}
    var settings: () -> Void = {}

    var body: some View {
        Group {
            if state == .failed { errorPanel }
            else { activePanel }
        }
        .padding(state == .failed ? 16 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white).tint(.white)
        .background(.black, in: RoundedRectangle(cornerRadius: state == .failed ? 16 : 24))
        .overlay(RoundedRectangle(cornerRadius: state == .failed ? 16 : 24).stroke(.white.opacity(0.15)))
        .padding(2).preferredColorScheme(.dark)
    }

    private var activePanel: some View {
        HStack(spacing: 7) {
            if state == .starting || state == .transcribing {
                MonoSpinner().frame(width: 18, height: 18)
            } else if state == .copied {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            } else {
                BrandMark(size: 18)
            }
            if state == .recording {
                Text(clock).font(.system(size: 11, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach(Array(levels.suffix(12).enumerated()), id: \.offset) { _, value in
                        Capsule().fill(.white.opacity(value > 0.12 ? 1 : 0.35))
                            .frame(width: 3, height: max(3, min(22, value * 22)))
                    }
                }.frame(width: 69, height: 22)
                    .animation(.easeOut(duration: 0.08), value: levels)
                    .accessibilityLabel("Microphone level")
                Spacer(minLength: 0)
                Button(action: stop) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                        .frame(width: 28, height: 28).background(.white.opacity(0.16), in: Circle())
                }.buttonStyle(.plain).help("Stop and copy").accessibilityLabel("Stop and copy")
            } else {
                Text(state == .copied ? "Copied" : state == .starting ? "Preparing…" : "Transcribing…")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6)).frame(width: 18, height: 28)
            }.buttonStyle(.plain).help(state == .copied ? "Dismiss" : "Cancel")
                .accessibilityLabel(state == .copied ? "Dismiss" : "Cancel")
        }
    }

    private var errorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dictation needs attention", systemImage: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            HStack {
                if canRetry { Button("Retry", action: retry) }
                Button("Settings", action: settings)
                Spacer()
                Button("Dismiss", action: cancel)
            }.buttonStyle(.bordered).font(.system(size: 12))
        }
    }
}
