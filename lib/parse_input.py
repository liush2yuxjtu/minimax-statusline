"""parse_input — extract the fields a statusline needs from MiniMax's stdin JSON.

Input: a JSON object on stdin matching MiniMax's statusline contract.
Output: a single line of NUL-separated fields, in this fixed order:
  0  cwd
  1  model name (display_name or id)
  2  effort level (default if unknown)
  3  context-window remaining percent (0..100, or "" if unknown)
  4  context-window remaining tokens (int, or "" if unknown)
  5  git branch (or "" if not a git repo / detached / no head)
  6  five-hour data (encoded: p5|r5|b5, or empty)

The 0x1e record-separator keeps the shell-side `read` simple and avoids
NUL-string pitfalls in bash 3.2.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Optional

# Use stdlib tomllib (3.11+) if available; fall back to the bundled parser.
try:
    import tomllib as _toml
except ImportError:  # pragma: no cover
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    import tiny_toml as _toml  # type: ignore[no-redef]

SEP = "\x1e"


def _first(d: dict, *keys: str, default: str = "") -> str:
    for k in keys:
        v = d.get(k)
        if v is not None:
            return v if isinstance(v, str) else str(v)
    return default


def parse_stdin(text: str) -> dict:
    """Parse MiniMax's stdin JSON. Returns a dict of normalized fields."""
    try:
        d = json.loads(text)
    except Exception:
        return {
            "cwd": "",
            "model": "unknown",
            "effort": "default",
            "ctx_pct": "",
            "ctx_toks": "",
            "branch": "",
        }
    ws = d.get("workspace")
    if isinstance(ws, dict):
        cwd = _first(ws, "current_dir", "project_dir")
    else:
        cwd = ws or ""
    if not cwd:
        cwd = _first(d, "cwd", "project_dir", "working_directory", "pwd")
    m = d.get("model")
    if isinstance(m, dict):
        model = _first(m, "display_name", "id", "name", "model", default="unknown")
    else:
        model = m if isinstance(m, str) else _first(d, "model_id", default="unknown")
    eff = d.get("effort")
    if isinstance(eff, dict):
        effort = eff.get("level") or "default"
    else:
        effort = (
            eff
            or _first(d, "effort_level", "thinking_effort", "reasoning_effort")
            or "default"
        )
    branch = _first(d, "branch", "git_branch", "current_branch")
    ctx_pct = ""
    ctx_toks = ""
    cw = d.get("context_window")
    if isinstance(cw, dict):
        total = cw.get("context_window_size") or cw.get("total_tokens") or cw.get("total") or cw.get("max_tokens")
        used = (
            cw.get("total_input_tokens")
            or cw.get("used_tokens")
            or cw.get("used")
            or cw.get("input_tokens")
        )
        rp = None
        if total and used:
            try:
                rp = max(0.0, (float(total) - float(used)) / float(total) * 100.0)
            except Exception:
                rp = None
        if rp is None:
            raw_rp = cw.get("remaining_percentage")
            if raw_rp is not None:
                try:
                    rp = float(raw_rp)
                except Exception:
                    rp = None
        if rp is not None:
            ctx_pct = str(int(round(rp)))
        rt = None
        if total and used:
            try:
                rt = max(0.0, float(total) - float(used))
            except Exception:
                rt = None
        if rt is None:
            raw_rt = cw.get("remaining_tokens")
            if raw_rt is not None:
                try:
                    rt = float(raw_rt)
                except Exception:
                    rt = None
        if rt is not None:
            n = rt
            if n < 0:
                n = 0
            if n >= 1_000_000:
                ctx_toks = f"{n/1_000_000:.1f}M"
            elif n >= 1_000:
                ctx_toks = f"{n/1_000:.0f}k"
            else:
                ctx_toks = str(int(n))
    return {
        "cwd": cwd,
        "model": model or "unknown",
        "effort": effort or "default",
        "ctx_pct": ctx_pct,
        "ctx_toks": ctx_toks,
        "branch": branch,
    }


def model_context_max(model: str, model_table: dict) -> Optional[int]:
    """Look up the model's true context-window size in the config table.

    `model_table` is a dict mapping lowercase substrings → int.
    First substring match wins. Returns None if no match.
    """
    n = (model or "").lower()
    for needle, val in model_table.items():
        if needle.lower() in n:
            return int(val)
    return None


def apply_model_override(ctx_pct: str, ctx_toks: str, model: str,
                         model_table: dict, total_input: int = 0,
                         total_output: int = 0) -> tuple[str, str]:
    """If the model table has a max for this model and we have input/output
    tokens, recompute ctx_pct with the table's max. Returns (pct, toks)."""
    mx = model_context_max(model, model_table)
    if not mx or mx <= 0:
        return ctx_pct, ctx_toks
    used = total_input + total_output
    if used <= 0:
        return ctx_pct, ctx_toks
    pct = max(0.0, (float(mx) - float(used)) / float(mx) * 100.0)
    rem = float(mx) - float(used)
    if rem < 0:
        rem = 0
    if rem >= 1_000_000:
        toks = f"{rem/1_000_000:.1f}M"
    elif rem >= 1_000:
        toks = f"{rem/1_000:.0f}k"
    else:
        toks = str(int(rem))
    return str(int(round(pct))), toks


def git_branch(cwd: str) -> str:
    """Return the current git branch of `cwd`, or '' on failure."""
    if not cwd or not os.path.isdir(cwd):
        return ""
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "-c", "core.optionalLocks=true",
             "branch", "--show-current"],
            capture_output=True, text=True, timeout=2,
        )
        b = (out.stdout or "").strip()
        if b:
            return b
        out2 = subprocess.run(
            ["git", "-C", cwd, "-c", "core.optionalLocks=true",
             "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=2,
        )
        h = (out2.stdout or "").strip()
        return f"@{h}" if h else ""
    except Exception:
        return ""


def main() -> int:
    text = sys.stdin.read() if not sys.stdin.isatty() else ""
    parsed = parse_stdin(text)
    branch = parsed.get("branch") or git_branch(parsed["cwd"])
    out = SEP.join([
        parsed["cwd"],
        parsed["model"],
        parsed["effort"],
        parsed["ctx_pct"],
        parsed["ctx_toks"],
        branch,
    ])
    sys.stdout.write(out + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
