#!/usr/bin/env python3
"""
Re-master the existing alarm.m4a/caf to the same hot mastering target as
the new annoying alarm.

Source: alarm-current.wav (decoded from existing alarm.m4a)
  - peak: -5.28 dBFS, RMS: -9.03 dBFS  (5 dB of unused headroom)

Target: peak -3.0 dBFS pre-AAC (lands ~-1 dBFS post-AAC encoder overshoot)
        RMS pulled up by tanh soft-clip + hard limit chain.

Chain (matches synthesize_annoying_alarm.py):
  1. Pre-gain: bring peak to 0.95 (-0.45 dBFS) — full normalization first
  2. tanh(x * 1.4) / tanh(1.4) — soft saturation, fattens RMS, even harmonics
  3. Hard limit at 0.708 (-3 dBFS pre-AAC encode safety margin)

Stdlib only.
"""
import math
import struct
import sys
import wave

PEAK_TARGET = 0.708   # -3 dBFS pre-AAC (matches annoying-alarm)
NORMALIZE_TO = 0.95   # pre-saturation peak target
DRIVE = 1.4           # tanh drive — same as annoying-alarm

def read_wav_mono16(path):
    with wave.open(path, 'rb') as w:
        n = w.getnframes()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        fr = w.getframerate()
        raw = w.readframes(n)
    assert sw == 2, f"expected 16-bit, got {sw*8}-bit"
    samples = list(struct.unpack(f"<{n*ch}h", raw))
    if ch == 2:
        samples = [(samples[i] + samples[i+1]) // 2 for i in range(0, len(samples), 2)]
    return samples, fr


def write_wav_mono16(path, samples, fr):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fr)
        for s in samples:
            v = max(-32768, min(32767, int(s * 32767)))
            w.writeframes(struct.pack('<h', v))


def remaster(in_path, out_path):
    int_samples, fr = read_wav_mono16(in_path)
    n = len(int_samples)
    # Convert to float -1..1
    floats = [s / 32768.0 for s in int_samples]

    src_peak = max(abs(x) for x in floats)
    src_rms = math.sqrt(sum(x*x for x in floats) / n)
    src_peak_db = 20 * math.log10(src_peak) if src_peak > 0 else -math.inf
    src_rms_db = 20 * math.log10(src_rms) if src_rms > 0 else -math.inf
    print(f"source:    peak={src_peak_db:+.2f} dBFS  rms={src_rms_db:+.2f} dBFS  ({n/fr:.2f}s @ {fr}Hz)")

    # Step 1: normalize peak to NORMALIZE_TO
    if src_peak == 0:
        raise SystemExit("source is silent")
    pre_gain = NORMALIZE_TO / src_peak
    floats = [x * pre_gain for x in floats]

    # Step 2: tanh soft saturation
    tanh_drive = math.tanh(DRIVE)
    floats = [math.tanh(x * DRIVE) / tanh_drive for x in floats]

    # Step 3: hard limit at PEAK_TARGET
    floats = [max(-PEAK_TARGET, min(PEAK_TARGET, x)) for x in floats]

    out_peak = max(abs(x) for x in floats)
    out_rms = math.sqrt(sum(x*x for x in floats) / n)
    out_peak_db = 20 * math.log10(out_peak) if out_peak > 0 else -math.inf
    out_rms_db = 20 * math.log10(out_rms) if out_rms > 0 else -math.inf
    print(f"remaster:  peak={out_peak_db:+.2f} dBFS  rms={out_rms_db:+.2f} dBFS  "
          f"(Δrms={out_rms_db - src_rms_db:+.2f} dB louder)")

    write_wav_mono16(out_path, floats, fr)
    print(f"wrote:     {out_path}")


if __name__ == "__main__":
    in_path = sys.argv[1]
    out_path = sys.argv[2]
    remaster(in_path, out_path)
