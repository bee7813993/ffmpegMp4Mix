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
