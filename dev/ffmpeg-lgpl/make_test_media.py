#!/usr/bin/env python3
"""test_pitatrack_usage.ps1 で LGPL 版の ffmpeg.exe に読ませる素材を作る。

使い方: make_test_media.py 出力先 [FFMPEG]

FFMPEG（既定: PATH の ffmpeg）は libx264、libmp3lame、libvorbis、libopus と ac3、eac3 のエンコーダー入りの
ふつうのビルドにする。素材を作るだけで、確かめる対象の ffmpeg ではない。

どのファイルも同じ合成の「曲」（立ち上がりのはっきりした音の並び）が入っている:
  base:  ONSET 秒から始まる（video.mp4 の音声と同じ）
  early: EARLY_MS だけ早く始まる。ぴたトラックでは +EARLY_MS 遅らせるとそろう
  late:  LATE_MS だけ遅く始まる。ぴたトラックでは -LATE_MS 早めるとそろう
media.json に、ファイルの一覧とこれらの値を書く。
"""

import json
import math
import pathlib
import random
import struct
import subprocess
import sys
import wave

RATE = 44100
LENGTH = 30.0
ONSET = 1.0
EARLY_MS = 600
LATE_MS = 1234

# （ファイル名の後ろ、ffmpeg の出力の指定、ffmpeg が表示するコーデック名）
FORMATS = [
    (".m4a", ["-c:a", "aac", "-b:a", "192k"], "aac"),
    ("_alac.m4a", ["-c:a", "alac"], "alac"),
    (".aac", ["-c:a", "aac", "-b:a", "192k", "-f", "adts"], "aac"),
    (".mp3", ["-c:a", "libmp3lame", "-b:a", "192k"], "mp3"),
    (".wav", ["-c:a", "pcm_s16le"], "pcm_s16le"),
    ("_s24.wav", ["-c:a", "pcm_s24le"], "pcm_s24le"),
    ("_f32.wav", ["-c:a", "pcm_f32le"], "pcm_f32le"),
    (".flac", ["-c:a", "flac"], "flac"),
    ("_vorbis.ogg", ["-c:a", "libvorbis", "-q:a", "5"], "vorbis"),
    ("_opus.ogg", ["-c:a", "libopus", "-b:a", "128k"], "opus"),
    ("_flac.ogg", ["-c:a", "flac", "-f", "ogg"], "flac"),
    # MP4 の中の AC-3 / E-AC-3（テレビ録画など）。pitatrack3 から自動調整とボーカル分離の対象
    ("_ac3.mp4", ["-c:a", "ac3", "-b:a", "192k"], "ac3"),
    ("_eac3.mp4", ["-c:a", "eac3", "-b:a", "192k"], "eac3"),
]
# early と late は、artifact を小さくするためにこの形式だけで作る
SHIFTED_FORMATS = {".m4a", "_alac.m4a", ".aac", ".mp3", ".wav", ".flac", "_vorbis.ogg", "_opus.ogg"}


def make_music(length):
    """length 秒のモノラルのサンプル（-1〜1）。最初の音は 0 秒から始まる。"""
    rnd = random.Random(20261018)
    scale = [48, 50, 52, 55, 57, 60, 62, 64, 67, 69, 72, 74, 76, 79]
    total = int(length * RATE)
    samples = [0.0] * total
    position = 0
    while position < total:
        duration = int(rnd.choice([0.15, 0.2, 0.25, 0.3, 0.4]) * RATE)
        frequency = 440.0 * 2.0 ** ((rnd.choice(scale) - 69) / 12.0)
        attack = int(0.003 * RATE)
        release = int(0.005 * RATE)
        step = 2.0 * math.pi * frequency / RATE
        for i in range(min(duration, total - position)):
            envelope = math.exp(-i / (0.15 * RATE))
            if i < attack:
                envelope *= i / attack
            if i > duration - release:
                envelope *= (duration - i) / release
            phase = step * i
            samples[position + i] = envelope * (
                0.25 * math.sin(phase) + 0.12 * math.sin(2 * phase) + 0.06 * math.sin(3 * phase))
        position += duration
    return samples


def write_wav(path, music, start):
    total = int(LENGTH * RATE)
    lead = int(round(start * RATE))
    frames = bytearray()
    for i in range(total):
        j = i - lead
        value = music[j] if 0 <= j < len(music) else 0.0
        left = int(value * 32767)
        right = int(value * 0.8 * 32767)
        frames += struct.pack("<hh", left, right)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(bytes(frames))


def run(ffmpeg, *args):
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = pathlib.Path(sys.argv[1])
    ffmpeg = sys.argv[2] if len(sys.argv) > 2 else "ffmpeg"
    out.mkdir(parents=True, exist_ok=True)

    music = make_music(LENGTH)
    starts = {
        "base": ONSET,
        "early": ONSET - EARLY_MS / 1000.0,
        "late": ONSET + LATE_MS / 1000.0,
    }
    files = []
    for kind, start in starts.items():
        master = out / (kind + ".wav")
        write_wav(master, music, start)
        for suffix, options, codec in FORMATS:
            if kind != "base" and suffix not in SHIFTED_FORMATS:
                continue
            target = out / (kind + suffix)
            if target != master:
                run(ffmpeg, "-i", str(master), *options, str(target))
            files.append({"file": target.name, "kind": kind, "start": start, "codec": codec})

    run(ffmpeg, "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-i", str(out / "base.wav"),
        "-map", "0:v", "-map", "1:a", "-t", str(LENGTH),
        "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", str(out / "video.mp4"))

    manifest = {
        "length": LENGTH,
        "onset": ONSET,
        "earlyMs": EARLY_MS,
        "lateMs": LATE_MS,
        "video": "video.mp4",
        "files": files,
    }
    (out / "media.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("Made %d audio files and video.mp4 in %s" % (len(files), out))


if __name__ == "__main__":
    main()
