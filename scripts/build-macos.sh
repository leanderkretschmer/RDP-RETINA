#!/usr/bin/env bash
#
# Baut rdp-retina.app ohne Xcode-Oberfläche.
#
# Voraussetzung ist nur Xcode. Der erste Build baut FreeRDP und OpenSSL statisch mit
# (scripts/build-freerdp-static.sh, einmalig 10 bis 20 Minuten).
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-Release}

xcodebuild -project "$ROOT/rdp-retina.xcodeproj" -scheme rdp-retina -configuration "$CONFIG" \
	-derivedDataPath "$ROOT/build/xcode" build

APP="$ROOT/build/xcode/Build/Products/$CONFIG/rdp-retina.app"
echo
echo "fertig: $APP"
echo "Aufruf: $ROOT/bin/rdp-retina /v:<server> /u:<benutzer> ..."
