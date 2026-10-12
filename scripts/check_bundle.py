"""Check a standalone app's own payload without printing credential matches."""
import importlib.util
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("privacy_check", ROOT / "scripts/privacy_check.py")
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


def main(app):
    app = Path(app).resolve()
    resources = app / "Contents/Resources"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if "CopilotSourceDirectory" in info:
        raise RuntimeError("Portable app contains a source directory reference")
    backend = resources / "Backend"
    expected = {n for n in subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
                if n and (("/" not in n and n.endswith(".py")) or n == "research-rules.md"
                          or n.startswith(("rules/", "docs/", "examples/")) and n.endswith(".md")
                          or n.startswith("requirements") and n.endswith(".txt"))}
    actual = {str(p.relative_to(backend)) for p in backend.rglob("*") if p.is_file()}
    if actual != expected:
        raise RuntimeError("Backend payload differs from reviewed source list")
    errors = []
    for name in sorted(actual):
        blob = (backend / name).read_bytes()
        indexed = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
        if blob != indexed:
            errors.append(name + ": differs from reviewed source")
        for number, line in enumerate(blob.decode().splitlines(), 1):
            for label, pattern in privacy.PATTERNS.items():
                if pattern.search(line):
                    errors.append(f"{name}:{number}: {label}")
    # Compiler and launcher metadata must not expose the build account's home path.
    private_prefix = str(Path.home()).encode() + b"/"
    for path in app.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        if private_prefix in data:
            errors.append(str(path.relative_to(app)) + ": contains build-account path")
    if errors:
        raise RuntimeError("\n".join(errors))
    print(f"Standalone app payload verified: {len(actual)} reviewed files, no build-account paths or credential patterns")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python scripts/check_bundle.py APP_PATH")
    main(sys.argv[1])
