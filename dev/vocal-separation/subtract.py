"""other = mix - target, written as FLAC: python -I subtract.py mix.wav target.wav other.flac [target_copy.flac]"""
import sys

import numpy as np
import soundfile as sf

mix, sr = sf.read(sys.argv[1], dtype="float64", always_2d=True)
tgt, sr2 = sf.read(sys.argv[2], dtype="float64", always_2d=True)
assert sr == sr2, (sr, sr2)
n = min(len(mix), len(tgt))
if abs(len(mix) - len(tgt)) > 0:
    print(f"length differs: mix={len(mix)} target={len(tgt)}")
other = mix[:n] - tgt[:n]
sf.write(sys.argv[3], np.clip(other, -1, 1), sr, subtype="PCM_24")
if len(sys.argv) > 4:
    sf.write(sys.argv[4], np.clip(tgt[:n], -1, 1), sr, subtype="PCM_24")
print("peak other", float(np.abs(other).max()), "peak target", float(np.abs(tgt).max()))
