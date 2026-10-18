#!/usr/bin/env bash
# build.sh の出力を GitHub Release に置く形にまとめる。
#
# 使い方: dev/ffmpeg-lgpl/package_release.sh BUILD_OUTPUT_DIR RELEASE_DIR
#   BUILD_OUTPUT_DIR: build.sh の出力先（<名前>-lgpl-win64/ と <名前>-source/ がある）
#   RELEASE_DIR に次を作る:
#     <名前>-lgpl-win64.zip     ffmpeg.exe、LICENSE.txt、README.txt、BUILD.txt など
#     ffmpeg-<版>.tar.xz(.asc)  FFmpeg 公式のソースと署名（そのまま）
#     <名前>-build-files.zip    ビルドに使ったスクリプトと configure の指定
#     SHA256SUMS.txt、release-notes.md
# 必要なもの: zip
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ffmpeg-source.env
. "$script_dir/ffmpeg-source.env"

name="ffmpeg-${FFMPEG_VERSION}"
build_name="${name}-pitatrack${PITATRACK_BUILD}"
tarball="${name}.tar.xz"
repo_slug=${GITHUB_REPOSITORY:-bee7813993/ffmpegMp4Mix}
release_url="https://github.com/${repo_slug}/releases/tag/${build_name}"

build_out=$(cd "$1" && pwd)
mkdir -p "$2"
release_dir=$(cd "$2" && pwd)
bin_dir="$build_out/${build_name}-lgpl-win64"
source_dir="$build_out/${build_name}-source"
for path in "$bin_dir/ffmpeg.exe" "$source_dir/$tarball" "$source_dir/$tarball.asc"; do
    [ -f "$path" ] || { echo "error: $path がありません" >&2; exit 1; }
done

rm -rf "${release_dir:?}"/*
(cd "$build_out" && zip -q -r -X "$release_dir/${build_name}-lgpl-win64.zip" "${build_name}-lgpl-win64")
cp "$source_dir/$tarball" "$source_dir/$tarball.asc" "$release_dir/"
build_files="$release_dir/${build_name}-build-files"
mkdir -p "$build_files"
(cd "$source_dir" && cp BUILD.txt build.sh configure-options.txt ffmpeg-source.env ffmpeg-devel.asc "$build_files/")
(cd "$release_dir" && zip -q -r -X "${build_name}-build-files.zip" "${build_name}-build-files" && rm -rf "${build_name}-build-files")
(cd "$release_dir" && sha256sum ./*.zip "$tarball" "$tarball.asc" | sed 's| \./| |' >SHA256SUMS.txt)

configure_line=$(sed -n '/^Configure /,/^$/p' "$bin_dir/BUILD.txt" | sed '1d;/^$/d;s/^  //')
cat >"$release_dir/release-notes.md" <<EOF
FFmpeg ${FFMPEG_VERSION} を、ぴたトラックに同梱するために LGPL の部品だけでビルドした Windows x64 版の ffmpeg.exe です。
This is ffmpeg.exe for Windows x64, FFmpeg ${FFMPEG_VERSION} built with LGPL components only, bundled with PitaTrack.

This software uses code of FFmpeg licensed under the LGPLv2.1 and its source can be downloaded here: ${release_url}

| ファイル | 内容 |
|---|---|
| \`${build_name}-lgpl-win64.zip\` | ffmpeg.exe、LICENSE.txt（LGPL 2.1）、README.txt、BUILD.txt（configure の指定とビルド環境） |
| \`${tarball}\` | FFmpeg 公式のソース（手を加えていない）。SHA256 \`${FFMPEG_SHA256}\` |
| \`${tarball}.asc\` | 公式の署名（FFmpeg release signing key \`${FFMPEG_SIGNING_KEY}\`） |
| \`${build_name}-build-files.zip\` | ビルドに使ったスクリプト（build.sh）、configure の指定、ソースの版と SHA256 |
| \`SHA256SUMS.txt\` | 上のファイルの SHA256 |

- GPL と nonfree の部品、外部のライブラリは入っていません（\`--enable-gpl\`、\`--enable-nonfree\` なし）。
- ffmpeg.exe は静的リンクで、Windows に付属の DLL のほかには何も使いません。

configure:
\`\`\`
${configure_line}
\`\`\`

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. PitaTrack is not affiliated with the FFmpeg project.
EOF

ls -l "$release_dir"
