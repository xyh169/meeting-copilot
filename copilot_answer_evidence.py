"""Conservative evidence gates, separate from model-written answer summaries."""

import re

from meeting_interview_logic import clean_quote, grounded, normalized


def question_evidence(quote):
    text = str(quote).strip()
    return bool(re.search(r"[?]|^(?:who|what|when|where|why|how|which|do|does|did|is|are|can|could|will|would|have|has)\b", text, re.I))


def evidence_spans(values, transcript):
    if not isinstance(values, list):
        return []
    return list(dict.fromkeys(clean_quote(v) for v in values[:8]
                              if isinstance(v, str) and not question_evidence(v) and grounded(v, transcript)))


def missing_conditions(question, proofs):
    """Model coverage is necessary, not sufficient for easily conflated qualifiers."""
    missing = [str(p.get("condition") or "Question condition") for p in proofs
               if p.get("covered") is not True]
    evidence = "\n".join(str(p.get("quote") or "") for p in proofs if p.get("covered") is True)
    guards = []
    if re.search(r"full[- ]time", question, re.I):
        guards.append(("Full-time commitment", r"full[- ]time|exclusively|all (?:my|their|our) time"))
    if re.search(r"third[- ]party|independent", question, re.I) and re.search(r"report|test|audit", question, re.I):
        guards.append(("Independent evidence", r"third[- ]party|independent|external (?:lab|audit|test)"))
    if re.search(r"ownership|licen[cs]e|IP rights", question, re.I):
        guards.append(("Ownership or license", r"own|licen[cs]|rights|agreement|assign|transfer"))
    for label, pattern in guards:
        if not re.search(pattern, evidence, re.I):
            missing.append(label)
    return list(dict.fromkeys(missing))


def classify_update(old, update, transcript, cfg):
    spans = evidence_spans(update.get("evidence_quotes", [update.get("anchor", "")]), transcript)
    if not spans:
        return None
    if update.get("status") == "drop":
        if old.get("status") == "answered" or not update.get("reason"):
            return None
        return {**old, **update, "question": old["question"], "anchor": spans[0], "evidence_quotes": spans}
    proofs = update.get("coverage")
    if not isinstance(proofs, list) or not proofs:
        proofs = [{"condition": "Missing evidence for required conditions", "covered": False}]
    proofs = [dict(p) for p in proofs[:8] if isinstance(p, dict)]
    contexts = list(spans) + evidence_spans(old.get("evidence_quotes", []), transcript)
    for entry in old.get("answer_history", []):
        if isinstance(entry, dict):
            contexts.extend(evidence_spans(entry.get("evidence_quotes", [entry.get("anchor", "")]), transcript))
    contexts = [c for c in contexts if isinstance(c, str) and grounded(c, transcript) and not question_evidence(c)]
    for proof in proofs:
        fragment = clean_quote(proof.get("quote", ""))
        if proof.get("covered") is True and 2 <= len(normalized(fragment)) < 6 and not question_evidence(fragment):
            # Keep the normal grounding minimum; expand short qualifiers only inside cited, grounded context.
            context = next((c for c in contexts if normalized(fragment) in normalized(c)), None)
            if context:
                proof["quote_fragment"], proof["quote"] = fragment, context
        if proof.get("covered") is True and (question_evidence(proof.get("quote", "")) or not grounded(proof.get("quote", ""), transcript)):
            proof["covered"] = False
    if old.get("status") == "answered" and old.get("answer_kind") == "direct":
        prior = [dict(p) for p in old.get("coverage", []) if isinstance(p, dict)
                 and p.get("covered") is True and not question_evidence(p.get("quote", ""))
                 and grounded(p.get("quote", ""), transcript)]
        # New dates/details should not have to restate the already evidenced full-time commitment.
        proofs = prior + [p for p in proofs if p not in prior]
    missing = missing_conditions(old["question"], proofs)
    if not proofs:
        missing = ["Missing evidence for required conditions"]
    direct = not missing and update.get("status") == "answered"

    # Audio channels are not speaker diarization; the UI lets the user select the questioner channel.
    speaker = cfg.get("copilot_questioner_speaker", "")
    asked_quote = str(update.get("asked_quote") or "")
    asked_conditions_match = not missing_conditions(old["question"], [{"covered": True, "quote": asked_quote}])
    asked_line = next((i for i, line in enumerate(transcript.splitlines())
                       if speaker and asked_conditions_match and re.match(re.escape(speaker) + r"\s*[:: ]", line)
                       and grounded(asked_quote, line)
                       and question_evidence(asked_quote)), None)
    lines = transcript.splitlines()
    automatic_asked = asked_line is not None and any(
        grounded(span, "\n".join(lines[asked_line + 1:])) for span in spans)
    marks = cfg.get("copilot_asked_questions", {})
    offset = marks.get(old.get("id")) if isinstance(marks, dict) else None
    manual_asked = isinstance(offset, int) and not isinstance(offset, bool) and 0 <= offset <= len(transcript) and any(
        grounded(span, transcript[offset:]) for span in spans)
    was_nonresponsive = old.get("answer_kind") == "nonresponsive"
    nonresponsive = not direct and (automatic_asked or manual_asked or was_nonresponsive)
    status = "answered" if direct or nonresponsive else "open"
    review = old.get("status") == "answered" and old.get("answer_kind") == "needs_review" and not direct and not nonresponsive
    if review:
        status = "answered"
    if old.get("status") == "answered" and not was_nonresponsive and not direct and not review:
        # Unrelated/partial additions cannot silently corrupt a previously accepted direct answer.
        return None
    if not direct:
        # A rejected classification must not survive as an unsupported claim in the summary.
        update = {**update, "answer_summary": "Related speech: " + "\n".join(spans),
                  "reason": "Still missing: " + ", ".join(missing)}
    else:
        # Grounded classification does not prove a generated paraphrase is faithful (e.g. reversed roles).
        update = {**update, "answer_summary": "Quoted answer: " + "\n".join(spans)}
    return {**old, **update, "question": old["question"], "status": status,
            "answer_kind": "nonresponsive" if nonresponsive else "needs_review" if review else ("direct" if direct else "partial"),
            "anchor": spans[0], "evidence_quotes": spans, "coverage": proofs,
            "missing_conditions": missing, "asked_quote": asked_quote if automatic_asked else old.get("asked_quote", ""),
            "verification": "Nonresponsive; conditions still missing" if nonresponsive else "Answered; evidence unverified" if direct else ""}
