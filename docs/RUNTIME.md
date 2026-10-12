# Download runtime

The macOS App includes CPython 3.12.14 from [python-build-standalone release 20260924](https://github.com/astral-sh/python-build-standalone/releases/tag/20260924), using the Apple Silicon install-only distribution, and the dependencies listed in `requirements.txt`.

Runtime archive SHA-256: `c2edb321cd32ec2b170df208db0446dccc4398db602ca27cf2079098fb1f7d9d`.

Python and its bundled libraries retain their upstream licenses under `Contents/Resources/python`. Installed Python dependencies retain their license and distribution metadata. OBS, Ollama, Qwen model weights and Apple speech resources are installed separately when needed.

To build a download package on an Apple Silicon Mac with the macOS 26 SDK, stage the source files and run:

```sh
zsh scripts/package_macos.sh
.venv/bin/python scripts/test_download.py
```

The package script produces a DMG, a ZIP and `SHA256SUMS.txt` under `dist`. The app uses local signing and is not Apple notarized.
