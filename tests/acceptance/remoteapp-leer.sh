#!/usr/bin/env bash
#
# RemoteApp-Sitzung ohne erstes Programm (/retina-remoteapp) – so verbindet die Oberfläche:
#   - die Verbindung steht, ohne dass ein Programm startet
#   - der RemoteApp-Kanal kommt hoch, Fenster aus der Windows-Sitzung erscheinen
#   - der Server meldet zu jedem Hauptfenster eine App-ID (MS-RDPERP Get Application ID)
#   - ein Programm startet nachträglich über dieselbe Verbindung; die App-ID seines Fensters
#     endet auf notepad.exe, daran ordnet die Oberfläche Fenster ihren RemoteApps zu
#
# Meldet keine Sitzung ab und wartet, wenn gerade jemand verbunden ist. Das geöffnete
# Editor-Fenster schließt es wieder.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT=${OUT:-$ROOT/probe-out/remoteapp-leer-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
FAILED=0

# Gemeinsame Sperre: Prüf-Client, Mac-App und andere Tests nutzen denselben Server.
exec 9> /tmp/rdp-retina-server.lock
flock 9

sessions=$(printf '%s\n' 'quser 2>&1' | winsrv_ps | grep -v -E 'CLIXML|<Objs')
echo "$sessions" > "$OUT/sitzungen.txt"
if echo "$sessions" | grep -i "$WINSRV_USER" | grep -q -E 'Aktiv|Active'; then
	echo "ABBRUCH: Sitzung von $WINSRV_USER ist gerade verbunden, später erneut versuchen"
	exit 0
fi

echo "Ausgabe: $OUT"
"$PROBE" /v:"$WINSRV_HOST" /u:"$WINSRV_USER" /p:"$WINSRV_PASSWORD" /cert:ignore /network:lan \
	/retina-remoteapp /log-filters:com.freerdp.client.retina:INFO /probe-seconds:36 \
	/probe-script:"8000 state; 10000 app program:||notepad; 20000 state; 26000 close title=Editor; 32000 state" \
	> "$OUT/probe.log" 2>&1
flock -u 9

grep -q 'RemoteApp-Sitzung ohne erstes Programm' "$OUT/probe.log"
check "Sitzung ohne erstes Programm" $(($? == 0)) \
	"$(grep -c 'VERBUNDEN sitzung=' "$OUT/probe.log") Verbindungsaufbau"

grep -q 'REMOTEAPP aktiv' "$OUT/probe.log"
check "RemoteApp-Kanal steht" $(($? == 0)) ""

before=$(sed -n '/AKTION app/q;/starte RemoteApp/p' "$OUT/probe.log" | wc -l)
check "vor dem Nachstarten nichts gestartet" $((before == 0)) "$before Starts"

ids=$(grep -c 'PROGRAMM 0x' "$OUT/probe.log")
check "App-IDs gemeldet" $((ids > 0)) "$ids Fenster"

grep -q -E 'RemoteApp \|\|notepad gestartet' "$OUT/probe.log"
check "Editor nachträglich gestartet" $(($? == 0)) ""

grep -q -i -E 'PROGRAMM 0x[0-9A-F]+ id="[^"]*notepad\.exe"' "$OUT/probe.log"
check "App-ID des Editors endet auf notepad.exe" $(($? == 0)) \
	"$(grep -o -i -E 'id="[^"]*notepad\.exe"' "$OUT/probe.log" | head -1)"

final=$(sed -n '/32.* ZUSTAND/,/Desktop:/p' "$OUT/probe.log")
echo "$final" | grep -q '"Unbenannt - Editor"'
check "Editor wieder geschlossen" $(($? != 0)) ""

exit $FAILED
