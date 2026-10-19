"""How closely B matches A (A = reference): python -I match.py A.flac B.wav"""
import sys

import numpy as np
import soundfile as sf
import soxr

a, sra = sf.read(sys.argv[1], dtype="float64", always_2d=True)
b, srb = sf.read(sys.argv[2], dtype="float64", always_2d=True)
if srb != sra:
    b = soxr.resample(b, srb, sra, quality="VHQ")
n = min(len(a), len(b))
a, b = a[:n], b[:n]
am, bm = a.mean(axis=1), b.mean(axis=1)
lag = max(range(-200, 201), key=lambda L: float(np.dot(am[200:-200:4], np.roll(bm, L)[200:-200:4])))
b = np.roll(b, lag, axis=0)
a, b = a[200:-200], b[200:-200]
g = float(np.sum(a * b) / np.sum(b * b))
res = a - g * b
print(f"lag={lag} gain={g:.4f} match={10*np.log10(np.sum(a**2)/max(np.sum(res**2),1e-20)):.1f} dB (ref rms {np.sqrt(np.mean(a**2)):.4f})")
