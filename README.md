# Think Out Loud

A free, open-source dictation app for Mac. Press a shortcut, say what’s on your mind, and paste the text wherever you need it.

Think Out Loud records your microphone and transcribes it locally using [Whisper](https://github.com/openai/whisper) through [whisper.cpp](https://github.com/ggml-org/whisper.cpp). Once the engine and model are installed, it works without an internet connection. No account or subscription.

## How it works

1. Press **Shift + Space** to start recording.
2. Speak. A small floating bar shows your microphone level and recording time while you keep using your Mac.
3. Press **Space** to stop, or use the bar’s Stop button. Shift + Space also stops recording.
4. Wait for **Copied**, then press **Command + V** to paste.

The × button cancels the recording without changing your clipboard. **Copy Last Dictation** in the menu bar lets you copy the last successful result again.

## Get started

You need macOS 13 or later, Apple’s command-line developer tools, a `whisper-cli` executable, and a compatible Whisper model in `.bin` format. This app has been built and tested on Apple Silicon; Intel Macs have not been verified.

### 1. Install the tools

If you don’t have Apple’s developer tools, run:

```sh
xcode-select --install
```

With [Homebrew](https://brew.sh) installed, install the transcription engine:

```sh
brew install whisper.cpp
```

You can also [build whisper.cpp from source](https://github.com/ggml-org/whisper.cpp#quick-start).

### 2. Download a model

Think Out Loud checks its own model folder, Vibe’s folder, Downloads, Documents, and `~/whisper.cpp/models` for compatible `.bin` models. It keeps your selected model when it is still available.

If no model is found, open Settings and click **Download model**. This downloads **Large V3 Turbo** (about 1.5 GiB), shows progress, checks the file against its published checksum, and selects it automatically. You can cancel and retry. The model is saved in `~/Library/Application Support/ThinkOutLoud/models`.

For another model, use **Local model & engine → Model** to select a download from the [whisper.cpp model collection](https://huggingface.co/ggerganov/whisper.cpp/tree/main). Choose a multilingual model for automatic language detection; English-only models have `.en` in their names.

The engine and model are separate downloads and are not included in this repository. Settings offers **Install engine** if Homebrew is available. If it isn’t, **How to install** opens Homebrew’s instructions and copies `brew install whisper.cpp` for you to run in Terminal. Click **Check again** after installing.

### 3. Build and install the app

```sh
git clone https://github.com/federicopoi/thinkoutloud.git
cd thinkoutloud
bash scripts/build.sh
bash scripts/install.sh
open "$HOME/Applications/Think Out Loud.app"
```

The build script creates `dist/Think Out Loud.app`. The install script copies it to your user Applications folder. Quit the app from its menu bar before installing an update.

This is a locally signed build, without Apple notarization. If macOS blocks it, use **Open Anyway** under **System Settings → Privacy & Security** after trying to open it.

### 4. Choose your engine and model

Open **Settings** from the menu bar. Under **Local model & engine**, choose your `whisper-cli` executable and downloaded model if they weren’t found automatically. Allow microphone access when macOS asks.

## Settings

- **Shortcut:** Shift + Space is the default. Click **Change** to choose another shortcut. Space stops recording only while dictation is active.
- **Microphone and speakers:** Automatic follows the devices selected by macOS, including switches to and from earbuds. You can also choose a specific device. Speakers are used for the optional completion sound; the app records your microphone, not system audio.
- **Language:** Auto-detect is the default. You can select English, Spanish, French, German, or Portuguese instead. Dictation keeps the spoken language rather than translating it into English.
- **Launch at login:** Add the app under **System Settings → General → Login Items**.

Closing Settings leaves the menu bar app running. Use **Quit** in its menu to exit. No Accessibility or Input Monitoring permission is required.

## Your recordings

Dictation runs locally and makes no network requests. Setup connects to Hugging Face only when you click **Download model**; installing the engine through Homebrew also requires internet. The app has no telemetry or history database. Transcription starts after you stop recording; its speed depends on your Mac, model, and recording length. Recordings are limited to 30 minutes.

Successful dictation and cancellation delete the temporary audio. If transcription fails, the app keeps the recording available for **Retry** until you dismiss the error or quit. It cleans up leftover recordings from a crash the next time it opens.

The last successful transcript stays in memory until you quit. Copied text stays on the system clipboard and may also be saved by a clipboard manager. Silence, cancellation, and errors leave the clipboard unchanged. The app copies text; you paste it yourself.

## Development

The app uses SwiftUI, AppKit, AVFoundation, Core Audio, and Carbon. It has no Swift package dependencies. The internal executable target is named `LocalDictation`; the installed app is **Think Out Loud**.

```sh
bash scripts/test.sh
bash scripts/build.sh
```

The test script supports both Xcode and the standalone Command Line Tools. Tests cover session handling, shortcuts, preferences, audio conversion, transcription failures, cancellation, and cleanup. Hardware recording and global shortcuts should also be checked on a Mac.

| Directory | Contents |
| --- | --- |
| `Sources/LocalDictation` | Menu bar app, settings, recording bar, and shortcuts |
| `Sources/DictationAudio` | Audio devices, recording, and WAV conversion |
| `Sources/DictationCore` | Session state, preferences, temporary files, and Whisper process |
| `Tests` | Core and audio tests |
| `resources` | App metadata and microphone entitlement |
| `scripts` | Build, test, install, and icon generation |

Bug reports and pull requests are welcome. For audio problems, include your macOS version, Mac model, microphone, engine version, and model name. There’s no need to attach a private recording.

## License

Think Out Loud’s source is available under the [MIT License](LICENSE). Whisper, whisper.cpp, and their model downloads are separate projects with their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
