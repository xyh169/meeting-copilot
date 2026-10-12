#!/usr/bin/env python3
"""
Browser-based local GUI for OBS meeting-audio recording.

Run with ./run_obs_audio_gui.command. It starts a localhost web UI and opens it
in the default browser. The server only binds to 127.0.0.1.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import secrets
import socket
import subprocess
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    from meeting_copilot_engine import (
        API_KEYCHAIN_ACCOUNT,
        API_KEYCHAIN_SERVICE,
        get_copilot_controller,
        reasoning_json,
    )
except Exception as exc:
    get_copilot_controller = None
    reasoning_json = None
    COPILOT_IMPORT_ERROR = exc
else:
    COPILOT_IMPORT_ERROR = None


APP_DIR = pathlib.Path(__file__).resolve().parent
CONFIG_PATH = APP_DIR / "obs_audio_config.json"
GUIDE_PATH = APP_DIR / "recording-guide.txt"
WEBSOCKET_CONFIG_PATH = (
    pathlib.Path.home()
    / "Library"
    / "Application Support"
    / "obs-studio"
    / "plugin_config"
    / "obs-websocket"
    / "config.json"
)
LOCAL_OBS_APP = APP_DIR / "OBS.app"
APPLICATIONS_OBS_APP = pathlib.Path("/Applications/OBS.app")
COPILOT_APP = APP_DIR / "Meeting Copilot.app"
DEFAULT_OUTPUT_DIR = pathlib.Path.home() / "Movies" / "OBS Audio Meetings"
LOCAL_FFMPEG = APP_DIR / "bin/ffmpeg"


DEFAULT_CONFIG = {
    "obs_host": "127.0.0.1",
    "obs_port": 4455,
    "obs_password": "",
    "hide_obs_window": True,
    "recording_mode": "meeting_and_mic",
    "scene_name": "Meeting Audio Recorder",
    "meeting_source_name": "Meeting audio",
    "meeting_capture_mode": "macOS Audio Capture",
    "meeting_app_hint": "Zoom / Teams / Google Chrome",
    "mic_source_name": "My microphone",
    "mic_device_hint": "Default",
    "enable_mic": True,
    "enable_gate": True,
    "voice_enhancement": False,
    "voice_preset": "natural",
    "noise_suppression": False,
    "expander_enabled": False,
    "expander_threshold": -55.0,
    "expander_ratio": 1.4,
    "compressor_enabled": True,
    "compressor_threshold": -24.0,
    "compressor_ratio": 2.2,
    "compressor_output_gain": 4.0,
    "limiter_enabled": True,
    "limiter_threshold": -2.5,
    "close_threshold": -45.0,
    "open_threshold": -35.0,
    "attack_time": 10,
    "hold_time": 200,
    "release_time": 150,
    "output_dir": str(DEFAULT_OUTPUT_DIR),
    "file_prefix": "meeting_audio",
    "preferred_container": "m4a audio-only after recording",
    "low_video_overhead": True,
    "open_properties_after_apply": False,
    "enable_copilot": False,
    "copilot_model": "mlx-community/Qwen3-ASR-1.7B-bf16",
    "copilot_chunk_seconds": 30,
    "copilot_lag_seconds": 8,
    "copilot_analyze_minutes": 15,
    "copilot_reference_doc_1": "",
    "copilot_reference_doc_2": "",
    "copilot_reasoning_provider": "openai_compatible",
    "copilot_reasoning_model": "",
    "copilot_api_base_url": "https://api.deepseek.com",
    "copilot_api_model": "",
    "copilot_web_verification": "public_search",
}


CONFERENCE_ROOM_PRESET = {
    "voice_enhancement": True,
    "enable_gate": False,
    "noise_suppression": False,
    "expander_enabled": False,
    "expander_threshold": -55.0,
    "expander_ratio": 1.4,
    "compressor_enabled": True,
    "compressor_threshold": -24.0,
    "compressor_ratio": 2.2,
    "compressor_output_gain": 4.0,
    "limiter_enabled": True,
    "limiter_threshold": -2.5,
}


NATURAL_PRESET = {
    "voice_enhancement": False,
    "enable_gate": False,
    "noise_suppression": False,
    "expander_enabled": False,
    "compressor_enabled": False,
    "limiter_enabled": False,
}


HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OBS Meeting audio recording settings</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f7f8fa;
      --panel: #ffffff;
      --text: #18202a;
      --muted: #607080;
      --line: #dfe5eb;
      --accent: #1976d2;
      --accent-2: #0f8b6f;
      --danger: #c3423f;
      --field: #fbfcfd;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
    }
    header {
      padding: 18px 24px;
      border-bottom: 1px solid var(--line);
      background: #fff;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
    }
    h1 { font-size: 20px; margin: 0; font-weight: 650; }
    main {
      display: grid;
      grid-template-columns: minmax(420px, 1fr) minmax(320px, 430px);
      gap: 16px;
      padding: 16px;
      max-width: 1280px;
      margin: 0 auto;
    }
    section {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
    }
    h2 { margin: 0 0 12px; font-size: 15px; }
    .grid {
      display: grid;
      grid-template-columns: 190px minmax(0, 1fr);
      gap: 10px 12px;
      align-items: center;
    }
    label { color: var(--muted); }
    input, select {
      width: 100%;
      min-height: 34px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--field);
      padding: 6px 9px;
      color: var(--text);
    }
    input[type="checkbox"] { width: auto; min-height: auto; }
    input[type="range"] { padding: 0; }
    .range-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 72px;
      gap: 8px;
      align-items: center;
    }
    .stack { display: grid; gap: 16px; }
    .buttons {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }
    button {
      min-height: 34px;
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 7px 11px;
      background: #fff;
      color: var(--text);
      cursor: pointer;
    }
    button.primary { background: var(--accent); color: white; border-color: var(--accent); }
    button.green { background: var(--accent-2); color: white; border-color: var(--accent-2); }
    button.danger { color: var(--danger); }
    button:disabled { opacity: .55; cursor: wait; }
    .hint {
      color: var(--muted);
      font-size: 13px;
      margin-top: 10px;
    }
    pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      background: #0e1621;
      color: #dce6f2;
      border-radius: 8px;
      padding: 12px;
      min-height: 220px;
      max-height: 480px;
      overflow: auto;
      font-size: 12px;
    }
    .status {
      color: var(--muted);
      font-size: 13px;
    }
    .copilot-state {
      margin-top: 12px;
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: #f7faf9;
      color: var(--text);
      min-height: 42px;
    }
    .copilot-card {
      margin-top: 10px;
      padding: 10px 12px;
      border-left: 3px solid var(--accent-2);
      background: #f5f9f8;
    }
    .copilot-card strong { display: block; margin-bottom: 4px; }
    .copilot-card small { display: block; color: var(--muted); margin-top: 5px; }
    .copilot-transcript { min-height: 120px; max-height: 260px; margin-top: 10px; }
    .full { grid-column: 1 / -1; }
    @media (max-width: 900px) {
      main { grid-template-columns: 1fr; }
      .grid { grid-template-columns: 1fr; }
      header { align-items: flex-start; flex-direction: column; }
    }
  </style>
</head>
<body>
  <header>
    <div>
      <h1>OBS Meeting audio recording settings</h1>
      <div class="status" id="status">Local panel binds only to 127.0.0.1</div>
    </div>
    <div class="buttons">
      <button onclick="openObs()">Launch OBS audio engine</button>
      <button onclick="openInstaller()">Open installer</button>
      <button class="primary" onclick="saveConfig()">Save settings</button>
    </div>
  </header>

  <main>
    <div class="stack">
      <section>
        <h2>Recording mode</h2>
        <div class="grid">
          <label for="recording_mode">Recording mode</label>
          <select id="recording_mode" onchange="syncRecordingMode()">
            <option value="meeting_and_mic">Meeting audio + Microphone</option>
            <option value="meeting_only">Meeting audio only</option>
            <option value="mic_only">Microphone only</option>
          </select>
          <label for="scene_name">OBS Scene name</label>
          <input id="scene_name">
          <label for="meeting_source_name">Meeting audio source name</label>
          <input id="meeting_source_name">
          <label for="meeting_capture_mode">Meeting audio capture</label>
          <select id="meeting_capture_mode">
            <option>macOS Audio Capture</option>
            <option>Audio Output Capture</option>
            <option>BlackHole / virtual output</option>
          </select>
          <label for="meeting_app_hint">Application hint</label>
          <input id="meeting_app_hint">
        </div>
        <div class="hint" id="meeting_hint">Use macOS Audio Capture to record computer audio output. This panel selects Desktop Audio Capture automatically.</div>
      </section>

      <section>
        <h2>Microphone and voice processing</h2>
        <div class="grid">
          <label for="enable_mic">Record microphone</label>
          <div><input id="enable_mic" type="checkbox" onchange="toggleMic()"> Capture my voice; off records meeting audio only</div>
          <label for="voice_enhancement">Voice enhancement</label>
          <div><input id="voice_enhancement" type="checkbox"> Enable OBS Microphone filter; disable if speech is cut off</div>
          <label for="voice_preset">Voice preset</label>
          <select id="voice_preset" onchange="applyVoicePreset()">
            <option value="natural">Natural voice</option>
            <option value="conference_room">Conference room preset</option>
            <option value="standard">Standard meeting</option>
            <option value="strong">Strong noise suppression</option>
            <option value="light">Light processing</option>
          </select>
          <label for="mic_source_name">Microphone source name</label>
          <input id="mic_source_name">
          <label for="mic_device_hint">Microphone device hint</label>
          <input id="mic_device_hint">
          <label for="enable_gate">Enable Noise Gate</label>
          <div><input id="enable_gate" type="checkbox"> Open microphone only when speech is detected</div>
          <label for="noise_suppression">Strong noise suppression</label>
          <div><input id="noise_suppression" type="checkbox"> Suppress continuous noise; off by default for conference rooms</div>
          <label for="expander_enabled">Background noise reduction</label>
          <div><input id="expander_enabled" type="checkbox"> Reduce noise between speech</div>
          <label for="expander_threshold">Background noise threshold dB</label>
          <input id="expander_threshold" type="number" min="-80" max="-10">
          <label for="expander_ratio">Background reduction ratio</label>
          <input id="expander_ratio" type="number" min="1" max="8" step="0.1">
          <label for="compressor_enabled">Voice compression</label>
          <div><input id="compressor_enabled" type="checkbox"> Reduce volume differences</div>
          <label for="compressor_threshold">Compression threshold dB</label>
          <input id="compressor_threshold" type="number" min="-40" max="0">
          <label for="compressor_ratio">Compression ratio</label>
          <input id="compressor_ratio" type="number" min="1" max="20" step="0.1">
          <label for="compressor_output_gain">Voice gain dB</label>
          <input id="compressor_output_gain" type="number" min="0" max="12" step="0.5">
          <label for="limiter_enabled">Peak limiter</label>
          <div><input id="limiter_enabled" type="checkbox"> Prevent peak clipping</div>
          <label for="limiter_threshold">Limiter threshold dB</label>
          <input id="limiter_threshold" type="number" min="-12" max="0">
          <label for="close_threshold">Close threshold dB</label>
          <div class="range-row"><input id="close_threshold" type="range" min="-80" max="-10" step="1"><input id="close_threshold_num" type="number" min="-80" max="-10"></div>
          <label for="open_threshold">Open threshold dB</label>
          <div class="range-row"><input id="open_threshold" type="range" min="-80" max="-10" step="1"><input id="open_threshold_num" type="number" min="-80" max="-10"></div>
          <label for="attack_time">Attack ms</label>
          <input id="attack_time" type="number" min="1" max="200">
          <label for="hold_time">Hold ms</label>
          <input id="hold_time" type="number" min="0" max="2000">
          <label for="release_time">Release ms</label>
          <input id="release_time" type="number" min="10" max="3000">
        </div>
        <div class="hint" id="mic_only_hint" style="display:none">Microphone-only mode preserves quiet speech and uses the default microphone, 48 kHz mono and high quality AAC.</div>
      </section>

      <section>
        <h2>Output</h2>
        <div class="grid">
          <label for="output_dir">Output directory</label>
          <input id="output_dir">
          <label for="file_prefix">Filename prefix</label>
          <input id="file_prefix">
          <label for="preferred_container">Preferred format</label>
          <select id="preferred_container">
            <option>m4a audio-only after recording</option>
            <option>mp4 audio-focused</option>
            <option>mkv fallback, no screen source</option>
            <option>fragmented mp4 fallback, no screen source</option>
          </select>
          <label for="low_video_overhead">Low-overhead audio priority</label>
          <div><input id="low_video_overhead" type="checkbox"> Reduce OBS canvas to 320x180 / 5fps</div>
          <label for="open_properties_after_apply">Open source properties automatically</label>
          <div><input id="open_properties_after_apply" type="checkbox"> Apply OBS then open source properties</div>
        </div>
      </section>
    </div>

    <div class="stack">
      <section>
        <h2>OBS WebSocket</h2>
        <div class="grid">
          <label for="obs_host">Host</label>
          <input id="obs_host">
          <label for="obs_port">Port</label>
          <input id="obs_port" type="number" min="1" max="65535">
          <label for="obs_password">Password</label>
          <input id="obs_password" type="password">
          <label for="hide_obs_window">Hide OBS in background</label>
          <div><input id="hide_obs_window" type="checkbox"> Hide the OBS window during launch and recording</div>
        </div>
        <div class="buttons" style="margin-top:12px">
          <button onclick="testObs()">Test connection</button>
          <button class="primary" onclick="applyObs()">Apply OBS Scene/filters</button>
          <button onclick="syncMode()">Sync recording mode</button>
          <button id="record_start" class="green" onclick="record('start')">Start recording</button>
          <button id="record_pause" onclick="record('pause')">Pause</button>
          <button id="record_resume" onclick="record('resume')">Resume</button>
          <button id="record_stop" class="danger" onclick="record('stop')">Stop recording</button>
          <span class="status" id="recording_status">Reading recording status</span>
        </div>
        <div class="hint">This panel configures OBS WebSocket automatically. OBS records in the background with its window hidden by default.</div>
      </section>

      <section>
        <h2>Guide and log</h2>
        <div class="buttons" style="margin-bottom:10px">
          <button onclick="guide()">Generate guide</button>
          <button onclick="copyGuide()">Copy guide</button>
          <button onclick="clearLog()">Clear log</button>
        </div>
        <pre id="log"></pre>
      </section>
    </div>
  </main>

  <script>
    const fields = [
      "obs_host", "obs_port", "obs_password", "scene_name", "meeting_source_name",
      "recording_mode", "meeting_capture_mode", "meeting_app_hint", "mic_source_name", "mic_device_hint",
      "hide_obs_window", "enable_mic", "enable_gate", "voice_enhancement", "voice_preset",
      "noise_suppression", "expander_enabled", "expander_threshold", "expander_ratio",
      "compressor_enabled", "compressor_threshold", "compressor_ratio", "compressor_output_gain",
      "limiter_enabled", "limiter_threshold", "close_threshold", "open_threshold", "attack_time",
      "hold_time", "release_time", "output_dir", "file_prefix", "preferred_container", "low_video_overhead",
      "open_properties_after_apply"
    ];

    function log(message) {
      const el = document.getElementById("log");
      const stamp = new Date().toLocaleTimeString();
      el.textContent += `[${stamp}] ${message}\n`;
      el.scrollTop = el.scrollHeight;
    }

    let recordingActive = false;
    let recordingAvailable = false;
    let recordingPaused = false;

    function updateRecordingControls(active, available = true, paused = false) {
      recordingActive = Boolean(active);
      recordingAvailable = Boolean(available);
      recordingPaused = Boolean(paused);
      const start = document.getElementById("record_start");
      const pause = document.getElementById("record_pause");
      const resume = document.getElementById("record_resume");
      const stop = document.getElementById("record_stop");
      const status = document.getElementById("recording_status");
      // Starting a recording can launch OBS automatically, so a disconnected
      // OBS must not disable the start button.
      if (start) start.disabled = recordingActive;
      if (pause) pause.disabled = !recordingAvailable || !recordingActive || recordingPaused;
      if (resume) resume.disabled = !recordingAvailable || !recordingActive || !recordingPaused;
      if (stop) stop.disabled = !recordingAvailable || !recordingActive;
      if (status) {
        status.textContent = !recordingAvailable
          ? "OBS Not running; Start launches automatically"
          : (recordingActive ? (recordingPaused ? "Recording paused" : "Recording") : "Not recording");
      }
    }

    function setBusy(isBusy) {
      document.querySelectorAll("button").forEach(btn => btn.disabled = isBusy);
      if (!isBusy) updateRecordingControls(recordingActive, recordingAvailable, recordingPaused);
    }

    function readForm() {
      const data = {};
      fields.forEach(id => {
        const el = document.getElementById(id);
        if (el.type === "checkbox") data[id] = el.checked;
        else if (el.type === "number" || id.endsWith("_threshold")) data[id] = Number(el.value);
        else data[id] = el.value;
      });
      return data;
    }

    function writeForm(data) {
      fields.forEach(id => {
        const el = document.getElementById(id);
        if (!el || data[id] === undefined) return;
        if (el.type === "checkbox") el.checked = Boolean(data[id]);
        else el.value = data[id];
      });
      syncRanges();
      syncRecordingMode(false);
    }

    function syncRanges() {
      for (const key of ["close_threshold", "open_threshold"]) {
        const slider = document.getElementById(key);
        const num = document.getElementById(`${key}_num`);
        if (slider && num) {
          num.value = slider.value;
          slider.oninput = () => num.value = slider.value;
          num.oninput = () => slider.value = num.value;
        }
      }
    }

    function applyVoicePreset() {
      const preset = document.getElementById("voice_preset").value;
      const values = {
        natural: {
          voice_enhancement: false,
          enable_gate: false, noise_suppression: false, expander_enabled: false,
          compressor_enabled: false, limiter_enabled: false
        },
        conference_room: {
          voice_enhancement: true,
          enable_gate: false, noise_suppression: false, expander_enabled: false,
          expander_threshold: -55, expander_ratio: 1.4,
          compressor_enabled: true, compressor_threshold: -24, compressor_ratio: 2.2,
          compressor_output_gain: 4, limiter_enabled: true, limiter_threshold: -2.5
        },
        light: {
          voice_enhancement: true,
          enable_gate: false, noise_suppression: false, expander_enabled: true,
          expander_threshold: -55, expander_ratio: 1.5,
          compressor_enabled: true, compressor_threshold: -22, compressor_ratio: 2.2,
          compressor_output_gain: 3, limiter_enabled: true, limiter_threshold: -3
        },
        standard: {
          voice_enhancement: true,
          enable_gate: false, noise_suppression: true, expander_enabled: true,
          expander_threshold: -48, expander_ratio: 1.8,
          compressor_enabled: true, compressor_threshold: -20, compressor_ratio: 3,
          compressor_output_gain: 3, limiter_enabled: true, limiter_threshold: -3
        },
        strong: {
          voice_enhancement: true,
          enable_gate: false, noise_suppression: true, expander_enabled: true,
          expander_threshold: -42, expander_ratio: 2.5,
          compressor_enabled: true, compressor_threshold: -20, compressor_ratio: 4,
          compressor_output_gain: 4, limiter_enabled: true, limiter_threshold: -4
        }
      }[preset];
      if (!values) return;
      for (const [key, value] of Object.entries(values)) {
        const el = document.getElementById(key);
        if (!el) continue;
        if (el.type === "checkbox") el.checked = Boolean(value);
        else el.value = value;
      }
      syncRecordingMode(false);
    }

    function setFieldVisible(id, visible) {
      const label = document.querySelector(`label[for="${id}"]`);
      const field = document.getElementById(id);
      const control = field && field.parentElement && field.parentElement.classList.contains("range-row")
        ? field.parentElement
        : field && field.parentElement && field.parentElement.tagName === "DIV" && field.type === "checkbox"
          ? field.parentElement
          : field;
      for (const el of [label, control]) {
        if (el) el.style.display = visible ? "" : "none";
      }
    }

    function syncRecordingMode(updateSwitches = true) {
      const mode = document.getElementById("recording_mode").value;
      const micSwitch = document.getElementById("enable_mic");
      const meetingCapture = document.getElementById("meeting_capture_mode");
      const gateSwitch = document.getElementById("enable_gate");
      const gateFields = [
        "enable_gate", "close_threshold", "open_threshold",
        "attack_time", "hold_time", "release_time"
      ];
      const meetingFields = ["meeting_source_name", "meeting_capture_mode", "meeting_app_hint"];
      const micOnlyAdvancedFields = [
        "expander_threshold", "expander_ratio",
        "compressor_threshold", "compressor_ratio", "compressor_output_gain",
        "limiter_threshold"
      ];
      const micOnlyLockedFields = [
        "voice_enhancement", "voice_preset", "noise_suppression", "expander_enabled",
        "compressor_enabled", "limiter_enabled"
      ];
      if (updateSwitches && micSwitch) {
        micSwitch.checked = mode !== "meeting_only";
      }
      if (mode === "mic_only") {
        if (gateSwitch) gateSwitch.checked = false;
        if (updateSwitches) {
          document.getElementById("voice_preset").value = "natural";
          applyVoicePreset();
          log("Microphone-only capture is continuous; no gate, strong suppression or expander.");
        }
      }
      if (meetingCapture) {
        meetingCapture.disabled = mode === "mic_only";
      }
      for (const id of meetingFields) {
        setFieldVisible(id, mode !== "mic_only");
      }
      const meetingHint = document.getElementById("meeting_hint");
      if (meetingHint) meetingHint.style.display = mode === "mic_only" ? "none" : "";
      const micOnlyHint = document.getElementById("mic_only_hint");
      if (micOnlyHint) micOnlyHint.style.display = mode === "mic_only" ? "" : "none";
      for (const id of gateFields) {
        const el = document.getElementById(id);
        if (el) el.disabled = mode === "mic_only";
        setFieldVisible(id, mode !== "mic_only");
      }
      for (const id of micOnlyAdvancedFields) {
        setFieldVisible(id, mode !== "mic_only");
      }
      for (const id of micOnlyLockedFields) {
        const el = document.getElementById(id);
        if (el) el.disabled = mode === "mic_only";
      }
    }

    async function api(path, payload = {}) {
      setBusy(true);
      try {
        const res = await fetch(path, {
          method: "POST",
          headers: {"Content-Type": "application/json"},
          body: JSON.stringify(payload)
        });
        const data = await res.json();
        if (!res.ok || data.ok === false) throw new Error(data.error || res.statusText);
        if (data.config) writeForm(data.config);
        if (data.message) log(data.message);
        if (data.guide) log("\n" + data.guide);
        if (data.details) log(JSON.stringify(data.details, null, 2));
        return data;
      } catch (err) {
        log(`Error: ${err.message}`);
      } finally {
        setBusy(false);
      }
    }

    async function loadConfig() {
      const res = await fetch("/api/config");
      const data = await res.json();
      writeForm(data);
      log("GUI loaded. Open OBS, Enable WebSocket, then test connection.");
      await refreshRecordingStatus();
    }

    async function refreshRecordingStatus() {
      try {
        const res = await fetch("/api/recording_status");
        const data = await res.json();
        updateRecordingControls(Boolean(data.active), Boolean(data.available), Boolean(data.paused));
      } catch (_) {
        updateRecordingControls(false, false, false);
      }
    }

    function saveConfig() { return api("/api/config", readForm()); }
    function openObs() { return api("/api/open_obs", readForm()); }
    function openInstaller() { return api("/api/open_installer", readForm()); }
    function testObs() { return api("/api/test_obs", readForm()); }
    async function toggleMic() {
      await saveConfig();
      return api("/api/set_mic", readForm());
    }
    async function syncMode() {
      await saveConfig();
      return api("/api/apply_obs", readForm());
    }
    async function applyObs() {
      await saveConfig();
      return api("/api/apply_obs", readForm());
    }
    async function record(action) {
      const result = await api(`/api/${action}_recording`, readForm());
      await refreshRecordingStatus();
      return result;
    }
    async function guide() {
      await saveConfig();
      return api("/api/guide", readForm());
    }
    async function copyGuide() {
      await saveConfig();
      return api("/api/copy_guide", readForm());
    }
    function clearLog() { document.getElementById("log").textContent = ""; }

    loadConfig();
    setInterval(refreshRecordingStatus, 3000);
  </script>
</body>
</html>
"""


def load_config() -> dict:
    data = dict(DEFAULT_CONFIG)
    if CONFIG_PATH.exists():
        try:
            saved = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(saved, dict):
                data.update(saved)
        except Exception:
            pass
    return normalize_config(data)


def normalize_config(data: dict) -> dict:
    had_recording_mode = "recording_mode" in data
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(data)

    if cfg.get("meeting_capture_mode") == "Only microphone":
        cfg["recording_mode"] = "mic_only"
        cfg["meeting_capture_mode"] = "macOS Audio Capture"
    elif not had_recording_mode and data.get("enable_mic") is False:
        cfg["recording_mode"] = "meeting_only"

    mode = cfg.get("recording_mode") or "meeting_and_mic"
    if mode not in {"meeting_and_mic", "meeting_only", "mic_only"}:
        mode = "meeting_and_mic"
    cfg["recording_mode"] = mode

    preset = str(cfg.get("voice_preset") or DEFAULT_CONFIG["voice_preset"])
    if preset not in {"natural", "conference_room", "light", "standard", "strong"}:
        preset = DEFAULT_CONFIG["voice_preset"]
    cfg["voice_preset"] = preset

    if mode == "mic_only":
        cfg["enable_mic"] = True
        cfg["voice_preset"] = "natural"
        cfg.update(NATURAL_PRESET)
    elif mode == "meeting_only":
        cfg["enable_mic"] = False
    elif mode == "meeting_and_mic":
        cfg["enable_mic"] = True

    if preset == "natural":
        cfg.update(NATURAL_PRESET)
    elif preset == "conference_room":
        cfg.update(CONFERENCE_ROOM_PRESET)

    preferred = str(cfg.get("preferred_container", DEFAULT_CONFIG["preferred_container"]))
    if preferred in {"m4a audio-only if available", "mp3 audio-only if available"}:
        preferred = "m4a audio-only after recording"
    if preferred not in {
        "m4a audio-only after recording",
        "mp4 audio-focused",
        "mkv fallback, no screen source",
        "fragmented mp4 fallback, no screen source",
    }:
        preferred = "m4a audio-only after recording"
    cfg["preferred_container"] = preferred

    cfg["copilot_chunk_seconds"] = max(10, min(180, int(float(cfg.get("copilot_chunk_seconds", 30)))))
    cfg["copilot_lag_seconds"] = max(3, min(60, int(float(cfg.get("copilot_lag_seconds", 8)))))
    cfg["copilot_analyze_minutes"] = max(1, min(60, int(float(cfg.get("copilot_analyze_minutes", 15)))))
    if cfg.get("copilot_web_verification") not in {"mark_only", "public_search"}:
        cfg["copilot_web_verification"] = "mark_only"
    if cfg.get("copilot_reasoning_provider") not in {"ollama", "openai_compatible", "rules"}:
        cfg["copilot_reasoning_provider"] = "ollama"
    cfg["copilot_reasoning_model"] = str(
        cfg.get("copilot_reasoning_model") or DEFAULT_CONFIG["copilot_reasoning_model"]
    ).strip()[:160]
    cfg["copilot_api_base_url"] = str(
        cfg.get("copilot_api_base_url") or DEFAULT_CONFIG["copilot_api_base_url"]
    ).strip().rstrip("/")[:500]
    cfg["copilot_api_model"] = str(
        cfg.get("copilot_api_model") or DEFAULT_CONFIG["copilot_api_model"]
    ).strip()[:160]

    return cfg


def save_config(data: dict) -> dict:
    merged = load_config()
    merged.update(data)
    cfg = normalize_config(merged)
    cfg["obs_port"] = int(cfg["obs_port"])
    cfg["close_threshold"] = float(cfg["close_threshold"])
    cfg["open_threshold"] = float(cfg["open_threshold"])
    cfg["expander_threshold"] = float(cfg["expander_threshold"])
    cfg["expander_ratio"] = float(cfg["expander_ratio"])
    cfg["compressor_threshold"] = float(cfg["compressor_threshold"])
    cfg["compressor_ratio"] = float(cfg["compressor_ratio"])
    cfg["compressor_output_gain"] = float(cfg["compressor_output_gain"])
    cfg["limiter_threshold"] = float(cfg["limiter_threshold"])
    cfg["attack_time"] = int(cfg["attack_time"])
    cfg["hold_time"] = int(cfg["hold_time"])
    cfg["release_time"] = int(cfg["release_time"])
    cfg["copilot_chunk_seconds"] = int(cfg["copilot_chunk_seconds"])
    cfg["copilot_lag_seconds"] = int(cfg["copilot_lag_seconds"])
    cfg["copilot_analyze_minutes"] = int(cfg["copilot_analyze_minutes"])
    pathlib.Path(cfg["output_dir"]).expanduser().mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    CONFIG_PATH.chmod(0o600)
    return cfg


def api_key_configured() -> bool:
    result = subprocess.run(
        [
            "security", "find-generic-password",
            "-s", API_KEYCHAIN_SERVICE,
            "-a", API_KEYCHAIN_ACCOUNT,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )
    return result.returncode == 0


def save_api_key(api_key: str) -> None:
    value = api_key.strip()
    if not value:
        return
    subprocess.run(
        [
            "security", "add-generic-password", "-U",
            "-s", API_KEYCHAIN_SERVICE,
            "-a", API_KEYCHAIN_ACCOUNT,
            "-w", value,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=10,
        check=True,
    )


def delete_api_key() -> None:
    subprocess.run(
        [
            "security", "delete-generic-password",
            "-s", API_KEYCHAIN_SERVICE,
            "-a", API_KEYCHAIN_ACCOUNT,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )


def validate_api_base_url(value: str) -> str:
    url = value.strip().rstrip("/")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("API Address must be a complete http:// or https:// Address")
    if parsed.username or parsed.password:
        raise ValueError("API Address must not contain credentials")
    if parsed.scheme == "http" and parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError("non-local API Must use HTTPS")
    return url


def save_ai_config(data: dict) -> dict:
    provider = str(data.get("copilot_reasoning_provider") or "ollama")
    if provider not in {"ollama", "openai_compatible"}:
        raise ValueError("Unsupported analysis mode")
    updates = {
        "copilot_reasoning_provider": provider,
        "copilot_reasoning_model": str(data.get("copilot_reasoning_model") or "").strip(),
        "copilot_api_base_url": validate_api_base_url(
            str(data.get("copilot_api_base_url") or DEFAULT_CONFIG["copilot_api_base_url"])
        ),
        "copilot_api_model": str(data.get("copilot_api_model") or "").strip(),
    }
    if provider == "ollama" and not updates["copilot_reasoning_model"]:
        raise ValueError("Local model name is required")
    if provider == "openai_compatible" and not updates["copilot_api_model"]:
        raise ValueError("Cloud model name is required")
    if str(data.get("api_key") or "").strip():
        save_api_key(str(data["api_key"]))
    if bool(data.get("remove_api_key")):
        delete_api_key()
    return save_config(updates)


def ai_config_payload(cfg: dict) -> dict:
    return {
        "copilot_reasoning_provider": cfg.get("copilot_reasoning_provider", "ollama"),
        "copilot_reasoning_model": cfg.get("copilot_reasoning_model", ""),
        "copilot_api_base_url": cfg.get("copilot_api_base_url", DEFAULT_CONFIG["copilot_api_base_url"]),
        "copilot_api_model": cfg.get("copilot_api_model", DEFAULT_CONFIG["copilot_api_model"]),
        "api_key_configured": api_key_configured(),
    }


def ensure_obs_websocket_config(cfg: dict) -> tuple[dict, str]:
    ws_cfg = {}
    if WEBSOCKET_CONFIG_PATH.exists():
        try:
            loaded = json.loads(WEBSOCKET_CONFIG_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                ws_cfg.update(loaded)
        except Exception:
            ws_cfg = {}

    password = cfg.get("obs_password") or ws_cfg.get("server_password") or secrets.token_urlsafe(18)
    ws_cfg.update(
        {
            "first_load": False,
            "server_enabled": True,
            "server_port": int(cfg["obs_port"]),
            "alerts_enabled": False,
            "auth_required": True,
            "server_password": password,
        }
    )
    WEBSOCKET_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    WEBSOCKET_CONFIG_PATH.write_text(json.dumps(ws_cfg, ensure_ascii=False, indent=2), encoding="utf-8")

    if cfg.get("obs_password") != password:
        cfg = dict(cfg)
        cfg["obs_password"] = password
        save_config(cfg)

    return cfg, f"OBS WebSocket configured on port {cfg['obs_port']}, Authentication password synced to this GUI."


def build_guide(cfg: dict) -> str:
    record_mode = recording_mode(cfg)
    record_mode_label = {
        "meeting_and_mic": "Meeting audio + Microphone",
        "meeting_only": "Meeting audio only",
        "mic_only": "Microphone only",
    }.get(record_mode, record_mode)
    mode = cfg["meeting_capture_mode"]
    if mode == "macOS Audio Capture":
        source_hint = (
            "This panel adds automatically/Check 'macOS Audio Capture”, and set Method for Desktop Audio Capture, "
            "Captures computer audio output."
        )
    elif mode == "Audio Output Capture":
        source_hint = "Add/Check 'Audio Output Capture”, Device Select default output or the device used to hear the meeting."
    elif mode == "BlackHole / virtual output":
        source_hint = (
            "Add/Check 'Audio Output Capture”, Device select BlackHole.macOS Audio MIDI Set output to"
            "Multi-output device: headphones/Speakers + BlackHole."
        )
    else:
        source_hint = "Microphone source only; other participants are not captured."

    gate_label = (
        "Off in microphone-only mode; microphone stays open"
        if record_mode == "mic_only"
        else ("Enable" if cfg["enable_gate"] else "Close")
    )

    dmgs = sorted(APP_DIR.glob("OBS-Studio-*-macOS-Apple.dmg"))
    installer = dmgs[-1] if dmgs else "Not found"
    return f"""OBS Meeting audio recording settings

OBS Path:
- this directory OBS: {LOCAL_OBS_APP}
- Installer: {installer}
- Hide OBS in background: {'Enable' if cfg.get('hide_obs_window', True) else 'Close'}

Recommended scene:
- Recording mode: {record_mode_label}
- Scene name: {cfg['scene_name']}
- Meeting audio source: {cfg['meeting_source_name']}
- Microphone source: {cfg['mic_source_name']}

Meeting audio:
- Status: {'Enable' if meeting_audio_enabled(cfg) else 'Close'}
- Mode: {mode}
- Application hint: {cfg['meeting_app_hint']}
- Action: {source_hint}

Microphone:
- Record microphone: {'Enable' if mic_audio_enabled(cfg) else 'Off; meeting audio only'}
- Device hint: {cfg['mic_device_hint']}
- Voice enhancement: {'Enable' if cfg.get('voice_enhancement', True) else 'Close'}
- Voice preset: {cfg.get('voice_preset', 'standard')}
- RNNoise Noise suppression: {'Enable' if cfg.get('noise_suppression', True) else 'Close'}
- Background noise reduction: {'Enable' if cfg.get('expander_enabled', True) else 'Close'}, threshold {cfg.get('expander_threshold', -42.0)} dB, Strength {cfg.get('expander_ratio', 2.5)}
- Voice compression: {'Enable' if cfg.get('compressor_enabled', True) else 'Close'}, threshold {cfg.get('compressor_threshold', -18.0)} dB, Strength {cfg.get('compressor_ratio', 4.0)}, Gain {cfg.get('compressor_output_gain', 3.0)} dB
- Peak limiter: {'Enable' if cfg.get('limiter_enabled', True) else 'Close'}, threshold {cfg.get('limiter_threshold', -3.0)} dB
- Noise Gate: {gate_label}
- Close Threshold: {cfg['close_threshold']} dB
- Open Threshold: {cfg['open_threshold']} dB
- Attack: {cfg['attack_time']} ms
- Hold: {cfg['hold_time']} ms
- Release: {cfg['release_time']} ms

Output:
- Output directory: {cfg['output_dir']}
- Filename prefix: {cfg['file_prefix']}
- Preferred format: {cfg['preferred_container']}
- OBS Recording container: {obs_record_format(cfg)}
- Low-overhead audio priority: {'Enable' if cfg.get('low_video_overhead', True) else 'Close'}

OBS Output recommendations:
1. Settings -> Audio: Sample Rate 48 kHz, Channels Stereo.
2. Settings -> Output:
   - If OBS of Custom Output (FFmpeg) For audio-only, select container m4a or mp3.
   - If audio-only unavailable, use mkv or fragmented mp4; Do not add screen/window/camera sources; record audio in a black-frame container without screen video.
3. Advanced Audio Properties: Check both 'Meeting audio' and 'My microphone' Track 1.
4. Use 'Meeting audio only' when listening, or 'Microphone only' to record your own voice.
5. Before recording check OBS Check the mixer: meeting audio should react to others; microphone-only mode keeps the microphone open with voice processing.
6. For everyday use open the desktop app and browser panel; OBS runs as a background audio engine, hidden by default.

OBS WebSocket:
- Host: {cfg['obs_host']}
- Port: {cfg['obs_port']}
- Password: {'Configured' if cfg['obs_password'] else 'empty'}
"""


def obs_app_path() -> pathlib.Path:
    return LOCAL_OBS_APP if LOCAL_OBS_APP.exists() else APPLICATIONS_OBS_APP


def hide_obs_window() -> None:
    subprocess.run(
        [
            "osascript",
            "-e",
            'tell application "System Events" to if exists process "OBS" then set visible of process "OBS" to false',
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=4,
    )


def open_obs_app(hidden: bool = True) -> str:
    target = obs_app_path()
    if not target.exists():
        raise FileNotFoundError(str(target))
    cmd = ["open"]
    if hidden:
        cmd.append("-j")
    cmd.extend([str(target), "--args", "--minimize-to-tray", "--disable-updater", "--disable-missing-files-check"])
    subprocess.Popen(cmd)
    if hidden:
        time.sleep(1)
        try:
            hide_obs_window()
        except Exception:
            pass
    return f"Requested background launch OBS: {target}" if hidden else f"Requested opening OBS: {target}"


def is_obs_not_ready_error(exc: Exception) -> bool:
    text = str(exc)
    return "not ready to perform" in text or "code 207" in text or "OBS is not ready" in text


def wait_for_obs_ready(client, timeout: float = 20.0, poll: float = 0.75) -> None:
    deadline = time.time() + timeout
    last_exc = None
    while True:
        try:
            client.get_input_list()
            return
        except Exception as exc:
            last_exc = exc
            if not is_obs_not_ready_error(exc):
                raise
            if time.time() >= deadline:
                raise RuntimeError(
                    "OBS WebSocket Connected, but OBS Still initializing."
                    "Please wait OBS Wait for the main window, or close OBS then restart using this panel."
                ) from last_exc
            time.sleep(poll)


def connect_obs(cfg: dict, autostart: bool = False):
    import obsws_python as obs

    cfg = dict(cfg)

    def make_client(timeout: int):
        with contextlib.redirect_stderr(io.StringIO()):
            return obs.ReqClient(
                host=cfg["obs_host"],
                port=int(cfg["obs_port"]),
                password=cfg["obs_password"],
                timeout=timeout,
            )

    if autostart:
        cfg, _ = ensure_obs_websocket_config(cfg)
        open_obs_app(bool(cfg.get("hide_obs_window", True)))
        deadline = time.time() + 30
        last_exc = None
        while time.time() < deadline:
            try:
                client = make_client(3)
                try:
                    wait_for_obs_ready(client, max(0.1, deadline - time.time()))
                except Exception:
                    client.disconnect()
                    raise
                if cfg.get("hide_obs_window", True):
                    try:
                        hide_obs_window()
                    except Exception:
                        pass
                return client
            except Exception as exc:
                last_exc = exc
                time.sleep(1)
        raise RuntimeError(
            "OBS WebSocket Not ready; check OBS Opened; in OBS of Tools/Tools -> "
            "WebSocket Server Settings Enable server; port should be 4455."
        ) from last_exc

    try:
        client = make_client(5)
        try:
            wait_for_obs_ready(client, 8)
        except Exception:
            client.disconnect()
            raise
        return client
    except Exception as exc:
        if is_obs_not_ready_error(exc):
            raise RuntimeError(
                "OBS Connected but initializing; please wait OBS Wait for the main window, then click 'Test connection'."
            ) from exc
        raise RuntimeError(
            "Connect OBS failed, usually because OBS not open, or OBS of WebSocket Server is not enabled."
            "First click 'Open OBS”, etc. OBS Wait for startup, then click 'Test connection'."
        ) from exc


def public_attrs(obj) -> dict:
    if isinstance(obj, dict):
        return obj
    result = {}
    for name in dir(obj):
        if name.startswith("_"):
            continue
        try:
            value = getattr(obj, name)
        except Exception:
            continue
        if callable(value):
            continue
        result[name] = value
    return result


def response_value(obj, *names: str, default=None):
    for name in names:
        if isinstance(obj, dict) and name in obj:
            return obj[name]
        if hasattr(obj, name):
            return getattr(obj, name)
    attrs = public_attrs(obj)
    for name in names:
        if name in attrs:
            return attrs[name]
    return default


def listish(obj) -> list:
    if isinstance(obj, list):
        return obj
    if isinstance(obj, tuple):
        return list(obj)
    if hasattr(obj, "__iter__") and not isinstance(obj, (str, bytes, dict)):
        try:
            return list(obj)
        except TypeError:
            return []
    return []


def audio_kinds(kinds_obj) -> list:
    kinds = response_value(kinds_obj, "input_kinds", "inputKinds", default=[])
    if not kinds:
        kinds = listish(kinds_obj)
    return [kind for kind in kinds if "audio" in str(kind).lower() or "coreaudio" in str(kind).lower()]


def choose_meeting_kind(mode: str, kinds: list) -> str | None:
    if mode == "macOS Audio Capture":
        for kind in ["sck_audio_capture", "coreaudio_output_capture"]:
            if kind in kinds:
                return kind
    if mode in {"Audio Output Capture", "BlackHole / virtual output"}:
        for kind in ["coreaudio_output_capture", "sck_audio_capture"]:
            if kind in kinds:
                return kind
    return None


def choose_mic_kind(kinds: list) -> str | None:
    for kind in ["coreaudio_input_capture", "wasapi_input_capture", "pulse_input_capture"]:
        if kind in kinds:
            return kind
    return None


def input_kind_by_name(client, name: str) -> str | None:
    inputs_obj = client.get_input_list()
    inputs = response_value(inputs_obj, "inputs", default=[])
    for item in inputs:
        if isinstance(item, dict):
            input_name = item.get("inputName") or item.get("input_name")
            input_kind = item.get("inputKind") or item.get("input_kind")
        else:
            input_name = getattr(item, "input_name", None) or getattr(item, "inputName", None)
            input_kind = getattr(item, "input_kind", None) or getattr(item, "inputKind", None)
        if input_name == name:
            return input_kind
    return None


def meeting_input_settings(source_kind: str | None) -> dict:
    if source_kind == "sck_audio_capture":
        # OBS macOS Audio Capture: type 0 = Desktop Audio Capture, type 1 = Application Audio Capture.
        return {"type": 0, "application": ""}
    if source_kind == "coreaudio_output_capture":
        return {"device_id": "default", "enable_downmix": True}
    return {}


def scene_has_source(client, scene_name: str, source_name: str) -> bool:
    try:
        client.get_scene_item_id(scene_name, source_name)
        return True
    except Exception:
        return False


def ensure_scene_item(client, scene_name: str, source_name: str, enabled: bool = True) -> str | None:
    if scene_has_source(client, scene_name, source_name):
        return None
    try:
        client.create_scene_item(scene_name, source_name, enabled)
        return f"Add source to scene: {source_name}"
    except Exception as exc:
        return f"Unable to add source: {source_name}.{exc}"


def recording_mode(cfg: dict) -> str:
    return normalize_config(cfg)["recording_mode"]


def meeting_audio_enabled(cfg: dict) -> bool:
    return recording_mode(cfg) != "mic_only"


def mic_audio_enabled(cfg: dict) -> bool:
    return recording_mode(cfg) != "meeting_only"


def selected_output_kind(cfg: dict) -> str:
    preferred = normalize_config(cfg)["preferred_container"]
    if preferred.startswith("m4a"):
        return "m4a"
    if preferred.startswith("mkv"):
        return "mkv"
    if preferred.startswith("fragmented"):
        return "fragmented_mp4"
    return "mp4"


def obs_record_format(cfg: dict) -> str:
    kind = selected_output_kind(cfg)
    if kind == "mkv":
        return "mkv"
    if kind == "fragmented_mp4":
        return "fragmented_mp4"
    return "hybrid_mp4"


def scene_names(client) -> list:
    scenes_obj = client.get_scene_list()
    scenes = response_value(scenes_obj, "scenes", default=[])
    names = []
    for item in scenes:
        if isinstance(item, dict):
            names.append(item.get("sceneName") or item.get("scene_name"))
        else:
            names.append(getattr(item, "scene_name", None) or getattr(item, "sceneName", None))
    return names


def input_names(client) -> list:
    inputs_obj = client.get_input_list()
    inputs = response_value(inputs_obj, "inputs", default=[])
    names = []
    for item in inputs:
        if isinstance(item, dict):
            names.append(item.get("inputName") or item.get("input_name"))
        else:
            names.append(getattr(item, "input_name", None) or getattr(item, "inputName", None))
    return names


def filter_names(client, source_name: str) -> list:
    filters = filter_entries(client, source_name)
    names = []
    for item in filters:
        if isinstance(item, dict):
            names.append(item.get("filterName") or item.get("filter_name"))
        else:
            names.append(getattr(item, "filter_name", None) or getattr(item, "filterName", None))
    return names


def filter_entries(client, source_name: str) -> list:
    filters_obj = client.get_source_filter_list(source_name)
    return response_value(filters_obj, "filters", default=[])


def filter_identity(item) -> tuple[str, str]:
    if isinstance(item, dict):
        name = item.get("filterName") or item.get("filter_name") or ""
        kind = item.get("filterKind") or item.get("filter_kind") or ""
    else:
        name = getattr(item, "filter_name", None) or getattr(item, "filterName", None) or ""
        kind = getattr(item, "filter_kind", None) or getattr(item, "filterKind", None) or ""
    return str(name), str(kind)


def mic_input_settings(cfg: dict) -> dict:
    hint = str(cfg.get("mic_device_hint") or "Default").strip().lower()
    settings = {"enable_downmix": True}
    if hint in {"", "default", "System default", "system default"}:
        settings["device_id"] = "default"
    return settings


def mute_other_global_mics(client, cfg: dict) -> list[str]:
    muted = []
    mic_name = cfg["mic_source_name"]
    try:
        special = public_attrs(client.get_special_inputs())
    except Exception:
        special = {}

    candidates = set()
    for key in ("mic1", "mic2", "mic3", "mic4"):
        name = special.get(key)
        if name and name != mic_name:
            candidates.add(name)

    for fallback in ("Mic/Aux", "Microphone/Aux"):
        if fallback != mic_name:
            candidates.add(fallback)

    existing = set(input_names(client))
    for name in sorted(candidates):
        if name in existing:
            try:
                client.set_input_mute(name, True)
                muted.append(name)
            except Exception:
                pass
    return muted


def sync_mic_mute(client, cfg: dict) -> str:
    mic_name = cfg["mic_source_name"]
    mic_enabled = mic_audio_enabled(cfg)
    if mic_name not in input_names(client):
        if not mic_enabled:
            return "Microphone capture disabled."
        return f"Microphone source missing: {mic_name}.First click 'Apply OBS Scene/filters'."

    muted_globals = mute_other_global_mics(client, cfg)
    client.set_input_mute(mic_name, not mic_enabled)
    suffix = ""
    if muted_globals:
        suffix = f" Muted OBS Default global microphone: {', '.join(muted_globals)}."
    if mic_enabled:
        return f"Microphone capture enabled.{suffix}"
    return f"Microphone capture disabled; OBS Microphone source muted.{suffix}"


def sync_meeting_mute(client, cfg: dict) -> str:
    meeting_name = cfg["meeting_source_name"]
    existing = set(input_names(client))
    enabled = meeting_audio_enabled(cfg)
    if meeting_name not in existing:
        if enabled:
            return f"Meeting audio source missing: {meeting_name}.First click 'Apply OBS Scene/filters'."
        return "Meeting audio capture disabled."

    if not enabled and recording_mode(cfg) == "mic_only":
        try:
            client.remove_input(meeting_name)
            return "Meeting audio source removed in microphone-only mode to avoid macOS screen/system audio capture permission."
        except Exception as exc:
            try:
                client.set_input_mute(meeting_name, True)
            except Exception:
                pass
            return f"Could not remove meeting audio source; attempted mute: {exc}"

    client.set_input_mute(meeting_name, not enabled)
    if enabled:
        return "Meeting audio capture enabled."
    return "Meeting audio capture disabled; OBS Meeting audio source muted."


def sync_recording_mode(client, cfg: dict) -> list[str]:
    mode = recording_mode(cfg)
    labels = {
        "meeting_and_mic": "Meeting audio + Microphone",
        "meeting_only": "Meeting audio only",
        "mic_only": "Microphone only",
    }
    messages = [f"Recording mode: {labels.get(mode, mode)}."]
    messages.append(sync_meeting_mute(client, cfg))
    messages.append(sync_mic_mute(client, cfg))
    return messages


def source_filter_kinds(client) -> list[str]:
    obj = client.get_source_filter_kind_list()
    kinds = response_value(obj, "source_filter_kinds", "sourceFilterKinds", default=[])
    if not kinds:
        kinds = listish(obj)
    return [str(kind) for kind in kinds]


def upsert_filter(
    client,
    source_name: str,
    filter_name: str,
    filter_kind: str,
    settings: dict,
    enabled: bool = True,
    index: int | None = None,
) -> str:
    exists = filter_name in filter_names(client, source_name)
    if exists:
        client.set_source_filter_settings(source_name, filter_name, settings)
        action = f"Update filter: {filter_name}"
    else:
        client.create_source_filter(source_name, filter_name, filter_kind, settings)
        action = f"Create filter: {filter_name}"

    try:
        client.set_source_filter_enabled(source_name, filter_name, enabled)
    except Exception:
        pass
    if index is not None:
        try:
            client.set_source_filter_index(source_name, filter_name, index)
        except Exception:
            pass
    return action


def disable_filter_if_exists(client, source_name: str, existing_filters: set[str], filter_name: str) -> str | None:
    if filter_name not in existing_filters:
        return None
    try:
        client.set_source_filter_enabled(source_name, filter_name, False)
        return f"Disable filters: {filter_name}"
    except Exception:
        return None


def ensure_voice_filters(client, source_name: str, cfg: dict) -> list[str]:
    actions = []
    kinds = source_filter_kinds(client)
    index = 0
    existing_filters = set(filter_names(client, source_name))
    if recording_mode(cfg) == "mic_only":
        cutoff_kinds = {
            "noise_gate_filter",
            "noise_suppress_filter",
            "noise_suppress_filter_v2",
            "expander_filter",
        }
        for item in filter_entries(client, source_name):
            filter_name, filter_kind = filter_identity(item)
            if filter_name and filter_kind in cutoff_kinds:
                try:
                    client.set_source_filter_enabled(source_name, filter_name, False)
                    actions.append(f"Disable filters that may suppress speech: {filter_name}")
                except Exception:
                    pass
    if "Capture microphone only during speech" in existing_filters:
        try:
            client.remove_source_filter(source_name, "Capture microphone only during speech")
            actions.append("Remove legacy microphone gate")
        except Exception:
            pass
    gate_enabled = bool(cfg.get("enable_gate", True)) and recording_mode(cfg) != "mic_only"
    if not gate_enabled and "02 Capture microphone only during speech" in existing_filters:
        try:
            client.set_source_filter_enabled(source_name, "02 Capture microphone only during speech", False)
            actions.append("Disabled Noise Gate")
        except Exception:
            pass

    if cfg.get("voice_enhancement", True) and cfg.get("noise_suppression", True):
        ns_kind = "noise_suppress_filter_v2" if "noise_suppress_filter_v2" in kinds else "noise_suppress_filter"
        if ns_kind in kinds:
            actions.append(
                upsert_filter(
                    client,
                    source_name,
                    "01 Voice noise suppression RNNoise",
                    ns_kind,
                    {"method": "rnnoise", "suppress_level": -30},
                    True,
                    index,
                )
            )
            index += 1
    else:
        action = disable_filter_if_exists(client, source_name, existing_filters, "01 Voice noise suppression RNNoise")
        if action:
            actions.append(action)

    if gate_enabled and "noise_gate_filter" in kinds:
        gate = {
            "close_threshold": float(cfg["close_threshold"]),
            "open_threshold": float(cfg["open_threshold"]),
            "attack_time": int(cfg["attack_time"]),
            "hold_time": int(cfg["hold_time"]),
            "release_time": int(cfg["release_time"]),
        }
        actions.append(
            upsert_filter(client, source_name, "02 Capture microphone only during speech", "noise_gate_filter", gate, True, index)
        )
        index += 1

    if cfg.get("voice_enhancement", True) and cfg.get("expander_enabled", True) and "expander_filter" in kinds:
        expander = {
            "presets": "expander",
            "ratio": float(cfg["expander_ratio"]),
            "threshold": float(cfg["expander_threshold"]),
            "attack_time": 10,
            "release_time": 100,
            "output_gain": 0.0,
            "detector": "RMS",
        }
        actions.append(upsert_filter(client, source_name, "03 Reduce background noise", "expander_filter", expander, True, index))
        index += 1
    else:
        action = disable_filter_if_exists(client, source_name, existing_filters, "03 Reduce background noise")
        if action:
            actions.append(action)

    if cfg.get("voice_enhancement", True) and cfg.get("compressor_enabled", True) and "compressor_filter" in kinds:
        compressor = {
            "threshold": float(cfg["compressor_threshold"]),
            "ratio": float(cfg["compressor_ratio"]),
            "attack_time": 6,
            "release_time": 120,
            "output_gain": float(cfg["compressor_output_gain"]),
            "sidechain_source": "none",
        }
        actions.append(upsert_filter(client, source_name, "04 Voice compression", "compressor_filter", compressor, True, index))
        index += 1
    else:
        action = disable_filter_if_exists(client, source_name, existing_filters, "04 Voice compression")
        if action:
            actions.append(action)

    if cfg.get("voice_enhancement", True) and cfg.get("limiter_enabled", True) and "limiter_filter" in kinds:
        limiter = {
            "threshold": float(cfg["limiter_threshold"]),
            "release_time": 60,
        }
        actions.append(upsert_filter(client, source_name, "05 Peak limiter", "limiter_filter", limiter, True, index))
    else:
        action = disable_filter_if_exists(client, source_name, existing_filters, "05 Peak limiter")
        if action:
            actions.append(action)

    if actions:
        return actions
    return ["No voice enhancement filters; microphone settings preserved."]


def configure_recording_output(client, cfg: dict) -> list[str]:
    cfg = normalize_config(cfg)
    output_dir = str(pathlib.Path(cfg["output_dir"]).expanduser())
    pathlib.Path(output_dir).mkdir(parents=True, exist_ok=True)
    file_prefix = str(cfg.get("file_prefix") or "meeting_audio").strip() or "meeting_audio"
    filename_format = f"{file_prefix}_%CCYY-%MM-%DD_%hh-%mm-%ss"
    rec_format = obs_record_format(cfg)
    kind = selected_output_kind(cfg)

    actions = []
    for category, values in {
        "Audio": {
            "SampleRate": "48000",
            "ChannelSetup": "Mono" if recording_mode(cfg) == "mic_only" else "Stereo",
        },
        "Output": {"FilenameFormatting": filename_format},
        "SimpleOutput": {
            "FilePath": output_dir,
            "RecQuality": "Small",
            "RecFormat2": rec_format,
            "RecTracks": "1",
            "RecAudioEncoder": "aac",
            "ABitrate": "192",
        },
        "AdvOut": {
            "RecFilePath": output_dir,
            "RecFormat2": rec_format,
            "RecTracks": "1",
            "RecAudioEncoder": "CoreAudio_AAC",
            "Track1Bitrate": "192",
        },
    }.items():
        for name, value in values.items():
            try:
                client.set_profile_parameter(category, name, str(value))
            except Exception:
                pass

    try:
        client.set_record_directory(output_dir)
        actions.append(f"Set output directory: {output_dir}")
    except Exception as exc:
        actions.append(f"Unable to set output directory: {exc}")

    labels = {
        "m4a": "m4a Audio file (OBS Record first mp4, Extract automatically after stopping m4a)",
        "mp4": "mp4",
        "mkv": "mkv",
        "fragmented_mp4": "fragmented mp4",
    }
    actions.append(f"Set recording format: {labels.get(kind, kind)}")
    actions.append("Set local recording quality with pause and resume support")
    actions.append(f"Set filename prefix: {file_prefix}")
    return actions


def latest_recording_file(output_dir: str, since: float | None = None) -> pathlib.Path | None:
    directory = pathlib.Path(output_dir).expanduser()
    candidates = []
    for suffix in ("*.mp4", "*.mov", "*.mkv"):
        candidates.extend(directory.glob(suffix))
    if since is not None:
        candidates = [path for path in candidates if path.stat().st_mtime >= since - 2]
    if not candidates:
        return None
    return max(candidates, key=lambda path: path.stat().st_mtime)


def extract_m4a(recording_path: pathlib.Path, cfg: dict) -> str:
    recording_path = pathlib.Path(recording_path)
    if not recording_path.exists():
        return f"No convertible recording found: {recording_path}"
    if recording_path.suffix.lower() == ".m4a":
        return f"Already m4a: {recording_path}"

    output_path = recording_path.with_suffix(".m4a")
    if output_path.exists():
        stamp = time.strftime("%Y%m%d_%H%M%S")
        output_path = recording_path.with_name(f"{recording_path.stem}_{stamp}.m4a")

    ffmpeg = str(LOCAL_FFMPEG) if LOCAL_FFMPEG.exists() else "ffmpeg"
    result = subprocess.run(
        [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(recording_path), "-vn", "-c:a", "copy", str(output_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=3600,
    )
    if result.returncode != 0:
        result = subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(recording_path), "-vn", "-c:a", "aac", "-b:a", "192k", str(output_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=3600,
        )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        return f"m4a Extraction failed; original recording preserved: {recording_path}.{detail}"
    return f"Extracted m4a Audio file: {output_path}"


def wait_for_recording_stop(client, timeout: float = 8.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = client.get_record_status()
        if not bool(response_value(status, "output_active", "outputActive", default=False)):
            return True
        time.sleep(0.15)
    return False


def set_mic_from_config(cfg: dict) -> str:
    try:
        client = connect_obs(cfg)
    except Exception as exc:
        return f"Microphone setting saved; unable to connect to OBS, Will sync when starting or applying settings. Reason: {exc}"
    try:
        return sync_mic_mute(client, cfg)
    except Exception as exc:
        return f"Microphone setting saved; sync to OBS Failed: {exc}"
    finally:
        client.disconnect()


def apply_obs_config(cfg: dict) -> dict:
    client = connect_obs(cfg, autostart=True)
    actions = []
    try:
        kinds_obj = client.get_input_kind_list(False)
        kinds = response_value(kinds_obj, "input_kinds", "inputKinds", default=[])
        if not kinds:
            kinds = listish(kinds_obj)

        scene_name = cfg["scene_name"]
        if scene_name not in scene_names(client):
            client.create_scene(scene_name)
            actions.append(f"Create scene: {scene_name}")
        else:
            actions.append(f"Scene exists: {scene_name}")

        existing_inputs = input_names(client)

        if meeting_audio_enabled(cfg):
            source_kind = choose_meeting_kind(cfg["meeting_capture_mode"], kinds)
            meeting_name = cfg["meeting_source_name"]
            if source_kind and meeting_name not in existing_inputs:
                settings = meeting_input_settings(source_kind)
                client.create_input(scene_name, meeting_name, source_kind, settings, True)
                actions.append(f"Create meeting audio source: {meeting_name} ({source_kind})")
            elif source_kind:
                existing_kind = input_kind_by_name(client, meeting_name)
                if existing_kind != source_kind:
                    client.remove_input(meeting_name)
                    client.create_input(scene_name, meeting_name, source_kind, meeting_input_settings(source_kind), True)
                    actions.append(f"Rebuild meeting audio source: {meeting_name} ({existing_kind} -> {source_kind})")
                else:
                    client.set_input_settings(meeting_name, meeting_input_settings(source_kind), True)
                    action = ensure_scene_item(client, scene_name, meeting_name, True)
                    if action:
                        actions.append(action)
                    actions.append(f"Meeting audio source exists: {meeting_name}, Configured for computer audio output")
            else:
                actions.append(f"No suitable {cfg['meeting_capture_mode']} source type")
        else:
            actions.append("Microphone-only mode; no meeting audio source created.")

        mic_kind = choose_mic_kind(kinds)
        if mic_kind and cfg["mic_source_name"] not in input_names(client):
            client.create_input(
                scene_name,
                cfg["mic_source_name"],
                mic_kind,
                mic_input_settings(cfg),
                True,
            )
            actions.append(f"Create microphone source: {cfg['mic_source_name']} ({mic_kind})")
        elif mic_kind:
            client.set_input_settings(cfg["mic_source_name"], mic_input_settings(cfg), True)
            action = ensure_scene_item(client, scene_name, cfg["mic_source_name"], True)
            if action:
                actions.append(action)
            actions.append(f"Microphone source exists: {cfg['mic_source_name']}, Synced default system input")
        else:
            actions.append("No microphone source type")

        if mic_kind:
            actions.extend(sync_recording_mode(client, cfg))

        if mic_kind:
            actions.extend(ensure_voice_filters(client, cfg["mic_source_name"], cfg))

        actions.extend(configure_recording_output(client, cfg))

        if cfg.get("low_video_overhead", True):
            try:
                client.set_video_settings(5, 1, 320, 180, 320, 180)
                actions.append("Low-overhead canvas enabled: 320x180 / 5fps")
            except Exception as exc:
                actions.append(f"Unable to configure low-overhead video: {exc}")

        try:
            client.set_current_program_scene(scene_name)
        except Exception:
            pass

        if cfg.get("open_properties_after_apply"):
            property_names = []
            if meeting_audio_enabled(cfg):
                property_names.append(cfg["meeting_source_name"])
            if mic_audio_enabled(cfg):
                property_names.append(cfg["mic_source_name"])
            for name in property_names:
                try:
                    client.open_input_properties_dialog(name)
                    time.sleep(0.2)
                except Exception:
                    pass
            actions.append("Source properties requested")

        return {"actions": actions, "available_audio_kinds": audio_kinds(kinds_obj)}
    finally:
        client.disconnect()


def test_obs(cfg: dict) -> dict:
    client = connect_obs(cfg)
    try:
        version = public_attrs(client.get_version())
        kinds = client.get_input_kind_list(False)
        filters = client.get_source_filter_kind_list()
        return {
            "version": version,
            "available_audio_kinds": audio_kinds(kinds),
            "noise_gate_available": "noise_gate_filter" in str(filters),
        }
    finally:
        client.disconnect()


def recording_status(cfg: dict) -> dict:
    try:
        client = connect_obs(cfg)
    except Exception as exc:
        return {"available": False, "active": False, "error": str(exc)}
    try:
        response = client.get_record_status()
        return {
            "available": True,
            "active": bool(response_value(response, "output_active", "outputActive", default=False)),
            "paused": bool(response_value(response, "output_paused", "outputPaused", default=False)),
            "timecode": str(response_value(response, "output_timecode", "outputTimecode", default="")),
        }
    except Exception as exc:
        return {"available": False, "active": False, "error": str(exc)}
    finally:
        client.disconnect()


def control_recording(cfg: dict, start: bool) -> str:
    current = recording_status(cfg)
    if start and current.get("active"):
        return "OBS Recording already active."
    if not start and current.get("available") and not current.get("active"):
        return "OBS No recording in progress."

    setup_actions = []
    if start:
        setup_actions = apply_obs_config(cfg).get("actions", [])

    client = connect_obs(cfg, autostart=start)
    try:
        if start:
            status = client.get_record_status()
            if bool(response_value(status, "output_active", "outputActive", default=False)):
                return "OBS Recording already active."
            client.start_record()
            return f"{' '.join(setup_actions)} Sent to OBS start recording requested."
        status = client.get_record_status()
        if not bool(response_value(status, "output_active", "outputActive", default=False)):
            return "OBS No recording in progress."
        stopped_at = time.time()
        response = client.stop_record()
        output_path = response_value(response, "output_path", "outputPath", default=None)
        stopped = wait_for_recording_stop(client)
        messages = ["OBS Recording stopped." if stopped else "Stop requested; OBS Finishing file write."]
        if selected_output_kind(cfg) == "m4a":
            recording_path = pathlib.Path(output_path) if output_path else latest_recording_file(cfg["output_dir"], stopped_at)
            if recording_path:
                for _ in range(30):
                    if recording_path.exists() and recording_path.stat().st_size > 0:
                        break
                    time.sleep(0.1)
                messages.append(extract_m4a(recording_path, cfg))
            else:
                messages.append("Stopped recording not found; cannot extract automatically m4a.")
        return " ".join(messages)
    finally:
        client.disconnect()


def control_recording_pause(cfg: dict, pause: bool) -> str:
    client = connect_obs(cfg)
    try:
        status = client.get_record_status()
        active = bool(response_value(status, "output_active", "outputActive", default=False))
        paused = bool(response_value(status, "output_paused", "outputPaused", default=False))
        if not active:
            return "OBS No recording in progress."
        if pause and paused:
            return "OBS Recording already paused."
        if not pause and not paused:
            return "OBS Recording already running."
        if pause:
            client.pause_record()
        else:
            client.resume_record()

        deadline = time.time() + 5
        while time.time() < deadline:
            time.sleep(0.2)
            current = client.get_record_status()
            current_paused = bool(response_value(
                current, "output_paused", "outputPaused", default=False
            ))
            if current_paused == pause:
                if pause:
                    return "OBS Recording paused; file and meeting content preserved."
                return "OBS Recording resumed."
        action = "Pause" if pause else "Resume"
        raise RuntimeError(
            f"OBS received{action}requested, but recording state did not change."
            "Stop and restart recording to use local recording quality with pause support."
        )
    finally:
        client.disconnect()


def open_path(path: pathlib.Path) -> str:
    if not path.exists():
        raise FileNotFoundError(str(path))
    subprocess.Popen(["open", str(path)])
    return f"Requested opening: {path}"


class Handler(BaseHTTPRequestHandler):
    server_version = "OBSAudioGUI/1.0"

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            self.send_html(HTML)
        elif parsed.path == "/api/config":
            self.send_json(load_config())
        elif parsed.path == "/api/copilot_ai_config":
            self.send_json({"ok": True, "config": ai_config_payload(load_config())})
        elif parsed.path == "/api/recording_status":
            self.send_json(recording_status(load_config()))
        elif parsed.path == "/api/copilot_rules":
            from copilot_rule_library import catalog
            try:
                kind = urllib.parse.parse_qs(parsed.query).get("kind", ["interview"])[0]
                self.send_json(catalog(kind))
            except ValueError as exc:
                self.send_json({"ok": False, "error": str(exc)})
        else:
            self.send_error(404)

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        try:
            data = self.read_json()
            if parsed.path == "/api/config":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": f"Settings saved: {CONFIG_PATH}", "config": cfg})
            elif parsed.path == "/api/copilot_ai_config":
                cfg = save_ai_config(data)
                self.send_json({
                    "ok": True,
                    "message": "AI Analysis settings saved.",
                    "config": ai_config_payload(cfg),
                })
            elif parsed.path == "/api/copilot_rules/import":
                from copilot_rule_library import import_rule
                self.send_json(import_rule(data.get("kind"), data.get("filename"), data.get("content")))
            elif parsed.path == "/api/copilot_research/cancel":
                from copilot_research import cancel_research
                cancel_research(data.get("request_id"))
                self.send_json({"ok": True})
            elif parsed.path == "/api/copilot_research":
                from copilot_research import research
                self.send_json({"ok": True, "report": research(data, load_config())})
            elif parsed.path == "/api/copilot_ai_test":
                if reasoning_json is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                previous_cfg = load_config()
                try:
                    cfg = save_ai_config(data)
                    result = reasoning_json(
                        cfg,
                        "You test a connection. Output only JSON.",
                        'Output {"connected":true,"message":"Connected"}',
                        num_predict=80,
                    )
                finally:
                    save_config(previous_cfg)
                if result.get("connected") is not True:
                    raise RuntimeError("Model response failed connection test")
                self.send_json({
                    "ok": True,
                    "message": "Connected.",
                    "config": ai_config_payload(cfg),
                })
            elif parsed.path == "/api/open_obs":
                cfg = save_config(data)
                cfg, ws_message = ensure_obs_websocket_config(cfg)
                open_message = open_obs_app(bool(cfg.get("hide_obs_window", True)))
                self.send_json({"ok": True, "message": f"{ws_message}\n{open_message}", "config": cfg})
            elif parsed.path == "/api/open_installer":
                dmgs = sorted(APP_DIR.glob("OBS-Studio-*-macOS-Apple.dmg"))
                if not dmgs:
                    raise FileNotFoundError("Not found OBS macOS Apple DMG")
                self.send_json({"ok": True, "message": open_path(dmgs[-1])})
            elif parsed.path == "/api/guide":
                cfg = save_config(data)
                guide = build_guide(cfg)
                GUIDE_PATH.write_text(guide, encoding="utf-8")
                self.send_json({"ok": True, "message": f"Guide created: {GUIDE_PATH}", "guide": guide})
            elif parsed.path == "/api/copy_guide":
                cfg = save_config(data)
                guide = build_guide(cfg)
                subprocess.run(["pbcopy"], input=guide, text=True, check=True)
                self.send_json({"ok": True, "message": "Guide copied to clipboard."})
            elif parsed.path == "/api/test_obs":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": "OBS Connected.", "details": test_obs(cfg)})
            elif parsed.path == "/api/set_mic":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": set_mic_from_config(cfg)})
            elif parsed.path == "/api/apply_obs":
                cfg = save_config(data)
                result = apply_obs_config(cfg)
                self.send_json({"ok": True, "message": "Apply OBS completed.", "details": result})
            elif parsed.path == "/api/start_recording":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": control_recording(cfg, True)})
            elif parsed.path == "/api/pause_recording":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": control_recording_pause(cfg, True)})
            elif parsed.path == "/api/resume_recording":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": control_recording_pause(cfg, False)})
            elif parsed.path == "/api/stop_recording":
                cfg = save_config(data)
                self.send_json({"ok": True, "message": control_recording(cfg, False)})
            elif parsed.path == "/api/copilot_start":
                if get_copilot_controller is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                cfg = save_config(data)
                cfg["enable_copilot"] = True
                cfg = save_config(cfg)
                details = get_copilot_controller().start(cfg)
                self.send_json({"ok": True, "message": "Meeting Copilot started.", "details": details})
            elif parsed.path == "/api/open_copilot_app":
                if not COPILOT_APP.exists():
                    raise FileNotFoundError(f"No independent Copilot: {COPILOT_APP}")
                subprocess.Popen(["open", str(COPILOT_APP)])
                self.send_json({"ok": True, "message": "Opened Meeting Copilot."})
            elif parsed.path == "/api/copilot_stop":
                if get_copilot_controller is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                cfg = save_config(data)
                cfg["enable_copilot"] = False
                save_config(cfg)
                details = get_copilot_controller().stop()
                self.send_json({"ok": True, "message": "Stopping Meeting Copilot.", "details": details})
            elif parsed.path == "/api/copilot_status":
                if get_copilot_controller is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                self.send_json({"ok": True, "details": get_copilot_controller().status()})
            elif parsed.path == "/api/copilot_analyze_latest":
                if get_copilot_controller is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                cfg = save_config(data)
                details = get_copilot_controller().analyze_latest(cfg)
                self.send_json({"ok": True, "message": "Recent recording analysis complete.", "details": details})
            elif parsed.path == "/api/copilot_live_transcript":
                if get_copilot_controller is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                cfg = load_config()
                mode = str(data.get("interview_mode") or "initial")
                from copilot_rule_library import load_rule
                _, rule_version = load_rule("interview", mode)
                background = str(data.get("project_context") or "")
                if len(background) > 6000:
                    raise ValueError("Meeting background limit: 6000characters or fewer")
                cfg["copilot_interview_mode"] = mode
                cfg["copilot_rule_version"] = rule_version
                cfg["copilot_project_context"] = background
                cfg["copilot_terminology_notes"] = str(data.get("terminology_notes") or "")[:2000]
                cfg["copilot_questioner_speaker"] = data.get("questioner_speaker") if data.get("questioner_speaker") in {"Me", "Other", "Microphone", "System"} else ""
                cfg["copilot_session_id"] = str(data.get("session_id") or "")[:80]
                restored = data.get("restore_cards", [])
                cfg["copilot_restore_cards"] = restored[:500] if isinstance(restored, list) else []
                cfg["copilot_restore_usage"] = data.get("restore_usage", {})
                checkpoint = data.get("restore_checkpoint")
                cfg["copilot_restore_checkpoint"] = checkpoint if isinstance(checkpoint, str) and len(checkpoint) <= 500_000 else None
                marks = data.get("asked_questions", {})
                cfg["copilot_asked_questions"] = marks if isinstance(marks, dict) and len(marks) <= 500 else {}
                cfg["copilot_correction_revision"] = str(data.get("correction_revision") or "")[:80]
                details = get_copilot_controller().analyze_live_transcript(
                    cfg,
                    str(data.get("transcript") or ""),
                )
                self.send_json({"ok": True, "details": details})
            elif parsed.path == "/api/copilot_live_reset":
                if get_copilot_controller is None:
                    raise RuntimeError(f"Copilot component failed to load: {COPILOT_IMPORT_ERROR}")
                details = get_copilot_controller().reset_live_analysis(
                    session_id=str(data.get("session_id") or "")[:80],
                    previous_session_id=data.get("previous_session_id"))
                self.send_json({"ok": True, "details": details})
            else:
                self.send_error(404)
        except Exception as exc:
            self.send_json(
                {
                    "ok": False,
                    "error": str(exc),

                },
                status=500,
            )

    def read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        data = json.loads(raw.decode("utf-8"))
        if not isinstance(data, dict):
            return {}
        return data

    def send_html(self, html: str) -> None:
        encoded = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def send_json(self, data: dict, status: int = 200) -> None:
        encoded = json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args) -> None:
        print(f"[{time.strftime('%H:%M:%S')}] {fmt % args}")


def find_free_port(preferred: int) -> int:
    for port in [preferred, *range(8766, 8790)]:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("No available port")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()

    DEFAULT_OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    port = find_free_port(args.port)
    url = f"http://127.0.0.1:{port}/"
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"OBS Audio GUI: {url}")
    print("Press Ctrl+C to stop.")
    if not args.no_open:
        subprocess.Popen(["open", url])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
