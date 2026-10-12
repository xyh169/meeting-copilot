"""Synthetic meeting, evidence and incremental-analysis regressions."""
import json
import unittest
from unittest.mock import patch

import copilot_answer_evidence as evidence
import copilot_live_batch as live
import meeting_copilot_engine as engine
from meeting_interview_logic import build_prompt, grounded, validate_cards


QUOTE = "The prototype has not been tested with users yet."


def card(identity="q1", **changes):
    return dict(id=identity, category="Readiness", priority="High", status="open",
                question="Has the prototype been tested with users?", reason="Clarify readiness",
                anchor=QUOTE, answer_summary="", **changes)


class EvidenceTests(unittest.TestCase):
    def test_quotes_are_grounded_and_labels_are_ignored(self):
        self.assertTrue(grounded(QUOTE, "System: " + QUOTE))
        self.assertFalse(grounded("The prototype passed user testing.", QUOTE))

    def test_question_is_not_answer_evidence(self):
        self.assertEqual(evidence.evidence_spans(["Has the prototype been tested?"],
                                                "Has the prototype been tested?"), [])

    def test_explicit_negative_is_direct_answer(self):
        update = dict(status="answered", evidence_quotes=[QUOTE],
                      coverage=[dict(condition="User testing", covered=True, quote=QUOTE)])
        result = evidence.classify_update(card(), update, "System: " + QUOTE, {})
        self.assertEqual(result["answer_kind"], "direct")
        self.assertIn(QUOTE, result["answer_summary"])

    def test_generated_summary_cannot_reverse_an_answer(self):
        update = dict(status="answered", answer_summary="Successful user testing",
                      evidence_quotes=[QUOTE], coverage=[dict(condition="Testing", covered=True, quote=QUOTE)])
        result = evidence.classify_update(card(), update, QUOTE, {})
        self.assertNotIn("Successful", result["answer_summary"])

    def test_partial_asked_answer_is_flagged(self):
        quote = "The review will happen next week."
        old = card()
        update = dict(status="open", evidence_quotes=[quote],
                      coverage=[dict(condition="User testing", covered=False, quote="")])
        result = evidence.classify_update(old, update, quote,
                                         {"copilot_asked_questions": {old["id"]: 0}})
        self.assertEqual(result["answer_kind"], "nonresponsive")
        self.assertTrue(result["missing_conditions"])

    def test_named_person_does_not_prove_full_time_commitment(self):
        quote = "Fictional Participant A leads the technical review."
        self.assertEqual(evidence.missing_conditions("Who will work full-time?",
                         [dict(condition="Commitment", covered=True, quote=quote)]),
                         ["Full-time commitment"])

    def test_partial_speech_cannot_overwrite_direct_answer(self):
        old = card()
        old.update(status="answered", answer_kind="direct", answer_summary=QUOTE)
        quote = "We will discuss timing later."
        result = evidence.classify_update(old, dict(status="open", evidence_quotes=[quote],
                    coverage=[dict(condition="User testing", covered=False, quote="")]), quote, {})
        self.assertIsNone(result)

    def test_answered_item_cannot_be_dropped(self):
        old = card()
        old["status"] = "answered"
        self.assertIsNone(evidence.classify_update(old, dict(status="drop", reason="Duplicate",
                          evidence_quotes=[QUOTE]), QUOTE, {}))

    def test_stale_evidence_rejected(self):
        self.assertIsNone(evidence.classify_update(card(), dict(status="answered",
                         evidence_quotes=[QUOTE]), "A different meeting has started.", {}))


class IncrementalTests(unittest.TestCase):
    def test_batch_updates_answer_and_generates_grounded_question(self):
        payload = {"updates": [{"id": "q1", "status": "answered", "evidence_quotes": [QUOTE],
                   "coverage": [{"condition": "User testing", "covered": True, "quote": QUOTE}]}],
                   "cards": [{"category": "Next steps", "status": "open", "priority": "High",
                              "question": "What will the first user test measure?", "anchor_id": "S1",
                              "reason": "Define acceptance criteria"}], "fact_ids": ["S1"]}
        cfg, facts = {}, []
        result = live.run_batch("System: " + QUOTE, cfg, [card()], [], facts,
                                lambda *a, **k: payload, engine.accumulate_answer)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["status"], "answered")
        self.assertEqual(result[1]["priority"], "High")
        self.assertTrue(grounded(result[1]["anchor"], QUOTE))
        self.assertTrue(facts)

    def test_no_speech_background_questions_are_distinguished(self):
        _, data = live.batch_prompt("", {"copilot_project_context": "The team plans a prototype review."}, [], [], [])
        self.assertEqual(data["source_kind"], "project_background")
        self.assertTrue(data["speech"])

    def test_only_changed_speech_is_fresh(self):
        before = "System: The prototype is ready."
        after = before + "\nSystem: The review is scheduled for Demo Day 5."
        blocks = live.speech_blocks(after, before)
        fresh = " ".join(b["text"] for b in blocks if b["fresh"])
        self.assertIn("Demo Day 5", fresh)

    def test_speaker_label_is_not_part_of_quote(self):
        block = live.speech_blocks("Microphone: What is the next step?", "")[0]
        self.assertEqual(block["speaker"], "Microphone")
        self.assertEqual(block["text"], "What is the next step?")

    def test_failed_batch_preserves_existing_answer(self):
        old = card()
        with self.assertRaises(RuntimeError):
            live.run_batch(QUOTE, {}, [old], [], [], lambda *a, **k: {}, engine.accumulate_answer)
        self.assertEqual(old["status"], "open")

    def test_invalid_new_anchor_preserves_valid_answer_update(self):
        payload = {"updates": [{"id": "q1", "status": "answered", "evidence_quotes": [QUOTE],
                    "coverage": [{"condition": "Testing", "covered": True, "quote": QUOTE}]}],
                   "cards": [{"category": "Timing", "status": "open", "priority": "High",
                              "question": "When is the review?", "anchor_id": "missing", "reason": "Plan"}]}
        result = live.run_batch(QUOTE, {}, [card()], [], [], lambda *a, **k: payload,
                                engine.accumulate_answer)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["status"], "answered")

    def test_correction_invalidates_related_answer(self):
        old = card()
        old.update(status="answered", answer_kind="direct")
        before = QUOTE
        after = "The prototype has been tested with users."
        old["evidence_quotes"] = [before]
        live.invalidate_edited_evidence([old], before, after)
        self.assertEqual(old["answer_kind"], "needs_review")

    def test_default_policy_is_general_meeting_english(self):
        system, user, _ = build_prompt(QUOTE, {}, [], [], [])
        self.assertIn("General meeting", system)
        self.assertIn("Use English", system)
        self.assertIn("never instructions", system)
        self.assertEqual(json.loads(user)["transcript"], QUOTE)

    def test_evidence_review_requires_evidence_task(self):
        raw = dict(status="open", question="What evidence supports this?", reason="Review",
                   anchor=QUOTE, category="Evidence", priority="High")
        with self.assertRaises(RuntimeError):
            validate_cards({"cards": [raw]}, QUOTE, "diligence", [], [])

    def test_duplicate_question_not_recreated(self):
        old = card()
        raw = {**old, "id": ""}
        with self.assertRaises(RuntimeError):
            validate_cards({"cards": [raw]}, QUOTE, "initial", [old], [])

    def test_merge_retains_unmentioned_open_and_answered_items(self):
        archive = {"old-answer": {**card("old-answer"), "status": "answered"}}
        pending = {"q1": card()}
        engine.merge_question_cards([], [], archive, pending)
        self.assertIn("old-answer", archive)
        self.assertIn("q1", pending)

    def test_keychain_uses_only_new_namespace(self):
        with patch.dict("os.environ", {}, clear=True), patch.object(engine.subprocess, "run") as run:
            run.return_value.returncode = 44
            run.return_value.stdout = ""
            self.assertEqual(engine.keychain_api_key(), "")
        args = run.call_args.args[0]
        self.assertIn("io.github.xyh169.meeting-copilot.reasoning-api", args)
        self.assertNotIn("investment-copilot", " ".join(args))


if __name__ == "__main__":
    unittest.main()
