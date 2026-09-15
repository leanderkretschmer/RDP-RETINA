#!/bin/bash
#
# FreeRDP 3 und OpenSSL statisch für rdp-retina bauen.
#
# Für den Mac App Store muss die App alles mitbringen: keine Bibliotheken aus Homebrew, nichts,
# was zur Laufzeit von außerhalb des Bundles geladen wird. Dieses Skript lädt die Quellen in
# festen Versionen, prüft sie gegen SHA-256, baut OpenSSL und FreeRDP je Architektur statisch und
# fasst alles zu einer Bibliothek zusammen:
#
#   vendor/freerdp-static/include/freerdp3, include/winpr3
#   vendor/freerdp-static/lib/librr-freerdp.a     FreeRDP mit Kanälen und OpenSSL, arm64 + x86_64
#
# Xcode ruft es als ersten Build-Schritt auf („FreeRDP bauen“). Der erste Lauf braucht Internet
# und 10 bis 20 Minuten; danach vergleicht es nur einen Stempel aus Skript, Architekturen und
# Compiler. Nötig ist allein Xcode: curl, make und perl bringt macOS mit, CMake lädt das Skript.
#
# Bewusst ohne H.264 und AAC: FFmpeg dürfte nur dynamisch gelinkt in den App Store (LGPL), und
# OpenH264 aus Quellen bringt keine Patentlizenz mit. Die Grafik läuft über GFX mit ClearCodec,
# Planar und Progressive; bei 5K verwendet der Server ohnehin kein H.264.
#
# Unter Linux baut es dasselbe für die eigene Architektur – als Prüflauf ohne Mac.
#
# Umgebung (optional): RR_FREERDP_PREFIX, RR_FREERDP_WORK, RR_FREERDP_ARCHS, RR_FREERDP_JOBS
#
set -euo pipefail

# Xcode reicht Hunderte Build-Einstellungen als Umgebung weiter (ARCHS, SDKROOT, …). OpenSSL und
# CMake sollen davon nichts sehen: einmal mit sauberer Umgebung neu starten.
if [ -z "${RR_CLEAN_ENV:-}" ]; then
	clean=(RR_CLEAN_ENV=1 "HOME=$HOME" "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "TMPDIR=${TMPDIR:-/tmp}")
	for name in DEVELOPER_DIR RR_FREERDP_PREFIX RR_FREERDP_WORK RR_FREERDP_ARCHS RR_FREERDP_JOBS; do
		eval "value=\${$name:-}"
		if [ -n "$value" ]; then
			clean+=("$name=$value")
		fi
	done
	exec /usr/bin/env -i "${clean[@]}" /bin/bash "$0" "$@"
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${RR_FREERDP_PREFIX:-$ROOT/vendor/freerdp-static}
WORK=${RR_FREERDP_WORK:-$ROOT/build/freerdp-static}
LOGS=$WORK/logs
DL=$WORK/downloads
LIB=$PREFIX/lib/librr-freerdp.a
TARGET=13.0

FREERDP_VERSION=3.31.1
FREERDP_SHA256=4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991
OPENSSL_VERSION=3.5.8
OPENSSL_SHA256=a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
CMAKE_VERSION=4.4.3
CMAKE_SHA256=0c5d65251c14cc884bfa16bdbed3c263ce5bffe2e21c0d0d00962cb0610464fa

note() {
	echo "note: $*"
}

fail() {
	echo "error: $*"
	exit 1
}

fail_log() {
	echo "--- letzte Zeilen aus $2:"
	tail -n 40 "$2" || true
	fail "$1 fehlgeschlagen, vollständiges Protokoll: $2"
}

sha256() {
	if command -v shasum > /dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		sha256sum "$1" | cut -d' ' -f1
	fi
}

case "$(uname -s)" in
	Darwin)
		PLATFORM=mac
		ARCHS=${RR_FREERDP_ARCHS:-arm64 x86_64}
		JOBS=${RR_FREERDP_JOBS:-$(sysctl -n hw.ncpu)}
		SDK=$(xcrun --sdk macosx --show-sdk-path 2> /dev/null) ||
			fail "macOS-SDK nicht gefunden – Xcode installieren und einmal starten"
		export SDKROOT=$SDK
		COMPILER=$(xcrun clang --version | head -n 1)
		;;
	Linux)
		PLATFORM=linux
		ARCHS=${RR_FREERDP_ARCHS:-$(uname -m)}
		JOBS=${RR_FREERDP_JOBS:-$(nproc)}
		COMPILER=$(cc --version | head -n 1)
		;;
	*)
		fail "$(uname -s) wird nicht unterstützt"
		;;
esac

FREERDP_OPTIONS=(
	-DCMAKE_BUILD_TYPE=Release
	# Link-Time-Optimierung bände die Bibliothek an genau diese Compiler-Version
	-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
	-DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF
	# nur die Client-Bibliotheken
	-DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON -DWITH_CHANNELS=ON
	-DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF
	-DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF
	# keine Fremdbibliotheken außer OpenSSL (siehe oben)
	-DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_VIDEOTOOLBOX=OFF -DWITH_JPEG=OFF
	-DWITH_CAIRO=OFF -DWITH_OPUS=OFF -DWITH_SOXR=OFF -DWITH_FDK_AAC=OFF -DWITH_LAME=OFF
	-DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_JSON_DISABLED=ON -DWITH_URIPARSER=OFF -DWITH_AAD=OFF
	-DWITH_WEBVIEW=OFF -DWITH_SSO_MIB=OFF -DWITH_KRB5=OFF -DWITH_TIMEZONE_ICU=OFF -DWITH_CUPS=OFF
	-DWITH_FUSE=OFF
	# Geräteumleitung, die in der App Sandbox ohnehin nicht geht
	-DWITH_PCSC=OFF -DWITH_SMARTCARD_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF -DWITH_PKCS11=OFF
	-DCHANNEL_SMARTCARD=OFF -DCHANNEL_URBDRC=OFF -DCHANNEL_SERIAL=OFF -DCHANNEL_PARALLEL=OFF
	-DCHANNEL_PRINTER=OFF -DCHANNEL_RDPECAM=OFF
	# NTLM braucht MD4 und RC4 – aus FreeRDP statt aus OpenSSLs Legacy-Provider
	-DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_RC4=ON
)
if [ "$PLATFORM" = mac ]; then
	FREERDP_OPTIONS+=(-DWITH_MACAUDIO=ON)
else
	FREERDP_OPTIONS+=(-DWITH_ALSA=OFF -DWITH_PULSE=OFF -DWITH_OSS=OFF -DWITH_UNICODE_BUILTIN=ON
		-DWITH_LIBSYSTEMD=OFF)
fi

STAMP="skript $(sha256 "$0"), $ARCHS, macOS $TARGET, $COMPILER"

up_to_date() {
	[ -f "$LIB" ] && [ -f "$PREFIX/.stamp" ] && [ "$(cat "$PREFIX/.stamp")" = "$STAMP" ]
}

if up_to_date; then
	exit 0
fi

# ---- nur ein Build zur Zeit (Xcode kann denselben Schritt parallel starten) ------------------

mkdir -p "$WORK" "$LOGS" "$DL"
LOCK=$WORK/.lock
waited=0
while ! mkdir "$LOCK" 2> /dev/null; do
	holder=$(cat "$LOCK/pid" 2> /dev/null || true)
	if { [ -n "$holder" ] && ! kill -0 "$holder" 2> /dev/null; } || { [ -z "$holder" ] && [ "$waited" -ge 12 ]; }; then
		rm -rf "$LOCK"
		continue
	fi
	if [ "$waited" -eq 0 ]; then
		note "wartet auf einen anderen FreeRDP-Build"
	fi
	waited=$((waited + 1))
	sleep 5
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

if up_to_date; then
	exit 0
fi

# ---- Quellen -----------------------------------------------------------------------------------

fetch() { # adresse datei sha256
	local file=$DL/$2
	if [ -f "$file" ] && [ "$(sha256 "$file")" = "$3" ]; then
		return 0
	fi
	note "lade $2"
	rm -f "$file" "$file.part"
	curl -fL --retry 3 --connect-timeout 30 -sS -o "$file.part" "$1" || fail "Download fehlgeschlagen: $1"
	if [ "$(sha256 "$file.part")" != "$3" ]; then
		rm -f "$file.part"
		fail "Prüfsumme von $2 stimmt nicht – Download beschädigt oder verändert"
	fi
	mv "$file.part" "$file"
}

unpack() { # archiv ziel
	if [ -f "$2/.entpackt" ]; then
		return 0
	fi
	rm -rf "$2"
	mkdir -p "$2"
	tar -xzf "$1" -C "$2" --strip-components 1 || fail "$(basename "$1") ließ sich nicht entpacken"
	touch "$2/.entpackt"
}

note "baut FreeRDP $FREERDP_VERSION und OpenSSL $OPENSSL_VERSION statisch ($ARCHS) – einmalig, etwa 10 bis 20 Minuten"

fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
	"openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA256"
fetch "https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz" \
	"freerdp-$FREERDP_VERSION.tar.gz" "$FREERDP_SHA256"
FREERDP_SRC=$WORK/freerdp-$FREERDP_VERSION
unpack "$DL/freerdp-$FREERDP_VERSION.tar.gz" "$FREERDP_SRC"

if [ "$PLATFORM" = mac ]; then
	fetch "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" \
		"cmake-$CMAKE_VERSION-macos-universal.tar.gz" "$CMAKE_SHA256"
	unpack "$DL/cmake-$CMAKE_VERSION-macos-universal.tar.gz" "$WORK/cmake-$CMAKE_VERSION"
	CMAKE=$WORK/cmake-$CMAKE_VERSION/CMake.app/Contents/bin/cmake
else
	CMAKE=$(command -v cmake) || fail "cmake nicht gefunden"
fi

# ---- je Architektur ------------------------------------------------------------------------------

build_openssl() { # arch
	local arch=$1 src=$WORK/$1/openssl-src out=$WORK/$1/openssl log=$LOGS/openssl-$1.log
	local target flags=()

	case "$PLATFORM-$arch" in
		mac-arm64) target=darwin64-arm64-cc ;;
		mac-x86_64) target=darwin64-x86_64-cc ;;
		linux-x86_64) target=linux-x86_64 ;;
		linux-aarch64) target=linux-aarch64 ;;
		*) fail "keine OpenSSL-Plattform für $PLATFORM/$arch" ;;
	esac
	if [ "$PLATFORM" = mac ]; then
		flags=(--openssldir=/private/etc/ssl "-mmacosx-version-min=$TARGET")
	else
		flags=(--openssldir=/etc/ssl)
	fi

	note "OpenSSL $OPENSSL_VERSION ($arch)"
	rm -rf "$src" "$out"
	unpack "$DL/openssl-$OPENSSL_VERSION.tar.gz" "$src"
	{ cd "$src" &&
		./Configure "$target" no-shared no-module no-tests no-apps no-docs --prefix="$out" --libdir=lib \
			"${flags[@]}" &&
		make -j"$JOBS" build_libs &&
		make install_dev; } > "$log" 2>&1 || fail_log "OpenSSL ($arch)" "$log"
	cd "$ROOT"
}

build_freerdp() { # arch
	local arch=$1 build=$WORK/$1/freerdp-build out=$WORK/$1/freerdp log=$LOGS/freerdp-$1.log
	local flags=(-DCMAKE_INSTALL_PREFIX="$out" -DOPENSSL_ROOT_DIR="$WORK/$arch/openssl" -DOPENSSL_USE_STATIC_LIBS=ON)

	if [ "$PLATFORM" = mac ]; then
		# Homebrew und MacPorts ausblenden: nichts von dort darf in die Bibliothek gelangen
		flags+=(-DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET"
			-DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local"
			-DCMAKE_FIND_FRAMEWORK=LAST)
	fi

	note "FreeRDP $FREERDP_VERSION ($arch)"
	rm -rf "$build" "$out"
	{ "$CMAKE" -S "$FREERDP_SRC" -B "$build" -G "Unix Makefiles" "${flags[@]}" "${FREERDP_OPTIONS[@]}" &&
		"$CMAKE" --build "$build" --parallel "$JOBS" &&
		"$CMAKE" --install "$build"; } > "$log" 2>&1 || fail_log "FreeRDP ($arch)" "$log"
}

merge() { # arch – FreeRDP, Kanäle und OpenSSL in eine Bibliothek
	local arch=$1 out=$WORK/$1/librr-freerdp.a log=$LOGS/merge-$1.log
	local libs=() lib

	while IFS= read -r lib; do
		libs+=("$lib")
	done < <(find "$WORK/$arch/freerdp/lib" -name '*.a' | sort)
	if [ "${#libs[@]}" -eq 0 ]; then
		fail "FreeRDP ($arch) hat keine statischen Bibliotheken erzeugt"
	fi
	libs+=("$WORK/$arch/openssl/lib/libssl.a" "$WORK/$arch/openssl/lib/libcrypto.a")

	rm -f "$out"
	if [ "$PLATFORM" = mac ]; then
		xcrun libtool -static -no_warning_for_no_symbols -o "$out" "${libs[@]}" > "$log" 2>&1 ||
			fail_log "Zusammenfassen ($arch)" "$log"
	else
		{ echo "CREATE $out"
			for lib in "${libs[@]}"; do
				echo "ADDLIB $lib"
			done
			echo "SAVE"
			echo "END"; } | ar -M > "$log" 2>&1 && ranlib "$out" || fail_log "Zusammenfassen ($arch)" "$log"
	fi
	MERGED+=("$out")
}

MERGED=()
for arch in $ARCHS; do
	build_openssl "$arch"
	build_freerdp "$arch"
	merge "$arch"
done

# ---- Ergebnis ------------------------------------------------------------------------------------

NEW=$PREFIX.new
rm -rf "$NEW"
mkdir -p "$NEW/lib" "$NEW/include"
if [ "$PLATFORM" = mac ]; then
	xcrun lipo -create "${MERGED[@]}" -output "$NEW/lib/librr-freerdp.a" || fail "lipo fehlgeschlagen"
else
	cp "${MERGED[0]}" "$NEW/lib/librr-freerdp.a"
fi
first=${ARCHS%% *}
cp -R "$WORK/$first/freerdp/include/freerdp3" "$WORK/$first/freerdp/include/winpr3" "$NEW/include/"
printf '%s\n' "$STAMP" > "$NEW/.stamp"
rm -rf "$PREFIX"
mv "$NEW" "$PREFIX"

for arch in $ARCHS; do
	rm -rf "${WORK:?}/$arch"
done
note "FreeRDP bereit: $LIB ($(du -h "$LIB" | cut -f1))"
