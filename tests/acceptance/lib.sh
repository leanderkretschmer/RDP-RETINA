#!/usr/bin/env bash
#
# Gemeinsame Helfer für die Abnahme gegen den Testserver.
#
# Erwartet in der Umgebung: WINSRV_HOST, WINSRV_USER, WINSRV_PASSWORD
# (z.B. per ". /opt/incus/windows-server-kvm/.env"). Das Kennwort landet nie im Repo.
#
# Messungen in der Sitzung laufen über C:\Serverwerkzeuge\holinfo.ps1 und lies.ps1. Die
# starten per run-in-console.ps1 einen Prozess in der RDP-Sitzung, und das geht nur als
# SYSTEM (sonst SetTokenInformation-Fehler 1314). Deshalb eine kurzlebige geplante Aufgabe.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PROBE=${PROBE:-$ROOT/build/linux/rdp-probe}

: "${WINSRV_HOST:?WINSRV_HOST fehlt}"
: "${WINSRV_USER:?WINSRV_USER fehlt}"
: "${WINSRV_PASSWORD:?WINSRV_PASSWORD fehlt}"

# PowerShell-Skript von stdin auf dem Server ausführen
winsrv_ps() {
	local encoded
	encoded=$(iconv -f UTF-8 -t UTF-16LE | base64 -w0)
	SSHPASS="$WINSRV_PASSWORD" sshpass -e ssh -o StrictHostKeyChecking=accept-new \
		-o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR \
		"$WINSRV_USER@$WINSRV_HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $encoded" |
		tr -d '\r'
}

# Übriggebliebene Sitzungen des Testbenutzers abmelden (Konsole bleibt unberührt)
winsrv_free() {
	winsrv_ps <<'EOF'
& C:\Serverwerkzeuge\rdp-frei.ps1 | Out-Null
quser 2>$null
EOF
}

# Bildschirme, DPI und Encoder der aktiven Administrator-Sitzung
winsrv_measure() {
	winsrv_ps <<'EOF'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\Serverwerkzeuge\rdp-retina'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Remove-Item "$dir\*.txt" -ErrorAction SilentlyContinue
# sitzinfo.ps1 läuft nicht DPI-aware und sieht daher immer 96 DPI. dpi.ps1 fragt als
# Per-Monitor-V2-Prozess die tatsächliche DPI der Sitzung ab.
Set-Content -Path "$dir\dpi.ps1" -Encoding UTF8 -Value @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class RRDpi {
	[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
	[DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
	[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
	[DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
	[DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
	[DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
}
"@
[RRDpi]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
$system = [RRDpi]::GetDpiForSystem()
$monitor = [RRDpi]::MonitorFromPoint((New-Object RRDpi+POINT), 1)
$x = [uint32]0; $y = [uint32]0
[RRDpi]::GetDpiForMonitor($monitor, 0, [ref]$x, [ref]$y) | Out-Null
$w = [RRDpi]::GetSystemMetrics(0); $h = [RRDpi]::GetSystemMetrics(1)
"DPI-aware: System-DPI $system, Bildschirm-DPI $x (= $([math]::Round($x * 100 / 96)) %), Bildschirm ${w}x${h}" |
	Set-Content -Path C:\Serverwerkzeuge\rdp-retina\dpi.txt -Encoding UTF8
'@
Set-Content -Path "$dir\messen.ps1" -Encoding UTF8 -Value @'
& C:\Serverwerkzeuge\holinfo.ps1 *> C:\Serverwerkzeuge\rdp-retina\holinfo.txt
& C:\Serverwerkzeuge\lies.ps1 *> C:\Serverwerkzeuge\rdp-retina\lies.txt
$s = (quser 2>$null | Select-String 'administrator' | ForEach-Object {
	if ($_ -match '\s(\d+)\s+Aktiv') { [int]$Matches[1] } }) | Select-Object -First 1
if ($s) {
	& C:\VirtualDisplayDriver\bin\run-in-console.ps1 -Befehl 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Serverwerkzeuge\rdp-retina\dpi.ps1' `
		-TimeoutMs 20000 -Sitzung $s -Verzeichnis 'C:\Serverwerkzeuge\rdp-retina' | Out-Null
}
'@
$task = 'rdp-retina-messung'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $dir\messen.ps1"
Register-ScheduledTask -TaskName $task -Action $action -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $task
Start-Sleep -Seconds 2
for ($i = 0; $i -lt 90; $i++) {
	if ((Get-ScheduledTask -TaskName $task).State -ne 'Running') { break }
	Start-Sleep -Seconds 1
}
Unregister-ScheduledTask -TaskName $task -Confirm:$false
Write-Output '=== sitzung (holinfo)'
Get-Content "$dir\holinfo.txt" -ErrorAction SilentlyContinue
Write-Output '=== bildschirme (lies)'
Get-Content "$dir\lies.txt" -ErrorAction SilentlyContinue
Write-Output '=== dpi (DPI-aware)'
Get-Content "$dir\dpi.txt" -ErrorAction SilentlyContinue
Write-Output '=== quser'
quser 2>$null
Write-Output '=== encoder'
$enc = "$dir\enc.txt"
$p = Start-Process -FilePath 'C:\Windows\System32\nvidia-smi.exe' -ArgumentList 'encodersessions' -RedirectStandardOutput $enc -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 2500
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Get-Content $enc -ErrorAction SilentlyContinue | Select-Object -First 8
EOF
}

# Ergebniszeile
check() {
	local name=$1 ok=$2 detail=$3
	if [ "$ok" = 1 ]; then
		printf 'BESTANDEN  %-28s %s\n' "$name" "$detail"
	else
		printf 'FEHLT      %-28s %s\n' "$name" "$detail"
		FAILED=1
	fi
}
