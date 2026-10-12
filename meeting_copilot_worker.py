#!/usr/bin/env python3
"""Persistent Qwen3-ASR worker used by the OBS meeting copilot."""

from __future__ import annotations

import contextlib
import json
import sys
import traceback
from pathlib import Path


def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    model = None
    model_name = ""

    with contextlib.redirect_stdout(sys.stderr):
        from mlx_audio.stt.generate import generate_transcription
        from mlx_audio.stt.utils import load_model

    for raw in sys.stdin:
        try:
            request = json.loads(raw)
            requested_model = str(request.get("model") or "mlx-community/Qwen3-ASR-1.7B-bf16")
            audio_path = Path(str(request["audio"])).expanduser().resolve()
            if not audio_path.exists():
                raise FileNotFoundError(f"Audio segment not found: {audio_path}")

            if model is None or requested_model != model_name:
                with contextlib.redirect_stdout(sys.stderr):
                    model = load_model(requested_model)
                model_name = requested_model

            prompt = str(request.get("prompt") or "").strip()
            generate_args = {
                "model": model,
                "audio": str(audio_path),
                "output_path": str(audio_path.parent / "qwen_output"),
                "format": "txt",
                "verbose": False,
                "language": "English",
            }
            if prompt:
                generate_args["system_prompt"] = prompt
            with contextlib.redirect_stdout(sys.stderr):
                result = generate_transcription(**generate_args)
            text = getattr(result, "text", str(result)).strip()
            if prompt and text.strip(".！!, , ") == prompt.strip(".！!, , "):
                text = ""
            emit({"ok": True, "text": text, "model": model_name})
        except Exception as exc:
            emit({
                "ok": False,
                "error": str(exc),
                "trace": traceback.format_exc(limit=5),
            })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
