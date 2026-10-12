# Contributing

For a bug report, include your macOS version, the affected feature, steps to reproduce and the expected behavior. Remove credentials and meeting content from logs or screenshots before sharing them.

For a pull request, describe the behavior changed and how you tested it. Add regression coverage with sample fixtures where appropriate. Run the relevant Python and native macOS tests:

```sh
.venv/bin/python -m unittest discover -s tests -v
zsh scripts/test_native.sh
```

Keep credentials, runtime settings and local meeting files out of commits. `scripts/privacy_check.py` checks staged files for these artifacts and common credential patterns.

New meeting scenarios can be added as Markdown rules. Keep scenario-specific assumptions within their own rules so they can be selected independently.
