[![RedGCI Build](https://github.com/Applevangelist/RedGCI/actions/workflows/CI.yml/badge.svg)](https://github.com/Applevangelist/RedGCI/actions/workflows/CI.yml)

# RedGCI

**Ground Controlled Intercept simulator for DCS World** — Soviet-era GCI doctrine (MiG-29A, ~1985) implemented as a native DLL plugin with Lua mission scripting via MOOSE.

> *"Сокол-1, курс 112, высота 4900, скорость девятьсот."*

---

## Overview

RedGCI provides authentic GCI (Наземный пункт наведения) behaviour for DCS World missions. A C11 tactics core handles all intercept geometry and FSM logic, exposed to the DCS mission sandbox via a Lua 5.1 DLL. Voice output is delivered through SRS/MSRS with full localisation support.

**Key features:**
- Pursuit solver with COLLISION, LEAD, and PURE pursuit modes
- Intercept FSM: VECTOR → COMMIT → RADAR_CONTACT → VISUAL → MERGE
- Rolling waypoint guidance with terrain floor clamping
- Soviet/Russian GCI doctrine (centralised control, no datalink, N019 look-down offset)
- Multilingual voice output via MSRS (English, German, Russian)
- Token-based localisation — strings fully decoupled from C logic
- AI and human pilot modes
- Up to 8 simultaneous intercept contexts

---

## Architecture

```
DCS.exe → MissionScripting.lua (dofile hook, pre-sanitizer)
  └── gci_mission.lua          (DCS pre-sandbox loader, loads RedGCI.dll)
        └── RedGCI.dll          (luaopen_RedGCI, Lua 5.1)
              └── gci_core.lib  (C11 tactics core)
                    ├── pursuit_solver.c
                    ├── intercept_fsm.c
                    ├── merge_controller.c
                    └── message_handler.c

gci_bridge.lua                  (MOOSE mission script, full DCS API access)
  ├── gci_messages.lua          (localised string table en/de/ru + DirTokens)
  └── RedGCI.Transmit()         (token parser + MSRS output)
```

### Coordinate System

DCS `getPosition()` / `getVelocity()` mapping to GCI internal:

| DCS | Meaning | GCI internal |
|-----|---------|--------------|
| `x` | North/South | `z` |
| `y` | Altitude | `y` |
| `z` | East/West | `x` |

---

## Requirements

- **DCS World** (OpenBeta or Stable)
- **MOOSE** framework
- **SRS** (SimpleRadioStandalone) + **MSRS** MOOSE module
- **CMake** ≥ 3.16 (build)
- **MSVC** or **GCC** C11 compiler

---

## Building

```bash
git clone https://github.com/Applevangelist/RedGCI
cd RedGCI
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

Output: `build/Release/RedGCI.dll` + `build/Release/gci_core.lib`

For the DLL (Windows only), provide the Lua 5.1 headers and import library from your DCS installation:

```cmd
cmake -B build -DCMAKE_BUILD_TYPE=Release ^
  -DLUA51_LIB="C:\DCS\bin\lua51.lib" ^
  -DLUA51_INCLUDE="C:\DCS\LuaSocket\include"
cmake --build build --config Release
```

---

## Installation

### 1. File layout

Copy files to your DCS Saved Games folder:

```
%USERPROFILE%\Saved Games\DCS\
  Mods\Services\RedGCI\
    bin\RedGCI.dll
    Scripts\gci_mission.lua
  Config\RedGCI.lua          (optional — overrides defaults)
```

### 2. MissionScripting.lua hook

Add the following line to `MissionScripting.lua` **before** the `sanitizeModule()` calls:

```lua
dofile(lfs.writedir()..[[Mods\Services\RedGCI\Scripts\gci_mission.lua]])
```

> **Note:** `MissionScripting.lua` is overwritten by DCS updates — re-apply after every DCS update.

### 3. Mission Script

Load the following files **in order** via **ONCE / MISSION START** triggers:

```
Trigger → MISSION START → DO SCRIPT FILE → gci_messages.lua
Trigger → MISSION START → DO SCRIPT FILE → gci_bridge.lua
```

`gci_messages.lua` must be loaded first — it populates `RedGCI.Messages` and `RedGCI.DirTokens` which `gci_bridge.lua` requires.

### 4. Configuration

Optional: create `%USERPROFILE%\Saved Games\DCS\Config\RedGCI.lua` (evaluated inside the `RedGCI` namespace):

```lua
FIGHTER_GROUP = "Mig-29A"          -- DCS group name
TARGET_GROUP  = "Target"           -- DCS group name
CALLSIGN      = "Сокол-1"         -- voice callsign
LOCALE        = "de"               -- "en" | "de" | "ru"
IS_AI_PLANE   = true               -- false = human pilot
COALITION     = 1                  -- 1=RED
TICK_INTERVAL = 10                 -- seconds
DEBUG         = false
```

Alternatively, edit the defaults at the top of `gci_bridge.lua` directly.

The home airbase is set in `gci_bridge.lua`:

```lua
RedGCI.HOMEBASENAME = AIRBASE.Caucasus.Nalchik
```

---

## FSM States

| State | Trigger | Radar | Waypoints |
|-------|---------|-------|-----------|
| `VECTOR` | Range > 30 km | OFF | Rolling, every tick |
| `COMMIT` | Range < 30 km | ON | Rolling to intercept point |
| `RADAR_CONTACT` | Pilot has lock | ON | Rolling to intercept point |
| `VISUAL` | Range < 5 km | ON | — |
| `MERGE` | Range < 2 km | ON | — |
| `NOTCH` | Aspect 80–100° | OFF | Hold |
| `ABORT` | Threat / Bingo fuel | OFF | RTB heading |
| `RTB` | Mission complete | OFF | Home base |

---

## Pursuit Solver

Three modes, selected automatically:

- **COLLISION** — optimal CBDR course, solves quadratic intercept equation
- **LEAD** — bearing + lead angle fallback when closure is insufficient
- **PURE** — pure pursuit of last resort

TTI is capped at 600 s. Minimum closing speed floor: 50 m/s.

---

## Token System

The C core returns structured token strings instead of free text:

```
"VECTOR|hdg=165|alt=4900|rng=32|tti_m=8|delay=5.2"
"VECTOR_WITH_TTI|hdg=112|alt=4900|rng=28|tti_m=6|delay=4.1"
"COMMIT_FIRST|hdg=112|alt=4900|rng=28|aspect=033|delay=4.1"
"COMMIT_NUDGE|delay=2.0"
"RADAR_LOCK_WF|rng=23|delay=3.8"
"RADAR_LOCK_HOLD|rng=23|delay=3.8"
"NOTCH_ENTRY|delay=3.0"
"MERGE_ENTRY|brg=324|dir_rl=left|delay=2.1"
"MERGE_SPLASH|delay=1.5"
"ABORT_BINGO|hdg=270|delay=2.0"
```

`gci_bridge.lua` parses these, looks up the localised template in `RedGCI.Messages` via key, fills `{PLACEHOLDER}` values with `gsub`, and sends the result to `MSRSQUEUE:NewTransmission()`.

Repeated identical transmissions are suppressed for 30 seconds (`TX_REPEAT_INTERVAL`).

---

## Localisation

Add or modify strings in `gci_messages.lua`:

```lua
RedGCI.Messages = {
    en = {
        VECTOR          = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph.",
        VECTOR_WITH_TTI = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph. Target in {TTI_M} minutes.",
        COMMIT_FIRST    = "{CALLSIGN}, BOGEY ahead, {RNG} kilometers, altitude {ALT} meters. Search radar. Look.",
        -- ...
    },
    de = { ... },
    ru = { ... },
}
```

Available placeholders: `{CALLSIGN}` `{HDG}` `{ALT}` `{RNG}` `{TTI_M}` `{TTI_S}` `{ASPECT}` `{DIR_LR}` `{DIR_RL}`

Direction tokens (`{DIR_LR}`, `{DIR_RL}`) are resolved per locale from `RedGCI.DirTokens` and passed into `RedGCI.Transmit()` from `gci_bridge.lua`.

---

## Constants (gci_types.h)

| Constant | Value | Description |
|----------|-------|-------------|
| `GCI_RANGE_COMMIT` | 30 000 m | Radar ON, COMMIT transition |
| `GCI_RANGE_VISUAL` | 5 000 m | Visual contact expected |
| `GCI_RANGE_MERGE` | 2 000 m | Merge |
| `GCI_WF_RANGE_MAX` | 25 000 m | Max weapons free range |
| `GCI_ALT_OFFSET_LOOKDOWN` | 700 m | N019 look-down guidance offset |
| `GCI_ASPECT_REAR_ATTACK` | 120° | Minimum aspect for WF |
| `GCI_FUEL_BINGO` | 0.25 | Bingo fuel fraction |
| `GCI_MAX_TTI` | 600 s | TTI cap |

---

## F10 Menu

`gci_bridge.lua` registers a **GCI** sub-menu for the RED coalition with the following commands:

| Command | Action |
|---------|--------|
| Radar Lock | Pilot confirms radar lock (pilot_flags.radar = true) |
| Visual Contact | Pilot confirms visual (pilot_flags.visual = true) |
| Threat (RWR) | Pilot reports threat (pilot_flags.threat = true) |
| Splash / Kill | Trigger MERGE_SPLASH, reset GCI state |
| Reset GCI | Full state reset, radar off |
| Toggle AI Mode | Switch between AI waypoint control and human pilot mode |

---

## Project Status

| Phase | Status |
|-------|--------|
| Phase 1 — POC (UDP) | ✅ Complete |
| Phase 2 — DLL, pursuit solver, FSM, AI guidance | ✅ Complete |
| Phase 3 — Token system, MSRS multilingual voice | ✅ Complete |
| Phase 4 — MOOSE Detection integration | 🔲 Planned |
| Phase 5 — Multi-flight, team tactics | 🔲 Planned |

---

## License

GPL 2.0 — see [LICENSE](LICENSE)

---

*Built with DCS World Lua 5.1, MOOSE, SRS, and a healthy respect for 1985 Soviet air defence doctrine.*
