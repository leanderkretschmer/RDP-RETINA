# rdp-retina — Anforderungen

Ein RDP-Client für macOS, der zwei Dinge kann, die kein vorhandener Client gleichzeitig
beherrscht: **native Retina-Schärfe** und **RemoteApp**. Bedient wird er ausschließlich
über die Kommandozeile.

Grundlage ist **FreeRDP 3** als Bibliothek. Das Protokoll wird nicht neu geschrieben.

---

## 1. Warum das Ding gebaut wird

Auf einem Mac mit 5K-Bildschirm ist jeder getestete Client entweder unscharf oder kann
kein RemoteApp. Gemessen am 11.09.2026 gegen einen Windows Server 2025:

| Client | Retina | RemoteApp |
|---|---|---|
| Thincast (FreeRDP-basiert, kommerziell) | **nein** — meldet 2560×1440 auf einem 5120×2880-Panel | ja |
| `sdl-freerdp` | Fenster ist pixeldichte-bewusst, Monitorerkennung nicht | **nein** — kein RAIL-Code vorhanden |
| `xfreerdp` (X11 über XQuartz) | nein | halb — stürzt mit `BadAtom`/`BadMatch` ab |
| Microsoft Windows App | ja | ja — aber keine Kommandozeile |

### Die Ursache der Unschärfe

macOS meldet Anwendungen die **Punkt**-Auflösung, nicht die Pixel-Auflösung. Ein
5K-Panel (5120×2880 Pixel) erscheint als 2560×1440 Punkte; ein Punkt sind 2×2 Pixel.

Ein Client, der einfach fragt „wie groß ist der Bildschirm", bekommt 2560×1440, fordert
das beim Server an, und macOS malt jedes empfangene Pixel als 2×2-Block. Vierfach
vergrößert, ohne zusätzliche Information — das ist die Unschärfe.

**Der Server ist unschuldig.** Nachgemessen: eine Sitzung mit 3840×2160 und eine mit
5120×2880 kamen jeweils exakt so zustande. Es gibt keine serverseitige Begrenzung
(`MaxXResolution`/`MaxYResolution` sind nicht gesetzt).

### Zwei gemessene Eigenheiten, die den Entwurf bestimmen

**Clients deckeln `/size` auf ihre eigene Anzeigefläche.** Test mit einer 1920×1080
großen X-Fläche: angefordert wurden 5120×2880, 4096×2160 und 3840×2160 — herausgekommen
ist jedes Mal 1920×1080. Der Server sieht die große Zahl nie. Wer Retina will, muss
die **Pixel**-Größe des Backing-Store anfordern, nicht die Punkt-Größe.

**Im RemoteApp-Modus gibt es kein Desktopfenster.** Damit hat `/dynamic-resolution`
nichts, dessen Größe es melden könnte, und die Sitzung fällt auf den Vorgabewert
**1024×768** zurück. Die Desktopgröße muss dort ausdrücklich gesetzt werden.

---

## 2. Was FreeRDP mitbringt

Nicht selbst schreiben:

- das gesamte RDP-Protokoll, TLS, NLA/CredSSP
- Codecs samt H.264-Dekodierung (AVC420 und AVC444)
- Kanalverwaltung, Zwischenablage, Audio, Geräteumleitung
- **die Auswertung der Kommandozeile**: `freerdp_client_settings_parse_command_line()`
- **die RAIL-Protokollschicht**: `channels/rail/` — die Fensterbefehle kommen ausgepackt an

Vorlagen im selben Quellbaum (Stand 3.31.1):

| Pfad | Inhalt | brauchbar für |
|---|---|---|
| `client/Mac/` | nativer Cocoa-Client, `MRDPView.m` (41 KB), `Keyboard.m`, `Clipboard.m` | Zeichnen, Eingabe, Zwischenablage — **kein RAIL** |
| `client/X11/xf_rail.c` | 44 KB RAIL-Logik | Referenz für die Fensterbefehle |
| `client/SDL/SDL3/sdl_window.cpp` | `SDL_WINDOW_HIGH_PIXEL_DENSITY`, `SDL_GetWindowSizeInPixels` | wie man es richtig macht |
| `client/SDL/SDL3/sdl_monitor.cpp` | nur `SDL_GetDisplayBounds` | wie man es falsch macht |

`client/X11/xf_rail.c` ist ausdrücklich **keine** Vorlage zum Abschreiben: dort stehen
noch immer

```
xf_rail_monitored_desktop: TODO: implement WINDOW_ORDER_FIELD_DESKTOP_ACTIVE_WND
xf_rail_monitored_desktop: TODO: implement WINDOW_ORDER_FIELD_DESKTOP_ZORDER
xf_rail_server_system_param: TODO: implement
xf_rail_notify_icon_common: TODO: implement
```

Das sind genau die Teile, die ein Fenster fokussierbar und beweglich machen. Wer sie
überspringt, bekommt dasselbe Ergebnis: ein Fenster erscheint, lässt sich aber weder
anklicken noch verschieben.

---

## 3. Anforderungen

### Pflicht

**P1 — Bedienung nur über die Kommandozeile.** Kein Einstellungsfenster, keine
Verbindungsverwaltung, keine Lesezeichen. Aufruf wie `xfreerdp`. Argumente sollen mit
FreeRDPs Auswertung kompatibel sein, damit vorhandene Aufrufe weiterlaufen.

**P2 — Echtes Retina.** Der Client fordert die **Pixel**-Größe seines Backing-Store an,
nicht die Punkt-Größe. Auf einem 5K-Panel muss serverseitig eine Sitzung mit
5120×2880 ankommen. Ein empfangenes Pixel wird auf genau ein physisches Pixel gezeichnet
— keine Skalierung, keine Interpolation, an keiner Stelle.

**P3 — Kein Nachskalieren.** Passt die Sitzung nicht zum Fenster, wird die Sitzung
angepasst (Größenmeldung an den Server), nicht das Bild umgerechnet. Jede Umrechnung
zerstört Textkanten.

**P4 — DPI-Faktor durchreichen.** `/scale:100|140|180` muss als `desktopScaleFactor`
beim Server ankommen, damit Windows die Oberfläche größer *rendert*, statt dass der
Client sie vergrößert. Das ist der Unterschied zwischen scharf und matschig.

**P5 — RemoteApp.** Je entferntem Fenster ein natives `NSWindow`. Zu beherrschen:

- Erzeugen, Aktualisieren, Löschen von Fenstern
- Position und Größe
- **Fokus (`ACTIVE_WND`)** und **Fensterreihenfolge (`ZORDER`)** — nicht optional
- Minimieren, Maximieren, Wiederherstellen
- Fensterbild und -titel
- das Ziehen-und-Größe-Ändern-Protokoll (`localMoveSize`)
- Eingabe an das jeweils richtige Fenster

**P6 — Desktopgröße im RemoteApp-Modus ausdrücklich setzen.** Sonst 1024×768. Siehe
oben.

**P7 — Eingabe.** Tastatur mit deutschem Layout, Maus samt Rad, Modifikatoren. Die
macOS-Sondertasten (Cmd, Option) müssen sinnvoll abgebildet werden.

**P8 — H.264 4:4:4.** `/gfx:AVC444` muss angefordert werden. Ohne 4:4:4 verschmiert
farbiges Subpixel-Antialiasing von Text — das ist eine zweite, unabhängige Quelle von
Unschärfe.

### Wünschenswert

**W1 — Hardware-Dekodierung über VideoToolbox.** Bei 5120×2880 lohnt sich das; FreeRDPs
Software-Pfad geht sonst über OpenH264/ffmpeg.

**W2 — Zwischenablage** in beide Richtungen. `client/Mac/Clipboard.m` ist übernehmbar.

**W3 — Mehrere Bildschirme.**

**W4 — Wiederverbinden** nach Netzunterbrechung.

### Ausdrücklich nicht gefordert

- Oberfläche jeder Art
- Audio
- Geräte- und Laufwerksumleitung
- Gateway, Smartcard, AAD-Anmeldung

---

## 4. Abnahmekriterien

Messbar, nicht nach Gefühl:

1. **Auflösung.** Desktopsitzung von einem 5K-Panel aus: serverseitig steht
   5120×2880. Prüfbar mit `C:\Serverwerkzeuge\displays.ps1`.
2. **Schärfe.** Text in der Sitzung ist auf dem Retina-Panel so scharf wie lokal
   gerenderter Text. Kein weicher Saum, keine Farbränder.
3. **DPI.** Bei `/scale:180` meldet die Sitzung 172 DPI (180 %), nicht 96.
4. **RemoteApp brauchbar.** Ein per `/app:program:"||taskmgr"` gestartetes Fenster lässt
   sich anklicken, verschieben, in der Größe ändern, minimieren und wieder nach vorn
   holen.
5. **Kein Rückfall auf 1024×768** in irgendeiner Betriebsart.
6. **Encoder.** Während des Streamens meldet `nvidia-smi` auf dem Server eine aktive
   Encoder-Sitzung — Beleg dafür, dass der H.264-Pfad genutzt wird und nicht ein
   Notcodec.

---

## 5. Testumgebung

Ein echter Server steht bereit, das ist der wichtigste Vorteil dieses Projekts.

```
Server     192.168.6.46   Windows Server 2025 Standard (Eval), RTX 3080 durchgereicht
Benutzer   Administrator  (Kennwort in /opt/incus/windows-server-kvm/.env)
```

**RemoteApp ist eingerichtet**, folgende Aliase sind veröffentlicht:

```
||calc  ||cmd  ||control  ||explorer  ||mmc  ||notepad
||powershell  ||servermanager  ||settings  ||taskmgr
```

**Serverseitige Einstellungen stehen bereits** (`rdp-gpu.ps1 -Modus pruefen` zeigt sie):

| Wert | | |
|---|---|---|
| `bEnumerateHWBeforeSW` | 1 | Sitzung rendert auf der RTX 3080 |
| `fEnableWddmDriver` | 1 | WDDM-Anzeigetreiber |
| `AVCHardwareEncodePreferred` | 1 | NVENC statt CPU |
| `AVC444ModePreferred` | 1 | H.264 4:4:4 |
| `VisualExperiencePolicy` | 1 | Multimedia (nicht 2 = Text) |
| `ImageQuality` | 2 | Hoch |
| `MaxCompressionLevel` | 0 | keine zweite Kompression |
| `ColorDepth` | 5 | 32 Bit |
| `DWMFRAMEINTERVAL` | 15 | ~60 Bilder/s |
| `fSingleSessionPerUser` | 1 | eine Sitzung je Benutzer |

**`ImageQuality` nicht auf 1 stellen.** Verlustfrei schaltet den AVC444-Hardwarepfad ab;
der Server weist die Grafikaushandlung dann zurück und der Bildstrom bricht auf wenige
Bilder je Sekunde ein. Gemessen und eingegrenzt.

### Zwei Fallstricke beim Testen

**Nur zwei gleichzeitige Sitzungen.** Ohne die Remotedesktop-Rolle lässt der Server zwei
interaktive Sitzungen zu, die Konsole zählt mit. Eine dritte wird nach rund 32 Sekunden
abgemeldet.

**RemoteApp startet die Anwendung nur beim *Aufbau* einer Sitzung.** Hängt noch eine
alte Sitzung desselben Benutzers herum, verbindet der Client dorthin zurück, `rdpshell`
läuft, die Anwendung aber nicht. Vor jedem Test aufräumen:

```
ssh Administrator@192.168.6.46 "powershell -File C:\Serverwerkzeuge\rdp-frei.ps1"
```

Das meldet nur Administrator-Sitzungen ab; die Konsolensitzung ist fest ausgenommen.

### Werkzeuge auf dem Server

| | |
|---|---|
| `C:\Serverwerkzeuge\displays.ps1` | listet die Bildschirme einer Sitzung samt Auflösung |
| `C:\Serverwerkzeuge\rdp-gpu.ps1` | prüft und setzt die RDP-Grafikeinstellungen |
| `C:\Serverwerkzeuge\rdp-frei.ps1` | räumt übriggebliebene Sitzungen ab |
| `C:\Serverwerkzeuge\rdp-lasttest.ps1` | erzeugt gleichmäßige Bildbewegung zum Messen |

`displays.ps1` und `rdp-lasttest.ps1` müssen **in** der Zielsitzung laufen, also über
`C:\VirtualDisplayDriver\bin\run-in-console.ps1 -Sitzung <nr>` — und das wiederum als
SYSTEM, weil `SetTokenInformation(TokenSessionId)` sonst mit Fehler 1314 scheitert.

---

## 6. Aufwand

Grob 3000–5000 Zeilen Objective-C oder Swift.

| Teil | Umfang | |
|---|---|---|
| Gerüst, CLI, Verbindungsaufbau | 300–500 Zeilen | großteils aus `client/Mac` |
| Retina-Zeichnen | ~200 Zeilen | leicht, wenn von Anfang an richtig |
| RAIL-Fensterverwaltung | 1500–2500 Zeilen | **hier steckt die Arbeit** |
| Eingabe je Fenster | 400–800 Zeilen | Tastaturlayout ist ein Zeitfresser |
| Zwischenablage | ~300 Zeilen | aus `client/Mac` |

Realistische Stufen:

- **Desktop mit korrektem Retina: ein bis zwei Tage.** Im Wesentlichen Zusammensetzen.
- **RemoteApp, das Fenster öffnet und bedienbar ist: ein bis zwei Wochen.**
- **RemoteApp, das sich richtig anfühlt: Wochen.** Fensterreihenfolge, Fokus,
  Ziehen und Größe ändern, Tray-Symbole, mehrere Bildschirme.

Die letzte Stufe ist der Punkt, an dem „zu 80 % fertig, noch 80 % vor sich" entsteht.
Der Beleg steht oben: FreeRDPs X11-RAIL gibt es seit über einem Jahrzehnt und hat diese
Teile bis heute nicht.

---

## 7. Vorgehen

Vorschlag in dieser Reihenfolge, jede Stufe für sich abnehmbar:

1. **Stufe 1 — Desktop mit Retina.** `client/Mac` nehmen, das Zeichnen auf den
   Backing-Store umstellen, Pixelgröße statt Punktgröße anfordern. Abnahme: Kriterium
   1 bis 3. *Wenn das reicht, hör hier auf* — Revit und D5 laufen im vollen Desktop.
2. **Stufe 2 — RAIL-Grundgerüst.** Fenster erzeugen, zeichnen, schließen. Noch ohne
   Fokus und Reihenfolge.
3. **Stufe 3 — Fensterverwaltung.** `ACTIVE_WND`, `ZORDER`, Minimieren, Wiederherstellen.
   Abnahme: Kriterium 4.
4. **Stufe 4 — Feinschliff.** Ziehen und Größe ändern, Tray-Symbole, mehrere Bildschirme,
   VideoToolbox.

---

## 8. Vorher prüfen, ob es das Projekt überhaupt braucht

Drei billigere Wege, alle ungetestet:

1. **`sdl-freerdp` mit vollem Desktop.** Der SDL-Client ist im Fenster-Code
   nachweislich pixeldichte-bewusst. Wenn er scharfes 5K liefert, ist die
   RemoteApp-Frage für den eigentlichen Zweck — Revit und D5 — gegenstandslos.
   Aufwand: fünf Minuten. Befehle liegen in `../incus/windows-server-kvm/freerdp/.env`.
2. **Thincast anschreiben.** Das sind die FreeRDP-Betreuer, es ist ein kommerzielles
   Produkt, und „kein HiDPI auf Retina" ist ein Fehlerbericht, den sie vermutlich
   annehmen. Aufwand: eine E-Mail.
3. **Retina in FreeRDPs `client/Mac` beitragen.** Deutlich kleiner als eine eigene App,
   wird gegengelesen, und die Wartung hängt nicht an einem selbst.
