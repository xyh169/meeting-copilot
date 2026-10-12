#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/MeetingCopilotApp"
TASK_BUILD=$(mktemp -d)
trap 'rm -rf "$TASK_BUILD"' EXIT

xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  "$APP/TranscriptAssembler.swift" "$APP/TranscriptAssemblerTests.swift" -o "$TASK_BUILD/transcript-tests"
"$TASK_BUILD/transcript-tests"

xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  "$APP/PortableWorkspace.swift" "$APP/PortableWorkspaceTests.swift" -o "$TASK_BUILD/workspace-tests"
"$TASK_BUILD/workspace-tests"

SOURCES=("$APP/MeetingCopilotApp.swift" "$APP/QwenSpeechChannel.swift" "$APP/TranscriptAssembler.swift"
  "$APP/MeetingDraft.swift" "$APP/PortableWorkspace.swift" "$APP/TranscriptEditor.swift"
  "$APP/ResearchPanel.swift" "$APP/ResizableSplit.swift" "$APP/RuleSelection.swift"
  "$APP/ResearchDiscussion.swift" "$APP/ResearchReportMerge.swift")
xcrun swiftc -D COPILOT_TESTING -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  -framework AppKit -framework AVFoundation -framework CoreMedia -framework ScreenCaptureKit \
  -framework Speech -framework SwiftUI -framework WebKit \
  "${SOURCES[@]}" "$APP/QuestionUpdateTests.swift" -o "$TASK_BUILD/question-tests"
"$TASK_BUILD/question-tests"
