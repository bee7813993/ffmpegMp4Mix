# Store 版に同梱する ffmpeg.exe（FFmpeg の LGPL ビルド）

Store 版（MSIX）のぴたトラックに同梱する `ffmpeg.exe` を、FFmpeg 公式のソースから LGPL の部品だけでビルドする仕組みです。ZIP 版の `tools\setup.ps1` がダウンロードする gyan.dev のビルド（GPLv3、外部ライブラリ入り）は、同梱して配るには GPL の対応するソース一式が必要になるため使いません。

- FFmpeg 9.0.2 の公式ソース（`ffmpeg-9.0.2.tar.xz`）を、固定した SHA256 と FFmpeg の署名で確かめてから使います。ソースには手を加えません。
- `--enable-gpl` と `--enable-nonfree` を付けず、外部のライブラリも使いません。`--disable-everything` から、ぴたトラックが使う部品だけを足します。
- Ubuntu 上の mingw-w64 でクロスコンパイルした、Windows x64 の静的リンクの exe です（約 3.9 MB）。Windows に付属の DLL（kernel32、msvcrt、shell32、bcrypt）のほかには何も使いません。

ライセンス表示の文案と、FFmpeg 公式のチェックリストへの対応は [license-notice.md](license-notice.md) にあります。

## ファイル

| ファイル | 内容 |
|---|---|
| `ffmpeg-source.env` | ビルドする FFmpeg の版、ソースの SHA256、署名の鍵、ぴたトラック側のビルド番号 |
| `configure-options.txt` | configure の指定（入れる部品） |
| `build.sh` | ソースを取ってきて確かめ、ビルドし、成果物をまとめる |
| `ffmpeg-devel.asc` | FFmpeg の署名用の公開鍵（https://ffmpeg.org/ffmpeg-devel.asc） |
| `package_release.sh` | 成果物を GitHub Release に置く形（zip など）にまとめる |
| `make_test_media.py` | 確かめるための素材（動画と各形式の音声）を作る |
| `test_pitatrack_usage.ps1` | ぴたトラックの使い方どおりに ffmpeg.exe を動かして確かめる |
| `license-notice.md` | Store 版に入れるライセンス表示の文案 |
| `../../.github/workflows/ffmpeg-lgpl.yml` | 上を GitHub Actions で動かすワークフロー |

## 入っている部品

| 用途 | 部品 |
|---|---|
| 読む（入れ物） | mov（.mp4 .m4a .mov）、aac（ADTS）、mp3、wav、flac、ogg。ファイルとパイプ |
| 読む（音声のデコード） | aac、mp3、vorbis、opus、flac、alac、pcm（8/16/24/32 ビット整数、32/64 ビット浮動小数点） |
| 書く | mp4、f32le（自動調整の取り出し）。エンコーダーは aac と pcm_f32le だけ |
| フィルター | adelay、aresample（と ffmpeg.exe が自動で入れる aformat、anull、atrim など） |
| そのほか | aac_adtstoasc（.aac を MP4 にコピーするとき）、aac・mpegaudio・flac・vorbis・opus・h264・hevc のパーサー |

映像はいつもコピーなので、映像のデコーダーとエンコーダーは入っていません。動画の音声も、ずらさなければコピーするので、デコーダーがない形式（AC-3 など）でもそのまま入ります。デコーダーが要るのは、AAC に再エンコードするトラックと、自動調整で解析するファイルです。

## GitHub Actions

`.github/workflows/ffmpeg-lgpl.yml` は、このフォルダー、ワークフロー、`tools\mixtrack_ffmpeg_gui.ps1` を変えたプルリクエストと main への push で動きます。手動（workflow_dispatch）でも動かせます。

| ジョブ | 内容 |
|---|---|
| build | Ubuntu 24.04 で `build.sh` を実行し、成果物を artifact に出す |
| test-media | Ubuntu のふつうの ffmpeg で、確かめるための素材を作る（素材を作るだけで、確かめる対象ではない） |
| test | Windows（Windows PowerShell 5.1）で `test_pitatrack_usage.ps1` を実行する。結果はジョブの概要（Summary）にも出る |
| release | タグを push したとき、または手動で `release_tag` を指定したときだけ、GitHub Release にファイルを置く |

artifact:

| 名前 | 中身 |
|---|---|
| `ffmpeg-9.0.2-pitatrack1-lgpl-win64` | `ffmpeg.exe`、`LICENSE.txt`（LGPL 2.1 の全文）、`FFmpeg-LICENSE.md`、`README.txt`（ソースの場所）、`BUILD.txt`（configure の指定とビルド環境）、`configure-options.txt`、`mingw-w64-runtime-copyright.txt`、`SHA256SUMS.txt` |
| `ffmpeg-9.0.2-pitatrack1-source` | `ffmpeg-9.0.2.tar.xz`（公式のソース）とその署名、`BUILD.txt`、ビルドに使ったスクリプトと指定 |
| `ffmpeg-9.0.2-pitatrack1-test-report` | 確かめた結果（`test-report.md`）、`ffmpeg -version`・`-buildconf`・`-L`・部品の一覧、ffmpeg のログ |

## Store 版のパッケージに入れる

artifact を取ってきて、`dev\build_msix.ps1`（PR #5）の `-FfmpegPath` に渡します。

```bat
gh run download <実行の ID> -n ffmpeg-9.0.2-pitatrack1-lgpl-win64 -D dist\ffmpeg-lgpl
powershell -NoProfile -ExecutionPolicy Bypass -File dev\build_msix.ps1 -FfmpegPath dist\ffmpeg-lgpl\ffmpeg.exe
```

GitHub Release に置いたあとは、`ffmpeg-9.0.2-pitatrack1-lgpl-win64.zip` を展開したものでもかまいません。`ffmpeg.exe` と一緒に、同じフォルダーのライセンスのファイルもパッケージに入れます（[license-notice.md](license-notice.md) の「パッケージに入れるファイル」）。

## GitHub Release に置く

ライセンス表示が指す「ソースの置き場所」は、タグ `ffmpeg-<版>-pitatrack<ビルド番号>` の Release です。Store 版を出す前に作ります。

```bat
git tag ffmpeg-9.0.2-pitatrack1
git push origin ffmpeg-9.0.2-pitatrack1
```

ワークフローがビルドと確認をしてから、次のファイルを置いた Release を作ります。ぴたトラック本体の「最新のリリース」（Latest）は変えません。タグが `ffmpeg-source.env` の版と違うときは止まります。

- `ffmpeg-9.0.2-pitatrack1-lgpl-win64.zip`（artifact の `-lgpl-win64` と同じもの）
- `ffmpeg-9.0.2.tar.xz` と `ffmpeg-9.0.2.tar.xz.asc`（公式のソースと署名。そのまま）
- `ffmpeg-9.0.2-pitatrack1-build-files.zip`（`BUILD.txt`、`build.sh`、`configure-options.txt` など）
- `SHA256SUMS.txt`

GitHub はタグの時点のリポジトリのソース（Source code の zip と tar.gz）も Release に付けるので、ビルドに使ったスクリプトはそこにも残ります。

ぴたトラック本体の Release（例: v2.1.0）にも同じファイルを置きたいときは、Actions の画面で「FFmpeg LGPL build」を手動で実行し、`release_tag` にその Release のタグを入れます。

## 手元でビルドする

Ubuntu 24.04（WSL や Docker でもよい）で実行します。

```sh
sudo apt-get install -y --no-install-recommends build-essential curl ca-certificates xz-utils gnupg nasm \
  gcc-mingw-w64-x86-64-win32 binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev
bash dev/ffmpeg-lgpl/build.sh
```

`dist\ffmpeg-lgpl\` に成果物ができます（作業の場所は `build\ffmpeg-lgpl\`）。Docker なら、リポジトリのフォルダーで次のようにします。

```sh
docker run --rm -v "$PWD:/repo" -w /repo ubuntu:24.04 bash -c "apt-get update && apt-get install -y --no-install-recommends build-essential curl ca-certificates xz-utils gnupg nasm gcc-mingw-w64-x86-64-win32 binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev && WORK_DIR=/tmp/work bash dev/ffmpeg-lgpl/build.sh"
```

確かめるときは、素材を作ってから（ふつうの ffmpeg と Python 3 が要る）、Windows でテストを実行します。

```bat
python dev\ffmpeg-lgpl\make_test_media.py dist\test-media
powershell -NoProfile -ExecutionPolicy Bypass -File dev\ffmpeg-lgpl\test_pitatrack_usage.ps1 -FfmpegPath dist\ffmpeg-lgpl\ffmpeg-9.0.2-pitatrack1-lgpl-win64\ffmpeg.exe -MediaDir dist\test-media -OutputDir dist\test-results
```

`-UsageOnly` を付けると、ライセンスと部品の確認を飛ばして使い方だけを確かめます。ほかの ffmpeg（gyan.dev のビルドなど）と結果を比べるときに使います。

## テストで確かめていること

`test_pitatrack_usage.ps1` は、`tools\mixtrack_ffmpeg_gui.ps1` から `Build-FfmpegArguments` などの関数と、自動調整の C#（`AudioOffsetAnalyzer`）をそのまま読み込んで使います。ファイル名、フォルダー名、トラック名には日本語と空白を使います。

1. ライセンスと部品: `ffmpeg -version` の版、`-buildconf` に `--enable-gpl`・`--enable-nonfree`・`--enable-version3`・`--enable-lib…` がないこと、`-L` が LGPL 2.1 以降であること、必要な部品があること、エンコーダーが aac と pcm_f32le だけであること
2. MP4 にまとめる: コピーで遅らせる（`-itsoffset`）、コピーで早める（`-ss`）、ずらさないコピー、AAC で再エンコードして遅らせる（`adelay`）。どれも映像（H.264 のコピー）と、各形式の音声トラックを 1 つの MP4 にまとめ、コーデック、トラック名（`handler_name` と `title`）、音の出だしが動画の音声とそろっていること（許容差 40 ms）を見る
3. 自動調整: 各形式のファイルを `AudioOffsetAnalyzer.Decode`（`-f f32le` で標準出力へ）で読み、長さと出だしを見る。さらに `Analyze` で、ずれ（0、+600、-1234 ms）を許容差 25 ms で推定できること

素材は 30 秒と短いので、テストでは自動調整の探す範囲（`MaxLagSeconds`）を 20 秒にしています。

## FFmpeg の版を上げる

1. `ffmpeg-source.env` の手順で、新しいソースの署名を確かめ、`FFMPEG_VERSION`、`FFMPEG_SHA256` を書き換え、`PITATRACK_BUILD` を 1 に戻す（configure の指定だけを変えたときは `PITATRACK_BUILD` を 1 つ上げる）
2. プルリクエストを作り、ワークフローが緑になることを確かめる。configure で部品の名前が変わっていれば、build.sh がその名前を示して止まる
3. まとめた MP4 を MPC-BE などで再生し、遅らせる・早めるの結果を耳で確かめる（コピーで遅らせる方法は、ffmpeg が MP4 に書く編集リストにプレーヤーが従うことが前提）
4. タグ `ffmpeg-<版>-pitatrack<番号>` を push して Release を作り、ライセンス表示の URL をその Release に変える
