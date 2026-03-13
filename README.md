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

---

## Architecture

```
DCS.exe → MissionScripting.lua (dofile hook)
  └── gci_mission.lua          (DCS mission sandbox wrapper)
        └── RedGCI.dll          (luaopen_RedGCI, Lua 5.1)
              └── gci_core.lib  (C11 tactics core)
                    ├── pursuit_solver.c
                    ├── intercept_fsm.c
                    ├── merge_controller.c
                    └── message_handler.c

gci_bridge.lua                  (MOOSE mission script, full DCS API access)
  ├── gci_messages.lua          (localised string table en/de/ru)
  └── gci_tokens.lua            (token parser + MSRS output)
```

### Coordinate System

DCS `getPoint()` / `getVelocity()` mapping to GCI internal:

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
- **CMake** ≥ 3.20 (build)
- **MSVC** or **GCC** C11 compiler

---

## Building

```bash
git clone https://github.com/yourname/RedGCI
cd RedGCI
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
```

Output: `build/Release/RedGCI.dll` + `build/Release/gci_core.lib`

Copy `RedGCI.dll` to your DCS mission scripts folder or a path accessible from `MissionScripting.lua`.

---

## Installation

### 1. DLL loading

In `MissionScripting.lua` (or via dofile-Hook):

```lua
package.cpath = package.cpath .. ";C:/path/to/RedGCI/?.dll"
local _gci = require("RedGCI")
```

### 2. Mission Script

Load the following in order in your mission trigger (ONCE, on mission start):

```lua
dofile("gci_messages.lua")   -- string table
dofile("gci_tokens.lua")     -- token parser + MSRS
dofile("gci_mission.lua")    -- C-core wrapper functions
dofile("gci_bridge.lua")     -- main tick loop + DCS integration
```

### 3. Konfiguration

At the top of `gci_bridge.lua`, set your mission parameters:

```lua
RedGCI.FIGHTER_GROUP = "Sokol-1"         -- DCS group name
RedGCI.TARGET_GROUP  = "Bogey-1"         -- DCS group name
RedGCI.CALLSIGN      = "Сокол-1"         -- voice callsign
RedGCI.LOCALE        = "ru"              -- "en" | "de" | "ru"
RedGCI.IS_AI_PLANE   = true              -- false = human pilot
RedGCI.COALITION     = coalition.side.RED
RedGCI.TICK_INTERVAL = 10               -- seconds

RedGCI.HOME_BASE = { x = -125000, z = 759000 }  -- DCS coords

local path    = "C:/path/to/SRS"
local culture = "de-DE"
```

---

## FSM States

| State | Trigger | Radar | Waypoints |
|-------|---------|-------|-----------|
| `VECTOR` | Range > 30km | OFF | Rolling, every tick |
| `COMMIT` | Range < 30km | ON | Rolling to intercept point |
| `RADAR_CONTACT` | Pilot has lock | ON | Rolling to intercept point |
| `VISUAL` | Range < 5km | ON | — |
| `MERGE` | Range < 2km | ON | — |
| `NOTCH` | Aspect 80–100° | OFF | Hold |
| `ABORT` | Threat / Bingo fuel | OFF | RTB heading |
| `RTB` | Mission complete | OFF | Home base |

---

## Pursuit Solver

Three modes, selected automatically:

- **COLLISION** — optimal CBDR course, solves quadratic intercept equation
- **LEAD** — bearing + lead angle fallback when closure is insufficient
- **PURE** — pure pursuit of last resort

TTI is capped at 600s. Minimum closing speed floor: 50 m/s.

---

## Token System

The C core returns structured token strings instead of free text:

```
"VECTOR|hdg=165|alt=4900|rng=32|tti_m=8|delay=5.2"
"COMMIT_FIRST|hdg=112|alt=4900|rng=28|aspect=033|delay=4.1"
"RADAR_LOCK_HOLD|rng=23|delay=3.8"
"MERGE_ENTRY|brg=324|dir_rl=left|delay=2.1"
```

Lua parses these, looks up the localised template in `gci_messages.lua` via `TEXTANDSOUND:GetEntry()`, fills `{PLACEHOLDER}` values with `gsub`, and sends the result to `MSRSQUEUE:NewTransmission()`.

Repeated identical transmissions are suppressed for 30 seconds.

---

## Localisation

Add or modify strings in `gci_messages.lua`:

```lua
RedGCI.Messages = {
    en = {
        VECTOR = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph.",
        -- ...
    },
    de = { ... },
    ru = { ... },
}
```

Available placeholders: `{CALLSIGN}` `{HDG}` `{ALT}` `{RNG}` `{TTI_M}` `{BRG}` `{ASPECT}` `{DIR_LR}` `{DIR_RL}` `{ALT_REL}`

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

MIT — see [LICENSE](LICENSE)

---

*Built with DCS World Lua 5.1, MOOSE, SRS, and a healthy respect for 1985 Soviet air defence doctrine.*
