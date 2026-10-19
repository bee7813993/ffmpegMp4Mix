ぴたトラック（Store 版）のライセンス

■ ぴたトラック本体
ぴたトラックは Apache License 2.0 で提供しています。
  ライセンス: licenses\PitaTrack\LICENSE
  ソース: https://github.com/bee7813993/ffmpegMp4Mix

■ FFmpeg
ぴたトラックは、FFmpeg プロジェクトのソフトウェアを LGPLv2.1 で使っています。
This software uses libraries from the FFmpeg project under the LGPLv2.1.

同梱の ffmpeg.exe は FFmpeg __FFMPEG_VERSION__（https://ffmpeg.org/）を、公式のソースから手を加えずに、
LGPL の部品だけでビルドしたものです。ぴたトラックは ffmpeg.exe を別のプログラムとして呼び出します。
  ライセンス: GNU Lesser General Public License version 2.1 以降（licenses\FFmpeg\LICENSE.txt）
  ビルドの指定: licenses\FFmpeg\BUILD.txt
  ソース: licenses\FFmpeg\source\（このアプリに入っています）
          __FFMPEG_RELEASE_URL__
ぴたトラックの作者は FFmpeg の著作権を持っていません。FFmpeg の著作権は、その作者たちにあります。
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
ぴたトラックは FFmpeg プロジェクトとは関係ありません。

ffmpeg.exe に静的にリンクしている mingw-w64 のランタイムの著作権表示: licenses\FFmpeg\mingw-w64-runtime-copyright.txt

■ BSRoformer.cpp と ggml（ボーカル分離のエンジン）
ボーカル分離には、BSRoformer.cpp（__BSROFORMER_VERSION__）と、それが使うテンソル ライブラリ ggml を使っています。
どちらも MIT License です。同梱の tools\bsroformer\bs_roformer-cli.exe と ggml*.dll は、BSRoformer.cpp の作者が
配布している Windows 用（Vulkan 版）のファイルを手を加えずに入れたものです。ぴたトラックは bs_roformer-cli.exe を
別のプログラムとして呼び出します。
  BSRoformer.cpp: Copyright (c) 2026 沉默の金（chenmozhijin）
    ライセンス: licenses\BSRoformer.cpp\LICENSE.txt
    ソースと配布元: __BSROFORMER_RELEASE_URL__
  ggml: Copyright (c) 2023-2026 The ggml authors
    ライセンス: licenses\BSRoformer.cpp\ggml-LICENSE.txt
    ソース: https://github.com/ggml-org/ggml
bs_roformer-cli.exe が使う Microsoft Visual C++ ランタイムは、Microsoft Store が Microsoft.VCLibs.140.00.UWPDesktop
として一緒に入れます。

■ ボーカル分離のモデル
モデル（GGUF ファイル）はこのアプリには入っていません。初めて使うときに、ぴたトラックの GitHub Release
  __MODELS_RELEASE_URL__
からダウンロードし、各モデルのライセンス文（*.LICENSE.txt）を同じフォルダーに置きます。ダウンロードの前に、
作者・ライセンス・入手元を画面で確かめられます。置き場は設定と同じアプリ専用の場所
（%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\models）で、「ボーカル分離」画面の
「モデルフォルダーを開く」で開けます。アンインストールすると消えます。
  Kim Mel-Roformer（kim_mel_vocals-Q8_0.gguf）
    作者: Kimberley Jensen / ライセンス: MIT License
    元のモデル: https://huggingface.co/KimberleyJSN/melbandroformer
  BS-Roformer Karaoke anvuew（karaoke_anvuew-Q8_0.gguf）
    作者: anvuew / ライセンス: GNU General Public License version 3
    元のモデル: https://huggingface.co/anvuew/karaoke_bs_roformer
どちらも、元の重みを BSRoformer.cpp の変換スクリプトで GGUF 形式（8 bit 量子化）に変えたものです。
ぴたトラックの作者はモデルの著作権を持っていません。GPL のモデルは、ぴたトラック本体（Apache License 2.0）とは
別のファイルとして配っており、このアプリのパッケージには含まれません。
