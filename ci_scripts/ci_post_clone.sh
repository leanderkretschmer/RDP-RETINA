#!/bin/sh
#
# Xcode Cloud führt dieses Skript nach dem Klonen aus. Es baut FreeRDP und OpenSSL statisch vorab;
# dasselbe erledigt sonst der erste Build-Schritt, hier bleibt das Build-Protokoll übersichtlicher.
#
set -eu

"$(dirname "$0")/../scripts/build-freerdp-static.sh"
