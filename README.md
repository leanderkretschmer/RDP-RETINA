# rdp-retina

RDP-Client für macOS mit **nativer Retina-Schärfe** und **RemoteApp**, bedient
ausschließlich über die Kommandozeile. Grundlage ist FreeRDP 3.31 als Bibliothek; das
Protokoll wird nicht neu geschrieben. Anforderungen und Hintergrund:
[build-instructions.md](build-instructions.md).

| Stufe | Inhalt | Stand |
|---|---|---|
| 1 | Desktop mit Retina | fertig, am 5K-Display gemessen |
| 2 | RAIL-Grundgerüst | fertig |
| 3 | Fensterverwaltung (Fokus, Reihenfolge, Minimieren) | fertig, Protokoll gemessen |
| 4 | Verschieben/Größe, Tray, mehrere Bildschirme, VideoToolbox | fertig, siehe Abnahme |

## Bauen

Voraussetzungen: macOS 13 oder neuer, Xcode, FreeRDP 3 aus Homebrew.

```sh
brew install freerdp
```

Der erste Build-Schritt „FreeRDP prüfen“ sucht FreeRDP 3, bevor etwas kompiliert wird:

- gefunden unter `vendor/freerdp`, `/opt/homebrew` (Apple Silicon) oder `/usr/local` (Intel):
  weiter wie gewohnt
- per Homebrew installiert, aber nicht nach `include/` verlinkt (etwa nach einem Konflikt beim
  Verlinken): der Schritt hängt `$(brew --prefix freerdp)` als `vendor/freerdp` ein
- gar nicht vorhanden: Abbruch mit „FreeRDP 3 nicht gefunden … brew install freerdp“

Ältere Stände scheiterten stattdessen in jeder Datei mit `'winpr/crt.h' file not found`. Nach der
Installation in Xcode *Product → Clean Build Folder* und neu bauen. Ob die Header da sind, zeigt
`ls -d "$(brew --prefix freerdp)/include/winpr3"`.

**In Xcode:** `rdp-retina.xcodeproj` öffnen, Schema `rdp-retina`, *Run*. Beispielargumente
stehen abgeschaltet im Schema (*Product → Scheme → Edit Scheme → Arguments*); das Kennwort
fragt FreeRDP in der Xcode-Konsole ab.

**Im Terminal:**

```sh
scripts/build-macos.sh          # baut nach build/xcode
bin/rdp-retina /v:server ...    # startet die gebaute App
```

**Xcode Cloud:** `ci_scripts/ci_post_clone.sh` installiert FreeRDP per Homebrew. Für ein
Archiv muss in *Signing & Capabilities* ein Team gesetzt werden; lokal wird ad hoc
signiert („Sign to Run Locally“). Die App lädt FreeRDP zur Laufzeit aus Homebrew – sie
läuft also auf Macs, auf denen `brew install freerdp` ausgeführt wurde.

Homebrew baut FreeRDP für das installierte macOS. Der Linker meldet deshalb, die
Bibliotheken seien neuer als das Deployment-Ziel 13.0, und nennt nicht vorhandene
Suchpfade (`/opt/homebrew/lib` auf Intel, `vendor/freerdp/lib` ohne eigenen Build). Beides
ist harmlos; die gebaute App braucht dann aber das macOS, für das FreeRDP gebaut wurde.

**Hardware-Dekodierung (W1):** `scripts/build-freerdp-macos.sh` baut FreeRDP mit
VideoToolbox nach `vendor/freerdp`. Das Xcode-Projekt nimmt diesen Pfad vor Homebrew.

Das Xcode-Projekt wird aus den Quellen erzeugt. Nach dem Hinzufügen oder Entfernen von
Dateien: `python3 scripts/gen-xcodeproj.py`.

## Aufruf

Argumente wie bei `xfreerdp` (P1), vorhandene Aufrufe laufen weiter:

```sh
# voller Desktop im Vollbild, Windows rendert mit 175 %
bin/rdp-retina /v:192.168.0.0 /u:Administrator /f /scale:180 /gfx:AVC444 /network:lan

# Fenster, das die Sitzungsgröße bestimmt
bin/rdp-retina /v:192.168.0.0  /u:Administrator /dynamic-resolution /scale-desktop:200

# RemoteApp, auf Wunsch über alle Bildschirme
bin/rdp-retina /v:192.168.0.0  /u:Administrator '/app:program:||taskmgr' /multimon
```

Was der Client selbst festlegt:

| | |
|---|---|
| Sitzungsgröße | in **Pixeln** des Backing-Store: `/f` und RemoteApp = Bildschirm (5K: 5120×2880), ohne `/size` = größtes Fenster auf der nutzbaren Fläche, `/size:WxH` = wie angegeben, so groß wie der Bildschirm = Vollbild. Nie 1024×768. |
| Skalierung | ohne `/scale` der Faktor des Bildschirms (Retina: 200 %), sonst wie angegeben |
| Grafik | ohne `/gfx` wird H.264 4:4:4 angefordert |
| Tastatur | ohne `/kbd` das aktive macOS-Layout (Deutsch → 0x407) |
| RemoteApp | Arbeitsbereich ohne Menüleiste und Dock (je Bildschirm), Symbole in hoher Auflösung |
| Wiederverbinden | an, sofern nicht `/auto-reconnect` ausdrücklich angegeben ist |

Eigene Schalter (vor FreeRDP herausgefiltert):

| | |
|---|---|
| `/retina-cmd:win` | Befehlstaste links als Windows-Taste statt als Strg |
| `/retina-stats[:s]` | alle s Sekunden GFX-Codecs und gezeichnete Bilder auf stderr |
| `/retina-selftest` | prüft Geometrie und rechnet das Bild pixelgenau gegen die Quelle nach (P2) |
| `/retina-verbose` | protokolliert die RemoteApp-Fensterverwaltung |
| `/retina-noshare` | eigene Verbindung, statt Programme an eine laufende Instanz zu übergeben (verdrängt deren Sitzung) |

**Mehrere RemoteApps in einer Sitzung.** Windows gibt jedem Benutzer nur eine Sitzung
(`fSingleSessionPerUser`); eine zweite Verbindung würde die erste verdrängen. Deshalb laufen alle
Programme für denselben Server und Benutzer über eine Verbindung:

```sh
# mehrere Programme in einem Aufruf – /app: darf mehrfach stehen
bin/rdp-retina /v:192.168.0.0 /u:Administrator '/app:program:||taskmgr' '/app:program:||notepad'

# später dazu, z.B. aus einem anderen Terminal: übergibt an die laufende Instanz und endet
bin/rdp-retina /v:192.168.0.0 /u:Administrator '/app:program:||notepad'
```

Die laufende Instanz lauscht auf einem Unix-Socket in `$TMPDIR` (einer je Server, Port, Domäne
und Benutzer, nur für den eigenen Benutzer zugänglich). Die Programme startet sie nacheinander,
jeweils nach der Antwort des Servers auf das vorige; kommt keine, nach 10 Sekunden. Ein
fehlgeschlagenes Programm beendet die Verbindung nur, wenn sonst nichts läuft.

Tastatur (P7):

| Mac | Windows |
|---|---|
| Befehl links | Strg (Cmd+C/V/Z wie gewohnt) |
| Befehl rechts | Windows-Taste |
| Option links | Alt |
| Option rechts | AltGr (`@` = AltGr+Q) |
| Control | Strg |

## Aufbau

```
core/     C, portabel – FreeRDP-Anbindung, Einstellungen, RemoteApp-Zustand
mac/      Objective-C – Fenster, Metal, Eingabe, Zwischenablage, Tray
probe/    Prüf-Client ohne Fenster (Linux), spielt Benutzeraktionen durch
tests/    Abnahmeskripte gegen den Testserver
```

**Bildweg:** FreeRDP dekodiert (GDI/GFX) → der Kern meldet geänderte Rechtecke → nur diese
wandern in eine Metal-Textur → der Fragment-Shader liest mit `texture.read()` genau das
Texel unter jedem Ausgabepixel → der `CAMetalLayer` hat als Drawable exakt
Punktgröße × `backingScaleFactor`, `contentsGravity` oben links, Filter *nearest*.
Keine Stelle skaliert oder interpoliert (P2, P3).

**RemoteApp:** je entferntem Fenster ein randloses `NSWindow`. Windows zeichnet Rahmen und
Titelleiste selbst (HiDef-Flächen mit Alpha), der Mac liefert Lage, Fokus
(`ACTIVE_WND` ↔ `ClientActivate`), Reihenfolge (`ZORDER`), Minimieren und das lokale
Verschieben/Größeändern (`LocalMoveSize`).

**Koordinaten:** Der Kern rechnet im virtuellen Bildschirm von Windows (primärer Bildschirm
bei 0,0). Bei `/multimon` beginnen Desktoppuffer und Mauseingaben dagegen an der linken
oberen Ecke aller Bildschirme – gemessen, nicht angenommen: Ein Rechtsklick an einer
Pufferkoordinate öffnet dort das Kontextmenü, ein maximiertes RemoteApp-Fenster liegt bei
`-2560,0` auf dem linken Bildschirm. Der Kern verschiebt entsprechend
(`rr_desktop_origin`).

**Eigenheit beim Bauen:** WinPR und CoreFoundation definieren beide `REFIID`.
`mac/RRPrefix.h` bindet WinPR in jeder Objective-C-Datei zuerst ein und benennt den Typ
um; Carbon-Aufrufe liegen getrennt in `mac/RRInputSource.m`.

## Applets für das Dock

Ein Applet ist ein kleines App-Bundle, das genau eine RemoteApp öffnet – im Dock mit einem
Klick, im Finder mit einem Doppelklick:

```sh
bin/rdp-retina --createapp /v:192.168.0.0 /u:Administrator /p:Kennwort \
	'/app:||notepad' --appname=Editor --icon=~/Bilder/editor.png
```

Daraus entsteht `~/Applications/Editor.app`:

| | |
|---|---|
| Start | `open -n -b com.cratchmere.rdp-retina --args …` mit den gespeicherten Argumenten. Läuft schon eine Verbindung zu diesem Server und Benutzer, übernimmt sie das Programm (siehe *Mehrere RemoteApps in einer Sitzung*). |
| Kennwort | steht **nicht** im Bundle, sondern als generisches Kennwort im Anmelde-Schlüsselbund (Dienst `rdp-retina`, Konto `[domäne\]benutzer@host`). Ohne `/p:` holt rdp-retina es von dort; beim ersten Zugriff fragt macOS einmal nach der Erlaubnis. |
| Symbol | `--icon=` nimmt eine Datei oder eine `http(s)`-Adresse (PNG, JPEG, ICNS, PDF) und schreibt daraus eine `.icns` von 16 bis 1024 Pixeln samt @2x. Ohne Angabe das Symbol von rdp-retina. |
| Zertifikat | ohne eigenes `/cert:` bekommt das Applet `/cert:tofu`, weil es keine Rückfrage im Terminal stellen kann |
| Name | `--appname=`, sonst `name:` aus `/app:`, sonst das Programm (`||notepad` → „notepad“) |
| Weiteres | `--nodock` legt es nicht ins Dock, `--dest=` wählt einen anderen Ordner als `~/Applications`. Alle übrigen Argumente (`/multimon`, `/scale:180`, …) gehen unverändert ins Applet. |

`/app:` darf wie oben ohne `program:` geschrieben werden. Überschrieben werden nur eigene
Applets, andere Bundles bleiben unangetastet.

Entfernen: Symbol aus dem Dock ziehen, `~/Applications/<Name>.app` löschen und bei Bedarf
`security delete-generic-password -s rdp-retina -a '<konto>'`.

## Abnahme

Gemessen am 11.09.2026 gegen Windows Server 2025 (RTX 3080), Mac mit Studio Display 5K.

| Kriterium | Ergebnis | Beleg |
|---|---|---|
| 1 Auflösung | **erfüllt** | Mac-App im Vollbild und Prüf-Client: `lies.ps1` meldet in der Sitzung 5120×2880 |
| 2 Schärfe | **erfüllt** (technisch) | `/retina-selftest`: 2560×1440 pt × 2 = Drawable 5120×2880 px, 14 745 600 Pixel gegen die Quelle verglichen, 0 abweichend. RemoteApp-Fenster ebenso (3 840 000 Pixel, 0). Der Blick aufs Panel steht aus. |
| 3 DPI | **Faktor kommt an** | `/scale-desktop:200` → 192 DPI. `/scale:180` → 168 DPI (175 %): Windows kennt keine 180-%-Stufe und rundet. 172 DPI sind mit Windows Server 2025 nicht erreichbar. |
| 4 RemoteApp | **Protokoll erfüllt** | Prüf-Client mit `||taskmgr`: anklicken, per Titelleiste lokal verschieben, Größe ändern, minimieren, wiederherstellen, wieder aktiv – jede Aktion vom Server bestätigt. Mac-App: Fenster erscheint, Server setzt den Fokus, lokales Verschieben ausgeführt. Die Bedienung mit der Maus am Mac steht aus. |
| 5 kein 1024×768 | **erfüllt** | Desktop, Vollbild und RemoteApp: 5120×2880 |
| 6 Encoder | **nur bis 4096 px Breite** | 3840×2160 und 4096×2304: H.264-Sitzung in `nvidia-smi`, Codec AVC444v2. 5120×2880: siehe unten. |

| Wunsch | Ergebnis |
|---|---|
| W1 VideoToolbox | `build-freerdp-macos.sh` baut; die App läuft damit (3840×2160, AVC444v2, Selbsttest 1:1). Wie viel die GPU übernimmt, ist nicht gemessen. |
| W2 Zwischenablage | eingebaut (Text in beide Richtungen), nicht automatisch prüfbar |
| W3 mehrere Bildschirme | Prüf-Client mit simuliertem zweitem Bildschirm (2560×1440 links neben 5K): Sitzung 7680×2880 über beide, ein links maximiertes Fenster liegt bei -2560,0 mit 2560×1440, Klicks treffen. Mit zwei echten Bildschirmen am Mac nicht getestet. |
| W4 Wiederverbinden | `reconnect.sh`: Netz 20 s gesperrt und TCP-Verbindung abgerissen → der Client verbindet sich beim zweiten Versuch selbst neu, sobald das Netz wieder da ist, das Bild kommt wieder. Mit RemoteApp nicht getestet. |

Nachprüfen ohne Mac, mit dem Prüf-Client unter Linux:

```sh
scripts/build-linux.sh
export WINSRV_HOST=192.168.0.0 WINSRV_USER=Administrator WINSRV_PASSWORD=...
tests/acceptance/desktop.sh     # Kriterien 1, 3, 5, 6
tests/acceptance/remoteapp.sh   # Kriterien 4, 5
tests/acceptance/reconnect.sh   # W4, braucht root
```

## Erkenntnisse

### H.264 endet bei 4096 Pixeln Breite

| Sitzung | GFX-Bestätigung | Codecs | NVENC |
|---|---|---|---|
| 3840×2160 | AVC an | AVC444v2 | H.264 3840×2160 |
| 4096×2304 | AVC an | AVC444v2 | H.264 4096×2304 |
| 5120×2880 | `AVC_DISABLED` | ClearCodec, Progressive | keine |

Der Client fordert AVC444 an; bei 5K lehnt der **Server** ab – H.264 auf NVENC geht nur
bis 4096 Pixel Breite. Kriterium 6 und P2 schließen sich auf diesem Server damit aus.

Für die Schärfe ist das kein Verlust: ClearCodec und Progressive unterabtasten die
Farbe nicht, das Verschmieren aus P8 tritt bei ihnen nicht auf. Der Preis ist mehr
Bandbreite und Rechenarbeit auf dem Server statt auf der GPU. Wer H.264 will, nimmt ein
Fenster mit höchstens 4096 Pixeln Breite, z.B. `/size:3840x2160` – auch das ist 1:1,
nur eben kleiner als der Bildschirm.

### DPI-Stufen

`desktopScaleFactor` kommt unverändert an, Windows setzt aber nur seine eigenen Stufen
(100, 125, 150, 175, 200, … %). `/scale` erlaubt laut Protokoll nur 100, 140 und 180;
für eine exakte Stufe `/scale-desktop:175` oder `/scale-desktop:200` verwenden.
`sitzinfo.ps1` meldet immer 96 DPI, weil es selbst nicht DPI-aware läuft;
`tests/acceptance/lib.sh` misst mit einem Per-Monitor-V2-Prozess.

### Mehrere Programme in einer Sitzung

Gemessen mit dem Prüf-Client: Task-Manager, Einstellungen und Editor liefen in **einer**
Verbindung und damit in einer Sitzung; das dritte Programm wurde zur Laufzeit nachgestartet, also
über denselben Weg, den ein weiterer Aufruf auf dem Mac nimmt. Der Server bestätigt jeden Start
einzeln, und zwar auch den erfolgreichen – darauf wartet der Kern, bevor er das nächste schickt.

Die Einstellungen brauchen einen Umweg. `SystemSettings.exe` direkt zu starten meldet Erfolg,
öffnet aber kein Fenster, weil die App über ihre AUMID aktiviert und nicht als Programm gestartet
wird. Das funktioniert:

```sh
'/app:program:||cmd,cmd:/c start ms-settings:'
```

Das Fenster „Einstellungen“ erscheint damit maximiert mit 5120×2721 Pixeln neben den anderen
Programmen. Beim Prüf-Server sind die Aliase (`||taskmgr`, `||notepad`, `||cmd`) in der
RemoteApp-Freigabeliste eingetragen; nicht gelistete Programme sind dort ebenfalls erlaubt, dann
ist statt des Alias der vollständige Pfad anzugeben.

### Was am Mac nicht automatisch geht

Über SSH verweigert macOS Bildschirmfotos und künstliche Eingaben. Die Schärfe weist
deshalb der Selbsttest nach (dieselbe Shader-Pipeline, Ergebnis Byte für Byte gegen die
Quelle); Mausbedienung, Tastatur, Zwischenablage und Tray sind am Gerät zu prüfen.

### Grenzen

- Mehrere Bildschirme mit **unterschiedlichem** Retina-Faktor: Lagen werden mit dem
  Faktor des primären Bildschirms umgerechnet.
- Verschieben per Tastatur (Alt+Leertaste → Verschieben) wird sofort beendet.
- Tray-Symbole: Klick und Kontextmenü, keine Sprechblasen.

## Ton und Mikrofon

Ohne Angabe spielt der Ton aus der Sitzung auf dem Mac – wie bei mstsc „Auf diesem Computer
wiedergeben“. Der Kern setzt dafür `AudioPlayback`; FreeRDP lädt daraufhin `rdpsnd` als
statischen und als dynamischen Kanal, schaltet `rdpdr` dazu und nimmt auf macOS sein Backend
`mac` (AVAudioEngine). Eigene Angaben haben Vorrang:

| Angabe | Ton |
|---|---|
| keine | auf dem Mac |
| `/sound[:…]` | auf dem Mac, mit den angegebenen Optionen (z.B. `/sound:latency:200`) |
| `/audio-mode:1` | am Server |
| `/audio-mode:2` | aus |
| `/microphone` | zusätzlich das Mac-Mikrofon in die Sitzung |

Die Protokollzeile des Kerns nennt das Ergebnis, z.B. `… RemoteApp ja, Ton hier, Mikrofon aus`.
Den Kanal selbst zeigt `/log-filters:com.freerdp.channels.rdpsnd.client:DEBUG`.

**Format.** Der Client bietet jedes Serverformat an, das FreeRDPs Audiodekoder (FFmpeg) lesen
oder das Gerät direkt spielen kann. Das macOS-Backend nimmt nur PCM mit 16 Bit Stereo; alles
andere dekodiert FreeRDP vorher. Gemessen mit dem Prüf-Client gegen den Testserver, Standard
ohne `/sound`, `Alarm01.wav` per PowerShell-RemoteApp abgespielt: Windows Server 2025
verhandelt über den dynamischen Kanal (Qualitätsmodus 2) und schickt **AAC** – 241 Blöcke in
5,6 s, einer je 23 ms mit rund 290 Byte. Ohne AAC-Dekoder bietet der Client nur an, was er
abspielen kann; unkomprimiertes PCM braucht bis 1,4 Mbit/s.

**Mikrofon** (`/microphone`). FreeRDPs `audin`-Backend für macOS nimmt PCM über AudioQueue
auf. macOS fragt beim ersten Mal nach der Erlaubnis; die Begründung steht in `mac/Info.plist`.
Die Antwort kommt asynchron: Öffnet eine Windows-Anwendung das Mikrofon, bevor „Erlauben“
geklickt ist, bleibt diese eine Aufnahme stumm. Abgelehnt lässt es sich unter
*Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon* wieder freigeben. Wer die App mit
Hardened Runtime archiviert, braucht zusätzlich `com.apple.security.device.audio-input`.

**Eigener FreeRDP-Build.** `scripts/build-freerdp-macos.sh` baut das macOS-Audio
(`WITH_MACAUDIO`) und die FFmpeg-Audiodekoder (`WITH_DSP_FFMPEG`) ausdrücklich mit.

**Nicht geprüft.** Der Mac war während der Umsetzung nicht erreichbar. Offen sind dort: der Ton
hörbar am Gerät, dass Homebrews FreeRDP das Backend `mac` enthält, und das Mikrofon. Unter Linux
hat der Prüf-Client nur das Backend `fake`; das Mikrofon lässt sich dort nicht prüfen.
