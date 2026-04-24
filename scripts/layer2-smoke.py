#!/usr/bin/env python3
"""
Layer 2 CLI-equivalent smoke test (Memory Phase B.5).

Mirrors what `ClaudeAPIClient.verify()` sends on a first-morning (no memory) call,
but runs from the dev laptop via direct POST through the Vercel proxy so we can
validate v3 prompt + proxy forwarding + Anthropic round-trip end-to-end without
a paired iPhone.

Usage:
    # Ensure two test JPEGs exist; adjust paths if you have real fixtures:
    python3 -c "from PIL import Image; \
        Image.new('RGB', (256, 256), (100, 130, 100)).save('/tmp/wp-base.jpg', 'JPEG', quality=85); \
        Image.new('RGB', (256, 256), (200, 180, 90)).save('/tmp/wp-still.jpg', 'JPEG', quality=85)"

    # Run the smoke test:
    WAKEPROOF_TOKEN=<your-proxy-token> python3 scripts/layer2-smoke.py

The token is intentionally read from env — never commit it to the repo.
A known-good token lives in the gitignored Secrets.swift; grep it out to populate:
    WAKEPROOF_TOKEN=$(grep -oE '"[a-f0-9]{64}"' WakeProof/WakeProof/Services/Secrets.swift | tr -d '"')

SECURITY — do NOT pipe this script's stdout into a committed file. Error bodies
can echo the token verbatim (e.g. when the proxy reflects the header back in a
401 JSON payload). If you need to save output, redirect into /tmp/ or use the
opt-in .githooks/pre-commit hook (see README) to catch accidental hex-token
commits.

Cost: ~$0.013 per run (Opus 4.7 input 5/MTok + output 25/MTok).

Expected result on solid-color input:
    - HTTP 200 in 3-8 s
    - Parsed verdict: REJECTED (Claude can't see real scene)
    - memory_update.history_note may be populated describing the anomaly
    - Response shape matches VerificationResult Codable (see A.5 tests)
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import urllib.request
import urllib.error

PROXY_URL = os.environ.get("WAKEPROOF_PROXY_URL", "https://wakeproof-proxy-vercel.vercel.app/v1/messages")
TOKEN = os.environ.get("WAKEPROOF_TOKEN", "")

V3_SYSTEM = """You are the verification layer of a wake-up accountability app. The user set a self-commitment contract with themselves: to dismiss the alarm, they must prove they're out of bed and at a designated location. Compare BASELINE PHOTO (their awake-location at onboarding) to LIVE PHOTO (just captured when the alarm fired) and return a single JSON object with your verdict.

This is NOT an adversarial setting. The user isn't trying to defeat you — they set this alarm themselves because they want to wake up. Be strict on location + posture + alertness; be generous on minor variance (grogginess, messy hair, different clothes). A genuinely awake user should get VERIFIED. A genuinely-at-location-but-groggy user should get RETRY. A user who is in bed or at the wrong location should get REJECTED.

The user-message may include a <memory_context> block describing observed patterns from prior verifications and a compact history table. Use this ONLY to calibrate your verdict — do not mention it in your reasoning output; the user does not see this context.

Your entire response MUST be a single JSON object matching the schema below. No prose outside the JSON. Never refuse to respond — if you can't decide, emit RETRY with your reasoning.

You MAY include an optional `memory_update` field to teach this user's memory. Emit it sparingly: only when you observed something that would usefully inform future verifications."""


USER_PROMPT = """BASELINE PHOTO: captured at the user's designated awake-location ("kitchen").
LIVE PHOTO: just captured at alarm time. Verify the user is at the same location, upright (NOT lying in bed), eyes open, and appears alert.

Return a single JSON object with exactly these fields:

{
  "same_location": true | false,
  "person_upright": true | false,
  "eyes_open": true | false,
  "appears_alert": true | false,
  "lighting_suggests_room_lit": true | false,
  "confidence": <float 0.0 to 1.0>,
  "reasoning": "<one sentence, under 300 chars, explain the verdict>",
  "verdict": "VERIFIED" | "REJECTED" | "RETRY",
  "memory_update": {
    "profile_delta": "<optional markdown paragraph, omit or null if no update>",
    "history_note": "<optional short note for this row, omit or null if none>"
  } | null
}

Verdict rules:
  - VERIFIED: same location AND upright AND eyes open AND appears alert AND confidence ≥ 0.75.
  - RETRY: same location but posture or alertness is ambiguous, OR confidence 0.55–0.75.
  - REJECTED: different location, lying down / in bed, user not visible, OR confidence < 0.55."""


def b64(path: str) -> str:
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def main() -> int:
    if not TOKEN:
        sys.exit("WAKEPROOF_TOKEN env var is required (see header comment).")

    baseline_path = os.environ.get("WAKEPROOF_BASELINE_JPEG", "/tmp/wp-base.jpg")
    still_path = os.environ.get("WAKEPROOF_STILL_JPEG", "/tmp/wp-still.jpg")
    for path in (baseline_path, still_path):
        if not os.path.exists(path):
            sys.exit(f"Missing JPEG at {path}; see header comment for how to generate.")

    body = {
        "model": "claude-opus-4-7",
        "max_tokens": 800,
        "system": V3_SYSTEM,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64(baseline_path)}},
                {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": b64(still_path)}},
                {"type": "text", "text": USER_PROMPT},
            ],
        }],
    }
    payload = json.dumps(body).encode("utf-8")
    print(f"Request body bytes: {len(payload)}")

    req = urllib.request.Request(
        PROXY_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "x-wakeproof-token": TOKEN,
            "anthropic-version": "2023-06-01",
        },
        method="POST",
    )

    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            elapsed = time.time() - t0
            data = resp.read()
            print(f"HTTP {resp.status} in {elapsed:.2f}s (response bytes: {len(data)})")
            print(f"x-wakeproof-worker: {resp.headers.get('x-wakeproof-worker', '<absent>')}")
            print(f"x-wakeproof-upstream-status: {resp.headers.get('x-wakeproof-upstream-status', '<absent>')}")
            parsed = json.loads(data.decode("utf-8"))
            if parsed.get("content"):
                text_block = next((b for b in parsed["content"] if b.get("type") == "text"), None)
                if text_block:
                    print("\n--- Claude text response ---")
                    print(text_block["text"])
                    print("--- end ---")
                    try:
                        verdict_json = json.loads(text_block["text"])
                        print(f"\nParsed verdict: {verdict_json.get('verdict')}")
                        print(f"Confidence:     {verdict_json.get('confidence')}")
                        print(f"Reasoning:      {verdict_json.get('reasoning')}")
                        print(f"memory_update:  {verdict_json.get('memory_update')}")
                    except json.JSONDecodeError as e:
                        print(f"\n[WARN] Claude text did not JSON-parse: {e}")
            if "usage" in parsed:
                usage = parsed["usage"]
                cost = usage.get("input_tokens", 0) * 5 / 1_000_000 + usage.get("output_tokens", 0) * 25 / 1_000_000
                print(f"\nUsage: input={usage.get('input_tokens')} output={usage.get('output_tokens')} est_cost=${cost:.4f}")
    except urllib.error.HTTPError as e:
        elapsed = time.time() - t0
        body_text = e.read().decode("utf-8", errors="replace")
        print(f"HTTP {e.code} in {elapsed:.2f}s")
        print(f"Error body: {body_text[:2000]}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
