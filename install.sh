#!/bin/bash
# Build and install Parsec for ARM64 Linux: the official x86-64 client run by Box64,
# decoding H.264 with a native ARM64 FFmpeg. Nothing outside PREFIX changes unless
# --mouse-bridge is given.
set -euo pipefail

BOX64_COMMIT=db0873caec7570c5de0c4b07e542ecaa7e74739e
FFMPEG_VERSION=4.4.8
FFMPEG_SHA256=c73848c4ae283d9eaee7be3b276affbc3543380483555500d0dd2c9b7e1c39c3
PARSEC_DEB=https://builds.parsec.app/package/parsec-linux.deb
# x86-64 libraries Parsec loads that Box64 does not wrap natively: package, URL, SHA256.
UBUNTU_DEBS=(
  "libpng16-16 https://archive.ubuntu.com/ubuntu/pool/main/libp/libpng1.6/libpng16-16_1.6.37-3ubuntu0.7_amd64.deb f0e18c46205e6b1bf9eb20ed97037c128f03cf27c1ff818f442a9cc173f8a002"
  "libjpeg-turbo8 https://archive.ubuntu.com/ubuntu/pool/main/libj/libjpeg-turbo/libjpeg-turbo8_2.1.2-0ubuntu1_amd64.deb bb9538fa94f06bf6b7907105439f0a0a30e3ec27030832820a6c2cc2dc6578a8"
)

repo=$(cd "$(dirname "$0")" && pwd)
prefix=${PREFIX:-$HOME/.local}
runtime=$prefix/opt/parsec-native
mouse_bridge=0

usage() {
  cat <<EOF
Usage: ./install.sh [--mouse-bridge]

Installs into PREFIX (default ~/.local):
  bin/parsec-native              launcher, also the parsec:// link handler
  opt/parsec-native/             Box64, FFmpeg, Parsec and the libraries it needs
  share/applications/parsec-native.desktop

--mouse-bridge  Also install parsec-mouse-bridge, for VMs whose only pointer is an
                absolute tablet (such as Try Omarchy). Uses sudo for a udev rule.

Environment: PREFIX, BOX64_TARGET (Box64 CMake target; default M1 on Apple CPUs,
otherwise ARM64).
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }
step() { echo "==> $*"; }
# Run a build command with its output in build.log, shown only if it fails.
quiet() {
  "$@" >>"$work/build.log" 2>&1 || { tail -n 40 "$work/build.log" >&2; die "failed: $*"; }
}

for argument in "$@"; do
  case $argument in
    --mouse-bridge) mouse_bridge=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ $(uname -m) == aarch64 ]] || die "this is for aarch64 Linux, not $(uname -m)"
for tool in bsdtar cmake curl gcc git make python sha256sum; do
  command -v "$tool" >/dev/null || die "missing $tool"
done
if ((mouse_bridge)); then
  python -c 'import evdev' 2>/dev/null || die "the mouse bridge needs python-evdev (pacman -S python-evdev)"
fi
if [[ -z ${BOX64_TARGET:-} ]]; then
  if grep -q '^CPU implementer[[:space:]]*: 0x61' /proc/cpuinfo; then BOX64_TARGET=M1; else BOX64_TARGET=ARM64; fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/runtime
mkdir -p "$stage"/{bin,lib/arm64,lib/x86_64,licenses/ubuntu,patches,skel}
jobs=$(nproc)

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
verify() { echo "$2  $1" | sha256sum --check --quiet - || die "$1 does not match its pinned SHA256"; }
# Extract a .deb's data archive into a directory.
unpack_deb() {
  mkdir -p "$2" "$1.d"
  bsdtar -xf "$1" -C "$1.d"
  bsdtar -xf "$1.d"/data.tar.* -C "$2"
}

step "Downloading Parsec"
fetch "$PARSEC_DEB" "$work/parsec.deb"
unpack_deb "$work/parsec.deb" "$work/parsec"
install -m755 "$work/parsec/usr/bin/parsecd" "$stage/bin/parsecd"
cp "$work/parsec/usr/share/parsec/skel/"* "$stage/skel/"
parsec_version=$(bsdtar -xOf "$work/parsec.deb.d"/control.tar.* ./control | sed -n 's/^Version: //p')

step "Building Box64 $BOX64_COMMIT for $BOX64_TARGET"
git init --quiet "$work/box64"
git -C "$work/box64" fetch --quiet --depth 1 https://github.com/ptitSeb/box64.git "$BOX64_COMMIT"
git -C "$work/box64" checkout --quiet FETCH_HEAD
git -C "$work/box64" apply "$repo/patches/box64-ffmpeg-hw-config.patch"
quiet cmake -S "$work/box64" -B "$work/box64/build" -Wno-dev \
  "-D$BOX64_TARGET=ON" -DBOX32=OFF -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo
quiet cmake --build "$work/box64/build" -j "$jobs"
install -s -m755 "$work/box64/build/box64" "$stage/bin/box64"
cp "$work/box64/LICENSE" "$stage/licenses/box64-MIT.txt"
cp "$repo/patches/"*.patch "$stage/patches/"

step "Building FFmpeg $FFMPEG_VERSION (H.264 decoder only)"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$work/ffmpeg.tar.xz"
verify "$work/ffmpeg.tar.xz" "$FFMPEG_SHA256"
tar -xf "$work/ffmpeg.tar.xz" -C "$work"
# libavformat stays enabled because Box64's libavcodec58 wrapper requires it.
(
  cd "$work/ffmpeg-$FFMPEG_VERSION"
  quiet ./configure --prefix="$work/ffmpeg-install" \
    --disable-autodetect --disable-everything --disable-programs --disable-doc \
    --disable-debug --disable-static --enable-shared --disable-network \
    --disable-avdevice --disable-avfilter --disable-postproc --disable-swresample \
    --disable-swscale --enable-decoder=h264 --enable-parser=h264 --enable-pic \
    --extra-cflags=-std=gnu11
  quiet make -j "$jobs"
  quiet make install
)
cp -P "$work/ffmpeg-install/lib/"lib{avcodec,avformat,avutil}.so* "$stage/lib/arm64/"
cp "$work/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$stage/licenses/ffmpeg-LGPL-2.1.txt"

step "Downloading x86-64 libpng and libjpeg from Ubuntu"
for entry in "${UBUNTU_DEBS[@]}"; do
  read -r package url sha256 <<<"$entry"
  fetch "$url" "$work/$package.deb"
  verify "$work/$package.deb" "$sha256"
  unpack_deb "$work/$package.deb" "$work/$package"
  cp -P "$work/$package/usr/lib/x86_64-linux-gnu/"lib*.so.* "$stage/lib/x86_64/"
  cp -r "$work/$package/usr/share/doc/$package" "$stage/licenses/ubuntu/"
done

cat >"$stage/BUILD-INFO.txt" <<EOF
Built $(date -I) by install.sh from $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo "an unversioned checkout").
Parsec $parsec_version from $PARSEC_DEB
  The launcher updates the client library from Parsec's release channel before each start.
Box64 $BOX64_COMMIT, -D$BOX64_TARGET=ON -DBOX32=OFF -DARM_DYNAREC=ON, patched with
  patches/box64-ffmpeg-hw-config.patch
FFmpeg $FFMPEG_VERSION, native ARM64, H.264 software decoding only
$(for entry in "${UBUNTU_DEBS[@]}"; do read -r package url _ <<<"$entry"; echo "$package (x86-64, emulated): $url"; done)
EOF

step "Installing into $prefix"
mkdir -p "$prefix/opt"
rm -rf "$runtime.previous"
[[ -e $runtime ]] && mv "$runtime" "$runtime.previous"
mv "$stage" "$runtime"
rm -rf "$runtime.previous"
install -Dm755 "$repo/bin/parsec-native" "$prefix/bin/parsec-native"
install -Dm644 "$work/parsec/usr/share/icons/hicolor/256x256/apps/parsecd.png" \
  "$prefix/share/icons/hicolor/256x256/apps/parsec.png"
applications=$prefix/share/applications
mkdir -p "$applications"
cat >"$applications/parsec-native.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Parsec
Comment=Connect to computers with Parsec
Exec=$prefix/bin/parsec-native %u
TryExec=$prefix/bin/parsec-native
Icon=parsec
Terminal=false
Categories=Network;RemoteAccess;
MimeType=x-scheme-handler/parsec;
StartupNotify=true
StartupWMClass=parsecd
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$applications" || true
command -v xdg-mime >/dev/null && xdg-mime default parsec-native.desktop x-scheme-handler/parsec || true

if ((mouse_bridge)); then
  step "Installing the mouse bridge (sudo)"
  sudo install -Dm644 "$repo/system/70-parsec-mouse-bridge.rules" /etc/udev/rules.d/70-parsec-mouse-bridge.rules
  sudo install -Dm644 "$repo/system/parsec-mouse-bridge.conf" /etc/modules-load.d/parsec-mouse-bridge.conf
  sudo modprobe uinput
  sudo udevadm control --reload
  sudo udevadm trigger --subsystem-match=input --subsystem-match=misc
  install -Dm755 "$repo/bin/parsec-mouse-bridge" "$prefix/bin/parsec-mouse-bridge"
  if ! grep -qs parsec-bridge-mouse "$HOME/.config/hypr/"*.lua "$HOME/.config/hypr/"*.conf; then
    echo "Turn off acceleration for the bridge's mouse in your Hyprland config (see README.md)."
  fi
fi

step "Done. Start Parsec from the app launcher or with $prefix/bin/parsec-native"
