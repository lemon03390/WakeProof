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
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# Dual-mode: prefer the Anthropic SDK if ANTHROPIC_API_KEY is set; fall back to
# POSTing through the Vercel proxy with WAKEPROOF_TOKEN (stdlib only, no SDK
# dep). Seed is ~2.5k input tokens + ~300 output = well under the Vercel Hobby
# 10s cap. Proxy path is what CI / non-dev-laptop runs use.
_HAS_SDK = False
try:
    import anthropic  # type: ignore
    _HAS_SDK = True
except ImportError:
    pass


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

    # Choose transport: direct Anthropic SDK if available + key set,
    # otherwise proxy-mode via WAKEPROOF_TOKEN + urllib.
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY")
    proxy_token = os.environ.get("WAKEPROOF_TOKEN")
    use_sdk = bool(anthropic_key and _HAS_SDK)
    use_proxy = not use_sdk and bool(proxy_token)
    if not (use_sdk or use_proxy):
        sys.exit(
            "No credentials found. Set either ANTHROPIC_API_KEY (with "
            "`pip install --break-system-packages anthropic`) or WAKEPROOF_TOKEN "
            "(uses the Vercel proxy at wakeproof-proxy-vercel.vercel.app)."
        )

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

    print(f"Transport:           {'anthropic-sdk' if use_sdk else 'vercel-proxy'}")
    print(f"System prompt bytes: {len(SYSTEM_PROMPT.encode('utf-8'))}")
    print(f"User prompt bytes:   {len(user_prompt.encode('utf-8'))}")

    if args.dry_run:
        print("\n--- User prompt ---\n")
        print(user_prompt)
        return 0

    t0 = time.time()
    if use_sdk:
        client = anthropic.Anthropic()
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
        input_tokens = response.usage.input_tokens
        output_tokens = response.usage.output_tokens
    else:
        proxy_url = os.environ.get(
            "WAKEPROOF_PROXY_URL", "https://wakeproof-proxy-vercel.vercel.app/v1/messages"
        )
        body = json.dumps({
            "model": args.model,
            "max_tokens": 1024,
            "system": SYSTEM_PROMPT,
            "messages": [{"role": "user", "content": user_prompt}],
        }).encode("utf-8")
        req = urllib.request.Request(
            proxy_url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "x-wakeproof-token": proxy_token,
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload_bytes = resp.read()
        except urllib.error.HTTPError as e:
            sys.exit(f"Proxy HTTP {e.code}: {e.read().decode('utf-8', errors='replace')[:500]}")
        except urllib.error.URLError as e:
            sys.exit(f"Proxy URL error: {e}")
        elapsed = time.time() - t0
        parsed = json.loads(payload_bytes)
        content_blocks = parsed.get("content", [])
        content_text = "".join(
            b.get("text", "") for b in content_blocks if b.get("type") == "text"
        )
        usage = parsed.get("usage", {})
        input_tokens = usage.get("input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)

    # Guard against zero-text-block responses (max_tokens too low, weird
    # stop_reason) so the user sees a specific error instead of the generic
    # "output did not parse as JSON" message below.
    if not content_text.strip():
        sys.exit(
            f"Claude returned no text content blocks (empty response). "
            f"This usually means max_tokens was too low for the response "
            f"or an unexpected stop_reason. Tokens used: {input_tokens} in / {output_tokens} out."
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
        "inputTokens": input_tokens,
        "outputTokens": output_tokens,
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
        f"{input_tokens}/{output_tokens}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
