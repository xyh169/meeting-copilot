"""Local, user-owned Markdown scenarios. IDs resolve only within this library."""

import hashlib
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parent
LIBRARY = ROOT / "rules"
KINDS = {"interview": "interview", "research": "research"}
DEFAULT_RESEARCH = ROOT / "research-rules.md"


def folder(kind):
    if kind not in KINDS:
        raise ValueError("Unknown rule kind")
    path = LIBRARY / KINDS[kind]
    path.mkdir(parents=True, exist_ok=True)
    return path


def read_markdown(path):
    if path.stat().st_size > 120000:
        raise ValueError("Rule limit: 30000characters or fewer")
    text = path.read_text(encoding="utf-8-sig").strip()
    if not text or len(text) > 30000:
        raise ValueError("Rules must be nonempty and shorter than30000characters")
    return text, hashlib.sha256(text.encode()).hexdigest()[:12]


def paths(kind):
    directory = folder(kind)
    result = {"default": DEFAULT_RESEARCH} if kind == "research" else {}
    for path in sorted(directory.glob("*.md")):
        if not path.is_symlink() and path.stem not in result:
            result[path.stem] = path
    return result


def resolve(kind, identity):
    path = paths(kind).get(identity)
    if path is None or not path.is_file():
        raise ValueError("Selected rule missing; select again or import Markdown")
    return path


def load_rule(kind, identity):
    path = resolve(kind, identity)
    text, version = read_markdown(path)
    return text, version


def catalog(kind):
    entries = []
    for identity, path in paths(kind).items():
        title, version, error = path.stem, "", ""
        try:
            text, version = read_markdown(path)
            title = next((line[2:].strip() for line in text.splitlines() if line.startswith("# ")), title)
        except (OSError, UnicodeError, ValueError) as exc:
            error = str(exc)
        entries.append(dict(id=identity, title=title[:100], path=str(path), version=version, error=error))
    return dict(ok=True, rules=entries, directory=str(folder(kind)))


def import_rule(kind, filename, content):
    if not isinstance(filename, str) or not filename.lower().endswith(".md"):
        raise ValueError("Select Markdown (.md) file")
    if not isinstance(content, str) or not content.strip() or len(content) > 30000:
        raise ValueError("Rules must be nonempty and shorter than30000characters")
    content = content.lstrip("\ufeff").strip()
    # Never overwrite a prior scenario or let the submitted filename choose a path.
    identity = "rule-" + uuid.uuid4().hex
    title = Path(filename).stem[:100]
    if not any(line.startswith("# ") for line in content.splitlines()):
        content = "# " + title + "\n\n" + content
    if len(content) > 30000:
        raise ValueError("Rule limit: 30000characters or fewer")
    target = folder(kind) / (identity + ".md")
    with target.open("x", encoding="utf-8") as stream:
        stream.write(content + "\n")
    return dict(catalog(kind), selected=identity)
