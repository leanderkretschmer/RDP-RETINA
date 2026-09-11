#!/usr/bin/env bash
#
# W1: FreeRDP 3 mit VideoToolbox-Dekodierung für H.264 bauen.
#
# Homebrews freerdp dekodiert H.264 in Software (ffmpeg). Dieses Skript baut dieselbe
# Version mit -DWITH_VIDEOTOOLBOX=ON nach vendor/freerdp; das Xcode-Projekt bevorzugt
# diesen Pfad automatisch vor Homebrew.
#
# Voraussetzungen (Homebrew): cmake pkgconf ffmpeg openssl@3 jansson jpeg-turbo
#   brew install cmake pkgconf ffmpeg openssl@3 jansson jpeg-turbo
#
# Hinweis: Der Server nutzt H.264 nur bis 4096 Pixel Breite (NVENC-Grenze). Bei einer
# 5120x2880-Sitzung kommt ClearCodec/Progressive, VideoToolbox bringt dort nichts.
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${FREERDP_VERSION:-3.31.1}
WORK=${WORK:-$ROOT/build/freerdp-src}
PREFIX=${PREFIX:-$ROOT/vendor/freerdp}
BREW=$(brew --prefix)

[ -d "$WORK" ] || git clone --depth 1 --branch "$VERSION" https://github.com/FreeRDP/FreeRDP.git "$WORK"

export PKG_CONFIG_PATH="$BREW/opt/openssl@3/lib/pkgconfig:$BREW/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

cmake -S "$WORK" -B "$WORK/build" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
	-DCMAKE_PREFIX_PATH="$BREW;$BREW/opt/openssl@3" \
	-DBUILD_SHARED_LIBS=ON \
	-DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON \
	-DWITH_CLIENT_SDL=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_CLIENT_MAC=OFF \
	-DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF \
	-DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_SWSCALE=ON -DWITH_VIDEOTOOLBOX=ON \
	-DWITH_OPENH264=OFF -DWITH_JPEG=ON -DWITH_MANPAGES=OFF -DWITH_WEBVIEW=OFF \
	-DWITH_CUPS=OFF -DWITH_FUSE=OFF -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_KRB5=OFF \
	-DWITH_AAD=OFF -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF -DCHANNEL_URBDRC=OFF

cmake --build "$WORK/build" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$WORK/build"

echo
echo "fertig: $PREFIX"
echo "Xcode-Projekt neu bauen; es findet vendor/freerdp vor Homebrew."
