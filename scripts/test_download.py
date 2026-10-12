"""Verify the extracted App and disk image after relocation."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.0.0"
ARCHIVE = ROOT / f"dist/Meeting-Copilot-{VERSION}-macOS-arm64.zip"
DMG = ROOT / f"dist/Meeting-Copilot-{VERSION}-macOS-arm64.dmg"


def main():
    with tempfile.TemporaryDirectory(prefix="meeting-copilot-download-") as directory:
        target = Path(directory)
        subprocess.run(["ditto", "-x", "-k", str(ARCHIVE), str(target)], check=True)
        app = target / "Meeting Copilot.app"
        resources = app / "Contents/Resources"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert "CopilotSourceDirectory" not in info
        assert info["CFBundleShortVersionString"] == VERSION
        assert info["LSMinimumSystemVersion"] == "26.0"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        subprocess.run([str(ROOT / ".venv/bin/python"), str(ROOT / "scripts/check_bundle.py"), str(app)], check=True)
        workspace = target / "User Workspace"
        shutil.copytree(resources / "Backend", workspace)
        assert not (workspace / "obs_audio_config.json").exists()
        assert not list(workspace.rglob("*.sqlite"))
        python = resources / "python/bin/python3"
        environment = dict(os.environ)
        environment.update(PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1")
        for key in ("PYTHONPATH", "PYTHONHOME", "COPILOT_APP_DIR", "MEETING_COPILOT_API_KEY"):
            environment.pop(key, None)
        subprocess.run([str(python), "-c", "import ssl, sqlite3, pypdf, obsws_python"],
                       cwd=workspace, env=environment, check=True)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        process = subprocess.Popen([str(python), "obs_audio_web_gui.py", "--no-open", "--port", str(port)],
                                   cwd=workspace, env=environment, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.PIPE)
        base = f"http://127.0.0.1:{port}"
        try:
            for _ in range(80):
                if process.poll() is not None:
                    raise RuntimeError("Bundled backend exited at startup")
                try:
                    config = json.load(urllib.request.urlopen(base + "/api/config", timeout=1))
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("Bundled backend did not start")
            assert config["obs_password"] == ""
            assert config["copilot_api_model"] == ""
            assert config["copilot_reference_doc_1"] == ""
            for kind, expected in [("interview", {"initial", "diligence", "action-items"}),
                                   ("research", {"default"})]:
                catalog = json.load(urllib.request.urlopen(base + "/api/copilot_rules?kind=" + kind))
                assert expected <= {r["id"] for r in catalog["rules"] if not r["error"]}
            request = urllib.request.Request(base + "/api/config", data=b"{}",
                                             headers={"Content-Type": "application/json"})
            assert json.load(urllib.request.urlopen(request))["ok"]
            assert (workspace / "obs_audio_config.json").stat().st_mode & 0o777 == 0o600
        finally:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

        mount = target / "Disk Image"
        mount.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(DMG)],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            installed = mount / "Meeting Copilot.app"
            assert (mount / "Applications").is_symlink()
            assert (mount / "Applications").readlink() == Path("/Applications")
            assert (mount / "Install.txt").is_file()
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
            assert hashlib.sha256((installed / "Contents/MacOS/MeetingCopilot").read_bytes()).digest() == \
                   hashlib.sha256((app / "Contents/MacOS/MeetingCopilot").read_bytes()).digest()
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True, stdout=subprocess.DEVNULL)
    print("Download checks passed: relocated App, signature, bundled Python, localhost backend, rules, settings and DMG install layout")


if __name__ == "__main__":
    main()
