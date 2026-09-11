#!/usr/bin/env bash
#
# W4: Wiederverbinden nach einer Netzunterbrechung.
#
# Der Prüf-Client verbindet sich; danach unterbricht iptables die Verbindung zum Server
# für 20 Sekunden (ausgehend mit TCP-Reset, eingehend verworfen). Ohne Neustart muss der
# Client danach wieder verbunden sein – in dieselbe Sitzung.
#
# Braucht root (iptables) auf dem Linux-Rechner.
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
echo "Netz unterbrochen: $(date +%T)"
sleep 20
unblock
echo "Netz wieder da:    $(date +%T)"

wait "$PROBE_PID"

connects=$(grep -c 'VERBUNDEN sitzung=' "$OUT/probe.log")
check "W4 Verbindung neu aufgebaut" $((connects >= 2)) "$connects Verbindungsaufbauten"

last_lines=$(tail -5 "$OUT/probe.log")
echo "$last_lines" | grep -q 'The connection was cancelled'
check "W4 bis zum Ende verbunden" $(($? == 0)) "Ende durch den Prüf-Client, nicht durch Abbruch"

exit $FAILED
