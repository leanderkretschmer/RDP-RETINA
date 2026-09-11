#!/usr/bin/env bash
#
# Abnahme Stufe 1 (Protokollseite) mit dem Prüf-Client:
#   1  Auflösung   – serverseitig 5120x2880
#   3  DPI         – /scale:180 ergibt 172 DPI
#   5  kein 1024x768
#   6  Encoder     – H.264-Sitzung auf der RTX 3080
#
# Kriterium 2 (Schärfe) lässt sich nur am Mac beurteilen.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT=${OUT:-$ROOT/probe-out/desktop-$(date +%Y%m%d-%H%M%S)}
SCALE=${SCALE:-180}
mkdir -p "$OUT"
FAILED=0

echo "Ausgabe: $OUT"
winsrv_free > "$OUT/frei.txt" 2>&1

"$PROBE" /v:"$WINSRV_HOST" /u:"$WINSRV_USER" /p:"$WINSRV_PASSWORD" /cert:ignore /network:lan \
	/f /scale:"$SCALE" /log-filters:com.freerdp.client.retina:INFO \
	/probe-screen:5120x2880@200 /probe-seconds:75 /probe-out:"$OUT" \
	/probe-script:"12000 dump desktop; 70000 state; 72000 stats" > "$OUT/probe.log" 2>&1 &
PROBE_PID=$!

# Windows braucht nach der Anmeldung einige Sekunden, bis der Desktop steht.
sleep 25
winsrv_measure > "$OUT/server.txt" 2>&1
wait "$PROBE_PID"

expected_dpi=$(( 96 * SCALE / 100 ))

grep -q 'VERBUNDEN sitzung=5120x2880' "$OUT/probe.log"
check "Client fordert 5120x2880 an" $(( $? == 0 )) "$(grep -o 'VERBUNDEN sitzung=[0-9x]*' "$OUT/probe.log" | head -1)"

grep -q 'Sitzung [0-9]*: 5120x2880' "$OUT/server.txt"
check "1 Auflösung serverseitig" $(( $? == 0 )) "$(grep -m1 -E 'Sitzung [0-9]+: ' "$OUT/server.txt")"

grep -q "effektive DPI *$expected_dpi" "$OUT/server.txt"
check "3 DPI ($SCALE %)" $(( $? == 0 )) "$(grep -m1 'effektive DPI' "$OUT/server.txt")"

! grep -q -E '1024x768' "$OUT/probe.log" "$OUT/server.txt"
check "5 kein 1024x768" $(( $? == 0 )) ""

grep -q -E 'H\.264 +5120 +2880' "$OUT/server.txt"
check "6 H.264-Encoder aktiv" $(( $? == 0 )) "$(grep -m1 -E 'H\.264' "$OUT/server.txt")"

grep -q -E 'Codec AVC444' "$OUT/probe.log"
check "P8 AVC444 empfangen" $(( $? == 0 )) "$(grep -E 'Codec ' "$OUT/probe.log" | tr -s ' ' | tr '\n' ';')"

exit $FAILED
