# Data and storage

## Transcription and analysis

Apple and Qwen transcription run on your Mac. The app sends no raw audio to the analysis API.

Cloud analysis sends the configured provider the text needed for the selected feature: transcript excerpts, meeting background, terminology, questions, answers and source material. Local Ollama analysis uses its localhost service.

## Research

Online research sends search queries and retrieves public pages. The research policy asks the model to use generic topic terms, but this is a model instruction rather than a technical filter. You can disable web search for discussions that should stay local.

Connected local documents are read-only inputs. Matching excerpts are sent to cloud research only when you enable local excerpt sharing in Research settings.

## Credentials and local files

API keys are saved in macOS Keychain. You can also supply a key through `MEETING_COPILOT_API_KEY`. Leaving the key field blank keeps your saved key; **Remove key** deletes it.

OBS settings are saved in `obs_audio_config.json` beside the backend. This file can contain your OBS password and has owner-only permissions.

Meeting drafts and the research index are stored under `~/Library/Application Support/MeetingCopilot`. Logs are stored under `~/Library/Logs/MeetingCopilot`. Source builds use `private-data/projects` for local document research unless you configure another directory. Recordings default to `~/Movies/OBS Audio Meetings`, and you choose where to save exports.

Drafts, exports and recordings contain the content of your meetings. Review them before sharing.

The backend listens on localhost and is intended for desktop use. The app has no telemetry.
