# Vision Verification — Test Scenarios

> Five fixtures exercised before any prompt change is merged or before device-path Task B.7 can be
> declared PASS. Scenario 4 (printed-photo attack) is the demo-day money shot — if it regresses,
> the whole Layer 1 "self-commitment contract" framing is undermined.

All scenarios use the same baseline: a photo captured during onboarding at the user's kitchen
counter under morning light. The live capture differs per scenario.

---

## Scenario 1 — Kitchen, morning, alert

**Baseline:** kitchen counter, 7 am daylight.
**Live capture:** same counter, same-ish time of day, user standing, eyes clearly open, facing camera.
**Expected verdict:** VERIFIED
**Console sentinel (subsystem=com.wakeproof.verification, category=claude):** `Claude verdict VERIFIED confidence=...`
**Pass criteria:** alarm stops within ~8 s of capture; WakeAttempt row has `verdict = "VERIFIED"` and non-empty `verdictReasoning`.

## Scenario 2 — Kitchen, night, alert

**Baseline:** kitchen counter (reused).
**Live capture:** same counter, 3 am with overhead light on; user standing.
**Expected verdict:** VERIFIED (confidence may be 0.75–0.90) OR RETRY if lighting diverges too much from baseline.
**Pass criteria:** verdict is not REJECTED and not stuck in infinite retry. A RETRY followed by an anti-spoof re-capture should resolve to VERIFIED.

## Scenario 3 — Bathroom, groggy

**Baseline:** kitchen (reused).
**Live capture:** bathroom, eyes half-closed, posture slouched.
**Expected verdict:** RETRY (location differs from baseline → likely REJECTED, but eyes half-closed is classically a RETRY signal). Document whichever the model emits.
**Pass criteria:** if RETRY, the anti-spoof prompt displays a random instruction; user performs it; second call resolves deterministically to VERIFIED or REJECTED.

## Scenario 4 — **Printed photo of baseline (DEMO MONEY SHOT)**

**Baseline:** kitchen (reused).
**Live capture:** on a second phone, open the baseline photo from camera roll; hold that phone's screen up to the WakeProof camera during capture.
**Expected verdict:** REJECTED with `spoofing_ruled_out` containing "photo-of-photo" but `verdict = REJECTED` because the spoof is NOT ruled out.
**Pass criteria:** alarm continues ringing; `lastCaptureError` banner cites "photo-of-photo" or "same_location=false". Console log shows `Claude verdict REJECTED confidence=...`.
**Demo note:** this is the 60-second moment in the demo video. Rehearse it.

## Scenario 5 — User in bed

**Baseline:** kitchen (reused).
**Live capture:** user lying in bed, phone held above face.
**Expected verdict:** REJECTED (same_location=false OR person_upright=false).
**Pass criteria:** alarm continues ringing; `lastCaptureError` mentions posture or location.

---

## Budget accounting

- Each scenario costs ~$0.013 per Decision 2. Five scenarios = ~$0.065 per full pass.
- Budget for the full Day 3 device validation round (5 scenarios × 2 for reliability): ~$0.13. Non-constraint.

## When to re-run

- After any prompt change (`docs/vision-prompt.md` version bump).
- After any VisionVerifier logic change.
- Once before pushing the submission build.
- After model swap (if the hackathon adds a Haiku 4.5 vision option — check the verdict shape is unchanged).
