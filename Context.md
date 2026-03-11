# GCI POC — Projektkontext für KI-Assistenten

> Diese Datei fasst alle Architekturentscheidungen, Design-Rationale und geplanten
> Erweiterungen zusammen. In einen neuen Chat hochladen um den Kontext wiederherzustellen.

-----

## Projektziel

Simulation eines lebensnahen **Warschauer-Pakt GCI Controllers** (Ground Controlled Intercept)
für **DCS World**, der Piloten in MiG-29A Flugzeugen Mitte der **1980er Jahre** führt.

Historische Doktrin: stark zentralisierte Führung, Pilot folgt Bodenanweisungen,
wenig Eigeninitiative. Kommunikation auf Russisch. Kein Datalink — rein sprachgeführt.

Autor: Applevangelist (MOOSE-Contributor: CSAR_MOOSE, Airbase PRs)

-----

## Technologie-Stack

|Schicht         |Technologie   |Begründung                           |
|----------------|--------------|-------------------------------------|
|Taktik-Kern     |C11           |Performance, deterministisch, kein GC|
|DCS-Interface   |Lua 5.1       |DCS interne Scripting Engine         |
|Taktik-Framework|MOOSE         |Detection, MSRS, SET_GROUP           |
|Sprachausgabe   |MOOSE MSRS    |SRS-Integration, multi-lingual       |
|CI/CD           |GitHub Actions|Linux-Tests + Windows EXE Build      |

-----

## Aktuelle Implementierung (POC — UDP-Weg)

### Architektur

```
DCS.exe
 └── Export.lua  (außerhalb Sandbox, voller Lua-Zugriff)
      └── UDP 127.0.0.1:9088
           └── gci_server.exe  (C-Prozess)
                └── gci_core (statische Bibliothek)
```

### C-Kern Module

```
include/
  gci_types.h          Alle Datentypen, Konstanten, Inline-Helfer
  pursuit_solver.h
  intercept_fsm.h      FSM + Merge Controller Header
  message_handler.h

src/
  pursuit_solver.c     Collision Course, Lead Pursuit, Aspect Angle
  intercept_fsm.c      State Machine + russische Transmission Builder
  merge_controller.c   Merge-Phasen: Entry/Overshoot/Separation/Reattack/Splash
  message_handler.c    UDP-Protokoll Parser/Formatter
  gci_server.c         UDP Server Main (Windows: ws2_32, Linux: nativ)

lua/
  Export.lua           DCS Export Hook (außerhalb Sandbox)
  gci_bridge.lua       Mission Script: F10-Menü, Event-Handler
  test_mission.lua     Standalone Lua-Test ohne DCS

test/
  test_pursuit.c       Unit Tests (25/25 bestanden)
```

### UDP-Protokoll

Client → Server:

```
PING
RESET
INTERCEPT|fx|fz|fy|fspd|tx|tz|ty|tspd|tvx|tvz|tvy
PILOT_RADAR|id|1        Radar Lock bestätigt
PILOT_VISUAL|id|1       Sichtkontakt
PILOT_THREAT|id|1       RWR-Warnung
FUEL|id|0.72
MERGE_SPLASH
```

Server → Client:

```
PONG
SILENCE                 GCI schweigt (Pilot arbeitet)
HDG:275|TTI:143|MODE:COLLISION|WF:1|STATE:RADAR_CONTACT|RANGE:...|RU:...|EN:...
ERR:msg
```

### Koordinatensystem

DCS World: `x` = Ost, `z` = Nord, `y` = Höhe MSL.
Alle Distanzen Meter, Geschwindigkeiten m/s, Winkel Grad (0°=Nord, Uhrzeigersinn).

-----

## Intercept-Geometrie

### Pursuit-Modi (Priorität absteigend)

**1. Collision Course (CBDR)** — optimal, WP-Doktrin
Löst quadratische Gleichung: `a*t² + b*t + c = 0`

```
a = |Vt|² - |Vf|²
b = 2 * (d · Vt)       d = T - F
c = |d|²
```

Kleinste positive Lösung = Treffzeit.

**2. Lead Pursuit** — Fallback wenn Jäger zu langsam für Collision
Sinus-Regel: `sin(lead) / |Vt| = sin(aspect) / |Vf|`

**3. Pure Pursuit** — im Code vorhanden aber vom GCI nie ausgegeben.
Bei fehlender geometrischer Lösung sagt GCI “Цель визуально”.

### Höhenstaffelung

MiG-29A wird **700m über Ziel** geführt → N019-Radar schaut nach unten (Look-Down),
bessere Doppler-Separation vom Bodenclutter.

### Waffenfreigabe

Bedingungen: Aspekt > 120° (Heckschuss) UND Range < 35km (R-27 Reichweite).

-----

## FSM — Intercept State Machine

```
STATE_VECTOR         GCI führt aktiv (Collision Course Vektoren)
STATE_COMMIT         Pilot sucht mit Bordradar (GCI gibt Sektor/Parameter)
STATE_RADAR_CONTACT  Pilot hat Lock (GCI bestätigt, tritt zurück)
STATE_VISUAL         Sichtkontakt (GCI schweigt bis auf WF)
STATE_MERGE          <2km (GCI als drittes Auge — relative Positionsmeldungen)
STATE_NOTCH          Ziel notcht (GCI wartet, gibt Lage-Updates)
STATE_ABORT          Bingo Fuel (<25%) oder Bedrohung
STATE_RTB            Return to Base
```

### Phasen-Distanzen (historisch kalibriert, MiG-29A / 1985)

|km   |Aktion                                   |
|-----|-----------------------------------------|
|>60  |Frühe Vektierung                         |
|40–60|Präziser Collision-Course-Vektor         |
|40   |STATE_COMMIT — “Включи локатор”          |
|25   |Erste Zieldaten (Azimut, Distanz, Höhe)  |
|15   |Lock erwartet — sonst Mikrokorrektur     |
|10   |Waffenfreigabe wenn Aspekt >120°         |
|5    |Letzter Vektor, dann Schweigen           |
|2    |STATE_MERGE — relative Positionsmeldungen|

### Merge-Phasen

```
MERGE_ENTRY       Erster Kontakt — "контакт справа, 045 градусов. Бой."
MERGE_OVERSHOOT   Ziel hinter Jäger — Richtungshinweis mit Höheninfo
MERGE_SEPARATION  Beide auseinander — Reattack oder RTB Entscheidung
MERGE_REATTACK    GCI vektiert für zweiten Pass
MERGE_LOST        Radarkontakt verloren — letzte bekannte Position
MERGE_SPLASH      Ziel zerstört — "Молодец. Курс домой."
```

### GCI Kommunikationsverhalten

- Funkverzögerung: 3–8s in VECTOR/COMMIT, 2–5s im MERGE
- GCI schweigt wenn Pilot arbeitet (RADAR_CONTACT, VISUAL)
- Mikrokorrektur nach 30s ohne Radar-Lock in COMMIT
- “Молодец” (gut gemacht) ist einziges Lob das WP-GCI gibt

-----

## Nächste Entwicklungsstufe: DLL-Weg

### Motivation

UDP-Roundtrip ersetzen durch direkten DLL-Load in die Lua Mission Sandbox —
analog zu SRS und Hound TTS.

### Hook-Mechanismus

`Scripts/MissionScripting.lua` einmalig patchen (vor dem Sanitizer):

```lua
-- Vor den sanitizeModule()-Aufrufen einfügen:
local _path = lfs.writedir() .. "Scripts\\gci_core.dll"
if lfs.attributes(_path) then
    package.loadlib(_path, "luaopen_gci")()
end
```

Danach sind `gci_*` Funktionen global in der Sandbox verfügbar.
Hinweis: MissionScripting.lua wird bei DCS-Updates überschrieben → im Installer dokumentieren.

### Lua-C Interface (geplant)

```c
// Gegen lua51.dll linken (DCS nutzt Lua 5.1, NICHT 5.4)
static int l_compute_intercept(lua_State *L);  // 10 floats rein → hdg, tti, mode, wf
static int l_fsm_update(lua_State *L);          // context update → state, transmission token
static int l_merge_update(lua_State *L);        // merge context → phase, transmission token
int luaopen_gci(lua_State *L);                  // Registrierung aller Funktionen
```

-----

## Nächste Entwicklungsstufe: Token-System + MSRS

### Design-Prinzip

C gibt **semantische Tokens** zurück — keine hardcodierten Sprachstrings.
Lua übersetzt in Zielsprache, MSRS sendet via SRS.

```
C gibt zurück:   "VECTOR|hdg=275|alt=5700|spd=900"
Lua → RU:        "Сокол-1, курс 275, высота 5700, скорость девятьсот."
Lua → DE:        "Falke Eins, Kurs 275, Höhe 5700, Geschwindigkeit 900."
Lua → EN:        "Falcon One, vector 275, altitude 5700, speed 900."
```

### MOOSE MSRS Integration

```lua
local msrs = MSRS:New("D:\\SRS", 251.0, radio.modulation.AM)
msrs:SetCoalition(coalition.side.RED)
msrs:SetCulture("ru-RU")
msrs:SetVoice(MSRS.Voices.Google.Russian.Female)
msrs:PlayTextToSRS(GCI.translate(token, "ru"))
```

-----

## Nächste Entwicklungsstufe: MOOSE Detection

### Problem mit aktuellem Polling

POC liest alle roten Einheiten alle 5s — kein Höhenprofil, kein LOS, kein RCS.

### MOOSE Detection als Input-Layer

```lua
local red_fighters = SET_GROUP:New()
    :FilterCoalitions("red"):FilterCategories("plane"):FilterStart()

local detection = DETECTION_AREAS:New(red_fighters, 40000)
detection:SetRefreshTimeInterval(5)

function detection:OnAfterDetected(From, Event, To)
    for _, area in pairs(self:GetDetectedAreas()) do
        -- Nur was durch den Physik-Filter kommt → an FSM weiterleiten
        GCI.updatePicture(area.Set, area.Coordinate)
    end
end
detection:Start()
```

### RCS-Berechnung: Hybrid-Ansatz

Bekannte Typen aus Lookup-Table (Performance), unbekannte aus `unit:getSize()` (wartungsfrei).

```lua
-- Häufige Typen: fest kodiert (schneller)
local RCS_KNOWN = {
    ["F-16C_50"]     = 5.0,    -- m², Baseline
    ["F-15C"]        = 12.0,
    ["FA-18C_hornet"]= 7.0,
    ["F-5E-3"]       = 3.5,
    ["A-10C"]        = 14.0,
    ["B-52H"]        = 100.0,
    ["Tu-95MS"]      = 120.0,
    ["Tu-22M3"]      = 50.0,
    ["MiG-29A"]      = 8.0,
}

-- Unbekannte Typen: aus Bounding-Box geschätzt
local function estimate_rcs(unit)
    local s = unit:getSize()      -- {l, w, h} in Metern
    if not s then return 5.0 end
    return s.h * s.w * 0.4        -- Frontfläche × empirischer Faktor ~0.4
end

-- API
function RCS.getFactor(unit)
    local rcs = RCS_KNOWN[unit:GetTypeName()] or estimate_rcs(unit)
    return rcs / 5.0  -- normiert auf F-16 Baseline
end
```

### Aspekt-abhängiger RCS (Notch/Beam)

```lua
-- N019 Zhuk: Doppler-Radar verliert Beam-Target fast vollständig
function get_aspect_factor(aspect_deg)
    if aspect_deg > 75 and aspect_deg < 105 then
        return 0.05   -- Notch: 95% Erkennungsverlust
    end
    if aspect_deg > 150 then
        return 0.7    -- Tail-on: geringere Doppler-Signatur
    end
    return 1.0        -- Nose-on: volle Erkennbarkeit
end
```

### Radar-Gleichung (vereinfacht, 4-Potenz-Gesetz)

```lua
-- SNR ∝ RCS / R⁴  (alle Radar-Konstanten in RADAR_CONST zusammengefasst)
local snr = RADAR_CONST * rcs / (range^4)

-- Sigmoid statt harter Schwelle: weicher Übergang
local p = 1.0 / (1.0 + math.exp(-3.0 * (snr - 1.0)))
```

### Radar-Horizont

```lua
-- Formel: d = 4120 * (sqrt(h_radar) + sqrt(h_target))  [Meter]
-- P-14 Frühwarnung: 30m Antennenmast
-- → NOE unter ~150m AGL: unsichtbar
-- → Bodenclutter-Zone 150–500m: probabilistisch
```

### Detection Confidence → GCI Verhalten

```
P > 0.8:  Sicherer Track  → GCI vektiert normal
P 0.4–0.8: Unsicherer Track → "Цель предположительно..." 
P < 0.4:  Kontakt verloren → STATE_NOTCH oder Schweigen
```

-----

## Nächste Entwicklungsstufe: Teamtaktik

**Stufe 1 — Bracket**: 2 Jäger → 1 Ziel

- Jäger 1: frontaler Intercept (normale FSM)
- Jäger 2: Collision Course auf Fluchtvektor des Ziels

**Stufe 2 — Sort**: 2 Jäger → 2 Ziele

- GCI weist zu: wer schießt auf wen (nach Priorität/Bedrohung)
- Deconfliction: automatische Höhenstaffelung ±500m

**Stufe 3 — Stack Management**

- GCI hält Gesamtbild, priorisiert nach ThreatLevel
- Vektiert spare fighters nach Splash zu neuen Zielen
- Historisch korrekt: WP-GCI führte tatsächlich mehrere Jäger simultan

-----

## Entwicklungsreihenfolge

```
[x] Phase 1: POC (UDP-Weg)
    Collision Course Solver, FSM, Merge Controller, UDP Server,
    Export.lua, GitHub Actions CI (Linux test + Windows EXE build + Release)

[ ] Phase 2: DLL-Weg
    luaopen_gci, MissionScripting.lua Hook, direkte Sandbox-Integration

[ ] Phase 3: Token-System + MSRS
    Semantische Tokens aus C, Lua-Sprachschicht (RU/EN/DE),
    MOOSE MSRS Integration auf SRS-Frequenz

[ ] Phase 4: MOOSE Detection
    DETECTION_AREAS als Input-Layer vor FSM, RCS Hybrid,
    Aspekt-Modulation, Radar-Horizont, Sigmoid P_detect,
    Confidence-Score an FSM weitergeben

[ ] Phase 5: Multi-Flight + Teamtaktik
    Session-Map für mehrere Jäger in C, Bracket/Sort Algorithmen,
    Stack Management
```

-----

## Wichtige Implementierungsdetails

|Detail              |Wert                                                          |
|--------------------|--------------------------------------------------------------|
|DCS Lua Version     |**5.1** — DLL muss gegen `lua51.dll` gelinkt werden, nicht 5.4|
|DCS Koordinaten     |Linkshand-System: x=Ost, z=Nord (nicht Standard-OpenGL)       |
|`unit:getSize()`    |Gibt `{l, w, h}` zurück, verfügbar für alle DCS-Objekte       |
|`Object:getSize()`  |Liefert manchmal nil für Einheiten ohne Hitbox → immer prüfen |
|MissionScripting.lua|Wird bei DCS-Updates überschrieben → Installer/README nötig   |
|MOOSE MSRS          |Benötigt laufendes SRS auf Server/Client                      |
|Funkverzögerung     |3–8s normal, 2–5s im Merge (historisch realistisch)           |
|Bingo-Fuel          |25% Restsprit → ABORT                                         |
|Look-Down Offset    |+700m über Ziel für N019 Look-Down                            |
|WF-Bedingungen      |Aspekt >120° UND Range <35km (R-27 Reichweite)                |
