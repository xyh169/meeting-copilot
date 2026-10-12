#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
OUTPUT_APP="${COPILOT_OUTPUT_APP:-${SCRIPT_DIR:h}/Meeting Copilot.app}"
CONTENTS="$OUTPUT_APP/Contents"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"
if [[ "${COPILOT_PORTABLE_BUILD:-0}" != "1" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CopilotSourceDirectory string ${SCRIPT_DIR:h}" "$CONTENTS/Info.plist"
fi

xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -target arm64-apple-macos26.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework ScreenCaptureKit \
  -framework Speech \
  -framework SwiftUI \
  -framework WebKit \
  "$SCRIPT_DIR/MeetingCopilotApp.swift" \
  "$SCRIPT_DIR/QwenSpeechChannel.swift" \
  "$SCRIPT_DIR/TranscriptAssembler.swift" \
  "$SCRIPT_DIR/MeetingDraft.swift" \
  "$SCRIPT_DIR/PortableWorkspace.swift" \
  "$SCRIPT_DIR/TranscriptEditor.swift" \
  "$SCRIPT_DIR/ResearchPanel.swift" \
  "$SCRIPT_DIR/ResizableSplit.swift" \
  "$SCRIPT_DIR/RuleSelection.swift" \
  "$SCRIPT_DIR/ResearchDiscussion.swift" \
  "$SCRIPT_DIR/ResearchReportMerge.swift" \
  -o "$CONTENTS/MacOS/MeetingCopilot"

codesign \
  --force \
  --deep \
  --sign - \
  --requirements '=designated => identifier "io.github.xyh169.meeting-copilot"' \
  "$OUTPUT_APP"
echo "$OUTPUT_APP"
