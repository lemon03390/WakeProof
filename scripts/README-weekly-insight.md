# Weekly Coach Generation Script

## Prereqs

```bash
pip install --break-system-packages anthropic
```

## Run

```bash
export ANTHROPIC_API_KEY="sk-ant-..."  # dev-laptop only, never commit this
python3 scripts/generate-weekly-insight.py \
    --history WakeProof/WakeProof/Resources/mock-wake-history-seed.json \
    --profile ~/Library/.../profile.md \
    --out WakeProof/WakeProof/Resources/weekly-insight-seed.json
```

Pass `--dry-run` to print the prompt without calling the API.

## Cost

One run on the 14-day seed + short profile: ~3,000 input tokens + ~300 output tokens at Opus 4.7 rates ($5 / $25 per MTok) = ~$0.023. Safe to iterate; the earlier planning assumption of $3–5 per call was based on true 1M-context loads. In practice we don't fill the window.

## After generation

Inspect the output JSON before committing. Verify:

1. `insightText` reads as useful coaching, not generic advice.
2. No accidental PII from the profile leaked into `insightText`.
3. `seedChecksum` matches `sha256(mock-wake-history-seed.json)[:16]`.

Then:

```bash
git add WakeProof/WakeProof/Resources/weekly-insight-seed.json
git commit -m "Coach: refresh weekly insight output (manual regen)"
```
