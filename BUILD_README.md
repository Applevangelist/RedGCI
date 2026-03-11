# GCI POC — Build & Installation

## Projektstruktur

```
gci_poc/
├── CMakeLists.txt
├── include/
│   ├── gci_types.h          ← Alle Datentypen + Konstanten
│   ├── pursuit_solver.h
│   ├── intercept_fsm.h      ← FSM + Merge Controller Header
│   └── message_handler.h
├── src/
│   ├── pursuit_solver.c     ← Collision/Lead/Pure Pursuit Geometrie
│   ├── intercept_fsm.c      ← State Machine + Transmission Builder
│   ├── merge_controller.c   ← Merge-Phasen Logik
│   ├── message_handler.c    ← UDP-Protokoll Parser
│   └── gci_server.c         ← UDP Server Main (Windows)
├── lua/
│   ├── Export.lua           ← DCS Export Hook (außerhalb Sandbox)
│   ├── gci_bridge.lua       ← Mission Script (F10 Menü, Events)
│   └── test_mission.lua     ← Standalone Lua Test
└── test/
    └── test_pursuit.c       ← Unit Tests (25/25)
```

---

## Windows: Kompilieren mit MinGW

### 1. MinGW installieren

Empfohlen: **WinLibs** (keine Admin-Rechte nötig)
- https://winlibs.com → "Release versions" → GCC 14.x, Win64, UCRT
- ZIP entpacken nach `C:\mingw64`
- `C:\mingw64\bin` zu PATH hinzufügen

Testen:
```cmd
gcc --version
```

### 2. CMake installieren

- https://cmake.org/download/ → Windows x64 Installer
- "Add CMake to PATH" beim Installieren aktivieren

### 3. Projekt bauen

```cmd
cd gci_poc
cmake -B build -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Ausgabe:
```
build/
├── gci_server.exe   ← Server starten
└── gci_tests.exe    ← Unit Tests
```

### 4. Tests ausführen

```cmd
build\gci_tests.exe
```

Erwartete Ausgabe: `Ergebnis: 25/25 Tests bestanden`

---

## Linux: Kompilieren (für Entwicklung / Tests)

```bash
# Dependencies
sudo apt install gcc cmake make   # Ubuntu/Debian
# oder
sudo dnf install gcc cmake make   # Fedora/RHEL

# Bauen
cd gci_poc
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SERVER=OFF
cmake --build build

# Tests
./build/gci_tests
```

Für den Server auf Linux (für Tests ohne DCS):
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/gci_server
```

---

## DCS Integration

### Schritt 1: Server starten

```cmd
build\gci_server.exe
```

Erwartete Ausgabe:
```
╔══════════════════════════════════════╗
║  GCI POC Server  —  UDP :9088       ║
║  Warschauer Pakt  /  MiG-29A  1985  ║
╚══════════════════════════════════════╝
[GCI] Ready. Waiting for DCS Export.lua...
```

### Schritt 2: Export.lua installieren

```
lua\Export.lua  →  %USERPROFILE%\Saved Games\DCS\Scripts\Export.lua
```

**Falls bereits eine Export.lua existiert:**
Inhalt von `lua\Export.lua` ans Ende der bestehenden Datei anfügen,
dann am Ende der bestehenden `LuaExportStart()` Funktion ergänzen:
```lua
GCI_connect()
```

### Schritt 3: Gruppenname konfigurieren

In `Export.lua` anpassen:
```lua
GCI.config = {
    fighter_group = "Сокол",    -- Exakter Gruppenname in der Mission
    target_group  = "Target",   -- Exakter Gruppenname des Ziels
    coalition     = 1,          -- 1=RED (Warschauer Pakt)
    debug         = true,       -- Log in %USERPROFILE%\Saved Games\DCS\Logs\dcs.log
}
```

### Schritt 4: Mission Script laden (optional)

Im DCS Mission Editor:
- Trigger → `MISSION START`
- Action → `DO SCRIPT FILE` → `lua\gci_bridge.lua`

Damit werden F10-Menü-Einträge für Pilot-Meldungen aktiviert:
- **Захват есть** → Radar Lock bestätigen
- **Захват потерян** → Lock verloren melden
- **Вижу цель** → Visuellen Kontakt melden

---

## Manueller Test ohne DCS

### UDP direkt testen (Linux/Windows mit netcat):

```bash
# Verbindungstest
echo "PING" | nc -u -q1 127.0.0.1 9088
# → PONG

# Intercept berechnen
# Format: INTERCEPT|fx|fz|fy|fspd|tx|tz|ty|tspd|tvx|tvz|tvy
echo "INTERCEPT|0|0|5000|250|0|50000|5700|220|0|-220|0" | nc -u -q1 127.0.0.1 9088
# → HDG:000|TTI:...|STATE:VECTOR|RU:Сокол-1, курс 000...

# Intercept-Sequenz (Jäger nähert sich an):
echo "INTERCEPT|0|0|5000|250|0|38000|5700|220|0|-220|0" | nc -u -q1 127.0.0.1 9088
# → STATE:COMMIT, Radar-Befehl

echo "PILOT_RADAR|f1|1" | nc -u -q1 127.0.0.1 9088
echo "INTERCEPT|0|0|5300|260|0|18000|5700|220|0|-220|0" | nc -u -q1 127.0.0.1 9088
# → STATE:RADAR_CONTACT, Waffenfreigabe wenn Aspekt passt
```

### Lua-Test (benötigt lua5.1 + luasocket):

```bash
# Linux
sudo apt install lua5.1 lua-socket
lua5.1 lua/test_mission.lua

# Windows
# lua5.1 von https://luabinaries.sourceforge.net/
# luasocket von luarocks
lua test_mission.lua
```

---

## UDP-Protokoll Referenz

### Client → Server

| Nachricht | Beschreibung |
|-----------|-------------|
| `PING` | Verbindungstest |
| `RESET` | Session zurücksetzen |
| `INTERCEPT\|fx\|fz\|fy\|fspd\|tx\|tz\|ty\|tspd\|tvx\|tvz\|tvy` | Intercept berechnen |
| `PILOT_RADAR\|id\|1` | Pilot meldet Radar Lock |
| `PILOT_RADAR\|id\|0` | Pilot meldet Lock verloren |
| `PILOT_VISUAL\|id\|1` | Pilot meldet Sichtkontakt |
| `PILOT_THREAT\|id\|1` | RWR-Warnung aktiv |
| `FUEL\|id\|0.72` | Spritstand 0.0–1.0 |
| `MERGE_SPLASH` | Ziel zerstört |

### Server → Client

| Antwort | Beschreibung |
|---------|-------------|
| `PONG` | Verbindung OK |
| `SILENCE` | GCI schweigt (Pilot arbeitet) |
| `HDG:275\|TTI:143\|MODE:COLLISION\|WF:1\|STATE:RADAR_CONTACT\|...\|RU:...\|EN:...` | GCI-Befehl |
| `ERR:msg` | Fehler |

---

## Nächste Schritte

1. **SRS-Integration**: `moose.lua` DCS-SRS-Wrapper für echte Funkübertragung
2. **Multi-Flight**: Mehrere Jäger gleichzeitig (Session-Map im message_handler)
3. **TTS**: Windows SAPI oder Google TTS für russische Sprachausgabe
4. **Radar-Simulation**: Höhenabhängige Erkennungswahrscheinlichkeit
5. **DLL-Weg**: `gci_core.dll` direkt aus Lua laden (Weg 2 aus der Dokumentation)
