"""Local JSON-line PCM bridge. One MLX model, independent audio-channel states."""
import base64
import contextlib
import json
import os
import sys
from pathlib import Path

import numpy as np

RATE = 16000
MODEL_ROOT = Path.home() / ".cache/huggingface/hub/models--mlx-community--Qwen3-ASR-1.7B-bf16"


def model_path():
    revision = (MODEL_ROOT / "refs/main").read_text().strip()
    path = MODEL_ROOT / "snapshots" / revision
    if not (path / "config.json").is_file():
        raise RuntimeError("Local Qwen3-ASR 1.7B model incomplete")
    return str(path)


class Channel:
    def __init__(self, model, path, start=0):
        from mlx_qwen3_asr.streaming import init_streaming
        self.model = model
        self.state = init_streaming(model=path, language="English", context="",
                                    chunk_size_sec=2, max_context_sec=24)
        self.offset = start
        self.samples = 0
        self.window_start = start
        self.committed = ""
        self.active = False

    def feed(self, pcm, final=False):
        from mlx_qwen3_asr.streaming import feed_audio, finish_streaming
        self.samples += len(pcm)
        # Skip only digital silence before a window; never gate quiet speech.
        if not self.active and not final and np.max(np.abs(pcm), initial=0) < 1e-6:
            self.offset += len(pcm) / RATE
            self.samples = 0
            self.window_start = self.offset
            return []
        self.active = self.active or len(pcm) > 0
        if len(pcm):
            feed_audio(pcm, self.state, model=self.model)
        if final:
            finish_streaming(self.state, model=self.model)
        end = self.offset + (self.samples - len(self.state.buffer)) / RATE
        start = end - len(self.state.audio_accum) / RATE
        events = []
        if start > self.window_start + 0.001:
            text = self.state.committed_text[len(self.committed):].strip()
            events.append(dict(start=self.window_start, end=start, text=text, final=True))
            self.committed = self.state.committed_text
            self.window_start = start
        if end > self.window_start:
            events.append(dict(start=self.window_start, end=end, text=self.state.window_text, final=final))
        return events


def main():
    os.environ["HF_HUB_OFFLINE"] = "1"
    model = None
    channels = {}
    for line in sys.stdin:
        try:
            request = json.loads(line)
            command = request.get("command")
            with contextlib.redirect_stdout(sys.stderr):
                if command == "load":
                    from mlx_qwen3_asr.load_models import load_model
                    path = model_path()
                    model, _ = load_model(path)
                    # Warm up kernels before live capture begins.
                    warm = Channel(model, path)
                    warm.feed(np.zeros(RATE * 2, dtype=np.float32), final=True)
                    result = {"ok": True}
                elif command == "open":
                    if model is None:
                        raise RuntimeError("Qwen model not loaded")
                    channels[request["channel"]] = Channel(model, path)
                    result = {"ok": True}
                elif command in ("feed", "finish"):
                    channel = channels[request["channel"]]
                    raw = base64.b64decode(request.get("pcm", ""), validate=True)
                    if len(raw) % 4 or len(raw) > RATE * 4 * 4:
                        raise ValueError("Invalid PCM block")
                    pcm = np.frombuffer(raw, dtype="<f4").copy()
                    if not np.isfinite(pcm).all():
                        raise ValueError("Invalid PCM values")
                    result = {"ok": True, "events": channel.feed(pcm, final=command == "finish")}
                    if command == "finish":
                        del channels[request["channel"]]
                else:
                    raise ValueError("Unknown command")
            print(json.dumps(result, ensure_ascii=False), flush=True)
        except Exception as exc:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
