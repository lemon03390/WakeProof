#!/usr/bin/env python3
"""Generate WakeProof's weekly coach insight (Layer 4).

Reads the 14-day synthetic seed + the user's memory profile (optional), calls
Claude Opus 4.7 with the full context, and writes the result as
WakeProof/WakeProof/Resources/weekly-insight-seed.json.

Run once per seed change. Expects ANTHROPIC_API_KEY in the environment. Refuses
to run without it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import anthropic
except ImportError:
    sys.exit("Install the Anthropic Python SDK first: pip install --break-system-packages anthropic")


SYSTEM_PROMPT = """You are the weekly coach of WakeProof, a wake-up accountability app. The user will give you:
1. Their last 14 days of wake-attempt history (a JSON array — synthetic for demo purposes but structurally real).
2. Their persistent memory profile (markdown; may be empty).

Your task: produce a single piece of coaching insight in 2–4 sentences. Warm, specific, concrete — not platitudes. Your insight should be actionable or acknowledge a pattern the user might not have noticed.

Rules:
- Use the full 14 days. Do not speculate beyond the window.
- Do not speculate medically.
- If you identify a pattern (e.g., "Mondays are harder than Tuesdays"), say so and name what could help — earlier bedtime on Sunday, etc.
- If the memory profile contradicts the 14-day data, trust the 14-day data and mention the discrepancy gently.
- Output a single JSON object:

{
  "insightText": "2–4 sentences of plain prose, no markdown",
  "patternNoticed": "short name of the pattern if any, or null",
  "suggestedAction": "one short sentence, or null"
}

No text outside the JSON. No markdown fences.
"""


def build_user_prompt(history: dict, profile: str) -> str:
    return f"""<wake_history>
{json.dumps(history.get("entries", []), indent=2)}
</wake_history>

<memory_profile>
{profile if profile.strip() else "(empty)"}
</memory_profile>

Produce the coaching insight JSON now."""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--history",
        default="WakeProof/WakeProof/Resources/mock-wake-history-seed.json",
    )
    parser.add_argument(
        "--profile",
        default="",
        help="Path to a profile.md file, or empty string for no profile",
    )
    parser.add_argument(
        "--out",
        default="WakeProof/WakeProof/Resources/weekly-insight-seed.json",
    )
    parser.add_argument("--model", default="claude-opus-4-7")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the prompt but do not call the API",
    )
    args = parser.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("ANTHROPIC_API_KEY not set in env. Refusing to run without it.")

    history_path = Path(args.history)
    if not history_path.exists():
        sys.exit(f"History file not found: {history_path}")

    history = json.loads(history_path.read_text())
    profile_text = ""
    if args.profile:
        profile_path = Path(args.profile)
        if profile_path.exists():
            profile_text = profile_path.read_text()

    user_prompt = build_user_prompt(history, profile_text)

    print(f"System prompt bytes: {len(SYSTEM_PROMPT.encode('utf-8'))}")
    print(f"User prompt bytes:   {len(user_prompt.encode('utf-8'))}")

    if args.dry_run:
        print("\n--- User prompt ---\n")
        print(user_prompt)
        return 0

    client = anthropic.Anthropic()
    t0 = time.time()
    response = client.messages.create(
        model=args.model,
        max_tokens=1024,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": user_prompt}],
    )
    elapsed = time.time() - t0

    content_text = "".join(
        block.text for block in response.content if getattr(block, "type", None) == "text"
    )
    # Claude is instructed to emit a single JSON object; parse it defensively.
    try:
        payload = json.loads(content_text)
    except json.JSONDecodeError as exc:
        sys.exit(f"Claude output did not parse as JSON: {exc}\nRaw:\n{content_text}")

    seed_checksum = hashlib.sha256(history_path.read_bytes()).hexdigest()[:16]

    wrapped = {
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "model": args.model,
        "elapsedSeconds": round(elapsed, 2),
        "inputTokens": response.usage.input_tokens,
        "outputTokens": response.usage.output_tokens,
        "seedChecksum": seed_checksum,
        "insight": payload,
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(wrapped, indent=2, ensure_ascii=False) + "\n")
    insight_len = len(wrapped["insight"].get("insightText", ""))
    print(f"\nWrote {out_path} ({insight_len} chars of insight)")
    print(
        f"Elapsed: {elapsed:.2f}s, tokens in/out: "
        f"{response.usage.input_tokens}/{response.usage.output_tokens}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
