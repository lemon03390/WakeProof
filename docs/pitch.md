# WakeProof — Pitch as Submitted

> **Reference anchor.** This is the original pitch submitted to Cerebral Valley for Built with Opus 4.7. Use this as the source of truth when scope creep tempts you. If a feature is not in this pitch, it is out of scope unless explicitly added.

---

## Project Name
**WakeProof — The Alarm That Actually Wakes You Up**

## One-liner
An intelligent iOS alarm that uses Claude Opus 4.7 to analyze your sleep patterns, find your optimal wake-up window, and verifies you're actually awake through photo proof — not just a dismissed alarm.

## The Problem
Traditional alarms have two critical failures:
1. They wake you at arbitrary times, often mid-deep-sleep, leaving you groggy
2. "Dismiss" and "Snooze" buttons are trivially defeated — you turn off the alarm and fall right back asleep

## The Solution
WakeProof combines sleep-quality analysis, adaptive alarm sequencing, and photo-based wake verification into a single iOS app powered by Claude Opus 4.7.

## Core Features (as pitched)

### 1. Intelligent Wake Window Analysis
- Tracks sleep cycles using iPhone sensors (motion, audio, HealthKit data)
- Claude Opus 4.7 analyzes sleep quality patterns to identify the optimal wake-up moment within a user-defined window

### 2. Adaptive Alarm Sequencing
- Claude Opus 4.7 learns which alarm sound, volume progression, and tempo sequence wakes the user most efficiently
- Every morning becomes training data — the model refines the wake strategy over time

### 3. Photo-Based Wake Verification (the core anti-snooze mechanic)
- During onboarding, user takes a baseline photo of themselves in a clearly awake state at a designated location
- When the alarm rings, the only way to dismiss it is to take a new live photo matching that same setting
- Claude Opus 4.7 (with vision) compares the new photo to the baseline to confirm: same location, eyes open, user physically up
- No more fake dismissals

### 4. Wake-Up Analytics Dashboard
- Weekly & monthly insights powered by Claude Opus 4.7
- Natural-language weekly summary

## Why Opus 4.7 is Central
- **Vision:** Photo verification — location matching, alertness detection, anti-spoofing
- **Reasoning:** Pattern analysis across multi-dimensional sleep data
- **Personalization:** Learns user's specific wake-up profile
- **Natural-language insights:** Converts raw sensor data into actionable weekly coaching

---

## Post-Submission Repositioning (Reality-Adjusted)

After researching iOS technical constraints, the actual demo will reframe slightly:

### What changed
- **Sleep stage detection from iPhone alone is infeasible** in 5 days. Reframe as "optimal wake window detection" using accelerometer + HealthKit (if user has Apple Watch).
- **Adaptive alarm learning** needs longitudinal data. Demo with seeded data + roadmap framing.
- **Photo verification is the true differentiator.** Make it the centerpiece of the demo, not one of three equal features.

### New positioning
> WakeProof is a **self-commitment device**, not a sleep tracker. Users opt into stricter wake-up rules because they know future-self will try to cheat. The app uses Opus 4.7 vision to enforce a "wake-up contract" the user signed with themselves the night before.

### Demo-day tagline
> "The alarm that verifies you're actually awake. Powered by Opus 4.7 vision."

---

## Submission Requirements (from official participant resources)

- **3-minute demo video** (YouTube / Loom)
- **GitHub repository** — fully open source under approved license
- **Written summary** 100–200 words
- **Deadline:** April 26th, 8:00 PM EST = April 27th 8:00 AM HKT

## Judging Criteria & Weighting

| Criterion | Weight | What WakeProof needs to show |
|---|---|---|
| Impact (30%) | 30% | Real-world potential. "Who cares about waking up?" → Everyone. Universal pain. |
| Demo (25%) | 25% | Working live demo. Must show end-to-end flow on real device. |
| Opus 4.7 Use (25%) | 25% | Creative use beyond basic API call. Vision + reasoning + personalization combo. |
| Depth & Execution (20%) | 20% | Engineering polish. Show iteration beyond first idea. |

## Special Prizes Worth Targeting

- **Most Creative Opus 4.7 Exploration ($5k):** Photo verification as a "trust contract" between past-self and future-self is a strong creative angle.
- **Best use of Claude Managed Agents ($5k):** If we can architect part of the app to use Managed Agents for long-running tasks (e.g., overnight sleep analysis pipeline), this is an under-targeted prize given most people will focus on raw API calls.
