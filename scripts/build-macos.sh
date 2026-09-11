#!/usr/bin/env bash
#
# Baut rdp-retina.app ohne Xcode-Oberfläche.
#
# Voraussetzungen: Xcode (oder die Command Line Tools mit xcodebuild) und FreeRDP 3:
#   brew install freerdp
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
