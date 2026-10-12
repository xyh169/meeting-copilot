"""Rule import, local research boundaries and localhost API tests with synthetic data."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.request

import copilot_research as research
import copilot_rule_library as rules
import obs_audio_web_gui as web


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        default = root / "research-rules.md"
        default.write_text("# Synthetic research\nUse English and cite evidence.")
        self.patches = [patch.object(rules, "LIBRARY", root / "rules"),
                        patch.object(rules, "DEFAULT_RESEARCH", default)]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.temp.cleanup()

    def test_import_cannot_choose_path(self):
        result = rules.import_rule("interview", "../../outside.md", "# Fictional planning\nClarify owners.")
        path = rules.resolve("interview", result["selected"])
        self.assertEqual(path.parent, rules.folder("interview"))
        self.assertTrue(path.name.startswith("rule-"))

    def test_same_filename_does_not_overwrite(self):
        first = rules.import_rule("interview", "planning.md", "# First\nFirst synthetic rule.")
        second = rules.import_rule("interview", "planning.md", "# Second\nSecond synthetic rule.")
        self.assertNotEqual(first["selected"], second["selected"])
        self.assertIn("First", rules.load_rule("interview", first["selected"])[0])

    def test_edited_rule_changes_version(self):
        result = rules.import_rule("interview", "planning.md", "# Planning\nClarify owners.")
        version = rules.load_rule("interview", result["selected"])[1]
        rules.resolve("interview", result["selected"]).write_text("# Planning\nClarify owners and deadlines.")
        self.assertNotEqual(version, rules.load_rule("interview", result["selected"])[1])

    def test_missing_rule_raises(self):
        with self.assertRaises(ValueError):
            rules.resolve("interview", "missing")

    def test_symlink_is_not_catalogued(self):
        target = Path(self.temp.name) / "outside.md"
        target.write_text("# External\nSynthetic content.")
        (rules.folder("interview") / "link.md").symlink_to(target)
        self.assertNotIn("link", rules.paths("interview"))

    def test_blank_rule_rejected(self):
        with self.assertRaises(ValueError):
            rules.import_rule("interview", "empty.md", "  ")


class ResearchTests(unittest.TestCase):
    def test_private_ip_rejected(self):
        for url in ("http://127.0.0.1/", "http://10.0.0.1/", "http://169.254.169.254/", "file:///private"):
            self.assertFalse(research.public_url(url), url)

    def test_missing_local_documents_do_not_invent_hits(self):
        with tempfile.TemporaryDirectory() as directory:
            hits, note = research.local_project_search(["synthetic"],
                         Path(directory) / "missing", Path(directory) / "index.sqlite")
            self.assertEqual(hits, [])
            self.assertIn("unavailable", note.lower())

    def test_cancellation_preserves_results_by_stopping_new_work(self):
        import uuid
        identity = str(uuid.uuid4())
        research.cancel_research(identity)
        with self.assertRaises(RuntimeError):
            research.check_cancelled(identity)

    def test_manual_answer_does_not_require_web_results(self):
        plan = dict(ready=False, terms=[], topic="Review plan", public_queries=[])
        answer = {"sections": [{"category": "Manual Q&A", "title": "Review plan",
                   "body": "The review needs a test dataset; no launch date has been decided.",
                   "status": "inferred", "source_ids": []}]}
        with patch.object(research, "reasoning_json", side_effect=[plan, answer]), \
             patch.object(research, "local_project_search", return_value=([], "")), \
             patch.object(research, "pikg_search", return_value=([], "")):
            result = research.research({"question": "What is needed for review?", "web_enabled": False},
                                       {"copilot_reasoning_provider": "ollama"})
        self.assertEqual(result["sections"][0]["category"], "Manual Q&A")
        self.assertEqual(result["sections"][0]["status"], "inferred")

    def test_automatic_short_discussion_does_not_call_model(self):
        with patch.object(research, "reasoning_json") as call:
            result = research.research({"automatic": True,
                      "transcript": "The team is discussing a synthetic search prototype.",
                      "discussion_segments": []}, {"copilot_reasoning_provider": "ollama"})
        self.assertTrue(result["skipped"])
        call.assert_not_called()


class LocalAPITests(unittest.TestCase):
    def test_clean_config_and_rule_catalog(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(web, "CONFIG_PATH", Path(directory) / "config.json"):
            server = web.ThreadingHTTPServer(("127.0.0.1", 0), web.Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = f"http://127.0.0.1:{server.server_port}"
            try:
                cfg = json.load(urllib.request.urlopen(base + "/api/config"))
                self.assertEqual(cfg["obs_password"], "")
                self.assertEqual(cfg["copilot_reference_doc_1"], "")
                self.assertFalse(any("key" in key.lower() for key in cfg))
                catalog = json.load(urllib.request.urlopen(base + "/api/copilot_rules?kind=interview"))
                self.assertEqual({r["id"] for r in catalog["rules"]}, {"initial", "diligence", "action-items"})
                html = urllib.request.urlopen(base + "/").read().decode()
                self.assertIn('<html lang="en">', html)
                self.assertIn("Meeting audio", html)
            finally:
                server.shutdown()
                thread.join()
                server.server_close()

    def test_settings_file_is_private(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(web, "CONFIG_PATH", Path(directory) / "config.json"):
            web.save_config({})
            self.assertEqual(web.CONFIG_PATH.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
