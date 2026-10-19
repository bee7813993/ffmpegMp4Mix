"""Check whether mix == sum(parts): python -I nulltest.py mix.wav part1.wav part2.wav ..."""
import sys

import numpy as np
import soundfile as sf


def load(path):
    data, sr = sf.read(path, dtype="float64", always_2d=True)
    return data, sr


mix, sr = load(sys.argv[1])
parts = [load(p) for p in sys.argv[2:]]
assert all(p[1] == sr for p in parts), "sample rate differs"
n = min([len(mix)] + [len(p[0]) for p in parts])
total = sum(p[0][:n] for p in parts)
mix = mix[:n]

# Lag search on the mono signals around zero (±50 ms).
a = mix.mean(axis=1)
b = total.mean(axis=1)
best = (None, -1.0)
for lag in range(-2400, 2401, 1):
    if lag >= 0:
        x, y = a[lag:], b[: n - lag]
    else:
        x, y = a[: n + lag], b[-lag:]
    if lag % 1 == 0:
        c = float(np.dot(x[::8], y[::8]))
        if c > best[1]:
            best = (lag, c)
lag = best[0]
if lag >= 0:
    m, t = mix[lag:], total[: n - lag]
else:
    m, t = mix[: n + lag], total[-lag:]
res = m - t
ratio_db = 10 * np.log10(np.sum(m ** 2) / max(np.sum(res ** 2), 1e-20))
# Best scalar gain too.
g = float(np.sum(m * t) / np.sum(t * t))
res_g = m - g * t
ratio_g_db = 10 * np.log10(np.sum(m ** 2) / max(np.sum(res_g ** 2), 1e-20))
print(f"lag={lag} samples, mix/residual={ratio_db:.1f} dB, with gain {g:.3f}: {ratio_g_db:.1f} dB")
