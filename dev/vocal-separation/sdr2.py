"""SDR of separated stems against an on-vocal / off-vocal pair.

python -I sdr2.py <on.wav> <off.wav> <out dir>
Reference instrumental = off-vocal (lag and gain fitted to the on-vocal mix),
reference vocals = on-vocal minus that. Mastering differences end up in the
vocal reference, so the numbers are relative, not absolute.
"""
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import soxr

on_path, off_path, out_dir = sys.argv[1:4]
out = Path(out_dir)


def load(path):
    data, sr = sf.read(path, dtype="float64", always_2d=True)
    return data, sr


on, sr = load(on_path)
off, sr_off = load(off_path)
if sr_off != sr:
    off = soxr.resample(off, sr_off, sr, quality="VHQ")
n = min(len(on), len(off))
on, off = on[:n], off[:n]


def shift(x, lag):
    y = np.zeros_like(x)
    if lag >= 0:
        y[lag:] = x[: len(x) - lag]
    else:
        y[:lag] = x[-lag:]
    return y


m = on.mean(axis=1)
o = off.mean(axis=1)
coarse = max(range(-44100, 44101, 8), key=lambda L: float(np.dot(m[::16], shift(o, L)[::16])))
lag = max(range(coarse - 16, coarse + 17), key=lambda L: float(np.dot(m[::4], shift(o, L)[::4])))
off_s = shift(off, lag)
g = float(np.sum(on * off_s) / np.sum(off_s * off_s))
inst_ref = g * off_s
voc_ref = on - inst_ref
print(f"lag={lag} samples ({lag / sr * 1000:.1f} ms) gain={g:.3f} "
      f"vocal/mix energy={10 * np.log10(np.sum(voc_ref ** 2) / np.sum(on ** 2)):.1f} dB")
# Drop the edges that the shift zeroed.
lo, hi = max(lag, 0) + sr, n - max(-lag, 0) - sr
inst_ref, voc_ref = inst_ref[lo:hi], voc_ref[lo:hi]


def sdr(ref, est):
    est = est[lo:hi]
    k = min(len(ref), len(est))
    ref, est = ref[:k], est[:k]
    return 10 * np.log10(np.sum(ref ** 2) / max(np.sum((ref - est) ** 2), 1e-20))


def est(name):
    for ext in (".flac", ".wav"):
        path = out / f"{name}{ext}"
        if path.exists():
            break
    else:
        return None
    data, esr = load(path)
    if esr != sr:
        data = soxr.resample(data, esr, sr, quality="VHQ")
    if len(data) < n:
        data = np.vstack([data, np.zeros((n - len(data), data.shape[1]))])
    return data


rows = [
    ("Inst HQ 3 (baseline)", "hq3_vocals", "hq3_inst"),
    ("Inst HQ 4 (baseline)", "hq4_vocals", "hq4_inst"),
    ("BS-Roformer 1297", "bsr_vocals", "bsr_inst"),
    ("Kim Mel-Roformer", "kim_vocals", "kim_inst"),
    ("6_HP-Karaoke (baseline)", "kara6hp_lead", "kara6hp_karaoke"),
    ("Mel-Roformer Karaoke aufr33/viperx", "karamel_lead", "karamel_karaoke"),
    ("BS-Roformer Karaoke frazer/becruily", "karafb_lead", "karafb_karaoke"),
    ("BS-Roformer Karaoke anvuew", "karaanv_lead", "karaanv_karaoke"),
    ("Kim -> frazer/becruily on vocal stem", "karafbv_lead", "mix_chorus_kept_via_vocal_stem"),
    ("cpp Kim Q8 (Vulkan)", "cppkim_vocals", "cppkim_inst"),
    ("cpp Kim Q8 overlap 4", "cppkim4_vocals", "cppkim4_inst"),
    ("cpp anvuew Q8 (Vulkan)", "cppanv_lead", "cppanv_karaoke"),
    ("cpp frazer/becruily Q8 (Vulkan)", "cppfb_lead", "cppfb_karaoke"),
]
print(f"{'model':40} {'vocal SDR':>9} {'inst SDR':>9}")
for label, v, i in rows:
    a, b = est(v), est(i)
    if a is None or b is None:
        continue
    print(f"{label:40} {sdr(voc_ref, a):9.2f} {sdr(inst_ref, b):9.2f}")
