# Privacy

## What the public repository contains

Application source, English documentation, generic rules, automated tests and fictional examples. It starts with a new Git history. Original configurations, private documents, real recordings/transcripts, meeting recovery snapshots, logs, evaluation output, models, virtual environments and packaged applications were excluded rather than anonymized and published.

All example business participants, people, figures, dates and events were newly invented. No original investment files or research rule text were copied into the examples. Software and provider names identify actual dependencies, not business examples.

## Credentials

No credential is distributed. Each user supplies their own API key. The Meeting Copilot namespace is separate from the legacy project's namespace and does not retrieve its credentials. Environment overrides are local only. The repository never includes Keychain exports, shell history or `.env` files.

Preparing or installing this project does not require deleting keys belonging to any earlier app. The namespaces are independent.

OBS passwords are generated or entered locally and stored in an ignored owner-only configuration file. Never commit runtime configurations. Runtime API responses may show whether a key is configured, but never its value.

## Data flow

- Apple/Qwen speech transcription stays on the Mac; raw audio is not submitted to the analysis API by this app.
- A cloud analysis provider receives the text needed for the configured feature: transcript excerpts, background, terminology, existing questions/answers and source material.
- Local Ollama analysis sends requests to its localhost service.
- Online research sends search queries and fetches public pages. The model policy requires generic public terms, but this is a prompt-level instruction, not a formal guarantee that model-generated queries cannot contain sensitive text. Keep web search off for confidential meetings unless you have reviewed this tradeoff.
- Local document excerpts are read-only inputs and are shared with cloud research only when the sharing setting permits it.
- Exports, drafts and recordings may contain sensitive information from your own use. Store and share them deliberately.

There is no telemetry or bundled external account. The local backend binds to the loopback interface. It is intended for a trusted local desktop, not internet hosting.

## Publication checks

`scripts/privacy_check.py` scans staged Git blobs, rejects private/runtime artifacts and reports credential patterns and personal paths without printing matched secrets. Manual review also checks examples and generic rules. The scanner is heuristic; review your own additions before publishing.
