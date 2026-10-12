# Meeting Copilot

A macOS meeting assistant for live transcription, evidence-grounded follow-up questions, answer tracking and contextual research.

Use it for team planning, interviews, project reviews and decision discussions.

## Features

- Transcribe microphone audio, system audio or both using Apple's on-device speech recognition.
- Edit transcript segments while retaining the recognition original.
- Generate short follow-up questions tied to verbatim meeting evidence.
- Track answers, missing conditions, later supplements and corrections.
- Mark questions as asked without incorrectly marking them answered.
- Research a topic or ask a manual question with cited sources and explicit uncertainty.
- Import your own Markdown meeting and research scenarios.
- Save drafts locally and export transcript, Q&A and research as Markdown.
- Optionally use OBS for separate audio-file recording and Qwen for local transcription.

Audio channels identify capture sources; they do not identify every speaker. An answered question is not the same as an independently verified fact.

## Requirements

The native app currently targets **Apple Silicon Macs running macOS 26 or later**. Building requires Xcode or Command Line Tools with the macOS 26 SDK and Python 3.12. This repository provides source code, not a notarized installer.

Apple transcription requires the relevant macOS permissions and speech resources. AI analysis requires your own configured OpenAI-compatible API credentials and model name, or an installed local Ollama model. OBS, FFmpeg and Qwen are optional; the default native transcription workflow does not require them.

## Quick start

From the project directory:

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
zsh MeetingCopilotApp/build_app.sh
open "Meeting Copilot.app"
```

The app is locally signed for development. macOS may require you to allow it in Privacy & Security before opening it. Grant microphone, screen/system audio and speech recognition permissions as needed for your chosen sources.

On first launch, open **AI settings** and enter your own provider URL, model name and API key, or choose **Local model** and enter the name of your installed Ollama model.

See [setup instructions](docs/SETUP.md) for optional components and configuration.

## A meeting workflow

1. Select **General meeting**, **Evidence review**, **Decisions and action items**, or an imported scenario.
2. Enter this meeting's background, goals and known terminology.
3. Choose microphone, system audio or both, then press **Start**.
4. Review transcript segments and edit recognition errors. Read follow-up questions and their quoted evidence.
5. Use **Mark as asked** after asking a suggested question. The app tracks direct, partial and nonresponsive answers conservatively.
6. Ask a manual research question or refresh contextual research. Review sources and uncertainty.
7. Pause/resume when needed. Press **Stop**, then **Export** to save the notes.
8. Use **New meeting** before switching topics or projects. It backs up the current meeting and clears its background and Q&A.

Question updates are incremental, normally batched at about 60 seconds. Automatic research requires more than three minutes of substantive new discussion on the same topic. Silence and pauses do not count. Manual research and refresh bypass that threshold.

Turning off question updates preserves existing Q&A and pauses answer updates and new questions. Transcription and research continue independently. Research pause/stop is separate from audio capture. Requests already sent to a provider may still be billed.

## Scenarios and examples

Default meeting rules live in [`rules/interview`](rules/interview); research rules live in [`research-rules.md`](research-rules.md). Select a scenario from the meeting menu. Import a `.md` file to create your own local rule copy, or open a rule from the menu to edit it.

Browse the [team planning](examples/team-planning.md) and [investment discussion](examples/investment-discussion.md) examples to see how transcripts become notes and follow-up questions. Import the [investment review scenario](examples/investment-scenario.md) to tailor questions to that use case.

## Data and storage

Transcription runs locally. API keys are saved in macOS Keychain, and meeting drafts and exports are saved on your Mac.

When you choose a cloud analysis provider, it receives the text needed for analysis. Research can also search public sources and use documents you connect. Local document excerpts are shared with cloud research only when you enable that option.

See [data handling details](docs/PRIVACY.md) for storage locations and online feature settings.

## Development

```sh
.venv/bin/python -m unittest discover -s tests -v
zsh scripts/test_native.sh
```

The backend binds to `127.0.0.1:8766`. The browser page is the optional OBS recording settings panel; the native app provides transcription, questions and research. To open the recording panel separately:

```sh
.venv/bin/python obs_audio_web_gui.py
```

Source builds reference their project directory. Rebuild after moving it. Do not run multiple copies of this backend simultaneously.

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes.
