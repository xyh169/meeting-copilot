#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="1.0.0"
DIST="$ROOT/dist"
APP="$DIST/Meeting Copilot.app"
RES="$APP/Contents/Resources"
RUNTIME="$DIST/cpython-runtime.tar.gz"
RUNTIME_URL='https://github.com/astral-sh/python-build-standalone/releases/download/20260924/cpython-3.12.14%2B20260924-aarch64-apple-darwin-install_only_stripped.tar.gz'
RUNTIME_SHA='c2edb321cd32ec2b170df208db0446dccc4398db602ca27cf2079098fb1f7d9d'
ZIP="$DIST/Meeting-Copilot-${VERSION}-macOS-arm64.zip"
DMG="$DIST/Meeting-Copilot-${VERSION}-macOS-arm64.dmg"

if [[ -e "$APP" || -e "$ZIP" || -e "$DMG" ]]; then
  print -u2 'Release output already exists. Move it aside before building again.'
  exit 1
fi
python3 scripts/privacy_check.py
mkdir -p "$DIST"
if [[ ! -f "$RUNTIME" ]]; then
  curl --fail --location --retry 2 "$RUNTIME_URL" --output "$RUNTIME"
fi
ACTUAL=$(shasum -a 256 "$RUNTIME")
[[ "${ACTUAL%% *}" == "$RUNTIME_SHA" ]] || { print -u2 'Runtime checksum mismatch'; exit 1; }
COPILOT_PORTABLE_BUILD=1 COPILOT_OUTPUT_APP="$APP" zsh MeetingCopilotApp/build_app.sh
tar -xzf "$RUNTIME" -C "$RES"
PYTHON="$RES/python/bin/python3"
PYTHONDONTWRITEBYTECODE=1 "$PYTHON" -m pip install --disable-pip-version-check --no-compile -r requirements.txt

# Package the reviewed Git index, including editable rules and user-facing guides.
mkdir -p "$RES/Backend"
while IFS= read -r -d '' file; do
  if [[ ( "$file" != */* && "$file" == *.py ) || "$file" == rules/*.md || "$file" == docs/*.md || "$file" == examples/*.md || "$file" == research-rules.md || "$file" == requirements*.txt ]]; then
    mkdir -p "$RES/Backend/${file:h}"
    git show ":$file" > "$RES/Backend/$file"
  fi
done < <(git ls-files -z)
git show :docs/RUNTIME.md > "$RES/RUNTIME.md"
git show :LICENSE > "$RES/LICENSE"

# pip launchers contain build paths; retain only interpreter entry points.
"$PYTHON" - <<'PY'
from pathlib import Path
import shutil
import sys
root = Path(sys.executable).parent
for path in root.iterdir():
    if (path.is_file() or path.is_symlink()) and path.name not in {"python", "python3", "python3.12"}:
        path.unlink()
for path in Path(sys.prefix).rglob("__pycache__"):
    shutil.rmtree(path)
PY
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 scripts/check_bundle.py "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

TASK_IMAGE_ROOT=$(mktemp -d "$DIST/dmg-stage.XXXXXX")
trap 'rm -rf "$TASK_IMAGE_ROOT"' EXIT
ditto "$APP" "$TASK_IMAGE_ROOT/Meeting Copilot.app"
ln -s /Applications "$TASK_IMAGE_ROOT/Applications"
cat > "$TASK_IMAGE_ROOT/Install.txt" <<'TEXT'
Meeting Copilot

Drag Meeting Copilot.app to Applications, then open it from Applications.

Requires an Apple Silicon Mac running macOS 26 or later.
Python and backend dependencies are included.

This build is locally signed and is not Apple notarized. If macOS blocks
the first launch, review the download source and use the normal
System Settings > Privacy & Security approval flow.
TEXT
hdiutil create -volname 'Meeting Copilot' -srcfolder "$TASK_IMAGE_ROOT" -ov -format UDZO "$DMG"
cd "$DIST"
shasum -a 256 "${ZIP:t}" "${DMG:t}" > SHA256SUMS.txt
print "Created $ZIP and $DMG"
