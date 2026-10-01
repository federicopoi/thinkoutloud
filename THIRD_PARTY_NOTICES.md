# Third-party projects

Think Out Loud uses a separately installed speech recognition engine and model. This repository does not bundle their code, executables, or model weights.

- **Whisper**, by OpenAI: https://github.com/openai/whisper. Its code and model weights are released under the MIT License. See https://github.com/openai/whisper/blob/main/LICENSE.
- **whisper.cpp**, by the whisper.cpp contributors: https://github.com/ggml-org/whisper.cpp. Released under the MIT License. See https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE.

These projects supply the speech recognition technology. Think Out Loud supplies the Mac app interface, recording, shortcuts, and clipboard workflow. If you distribute their engine or models with a modified app, include the applicable upstream license notices.
