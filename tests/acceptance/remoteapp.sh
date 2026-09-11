#!/usr/bin/env bash
#
# Abnahme Kriterien 4 und 5 im RemoteApp-Modus (Protokollseite) mit dem Prüf-Client:
#   Task-Manager starten, anklicken, per Titelleiste verschieben (lokales Verschieben),
#   Größe ändern, minimieren, wiederherstellen, aktivieren – der Server muss jede Aktion
#   mit einem Fensterbefehl bestätigen.
#
# Die Mac-App nutzt dieselben Kernfunktionen; dort fehlt nur die Bedienung durch einen Menschen.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT=${OUT:-$ROOT/probe-out/remoteapp-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
FAILED=0

echo "Ausgabe: $OUT"
# RemoteApp startet die Anwendung nur beim Aufbau einer Sitzung.
winsrv_free > "$OUT/frei.txt" 2>&1

"$PROBE" /v:"$WINSRV_HOST" /u:"$WINSRV_USER" /p:"$WINSRV_PASSWORD" /cert:ignore /network:lan \
	'/app:program:||taskmgr,hidef:on' /scale:180 /log-filters:com.freerdp.client.retina:INFO \
	/probe-screen:5120x2880@200 /probe-seconds:45 /probe-out:"$OUT" \
	/probe-script:"8000 state; 9000 click title=Task 300,30; 11000 drag title=Task 400,30 300,150; 15000 state; 16000 resize title=Task 2400,1600; 19000 state; 20000 minimize title=Task; 23000 state; 24000 restore title=Task; 27000 state; 28000 activate title=Task; 30000 dump ende; 31000 state; 32000 stats" \
	> "$OUT/probe.log" 2>&1 &
PROBE_PID=$!

sleep 22
winsrv_measure > "$OUT/server.txt" 2>&1
wait "$PROBE_PID"

LOG="$OUT/probe.log"

grep -q 'VERBUNDEN sitzung=5120x2880 .*remoteapp=1' "$LOG"
check "5 RemoteApp mit 5120x2880" $(( $? == 0 )) "$(grep -o -m1 'VERBUNDEN sitzung=[0-9x]*' "$LOG")"

grep -q 'Sitzung [0-9]*: 5120x2880' "$OUT/server.txt"
check "5 serverseitig 5120x2880" $(( $? == 0 )) "$(grep -m1 -E 'Sitzung [0-9]+: ' "$OUT/server.txt")"

ID=$(grep -o -m1 'FENSTER [^ ]* 0x[0-9A-F]* "Task-Manager"' "$LOG" | grep -o '0x[0-9A-F]*')
check "Fenster erscheint" $(( ${#ID} > 0 )) "Task-Manager ${ID:-?}"

FIRST=$(grep -m1 "$ID \"Task-Manager\"" "$LOG")
X0=0 Y0=0
if [[ $FIRST =~ \"Task-Manager\"\ (-?[0-9]+),(-?[0-9]+)\  ]]; then
	X0=${BASH_REMATCH[1]}
	Y0=${BASH_REMATCH[2]}
fi

grep -q "LOKAL START $ID verschieben" "$LOG" && grep -q "LOKAL ENDE $ID" "$LOG"
check "4 lokales Verschieben" $(( $? == 0 )) "Start und Ende vom Server"

grep -q "\"Task-Manager\" $((X0 + 300)),$((Y0 + 150)) " "$LOG"
check "4 verschoben" $(( $? == 0 )) "$X0,$Y0 -> $((X0 + 300)),$((Y0 + 150))"

grep -q "\"Task-Manager\" -\?[0-9]*,-\?[0-9]* 2400x1600 normal" "$LOG"
check "4 Größe geändert" $(( $? == 0 )) "2400x1600"

grep -q "\"Task-Manager\" .* minimiert" "$LOG"
check "4 minimiert" $(( $? == 0 )) ""

sed -n '/AKTION restore/,$p' "$LOG" | grep -q "\"Task-Manager\" .* normal"
check "4 wiederhergestellt" $(( $? == 0 )) ""

sed -n '/AKTION restore/,$p' "$LOG" | grep -q "ACTIVE_WND.* aktiv=$ID"
check "4 wieder vorn und aktiv" $(( $? == 0 )) "ACTIVE_WND $ID"

exit $FAILED
