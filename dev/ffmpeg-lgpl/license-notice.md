# Store 版の FFmpeg のライセンス表示（文案）

Store 版（MSIX）のぴたトラックは、FFmpeg 9.0.2 を LGPL の部品だけでビルドした `ffmpeg.exe`（このフォルダーの `build.sh` で作る）を同梱し、別のプログラムとして呼び出します。ここには、そのために入れるライセンス表示の文案と、FFmpeg 公式の [License Compliance Checklist](https://ffmpeg.org/legal.html) への対応をまとめます。

- ソースの置き場所は、GitHub Release の `https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack2` とします（[README.md](README.md) の「GitHub Release に置く」で作る）。FFmpeg の版や `PITATRACK_BUILD` を上げたら、下の文案の版と URL も変えます。
- 公開されている資料をもとにした整理で、法律の助言ではありません。

## 1. アプリの「ライセンス」画面（About）

チェックリストの 10 番（About に FFmpeg を LGPLv2.1 で使っていると書く）に当たります。

```text
ぴたトラックは、FFmpeg プロジェクトのソフトウェアを LGPLv2.1 で使っています。
This software uses libraries from the FFmpeg project under the LGPLv2.1.

同梱の ffmpeg.exe は FFmpeg 9.0.2（https://ffmpeg.org/）を、公式のソースから手を加えずに、
LGPL の部品だけでビルドしたものです。
  ライセンス: GNU Lesser General Public License version 2.1 以降（licenses\FFmpeg\LICENSE.txt）
  ソースとビルドの指定: https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack2
ぴたトラックの作者は FFmpeg の著作権を持っていません。FFmpeg の著作権は、その作者たちにあります。
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
ぴたトラックは FFmpeg プロジェクトとは関係ありません。

ぴたトラック本体: Apache License 2.0（licenses\PitaTrack\LICENSE）
```

## 2. Store の掲載情報「追加のライセンス条項」（Additional license terms）

チェックリストの 11〜14 番（使用許諾に FFmpeg を LGPLv2.1 で使っていると書く、FFmpeg を自分のものとしない、リバースエンジニアリングを禁じない、すべての言語で同じにする）に当たります。日本語と英語の両方を入れ、内容をそろえます。

```text
ぴたトラックは Apache License 2.0 で提供します（https://github.com/bee7813993/ffmpegMp4Mix/blob/main/LICENSE）。

このアプリには FFmpeg プロジェクト（https://ffmpeg.org/）の ffmpeg.exe が入っています。
このソフトウェアは LGPLv2.1 でライセンスされた FFmpeg のコードを使っています。ソースはこちらからダウンロードできます:
https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack2
FFmpeg は GNU Lesser General Public License version 2.1 以降のライセンスで配布されています。
ぴたトラックの提供者は FFmpeg の著作権を持っていません。FFmpeg の著作権はその作者たちにあります（https://ffmpeg.org/ とソースを参照）。
この条項は、LGPL が利用者に認める権利（FFmpeg を改変すること、その改変のデバッグのためにリバースエンジニアリングすることを含む）を制限しません。
FFmpeg は FFmpeg プロジェクトの創始者 Fabrice Bellard の商標です。

PitaTrack is provided under the Apache License 2.0 (https://github.com/bee7813993/ffmpegMp4Mix/blob/main/LICENSE).

This app includes ffmpeg.exe from the FFmpeg project (https://ffmpeg.org/).
This software uses code of FFmpeg licensed under the LGPLv2.1 and its source can be downloaded here:
https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack2
FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later.
The provider of PitaTrack does not own FFmpeg. FFmpeg is copyrighted by its authors (see https://ffmpeg.org/ and the source).
Nothing in these terms restricts the rights the LGPL gives you, including the right to modify FFmpeg and to reverse engineer for debugging such modifications.
FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
```

Store の既定の利用規約（Standard Application License Terms）は、複製や再配布を制限しています。この欄に書いた条項が既定の利用規約を置き換えるのか、足されるだけなのかを説明した公式の資料は見つかっていません。上の文案は、どちらの場合でも LGPL の権利を制限しないことをはっきりさせるためのものです。

## 3. ダウンロードのページ（Store の説明文、GitHub の README や Release など）

チェックリストの 9 番（アプリのダウンロードへのリンクがあるページすべてに、FFmpeg を LGPLv2.1 で使っていることとソースの場所を書く）に当たります。

```text
このソフトウェアは LGPLv2.1 でライセンスされた FFmpeg のコードを使っています。ソースはこちらからダウンロードできます: https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack2
This software uses code of FFmpeg licensed under the LGPLv2.1 and its source can be downloaded here: https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/ffmpeg-9.0.2-pitatrack2
```

## 4. パッケージに入れるファイル

| パッケージの中 | 元 |
|---|---|
| `tools\ffmpeg.exe` | Release の `ffmpeg-9.0.2-pitatrack2-lgpl-win64.zip` の `ffmpeg.exe` |
| `licenses\FFmpeg\LICENSE.txt` | 同じ artifact の `LICENSE.txt`（LGPL 2.1 の全文） |
| `licenses\FFmpeg\FFmpeg-LICENSE.md` | 同じ artifact の `FFmpeg-LICENSE.md` |
| `licenses\FFmpeg\README.txt` | 同じ artifact の `README.txt`（ソースの場所） |
| `licenses\FFmpeg\BUILD.txt` | 同じ artifact の `BUILD.txt`（configure の指定とビルド環境） |
| `licenses\FFmpeg\mingw-w64-runtime-copyright.txt` | 同じ artifact の `mingw-w64-runtime-copyright.txt`（静的にリンクした mingw-w64 のランタイム） |
| `licenses\PitaTrack\LICENSE` | リポジトリの `LICENSE`（Apache 2.0） |
| `licenses\FFmpeg\source\` | Release の `ffmpeg-9.0.2.tar.xz`、`ffmpeg-9.0.2.tar.xz.asc`、`ffmpeg-9.0.2-pitatrack2-build-files.zip`（下の案 A） |
| `licenses\README.txt` | `msix\licenses-README.txt`（1 の文面。アプリの「設定 → ライセンス」で表示する） |

`dev\build_msix.ps1` が、Release からこれらをダウンロードし、スクリプトに書いた SHA256 と照らし合わせてから入れます。zip の中の `SHA256SUMS.txt` と `configure-options.txt` も `licenses\FFmpeg\` に入ります。

### ソースをパッケージにも入れるか（案 A にした）

LGPL 2.1 の第 4 節は、FFmpeg を実行形式で配るとき、対応するソースを「一緒に付ける」か、実行形式と「同じ場所」からソースを取れるようにすることを求めています。FFmpeg のチェックリストの 8 番も、ソースを実行形式と同じサーバーに置くよう勧めています。Store 版の実行形式は Microsoft のサーバーから配られるので、GitHub Release のソースは厳密には「同じ場所」ではありません。

- **案 A（いちばん確実）**: `ffmpeg-9.0.2.tar.xz`（約 12 MB）と `ffmpeg-9.0.2-pitatrack2-build-files.zip` をパッケージの `licenses\FFmpeg\source\` にも入れる。パッケージは約 12 MB 大きくなる（ffmpeg.exe は約 3.9 MB）。ソースは必ず実行形式と一緒に届く。
- **案 B**: パッケージには入れず、GitHub Release に置いてライセンス画面と Store の掲載情報から案内する。多くのアプリがこの形をとっているが、上の「同じ場所」の条件を文字どおりには満たさない。

どちらの場合も、GitHub Release にはソースを置き、表示の URL はそこを指します。

2026-10-19 に**案 A** にしました（`dev\build_msix.ps1` がソースを `licenses\FFmpeg\source\` に入れる）。パッケージはソースの分だけ大きくなりますが、条件を文字どおりに満たします。

## 5. FFmpeg のチェックリストへの対応

| # | チェックリストの項目（要約） | 対応 |
|---|---|---|
| 1 | `--enable-gpl` と `--enable-nonfree` を付けない | 付けていない。`--enable-version3` も付けず、外部のライブラリも使わない。CI の `-buildconf` と `-L` の確認で毎回見る |
| 2 | FFmpeg のライブラリには動的にリンクする（Windows では DLL） | ぴたトラックは FFmpeg のライブラリにリンクせず、`ffmpeg.exe` を別のプロセスとして呼ぶだけ。`ffmpeg.exe` の中で FFmpeg のライブラリを静的にリンクしているのは FFmpeg 自身で、ぴたトラックの側のリンクではない |
| 3 | 改変の有無にかかわらず FFmpeg のソースを配る | GitHub Release に公式の tarball を置き、Store 版はパッケージにも入れる（案 A） |
| 4 | ソースが配る実行形式と正確に対応している | 同じタグのワークフローで、SHA256 と署名を確かめた tarball からビルドし、その tarball をそのまま置く |
| 5 | 改変を `changes.diff` にまとめる | 改変していない（パッチなし）。`BUILD.txt` にその旨を書いている |
| 6 | どうビルドしたか（configure の指定など）をテキストファイルで添える | `BUILD.txt`（configure の全体、ツールチェーンの版）と `configure-options.txt` を、バイナリの zip と build-files.zip の両方に入れる |
| 7 | ソースは tarball か zip で配る | 公式の `ffmpeg-9.0.2.tar.xz` をそのまま置く |
| 8 | ソースを実行形式と同じサーバーに置く | Store 版はソースをパッケージに入れて、実行形式と一緒に届ける（案 A）。ZIP 版などを GitHub Release で配るときは同じ Release に置ける |
| 9 | ダウンロードのリンクがあるページに、LGPLv2.1 の FFmpeg を使っていることとソースの場所を書く | 3 の文案 |
| 10 | About に LGPLv2.1 の FFmpeg を使っていると書く | 1 の文案 |
| 11 | 使用許諾（EULA）に LGPLv2.1 の FFmpeg を使っていると書く | 2 の文案 |
| 12 | EULA で所有権を主張するなら、FFmpeg は自分のものではないことと、持ち主がどこにいるかを書く | 2 の文案に入れている |
| 13 | EULA からリバースエンジニアリングの禁止を外す | ぴたトラックの Apache 2.0 には禁止がない。2 の文案で、LGPL の権利を制限しないことを書く |
| 14 | EULA のすべての翻訳に同じ変更をする | 2 の文案は日本語と英語で同じ内容にしている |
| 15 | FFmpeg の綴りを間違えない（F が 2 つ大文字、mpeg は小文字） | 文案はすべて「FFmpeg」 |
| 16 | FFmpeg の DLL の名前を分かりにくく変えない | DLL はない。`ffmpeg.exe` の名前もそのまま |
| 17 | FFmpeg に組み込んだ LGPL の外部ライブラリについても同じことをする | 外部のライブラリは組み込んでいない（`--disable-autodetect`）。静的にリンクしている mingw-w64 のランタイムは LGPL ではないが、著作権表示（`mingw-w64-runtime-copyright.txt`）を添える |
| 18 | GPL のライブラリ（特に libx264）を使わない | 使っていない。CI でエンコーダーが aac と pcm_f32le だけであることを確かめる |
