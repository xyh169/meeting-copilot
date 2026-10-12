# Setup

## Native app

Use an Apple Silicon Mac with macOS 26+, a matching macOS SDK, and Python 3.12. Create `.venv`, install `requirements.txt`, run `MeetingCopilotApp/build_app.sh`, and open `Meeting Copilot.app`. The build uses local development signing; it is not Apple notarization.

The app's default transcription locale is `en_US`. Apple speech resources may need an initial download. Choose an audio source and allow the corresponding macOS permissions. Use headphones when capturing microphone and system audio together to reduce speaker echo.

## Analysis

In AI settings select a provider mode:

- **Cloud API:** enter a complete HTTP(S) OpenAI-compatible chat-completions base URL, a model name supported by your account, and your own API key. Prefer HTTPS for cloud services. Provider compatibility and billing vary.
- **Local model:** install Ollama separately, download a suitable model, start the local service and enter the exact model name. The app does not download analysis models automatically.

The optional DeepSeek preset fills its service URL; you must supply the model name and your own credentials. Model availability is determined by the provider.

API keys are saved in macOS Keychain. Leave the key field blank to keep your saved key, or use **Remove key** to delete it.

Connection testing sends a small model request and may incur provider charges.

## Rules and local documents

Meeting rules: `rules/interview/*.md`. Research defaults: `research-rules.md`. Imported rules receive generated IDs and do not overwrite existing files.

Local document research is optional. Put your own documents in the ignored `private-data/projects` directory or configure:

| Variable | Purpose |
| --- | --- |
| `COPILOT_APP_DIR` | Override the native backend project directory |
| `MEETING_COPILOT_API_KEY` | Optional local environment override for the analysis key |
| `COPILOT_OFFLINE_ASR_PYTHON` | Optional Python executable for OBS file transcription |
| `COPILOT_WORKSPACE` | Root for your own private data |
| `COPILOT_PROJECTS_DIR` | Local document search directory |
| `COPILOT_PIKG_DB` | Optional compatible local SQLite knowledge graph |

For knowledge graph search, point `COPILOT_PIKG_DB` to a database using the supported PIKG schema. Keep local excerpt sharing disabled unless you want the configured cloud provider to receive matching excerpts.

## Optional Qwen transcription

The native default is Apple transcription. The optional native Qwen bridge expects a `.venv-asr` environment and an already-downloaded `mlx-community/Qwen3-ASR-1.7B-bf16` model in the Hugging Face cache:

```sh
python3.12 -m venv .venv-asr
.venv-asr/bin/python -m pip install -r requirements-asr.txt
```

Download the model separately using your preferred Hugging Face tools. The bridge runs offline. The OBS file-transcription worker additionally uses `mlx-audio`; install it in the interpreter selected by `COPILOT_OFFLINE_ASR_PYTHON` if you use that separate workflow.

## Optional OBS recording

Install OBS from its official distribution, and install FFmpeg separately if you want audio-only extraction. Enable the OBS module from the app menu. Its settings panel configures the OBS WebSocket service on localhost, normally port 4455. Use your own password.

The panel can create audio sources and filters, control file recording and convert completed recordings to M4A. OBS recording controls are separate from native transcription controls. The default output directory is `~/Movies/OBS Audio Meetings`.

OBS may require a restart after initial WebSocket configuration.

## Storage

Source builds keep ignored `obs_audio_config.json` beside the backend. Permissions are set to owner-only because it can include an OBS password. API keys are stored in Keychain, not that JSON file. Drafts and research indexes are stored under `~/Library/Application Support/MeetingCopilot`. Logs are stored under `~/Library/Logs/MeetingCopilot`.

The backend uses localhost port 8766. If the native app cannot connect, stop duplicate backends, ensure `.venv` exists and rebuild from the current project location.
