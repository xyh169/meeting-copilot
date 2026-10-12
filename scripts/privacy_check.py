"""Check indexed upload contents; print locations, never matched secret values."""
import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
BLOCKED_SUFFIXES = {
    ".wav", ".mp3", ".m4a", ".mp4", ".mkv", ".mov", ".aiff",
    ".sqlite", ".db", ".jsonl", ".safetensors", ".gguf", ".onnx",
    ".pt", ".pth", ".pem", ".key", ".p12", ".dmg", ".zip", ".keychain-db", ".backup",
}
BLOCKED_PARTS = {
    "models", "evaluations", "private-data", "recordings", "exports",
    "backups", "__pycache__", "build", "dist",
}
PATTERNS = {
    "API token": re.compile(r"\b(?:sk" + r"-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    "private key": re.compile("-----BEGIN " + r"(?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "personal absolute path": re.compile(r"/(?:Users|home)/[A-Za-z0-9_.-]+/"),
    "literal credential": re.compile(r'''(?i)["'](?:api_key|obs_password|server_password|access_token)["']\s*:\s*["'][^"'\s]{8,}["']'''),
    "assigned credential": re.compile(r'''(?i)\b(?:\w*api_key|\w*access_token|\w*secret_key)\s*=\s*["'][^"'\s]{8,}["']'''),
    "authorization literal": re.compile(r'''(?i)bearer\s+[A-Za-z0-9._-]{20,}'''),
}


def main():
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True
    )
    files = [p for p in result.stdout.decode().split("\0") if p]
    if not files:
        print("No indexed files. Stage the reviewed source files first.")
        return 1
    errors = []
    for name in files:
        path = pathlib.PurePosixPath(name)
        if (path.suffix.lower() in BLOCKED_SUFFIXES
                or set(path.parts) & BLOCKED_PARTS
                or any(p.startswith(".venv") or p.endswith(".app") for p in path.parts)
                or path.name == "obs_audio_config.json"
                or path.name in {".DS_Store", "hosts.yml"}
                or path.name.startswith(".env")):
            errors.append(f"{name}: excluded runtime/private file")
        blob = subprocess.run(
            ["git", "show", ":" + name], cwd=ROOT, capture_output=True, check=True
        ).stdout
        try:
            content = blob.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"{name}: unexpected binary file")
            continue
        for number, line in enumerate(content.splitlines(), 1):
            for label, pattern in PATTERNS.items():
                if pattern.search(line):
                    errors.append(f"{name}:{number}: {label}")
    if errors:
        print("\n".join(errors))
        return 1
    print(f"Checked {len(files)} indexed text files: no blocked files or secret patterns.")
    print("This heuristic does not replace manual review of private text and rules.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
