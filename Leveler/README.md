# Leveler

Kleine Mac-App für die Menüleiste, die bei Filmen, Serien und Videos die Lautstärke gleich hält – leise Dialoge werden lauter, plötzliche Explosionen leiser – und einen Equalizer mit 7 Bändern bietet.

- **Ausgleich** an/aus mit großem Schalter, Stärke per Regler (Sanft · Ausgewogen · Stark)
- **Equalizer** mit eigenem Schalter neben „Klang“ – Ausgleich und EQ lassen sich unabhängig voneinander ein- und ausschalten. Als Kurve: Punkte mit der Maus nach oben/unten ziehen; Presets *Film, Musik, Sprache, Nacht*; Rechtsklick → alle Bänder auf 0 dB. Ein Preset wählen oder einen Punkt ziehen schaltet den EQ automatisch ein.
- Live-Anzeige *Original* vs. *Mit Leveler*
- Läuft im Hintergrund (nur Symbol in der Menüleiste, kein Dock-Symbol), optional **Autostart** beim Anmelden
- Wirkt auf den gesamten Systemton – egal ob Safari, Netflix, YouTube, VLC oder Apple TV

## Voraussetzungen

- macOS **14.2 (Sonoma)** oder neuer
- Zum Selberbauen: Xcode oder die Xcode Command Line Tools (`xcode-select --install`)

## Bauen & starten

```bash
cd Leveler
./build-app.sh --install   # baut Leveler.app, kopiert sie nach /Applications und startet sie
```

Ohne `--install` liegt die App danach in `Leveler/build/Leveler.app`.

Alternativ: Bei jedem Push baut GitHub Actions die App automatisch (Workflow *Leveler (macOS)*). Unter *Artifacts* gibt es `Leveler-app` als ZIP. Da die App nicht notarisiert ist, beim ersten Start **Rechtsklick → Öffnen** wählen (oder `xattr -dr com.apple.quarantine /Applications/Leveler.app`).

## Beim ersten Start

macOS fragt nach der Erlaubnis für **Systemaudioaufnahme**. Die braucht Leveler, um den Ton bearbeiten zu können – es wird nichts aufgenommen oder gespeichert. Falls du die Frage verpasst hast:
*Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme › Nur Systemaudioaufnahme* → **Leveler** einschalten.

> Hinweis: Nach jedem Neubauen mit `build-app.sh` ändert sich die (ad-hoc) Signatur. macOS kann dann erneut nach der Erlaubnis fragen.

## So funktioniert es

```
Systemton ──► Core Audio Tap (Original stumm) ──► EQ (7 Bänder) ──► Leveler ──► Limiter ──► Lautsprecher/Kopfhörer
```

- **Core Audio Process Tap** (ab macOS 14.2) greift den gesamten Systemton ab und schaltet das Original stumm, solange Leveler läuft. Beim Beenden ist der normale Ton sofort zurück.
- **EQ:** 7 Peaking-Filter (60 Hz … 14 kHz, ±12 dB).
- **Leveler:** misst die Lautheit (schnell steigend, langsam fallend) und regelt Richtung −20 dBFS. Laute Stellen werden in ~15 ms heruntergeregelt, leise Stellen über ~2,5 s sanft angehoben. Stille wird nie hochgezogen (kein Rauschen).
- **Limiter:** harte Obergrenze bei −2 dBFS, damit auch ein plötzlicher Knall nie übersteuert.
- Sind EQ **und** Ausgleich aus, wird der Ton unverändert durchgereicht. Ein- und Ausschalten blendet in wenigen Millisekunden über – ohne Knacken.
- Wechselst du das Ausgabegerät (z. B. AirPods), startet Leveler automatisch auf dem neuen Gerät neu.

## Projektaufbau

```
Leveler/
├─ Package.swift
├─ build-app.sh                 # baut Leveler.app
├─ Resources/                   # Info.plist, App-Icon
├─ Sources/LevelerDSP/          # Tonverarbeitung (EQ, Leveler, Limiter) – plattformunabhängig, getestet
├─ Sources/Leveler/
│  ├─ Audio/                    # Core-Audio-Tap, Aggregate-Device, Berechtigung
│  ├─ Views/                    # SwiftUI-Oberfläche (Design 3)
│  ├─ AppState.swift            # Einstellungen, Presets, Speicherung
│  └─ LevelerApp.swift          # Menüleisten-App
└─ Tests/LevelerDSPTests/       # swift test
```
