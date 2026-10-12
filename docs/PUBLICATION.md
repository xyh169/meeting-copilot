# Public release preparation

Prepared on October 12, 2026.

## Scope

- Renamed the application, modules, storage and credentials namespace to Meeting Copilot.
- Switched interface text, documentation, analysis policies and default speech recognition to English.
- Replaced investment-specific defaults with general meeting, evidence review and action-item scenarios.
- Created new explicitly fictional planning and investment examples. All business names, participants, amounts, dates and events are invented.
- Created a new Git history from reviewed source files only.
- Excluded original settings, recordings, private documents, databases, recovery snapshots, evaluation results, logs, model weights, environments and app bundles.
- Kept credentials out of the public project and isolated its Keychain service from the earlier app.

## Validation

- English Python regression tests cover grounded quotes, negative/partial answers, updates, corrections, rule imports, mocked research, localhost API behavior and credential isolation.
- Native macOS tests cover transcript assembly, workspace updates, draft restoration and question-update controls.
- The native macOS application compiled successfully and its English interface was inspected.
- A staged-blob privacy scan checks the exact upload contents, including secret patterns, personal paths and excluded runtime artifacts.
- Examples and rules were manually checked for confidential identifiers and real business material.

Live paid model requests, actual microphone/system-audio capture and optional OBS/Qwen operation were not exercised during publication preparation. They depend on each user's own credentials, models and permissions.
