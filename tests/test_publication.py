"""Publication checks use invented identifiers, never actual credentials."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("privacy_check", ROOT / "scripts/privacy_check.py")
privacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(privacy)


class PublicationTests(unittest.TestCase):
    def test_credential_patterns_detect_synthetic_token(self):
        invented = "s" + "k-" + "x" * 30
        self.assertTrue(privacy.PATTERNS["API token"].search(invented))

    def test_literal_assignment_is_detected(self):
        invented = "api_" + "key = '" + "x" * 30 + "'"
        self.assertTrue(privacy.PATTERNS["assigned credential"].search(invented))

    def test_blank_defaults_are_allowed(self):
        self.assertFalse(privacy.PATTERNS["assigned credential"].search('api_key = ""'))
        self.assertFalse(privacy.PATTERNS["literal credential"].search('"obs_password": ""'))

    def test_examples_are_marked_and_have_no_contacts(self):
        for path in (ROOT / "examples").glob("*.md"):
            text = path.read_text()
            self.assertTrue("fictional" in text.lower() or "invented" in text.lower(), path.name)
            self.assertNotIn("@", text, path.name)

    def test_english_source_contains_no_legacy_personal_paths(self):
        for path in list(ROOT.glob("*.py")) + list((ROOT / "MeetingCopilotApp").glob("*.swift")):
            self.assertFalse(privacy.PATTERNS["personal absolute path"].search(path.read_text()), path.name)


if __name__ == "__main__":
    unittest.main()
