#!/usr/bin/env bash
#
# Mehrere RemoteApps in einer Sitzung, mit dem Prüf-Client:
#   - drei Programme, eine Verbindung: Task-Manager und Einstellungen beim Start,
#     der Editor zur Laufzeit (derselbe Weg, den eine Übergabe auf dem Mac nimmt)
#   - der Server bestätigt jeden Start einzeln
#
# Die Einstellungen brauchen den Umweg über cmd, weil SystemSettings.exe direkt gestartet
# kein Fenster öffnet (Aktivierung über die AUMID).
#
# Das Skript meldet keine Sitzung ab und wartet, wenn gerade jemand verbunden ist. Die
# Fenster, die es öffnet, schließt es am Ende wieder.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT=${OUT:-$ROOT/probe-out/multiapp-$(date +%Y%m%d-%H%M%S)}
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
	'/app:program:||taskmgr' '/app:program:||cmd,cmd:/c start ms-settings:' \
	/log-filters:com.freerdp.client.retina:INFO /probe-seconds:48 \
	/probe-script:"15000 app program:||notepad; 32000 state; 40000 close title=Editor; 41000 close title=Einstellungen; 46000 state" \
	> "$OUT/probe.log" 2>&1
flock -u 9

connects=$(grep -c 'VERBUNDEN sitzung=' "$OUT/probe.log")
check "eine Verbindung für alle Programme" $((connects == 1)) "$connects Verbindungsaufbauten"

starts=$(grep -c 'starte RemoteApp' "$OUT/probe.log")
started=$(grep -c 'gestartet' "$OUT/probe.log")
check "drei Programme gestartet" $((starts >= 3 && started >= 3)) "$starts gesendet, $started bestätigt"

# Zustand nach dem Nachstarten: alle drei Fenster da
state=$(sed -n '/32.* ZUSTAND/,/Desktop:/p' "$OUT/probe.log")
for title in Task-Manager Einstellungen Editor; do
	echo "$state" | grep -q "\"[^\"]*$title"
	check "Fenster $title" $(($? == 0)) "$(echo "$state" | grep -o "\"[^\"]*$title[^\"]*\"" | head -1)"
done

# Nach dem Schließen: nur noch, was vorher schon lief
final=$(sed -n '/46.* ZUSTAND/,/Desktop:/p' "$OUT/probe.log")
echo "$final" | grep -q -E '"(Einstellungen|Unbenannt - Editor)"'
check "eigene Fenster wieder geschlossen" $(($? != 0)) \
	"$(echo "$final" | grep -c -E '   0x' | tr -d ' ') Fenster übrig"

exit $FAILED
