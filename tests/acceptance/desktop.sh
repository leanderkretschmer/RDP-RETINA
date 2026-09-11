#!/usr/bin/env bash
#
# Abnahme Stufe 1 (Protokollseite) mit dem Prüf-Client:
#   1  Auflösung   – serverseitig 5120x2880
#   3  DPI         – der Skalierungsfaktor kommt als DPI in der Sitzung an
#   5  kein 1024x768
#   6  Encoder     – H.264-Sitzung auf der RTX 3080
#
# Kriterium 2 (Schärfe) prüft die Mac-App selbst: /retina-selftest.
#
# SCALE=180 (Vorgabe) nutzt /scale:180, andere Werte /scale-desktop:<n>.
# Windows kennt nur feste Stufen (100, 125, 150, 175, 200, ...) und nimmt die nächste:
# /scale:180 ergibt 175 % = 168 DPI, /scale-desktop:200 ergibt 192 DPI.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT=${OUT:-$ROOT/probe-out/desktop-$(date +%Y%m%d-%H%M%S)}
SCALE=${SCALE:-180}
mkdir -p "$OUT"
FAILED=0

case "$SCALE" in
	100 | 140 | 180) SCALE_ARG="/scale:$SCALE" ;;
	*) SCALE_ARG="/scale-desktop:$SCALE" ;;
esac

echo "Ausgabe: $OUT"
winsrv_free > "$OUT/frei.txt" 2>&1

"$PROBE" /v:"$WINSRV_HOST" /u:"$WINSRV_USER" /p:"$WINSRV_PASSWORD" /cert:ignore /network:lan \
	/f "$SCALE_ARG" /log-filters:com.freerdp.client.retina:INFO \
	/probe-screen:5120x2880@200 /probe-seconds:75 /probe-out:"$OUT" \
	/probe-script:"12000 dump desktop; 70000 state; 72000 stats" > "$OUT/probe.log" 2>&1 &
PROBE_PID=$!

# Windows braucht nach der Anmeldung einige Sekunden, bis der Desktop steht.
sleep 25
winsrv_measure > "$OUT/server.txt" 2>&1
wait "$PROBE_PID"

nearest=100
for step in 100 125 150 175 200 225 250 300 350 400 450 500; do
	if [ $(((SCALE - step) * (SCALE - step))) -lt $(((SCALE - nearest) * (SCALE - nearest))) ]; then
		nearest=$step
	fi
done
expected_dpi=$((96 * nearest / 100))

grep -q 'VERBUNDEN sitzung=5120x2880' "$OUT/probe.log"
check "Client fordert 5120x2880 an" $(($? == 0)) "$(grep -o 'VERBUNDEN sitzung=[0-9x]*' "$OUT/probe.log" | head -1)"

grep -q "desktopScale=$SCALE " "$OUT/probe.log"
check "P4 desktopScaleFactor gesendet" $(($? == 0)) "$(grep -o 'desktopScale=[0-9]*' "$OUT/probe.log" | head -1)"

grep -q 'Sitzung [0-9]*: 5120x2880' "$OUT/server.txt"
check "1 Auflösung serverseitig" $(($? == 0)) "$(grep -m1 -E 'Sitzung [0-9]+: ' "$OUT/server.txt")"

measured_dpi=$(grep -o -m1 'Bildschirm-DPI [0-9]*' "$OUT/server.txt" | grep -o '[0-9]*$')
check "3 DPI ($SCALE % -> Stufe $nearest % = $expected_dpi)" $((${measured_dpi:-0} == expected_dpi)) \
	"$(grep -m1 'DPI-aware:' "$OUT/server.txt")"

! grep -q -E '1024x768' "$OUT/probe.log" "$OUT/server.txt"
check "5 kein 1024x768" $(($? == 0)) ""

grep -q -E 'H\.264 +5120 +2880' "$OUT/server.txt"
check "6 H.264-Encoder aktiv" $(($? == 0)) "$(grep -m1 -E 'H\.264' "$OUT/server.txt" || echo 'keine H.264-Sitzung (NVENC: H.264 nur bis 4096 px Breite)')"

grep -q -E 'Codec AVC444' "$OUT/probe.log"
check "P8 AVC444 empfangen" $(($? == 0)) "$(grep -E 'Codec ' "$OUT/probe.log" | tail -4 | tr -s ' ' | tr '\n' ';')"

exit $FAILED
