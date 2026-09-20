"""Tests for lib/parse_input.py — input JSON → normalized fields."""
from __future__ import annotations

import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))

import parse_input  # noqa: E402


def _fixture(name: str) -> str:
    with open(os.path.join(HERE, "fixtures", name), "r", encoding="utf-8") as f:
        return f.read()


class TestParseStdin(unittest.TestCase):
    def test_basic_fixture(self) -> None:
        d = parse_input.parse_stdin(_fixture("basic.json"))
        self.assertEqual(d["cwd"], "/Users/example/projects/widget")
        self.assertEqual(d["model"], "MiniMax-M3")
        self.assertEqual(d["effort"], "high")
        self.assertEqual(d["branch"], "main")
        self.assertEqual(d["ctx_pct"], "97")
        # 1_000_000 - (28559+68) = 971373 → "971k"
        self.assertEqual(d["ctx_toks"], "971k")

    def test_empty_fixture(self) -> None:
        d = parse_input.parse_stdin(_fixture("empty.json"))
        self.assertEqual(d["cwd"], "/tmp")
        self.assertEqual(d["ctx_pct"], "")  # null fields
        self.assertEqual(d["ctx_toks"], "")

    def test_opus_200k_fixture(self) -> None:
        d = parse_input.parse_stdin(_fixture("opus-200k.json"))
        # parse_input prefers display_name over id; the fixture sets display_name.
        self.assertEqual(d["model"], "Claude Opus 4.7")
        self.assertEqual(d["effort"], "max")
        # parse_stdin recomputes from total/used when both are present
        # (200000 - 195000) / 200000 * 100 = 2.5 → banker's-round to 2.
        self.assertEqual(d["ctx_pct"], "2")

    def test_garbage_input(self) -> None:
        d = parse_input.parse_stdin("not json at all")
        self.assertEqual(d["cwd"], "")
        self.assertEqual(d["model"], "unknown")
        self.assertEqual(d["effort"], "default")
        self.assertEqual(d["ctx_pct"], "")

    def test_empty_input(self) -> None:
        d = parse_input.parse_stdin("")
        self.assertEqual(d["model"], "unknown")
        self.assertEqual(d["effort"], "default")

    def test_alternate_key_names(self) -> None:
        # Some MiniMax versions use top-level cwd / model_id.
        text = json.dumps({"cwd": "/x", "model_id": "claude-x", "effort_level": "low"})
        d = parse_input.parse_stdin(text)
        self.assertEqual(d["cwd"], "/x")
        self.assertEqual(d["model"], "claude-x")
        self.assertEqual(d["effort"], "low")

    def test_workspace_string_fallback(self) -> None:
        # workspace can sometimes be a plain string, not a dict.
        text = json.dumps({"workspace": "/fallback/path", "model": "m"})
        d = parse_input.parse_stdin(text)
        self.assertEqual(d["cwd"], "/fallback/path")


class TestModelContextMax(unittest.TestCase):
    def test_first_substring_wins(self) -> None:
        table = {"MiniMax-M3": 1_000_000, "opus-4": 200_000, "haiku-4": 200_000}
        self.assertEqual(parse_input.model_context_max("MiniMax-M3", table), 1_000_000)
        self.assertEqual(parse_input.model_context_max("claude-opus-4-7", table), 200_000)
        self.assertEqual(parse_input.model_context_max("claude-haiku-4-5", table), 200_000)

    def test_no_match(self) -> None:
        self.assertIsNone(parse_input.model_context_max("mystery", {"x": 1}))

    def test_empty_model(self) -> None:
        self.assertIsNone(parse_input.model_context_max("", {"x": 1}))

    def test_first_substring_in_iteration_order(self) -> None:
        # Whichever substring is checked first wins. We pick a table where
        # the longer pattern is the more specific match.
        table = {"opus-4-7": 500_000, "opus-4": 200_000}
        # Both substrings are in "claude-opus-4-7"; the one Python sees first
        # in dict iteration wins. dict preserves insertion order in 3.7+.
        self.assertEqual(parse_input.model_context_max("claude-opus-4-7", table), 500_000)


class TestApplyModelOverride(unittest.TestCase):
    def test_override_uses_table_max(self) -> None:
        # JSONL says total=1_000_000, used=500_000 → 50% left.
        # Table says model=200_000 max → with same 500_000 used, 0% left.
        pct, toks = parse_input.apply_model_override(
            "50", "500k", "claude-opus-4-7", {"opus-4": 200_000},
            total_input=499_000, total_output=1_000,
        )
        self.assertEqual(pct, "0")
        self.assertEqual(toks, "0")

    def test_no_override_when_no_table_match(self) -> None:
        pct, toks = parse_input.apply_model_override(
            "97", "971k", "mystery-model", {},
            total_input=28_000, total_output=68,
        )
        self.assertEqual(pct, "97")
        self.assertEqual(toks, "971k")

    def test_no_override_when_zero_used(self) -> None:
        pct, toks = parse_input.apply_model_override(
            "97", "971k", "claude-opus-4-7", {"opus-4": 200_000},
            total_input=0, total_output=0,
        )
        self.assertEqual(pct, "97")
        self.assertEqual(toks, "971k")


if __name__ == "__main__":
    unittest.main()
