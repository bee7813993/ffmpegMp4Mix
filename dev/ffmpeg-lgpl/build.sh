#!/usr/bin/env bash
# ぴたトラックに同梱する ffmpeg.exe を作ります。
#   - FFmpeg 公式のソースの tarball を、SHA256（ffmpeg-source.env で固定）と公式の署名で確かめてから使う
#   - LGPL だけ（--enable-gpl と --enable-nonfree なし）で、ぴたトラックが使う部品だけを入れる（configure-options.txt）
#   - mingw-w64 でクロスコンパイルした、Windows x64 の静的リンクの exe
#
# 使い方: dev/ffmpeg-lgpl/build.sh [出力先]        （既定: dist/ffmpeg-lgpl）
#   出力先/ffmpeg-<版>-pitatrack<n>-lgpl-win64/  ffmpeg.exe、LICENSE.txt、README.txt、BUILD.txt など
#   出力先/ffmpeg-<版>-pitatrack<n>-source/      公式のソースと署名、このビルドの指定一式
#
# 環境変数:
#   WORK_DIR  ダウンロード、展開、ビルドの場所（既定: build/ffmpeg-lgpl）
#   JOBS      make の並列数（既定: nproc）
#   BUILD_COMMIT  BUILD.txt に書くスクリプトのコミット（既定: GITHUB_SHA、なければ git の HEAD）
#
# 必要なもの（Ubuntu 24.04）: build-essential curl ca-certificates xz-utils gnupg nasm
#   gcc-mingw-w64-x86-64-win32 binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
# shellcheck source=ffmpeg-source.env
. "$script_dir/ffmpeg-source.env"

name="ffmpeg-${FFMPEG_VERSION}"
build_name="${name}-pitatrack${PITATRACK_BUILD}"
tarball="${name}.tar.xz"
source_url="https://ffmpeg.org/releases/${tarball}"
repo_slug=${GITHUB_REPOSITORY:-bee7813993/ffmpegMp4Mix}
release_url="https://github.com/${repo_slug}/releases/tag/${build_name}"

out_dir=${1:-$repo_root/dist/ffmpeg-lgpl}
work_dir=${WORK_DIR:-$repo_root/build/ffmpeg-lgpl}
jobs=${JOBS:-$(nproc)}
mkdir -p "$out_dir" "$work_dir/download"
out_dir=$(cd "$out_dir" && pwd)
work_dir=$(cd "$work_dir" && pwd)

fail() {
    echo "error: $*" >&2
    exit 1
}

# ---- ソース: 固定した SHA256 と FFmpeg の署名で確かめる ----

cd "$work_dir/download"
for file in "$tarball" "$tarball.asc"; do
    if [ ! -f "$file" ]; then
        curl -fsSL --retry 3 -o "$file.part" "https://ffmpeg.org/releases/$file"
        mv "$file.part" "$file"
    fi
done
echo "${FFMPEG_SHA256}  ${tarball}" | sha256sum -c - || fail "$tarball の SHA256 が ffmpeg-source.env と違います"

gnupg_home=$(mktemp -d)
gpg --homedir "$gnupg_home" --batch --quiet --import "$script_dir/ffmpeg-devel.asc"
gpg --homedir "$gnupg_home" --batch --status-fd 1 --verify "$tarball.asc" "$tarball" >"$work_dir/gpg-status.txt" 2>/dev/null || true
rm -rf "$gnupg_home"
grep -Eq "^\[GNUPG:\] VALIDSIG .* ${FFMPEG_SIGNING_KEY}\$" "$work_dir/gpg-status.txt" ||
    fail "$tarball.asc は ${FFMPEG_SIGNING_KEY} の正しい署名ではありません"
echo "確認しました: $tarball（SHA256 と ${FFMPEG_SIGNING_KEY} の署名）"

rm -rf "$work_dir/src" "$work_dir/obj"
mkdir -p "$work_dir/src" "$work_dir/obj"
tar -xJf "$tarball" -C "$work_dir/src"
src="$work_dir/src/$name"

# ---- configure ----

cross_prefix=x86_64-w64-mingw32-
# win32 のスレッド方式の gcc なら winpthreads を使わないので、Windows の DLL のほかは何もリンクしない
cc=${cross_prefix}gcc-win32
command -v "$cc" >/dev/null || cc=${cross_prefix}gcc

toolchain_options=(
    --enable-cross-compile
    --target-os=mingw32
    --arch=x86_64
    "--cross-prefix=${cross_prefix}"
    "--cc=${cc}"
    "--extra-ldflags=-static"
    "--extra-version=pitatrack${PITATRACK_BUILD}"
)
feature_options=()
while IFS= read -r line; do
    line=${line%%#*}
    line=${line//$'\r'/}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    if [ -n "$line" ]; then
        feature_options+=("$line")
    fi
done <"$script_dir/configure-options.txt"
configure_options=("${toolchain_options[@]}" "${feature_options[@]}")

cd "$work_dir/obj"
"$src/configure" "${configure_options[@]}" || {
    tail -n 50 ffbuild/config.log >&2 || true
    fail "configure が失敗しました"
}

# make の前に、configure の結果を確かめる
for define in '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' \
    '#define CONFIG_GPL 0' '#define CONFIG_NONFREE 0' '#define CONFIG_VERSION3 0' \
    '#define HAVE_W32THREADS 1' '#define HAVE_COMMANDLINETOARGVW 1'; do
    grep -qxF "$define" config.h || fail "config.h にありません: $define"
done
# configure は一覧の中の名前の間違いを黙って飛ばすので、1 つずつ有効になったかを見る
for option in "${feature_options[@]}"; do
    case "$option" in
    --enable-*=*)
        kind=${option#--enable-}
        kind=${kind%%=*}
        names=${option#*=}
        for component in ${names//,/ }; do
            macro=$(echo "CONFIG_${component}_${kind}" | tr '[:lower:]' '[:upper:]')
            grep -qxF "#define ${macro} 1" config_components.h || fail "$option の $component が有効になっていません"
        done
        ;;
    esac
done

make -j"$jobs"
[ -f ffmpeg.exe ] || fail "ffmpeg.exe ができませんでした"

# 使ってよい DLL は Windows に付属のものだけ（libwinpthread、libgcc、zlib などは不可）
imports=$(${cross_prefix}objdump -p ffmpeg.exe | sed -n 's/^[[:space:]]*DLL Name: //p' | tr '[:upper:]' '[:lower:]' | sort -u)
for dll in $imports; do
    case "$dll" in
    kernel32.dll | msvcrt.dll | user32.dll | shell32.dll | ole32.dll | advapi32.dll | bcrypt.dll | psapi.dll) ;;
    *) fail "ffmpeg.exe が Windows に付属しない $dll を使っています" ;;
    esac
done

# ---- 出力 ----

bin_dir="$out_dir/${build_name}-lgpl-win64"
source_dir="$out_dir/${build_name}-source"
rm -rf "$bin_dir" "$source_dir"
mkdir -p "$bin_dir" "$source_dir"

configure_line="../${name}/configure"
for option in "${configure_options[@]}"; do
    configure_line+=" \\"$'\n'"    ${option}"
done
build_commit=${BUILD_COMMIT:-${GITHUB_SHA:-$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)}}
host_os=$( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null || uname -sr)
mingw_runtime=$(dpkg-query -W -f='${Version}' mingw-w64-x86-64-dev 2>/dev/null || echo unknown)

cat >"$bin_dir/BUILD.txt" <<EOF
FFmpeg ${FFMPEG_VERSION} for PitaTrack, build ${PITATRACK_BUILD} (${build_name})
License: GNU Lesser General Public License version 2.1 or later (LICENSE.txt)

Source
  ${source_url}
  SHA256 ${FFMPEG_SHA256}
  Signature ${tarball}.asc by the FFmpeg release signing key ${FFMPEG_SIGNING_KEY}
  The official source is used as is: no patches, so a changes.diff would be empty.
  Copy of the source and these build files: ${release_url}

Build scripts
  https://github.com/${repo_slug}/tree/${build_commit}/dev/ffmpeg-lgpl
  build.sh, configure-options.txt, ffmpeg-source.env

Toolchain
  Build host: ${host_os}
  Compiler:   $("$cc" --version | head -n 1)
  Binutils:   $(${cross_prefix}ld --version | head -n 1)
  mingw-w64:  ${mingw_runtime}
  NASM:       $(nasm -v)
  Statically linked: the mingw-w64 runtime (mingw-w64-runtime-copyright.txt) and libgcc
  (GCC Runtime Library Exception). ffmpeg.exe uses no DLLs besides those of Windows.

Configure (run in an empty build directory next to the extracted source), then make
  ${configure_line}

To rebuild: on Ubuntu 24.04 with the packages listed at the top of build.sh,
  run dev/ffmpeg-lgpl/build.sh from a checkout of the build scripts above.
EOF

cat >"$bin_dir/README.txt" <<EOF
ffmpeg.exe - FFmpeg ${FFMPEG_VERSION} (LGPL build for PitaTrack, ${build_name})

This software uses code of FFmpeg licensed under the LGPLv2.1 and its source can be
downloaded here: ${release_url}

- ffmpeg.exe is FFmpeg (https://ffmpeg.org/) ${FFMPEG_VERSION}, built from the unmodified
  official source ${source_url}
  (SHA256 ${FFMPEG_SHA256}).
- FFmpeg is licensed under the GNU Lesser General Public License version 2.1 or later
  (LICENSE.txt, FFmpeg-LICENSE.md). This build has no GPL or nonfree parts and no
  external libraries.
- BUILD.txt lists the configure options and the toolchain.
- FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
  PitaTrack is not affiliated with the FFmpeg project.

この ffmpeg.exe は、FFmpeg ${FFMPEG_VERSION} を公式のソースから手を加えずにビルドしたものです。
FFmpeg は GNU Lesser General Public License（LGPL）version 2.1 以降のライセンスで
配布されています（LICENSE.txt）。GPL や nonfree の部品、外部のライブラリは入っていません。
ソースとビルドの指定: ${release_url}
EOF

cp "$work_dir/obj/ffmpeg.exe" "$bin_dir/"
cp "$src/COPYING.LGPLv2.1" "$bin_dir/LICENSE.txt"
cp "$src/LICENSE.md" "$bin_dir/FFmpeg-LICENSE.md"
cp "$script_dir/configure-options.txt" "$bin_dir/"
if [ -f /usr/share/doc/mingw-w64-x86-64-dev/copyright ]; then
    cp /usr/share/doc/mingw-w64-x86-64-dev/copyright "$bin_dir/mingw-w64-runtime-copyright.txt"
fi
(cd "$bin_dir" && sha256sum ffmpeg.exe >SHA256SUMS.txt)

cp "$work_dir/download/$tarball" "$work_dir/download/$tarball.asc" "$source_dir/"
cp "$bin_dir/BUILD.txt" "$script_dir/build.sh" "$script_dir/configure-options.txt" \
    "$script_dir/ffmpeg-source.env" "$script_dir/ffmpeg-devel.asc" "$source_dir/"
(cd "$source_dir" && sha256sum "$tarball" >SHA256SUMS.txt)

echo
echo "ffmpeg.exe: $(stat -c %s "$bin_dir/ffmpeg.exe") バイト、使う DLL: $(echo $imports)"
echo "出力: $bin_dir"
echo "      $source_dir"
