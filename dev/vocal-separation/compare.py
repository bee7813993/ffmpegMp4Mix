"""Run baseline UVR models and Roformer models on one song and build karaoke tracks.

Usage: python -I compare.py <input audio> <output dir> [--cpu] [--only key,key]
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SEP = Path(__file__).resolve().parent.parent / "sep"
CLI = SEP / "venv" / "Scripts" / "audio-separator.exe"
MODELS = SEP / "models"

# key: (model file, {stem name in model: output base name}, extra CLI args, input key or None for the song)
RUNS = {
    "hq3": ("UVR-MDX-NET-Inst_HQ_3.onnx", {"Instrumental": "hq3_inst", "Vocals": "hq3_vocals"}, [], None),
    "hq4": ("UVR-MDX-NET-Inst_HQ_4.onnx", {"Instrumental": "hq4_inst", "Vocals": "hq4_vocals"}, [], None),
    "bsr": ("model_bs_roformer_ep_317_sdr_12.9755.ckpt", {"Instrumental": "bsr_inst", "Vocals": "bsr_vocals"}, [], None),
    "kim": ("vocals_mel_band_roformer.ckpt", {"Other": "kim_inst", "Vocals": "kim_vocals"}, [], None),
    # Karaoke models on the full mix: "Instrumental" keeps backing vocals, "Vocals" is the lead.
    "kara6hp": ("6_HP-Karaoke-UVR.pth", {"Instrumental": "kara6hp_karaoke", "Vocals": "kara6hp_lead"}, ["--vr_aggression", "10"], None),
    "karamel": ("mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt", {"Instrumental": "karamel_karaoke", "Vocals": "karamel_lead"}, [], None),
    "karafb": ("bs_roformer_karaoke_frazer_becruily.ckpt", {"Instrumental": "karafb_karaoke", "Vocals": "karafb_lead"}, [], None),
    "karaanv": ("bs_roformer_karaoke_anvuew.ckpt", {"Instrumental": "karaanv_karaoke", "Vocals": "karaanv_lead"}, [], None),
    # Karaoke model on the Kim vocal stem: "Instrumental" is then the backing vocals only.
    "karafb_v": ("bs_roformer_karaoke_frazer_becruily.ckpt", {"Instrumental": "karafbv_backing", "Vocals": "karafbv_lead"}, [], "kim_vocals"),
}


def run_model(key, song, out, cpu):
    model, names, extra, source = RUNS[key]
    inp = song if source is None else out / f"{source}.flac"
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    if cpu:
        env["CUDA_VISIBLE_DEVICES"] = ""
        names = {k: v + "_cpu" for k, v in names.items()}
    cmd = [str(CLI), str(inp), "-m", model, "--model_file_dir", str(MODELS), "--output_dir", str(out),
           "--output_format", "FLAC", "--custom_output_names", json.dumps(names)] + extra
    start = time.perf_counter()
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
    elapsed = time.perf_counter() - start
    if proc.returncode != 0:
        print(proc.stdout[-2000:], proc.stderr[-4000:], sep="\n")
        raise SystemExit(f"{key} failed")
    return elapsed


def ffmpeg_mix(out, name, parts):
    """parts: list of (stem base name, gain dB)."""
    args = ["ffmpeg", "-v", "error", "-y"]
    for stem, _ in parts:
        args += ["-i", str(out / f"{stem}.flac")]
    chains = [f"[{i}:a]volume={db}dB[a{i}]" for i, (_, db) in enumerate(parts)]
    inputs = "".join(f"[a{i}]" for i in range(len(parts)))
    chains.append(f"{inputs}amix=inputs={len(parts)}:normalize=0[out]")
    args += ["-filter_complex", ";".join(chains), "-map", "[out]", "-c:a", "flac", str(out / f"{name}.flac")]
    subprocess.run(args, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("song", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--cpu", action="store_true")
    ap.add_argument("--only", default=",".join(RUNS))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    times = {}
    for key in a.only.split(","):
        times[key] = run_model(key, a.song.resolve(), a.out.resolve(), a.cpu)
        print(f"{key:10} {times[key]:7.1f} s", flush=True)

    if not a.cpu:
        made = {p.stem for p in a.out.glob("*.flac")}
        recipes = {
            "mix_vocal_reduced_-12dB_bsr": [("bsr_inst", 0), ("bsr_vocals", -12)],
            "mix_vocal_reduced_-12dB_kim": [("kim_inst", 0), ("kim_vocals", -12)],
            "mix_lead_reduced_-12dB_karafb": [("karafb_karaoke", 0), ("karafb_lead", -12)],
            "mix_chorus_kept_via_vocal_stem": [("kim_inst", 0), ("karafbv_backing", 0)],
        }
        for name, parts in recipes.items():
            if all(stem in made for stem, _ in parts):
                ffmpeg_mix(a.out, name, parts)
                print("made", name)
    (a.out / ("times_cpu.json" if a.cpu else "times.json")).write_text(json.dumps(times, indent=1))


if __name__ == "__main__":
    sys.exit(main())
