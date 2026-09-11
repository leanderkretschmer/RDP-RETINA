#!/usr/bin/env bash
#
# Baut den Prüf-Client für Linux. FreeRDP 3.31.1 wird bei Bedarf aus den Quellen nach
# .deps/linux gebaut (ohne Oberfläche, mit ffmpeg für H.264).
#
# Benötigte Pakete (Debian 13):
#   cmake ninja-build clang pkg-config libssl-dev zlib1g-dev libcjson-dev libavcodec-dev
#   libavutil-dev libswscale-dev libswresample-dev libicu-dev liburiparser-dev libpng-dev
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${FREERDP_VERSION:-3.31.1}
SRC="$ROOT/.deps/src/FreeRDP"
DEPS_BUILD="$ROOT/.deps/build/freerdp-linux"
PREFIX="$ROOT/.deps/linux"

if [ ! -f "$PREFIX/lib/pkgconfig/freerdp-client3.pc" ]; then
	[ -d "$SRC" ] || git clone --depth 1 --branch "$VERSION" https://github.com/FreeRDP/FreeRDP.git "$SRC"
	cmake -S "$SRC" -B "$DEPS_BUILD" -G Ninja \
		-DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX="$PREFIX" \
		-DBUILD_SHARED_LIBS=ON -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF \
		-DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_SDL=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF \
		-DWITH_CHANNELS=ON -DWITH_CLIENT_CHANNELS=ON \
		-DWITH_FFMPEG=ON -DWITH_VIDEO_FFMPEG=ON -DWITH_SWSCALE=ON -DWITH_DSP_FFMPEG=OFF -DWITH_OPENH264=OFF \
		-DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_FUSE=OFF -DWITH_PCSC=OFF \
		-DWITH_KRB5=OFF -DWITH_PKCS11=OFF -DWITH_AAD=OFF -DWITH_WEBVIEW=OFF -DWITH_MANPAGES=OFF \
		-DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF -DWITH_CCACHE=OFF \
		-DCHANNEL_URBDRC=OFF -DWITH_JPEG=OFF -DWITH_SMARTCARD_EMULATE=OFF
	ninja -C "$DEPS_BUILD" install
fi

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
cmake -S "$ROOT" -B "$ROOT/build/linux" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
ninja -C "$ROOT/build/linux"
echo "fertig: $ROOT/build/linux/rdp-probe"
