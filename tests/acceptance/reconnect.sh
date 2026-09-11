#!/usr/bin/env bash
#
# W4: Wiederverbinden nach einer Netzunterbrechung.
#
# Der Prüf-Client verbindet sich; danach sperrt iptables den Weg zum Server für 20 Sekunden
# und ss -K reißt die bestehende TCP-Verbindung ab (eine bloße Sperre übersteht TCP, die
# Pakete werden nur wiederholt). Ohne Neustart muss der Client danach wieder verbunden sein.
#
# Braucht root (iptables, ss) auf dem Linux-Rechner.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OUT=${OUT:-$ROOT/probe-out/reconnect-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
FAILED=0

block() {
	iptables -I OUTPUT -d "$WINSRV_HOST" -p tcp --dport 3389 -j REJECT --reject-with tcp-reset
	iptables -I INPUT -s "$WINSRV_HOST" -p tcp --sport 3389 -j DROP
}

unblock() {
	iptables -D OUTPUT -d "$WINSRV_HOST" -p tcp --dport 3389 -j REJECT --reject-with tcp-reset 2>/dev/null
	iptables -D INPUT -s "$WINSRV_HOST" -p tcp --sport 3389 -j DROP 2>/dev/null
}
trap unblock EXIT

echo "Ausgabe: $OUT"
winsrv_free > "$OUT/frei.txt" 2>&1

# Mausbewegungen, damit der Client während der Unterbrechung sendet und den Abbruch bemerkt
"$PROBE" /v:"$WINSRV_HOST" /u:"$WINSRV_USER" /p:"$WINSRV_PASSWORD" /cert:ignore /network:lan \
	/f /scale:180 /log-filters:com.freerdp.client.retina:INFO /probe-seconds:90 \
	/probe-script:"20000 klick 400,400; 25000 klick 420,420; 30000 klick 440,440; 35000 klick 460,460; 45000 klick 480,480; 60000 klick 500,500; 80000 state" \
	> "$OUT/probe.log" 2>&1 &
PROBE_PID=$!

sleep 18
block
ss -K dst "$WINSRV_HOST" dport = :3389 > /dev/null 2>&1
echo "Netz unterbrochen: $(date +%T), offene Verbindungen danach: $(ss -tn dst "$WINSRV_HOST" dport = :3389 | tail -n +2 | wc -l)"
sleep 20
unblock
echo "Netz wieder da:    $(date +%T)"

wait "$PROBE_PID"

attempts=$(grep -c 'Attempting reconnect' "$OUT/probe.log")
reconnects=$(grep -c 'Verbindung wiederhergestellt' "$OUT/probe.log")
check "W4 Verbindung neu aufgebaut" $((reconnects >= 1)) "$attempts Versuche, $reconnects erfolgreich"

# Bildaktualisierungen vor und nach dem Wiederverbinden
before=$(sed -n '/Verbindung wiederhergestellt/q;s/.*LAUF [0-9]*s, \([0-9]*\) Bild.*/\1/p' "$OUT/probe.log" | tail -1)
after=$(grep -o 'LAUF [0-9]*s, [0-9]*' "$OUT/probe.log" | tail -1 | grep -o '[0-9]*$')
check "W4 Bild kommt wieder" $((reconnects >= 1 && ${after:-0} > ${before:-0})) \
	"Bildaktualisierungen ${before:-?} -> ${after:-?}"

last_lines=$(tail -5 "$OUT/probe.log")
echo "$last_lines" | grep -q 'The connection was cancelled'
check "W4 bis zum Ende verbunden" $(($? == 0)) "Ende durch den Prüf-Client, nicht durch Abbruch"

exit $FAILED
