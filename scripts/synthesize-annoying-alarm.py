#!/usr/bin/env python3
"""
WakeProof "Anti-Human Alarm" synthesis — stdlib only.

Designed for maximum motivational pressure to disable. Combines:
  1. Beating dissonance (two square waves a minor 2nd apart, in the same
     critical band, ~50 Hz beating cycle).
  2. 4 Hz AM modulation — Plomp & Levelt's measured peak of perceptual
     roughness; the ear cannot integrate the modulation as a single tone,
     so it stays "rough" no matter how long you listen.
  3. Equal-loudness boost — 4.4 kHz square overlay where the human
     equal-loudness contour peaks. Same SPL feels louder vs. low tones.
  4. Siren chirp every 4th pulse — rising frequency sweeps trigger the
     mammalian threat response (analogous to fire alarms / sirens).
  5. Anti-entrainment rhythm — irregular pulse spacing
     (0.55 / 0.18 / 0.32 / 0.11 s pattern, prime-ratio'd) so the cortex
     can't predict the next pulse and habituate.
  6. High-pass click transients every 2.3 s — sharp 5 ms impulses where
     dental-drill nerves fire. Prime-spaced so they offset the main
     pulse rhythm.
  7. Hot mastering — peak limited to -0.3 dBFS, RMS pushed to ~-7 dBFS
     (vs. current alarm.m4a which sits at -5.3 dBFS peak / -9 dBFS RMS,
     i.e. ~5 dB quieter than ceiling).

Pure stdlib (math + wave + struct + random) so no pip surface for the
hackathon checkout. Output: 8.0 s mono 44.1kHz 16-bit WAV. Loops cleanly
via 30 ms cosine fade at file edges.
"""
import math
import random
import struct
import wave
import sys

# ---- Configuration ----
SR = 44100               # sample rate (Hz)
DUR = 8.0                # seconds — clean loop length
N = int(SR * DUR)
PEAK_TARGET = 0.708      # -3.0 dBFS — square waves + hi-freq content cause AAC
                         # intersample peak overshoot of ~3 dB even at 256 kbps.
                         # 0.708 lands the encoded m4a at ~-0.5 dBFS post-AAC.
EDGE_FADE = 0.030        # 30 ms cos-fade at boundaries to prevent loop click

random.seed(20260426)    # deterministic build — same audio every checkout

# ---- Helpers ----
def square(phase):
    """1.0 if phase mod 2π < π else -1.0. Phase passed in radians."""
    return 1.0 if (phase % (2 * math.pi)) < math.pi else -1.0


def cosine_window(t, total, fade):
    """Returns a 0..1 amplitude envelope with cos in/out fades of length `fade`s."""
    if t < fade:
        return 0.5 - 0.5 * math.cos(math.pi * t / fade)
    if t > total - fade:
        return 0.5 - 0.5 * math.cos(math.pi * (total - t) / fade)
    return 1.0


# ---- Pulse rhythm — anti-entrainment ----
# Pattern: prime-ratio durations so the brain cannot predict cadence.
# Each tuple: (on_seconds, off_seconds, kind)
# kind ∈ {"beat", "siren", "stab"} — rotated unevenly across the loop.
RHYTHM = [
    (0.55, 0.18, "beat"),
    (0.32, 0.11, "stab"),
    (0.46, 0.13, "beat"),
    (0.62, 0.20, "siren"),
    (0.28, 0.09, "stab"),
    (0.51, 0.16, "beat"),
    (0.43, 0.12, "siren"),
    (0.34, 0.10, "stab"),
    (0.49, 0.17, "beat"),
    (0.41, 0.14, "stab"),
]
# Sum check — RHYTHM should fill close to DUR seconds (we'll trim/loop the
# pattern as the synthesis cursor advances; no need for exact sum).


def synthesize_pulse(buf, start_idx, length_samples, kind, seed):
    """Renders one pulse into `buf` starting at start_idx. `kind` chooses the timbre."""
    rng = random.Random(seed)

    if kind == "beat":
        f1 = 880.0          # A5
        f2 = 932.33         # A#5 — minor 2nd, beats at ~52 Hz (within critical band)
    elif kind == "siren":
        # Linear sweep 1000 → 2200 Hz across the pulse; covers the
        # equal-loudness peak region. Set in the loop below.
        f1, f2 = 1000.0, 2200.0
    else:  # "stab"
        # Random ±150 cents jitter around 1320 Hz, recomputed per pulse for
        # jarring pitch jumps the cortex can't filter as music.
        cents = rng.uniform(-150, 150)
        f1 = 1320.0 * (2 ** (cents / 1200.0))
        f2 = f1 * 1.058     # micro-detune — beating in critical band

    # 4 Hz AM (peak roughness modulation rate per Plomp/Levelt 1965)
    am_hz = 4.0
    am_depth = 0.45         # 0..1 — 0 = no modulation, 1 = full silence at troughs

    # 4.4 kHz overlay — equal-loudness peak; toggled at 7 Hz to add dental-drill timbre
    hi_freq = 4400.0
    hi_gate_hz = 7.0
    hi_amp = 0.18

    # Pulse-internal envelope: fast attack (3 ms), sustain, fast release (8 ms).
    # Attack faster than release so each pulse hits as a transient.
    attack_s = 0.003
    release_s = 0.008
    pulse_dur = length_samples / SR

    for i in range(length_samples):
        t_pulse = i / SR
        # Pulse envelope
        if t_pulse < attack_s:
            env = t_pulse / attack_s
        elif t_pulse > pulse_dur - release_s:
            env = max(0.0, (pulse_dur - t_pulse) / release_s)
        else:
            env = 1.0

        # Frequency at this pulse-time
        if kind == "siren":
            # Linear sweep over the pulse duration
            freq_a = f1 + (f2 - f1) * (t_pulse / pulse_dur)
            phase_a = 2 * math.pi * freq_a * t_pulse
            phase_b = 2 * math.pi * (freq_a * 1.0594) * t_pulse  # +1 semitone detune
        else:
            phase_a = 2 * math.pi * f1 * t_pulse
            phase_b = 2 * math.pi * f2 * t_pulse

        # Two detuned squares — sum produces beating + odd harmonics
        core = 0.5 * square(phase_a) + 0.5 * square(phase_b)

        # 4 Hz roughness modulation
        am = 1.0 - am_depth * (0.5 - 0.5 * math.cos(2 * math.pi * am_hz * t_pulse))

        # 4.4 kHz overlay gated at 7 Hz
        hi_gate = 1.0 if math.sin(2 * math.pi * hi_gate_hz * t_pulse) > 0 else 0.0
        hi = hi_amp * hi_gate * square(2 * math.pi * hi_freq * t_pulse)

        sample = (core * am + hi) * env
        buf[start_idx + i] += sample


def add_click_transients(buf):
    """5 ms band-limited clicks at irregular intervals — high-pass character."""
    # Prime-spaced click times: 1.13, 2.37, 3.51, 4.79, 6.07, 7.23 s
    click_times = [1.13, 2.37, 3.51, 4.79, 6.07, 7.23]
    click_dur = 0.005       # 5 ms
    click_amp = 0.35

    for t0 in click_times:
        i0 = int(t0 * SR)
        n_click = int(click_dur * SR)
        for j in range(n_click):
            if i0 + j >= len(buf):
                break
            t = j / SR
            # Damped high-frequency burst — 6 kHz cosine × exp decay
            decay = math.exp(-t * 800.0)
            click = click_amp * decay * math.cos(2 * math.pi * 6000.0 * t)
            buf[i0 + j] += click


# ---- Main render ----
def main(out_path):
    buf = [0.0] * N

    # Walk the rhythm pattern across the buffer.
    cursor = 0
    pulse_seed = 0
    pattern_idx = 0
    while cursor < N:
        on_s, off_s, kind = RHYTHM[pattern_idx % len(RHYTHM)]
        on_n = int(on_s * SR)
        off_n = int(off_s * SR)
        if cursor + on_n > N:
            on_n = N - cursor
        synthesize_pulse(buf, cursor, on_n, kind, seed=pulse_seed)
        cursor += on_n + off_n
        pulse_seed += 1
        pattern_idx += 1

    # High-frequency click transients (anti-entrainment offset rhythm).
    add_click_transients(buf)

    # Apply edge fade to prevent loop-boundary clicks.
    for i in range(N):
        t = i / SR
        buf[i] *= cosine_window(t, DUR, EDGE_FADE)

    # Hard limit to PEAK_TARGET. Square+overlay will exceed 1.0 in places —
    # we want hard clip rather than scale-down to preserve perceived loudness.
    # Soft clip first (tanh) for smoother harmonics, then hard clip.
    for i in range(N):
        x = buf[i]
        # tanh soft clip with drive=1.4 — adds even harmonics, fattens
        x = math.tanh(x * 1.4) / math.tanh(1.4)
        # Hard ceiling at PEAK_TARGET
        if x > PEAK_TARGET:
            x = PEAK_TARGET
        elif x < -PEAK_TARGET:
            x = -PEAK_TARGET
        buf[i] = x

    # Stats for sanity — match measure_loudness.py output style.
    peak = max(abs(s) for s in buf)
    rms = math.sqrt(sum(s * s for s in buf) / len(buf))
    peak_db = 20 * math.log10(peak) if peak > 0 else -math.inf
    rms_db = 20 * math.log10(rms) if rms > 0 else -math.inf
    print(f"render:    peak={peak_db:+.2f} dBFS  rms={rms_db:+.2f} dBFS  crest={peak_db - rms_db:.2f} dB")

    # Write 16-bit mono WAV.
    with wave.open(out_path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        for s in buf:
            w.writeframes(struct.pack('<h', max(-32768, min(32767, int(s * 32767)))))

    print(f"wrote:     {out_path}  ({DUR:.1f}s @ {SR}Hz mono)")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/annoying-alarm.wav"
    main(out)
