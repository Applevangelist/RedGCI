-- RedGCI mission-side script
-- ═══════════════════════════════════════════════════════════════
-- Geladen via MissionScripting.lua dofile() VOR dem sanitizeModule-Block,
-- sodass package, require, lfs, env alle verfügbar sind.
--
-- Install:
--   1. Folgende Zeile in MissionScripting.lua VOR sanitizeModule einfügen:
--        dofile(lfs.writedir()..[[Mods\Services\RedGCI\Scripts\gci_mission.lua]])
--
--   2. Verzeichnisstruktur:
--        %USERPROFILE%\Saved Games\DCS\Mods\Services\RedGCI\
--            bin\gci_core.dll
--            Scripts\gci_mission.lua
--
-- Nach dem Laden sind folgende Funktionen global verfügbar:
--   gci_compute_intercept(f_x, f_z, f_y, f_spd, f_vx, f_vz, f_vy,
--                         t_x, t_z, t_y, t_spd, t_vx, t_vz, t_vy)
--   gci_fsm_update(ctx_id, range, aspect, closure, alt_delta, fuel,
--                  pilot_radar, pilot_visual, threat)
--   gci_fsm_transmission(ctx_id, callsign, hdg, tti, mode, wf, ip_x, ip_z, ip_y)
--   gci_fsm_reset(ctx_id)
--   gci_merge_update(ctx_id, callsign, rel_bearing, range, alt_delta, splash)
--   gci_version()

if not RedGCI then
    RedGCI = {}
end

-- ──────────────────────────────────────────────────────────────
--  Optionale Konfiguration laden
--  %USERPROFILE%\Saved Games\DCS\Config\RedGCI.lua
-- ──────────────────────────────────────────────────────────────
do
    env.info("[RedGCI] Checking config at Config\\RedGCI.lua ...")
    local file, err = io.open(lfs.writedir() .. [[Config\RedGCI.lua]], "r")
    if file then
        local chunk = file:read("*all")
        file:close()
        local f, loadErr = loadstring(chunk)
        if f then
            setfenv(f, RedGCI)
            local ok, runErr = pcall(f)
            if ok then
                env.info("[RedGCI] Config\\RedGCI.lua geladen")
            else
                env.error("[RedGCI] Config\\RedGCI.lua Laufzeitfehler: " .. tostring(runErr))
            end
        else
            env.error("[RedGCI] Config\\RedGCI.lua Parse-Fehler: " .. tostring(loadErr))
        end
    else
        env.info("[RedGCI] Config\\RedGCI.lua nicht gefunden (" .. tostring(err) .. ") — nutze Standardwerte")
    end
end

-- ──────────────────────────────────────────────────────────────
--  Standardwerte (nach Config-Load, or-Pattern)
-- ──────────────────────────────────────────────────────────────
RedGCI.FIGHTER_GROUP  = RedGCI.FIGHTER_GROUP  or "Mig-29A"
RedGCI.TARGET_GROUP   = RedGCI.TARGET_GROUP   or "Target"
RedGCI.CALLSIGN       = RedGCI.CALLSIGN       or "Сокол-1"
RedGCI.TICK_INTERVAL  = RedGCI.TICK_INTERVAL  or 10.0
RedGCI.SUBTITLE_TIME  = RedGCI.SUBTITLE_TIME  or 8
RedGCI.COALITION      = RedGCI.COALITION      or 1   -- 1=RED
RedGCI.DEBUG          = RedGCI.DEBUG          or false

-- ──────────────────────────────────────────────────────────────
--  DLL laden via package.cpath + require
--  Analog zu HoundTTS-mission.lua
-- ──────────────────────────────────────────────────────────────

do
    local dllPath = lfs.writedir() .. [[Mods\Services\RedGCI\bin\]]
    if not string.find(package.cpath, dllPath, 1, true) then
        package.cpath = package.cpath .. ";" .. dllPath .. "?.dll;"
    end
end

local ok, _gci = pcall(require, "RedGCI")
if not ok then
    env.error("[RedGCI] Fehler: " .. tostring(_gci))
    -- Zusätzlich: prüfe ob luaopen_gci überhaupt existiert
	local ok2, fn = pcall(package.loadlib, 
        lfs.writedir() .. [[Mods\Services\RedGCI\bin\RedGCI.dll]], 
        "luaopen_RedGCI")
    env.error("[RedGCI] loadlib: ok=" .. tostring(ok2) .. " fn=" .. tostring(fn))
    
    -- Alle DLL-Ladefehler sehen
    local ok3, err3 = pcall(package.loadlib,
        lfs.writedir() .. [[Mods\Services\RedGCI\bin\RedGCI.dll]],
        "*")   -- * = alle Exports laden
    env.error("[RedGCI] loadlib *: ok=" .. tostring(ok3) .. " err=" .. tostring(err3))
	return
end

-- gci_version() ist jetzt global (registriert von luaopen_gci)
env.info("[RedGCI] " .. _gci.gci_version() .. " geladen")

-- ──────────────────────────────────────────────────────────────
--  RedGCI öffentliche API
--  Wird von gci_bridge.lua in der Mission genutzt
-- ──────────────────────────────────────────────────────────────

-- Kontext-IDs: 1-basiert, bis zu 8 gleichzeitige Intercepts
-- Einfacher Zugriff über Rufzeichen-Map
RedGCI._ctx_map  = {}   -- callsign → ctx_id
RedGCI._ctx_next = 1

function RedGCI.getCtxId(callsign)
    if not RedGCI._ctx_map[callsign] then
        if RedGCI._ctx_next > 8 then
            env.error("[RedGCI] Kontext-Pool voll (max 8 gleichzeitige Intercepts)")
            return nil
        end
        RedGCI._ctx_map[callsign] = RedGCI._ctx_next
        RedGCI._ctx_next = RedGCI._ctx_next + 1
        _gci.gci_fsm_reset(RedGCI._ctx_map[callsign])
        env.info("[RedGCI] Neuer Kontext " .. RedGCI._ctx_map[callsign] ..
                 " für " .. callsign)
    end
    return RedGCI._ctx_map[callsign]
end

function RedGCI.releaseCtx(callsign)
    local id = RedGCI._ctx_map[callsign]
    if id then
        _gci.gci_fsm_reset(id)
        RedGCI._ctx_map[callsign] = nil
        env.info("[RedGCI] Kontext " .. id .. " freigegeben (" .. callsign .. ")")
    end
end

function RedGCI.computeIntercept(fighter, target)
    -- DEBUG
    local dx = target.x - fighter.x
    local dz = target.z - fighter.z
    env.info(string.format("[DEBUG] F: x=%.0f y=%.0f z=%.0f spd=%.0f | T: x=%.0f y=%.0f z=%.0f | dx=%.0f dz=%.0f | raw_bearing=%.0f",
        fighter.x, fighter.y, fighter.z, fighter.spd,
        target.x, target.y, target.z,
        dx, dz,
        math.deg(math.atan2(dz, dx)) % 360))

    -- NEU: Velocity debug
    env.info(string.format("[DEBUG_VEL] F: vx=%.1f vy=%.1f vz=%.1f | T: vx=%.1f vy=%.1f vz=%.1f",
        fighter.vx, fighter.vy, fighter.vz,
        target.vx, target.vy, target.vz))

    return _gci.gci_compute_intercept(
        fighter.x, fighter.y, fighter.z, fighter.spd,
        fighter.vx, fighter.vy, fighter.vz,
        target.x,  target.y,  target.z,  target.spd,
        target.vx, target.vy, target.vz)
end

-- Wrapper: FSM-State aktualisieren
function RedGCI.fsmUpdate(callsign, range, aspect, closure, alt_delta, fuel,
                           pilot_radar, pilot_visual, threat)
    local id = RedGCI.getCtxId(callsign)
    if not id then return nil, nil end
    return _gci.gci_fsm_update(id, range, aspect, closure, alt_delta, fuel,
                           pilot_radar or false,
                           pilot_visual or false,
                           threat or false)
end

-- buildTransmission: übergibt jetzt auch target_alt (arg 10)
-- Rückgabe: silence, token_str, weapons_free, delay  (4 statt 5)
function RedGCI.buildTransmission(callsign, hdg, tti, mode, wf,
                                   ip_x, ip_z, ip_y, target_alt)
    local id = RedGCI.getCtxId(callsign)
    if not id then return true, "", false, 3.0 end
    return _gci.gci_fsm_transmission(
        id, callsign,
        hdg, tti, mode, wf,
        ip_x or 0, ip_z or 0, ip_y or 0,
        target_alt or 0)
end

-- Wrapper: Merge aktualisieren
function RedGCI.mergeUpdate(callsign, rel_bearing, range, alt_delta, splash)
    local id = RedGCI.getCtxId(callsign)
    if not id then return "ENTRY", "", "", true end
    return _gci.gci_merge_update(id, callsign, rel_bearing, range, alt_delta,
                             splash or false)
end

-- Wrapper: Reset nach Splash oder RTB
function RedGCI.reset(callsign)
    RedGCI.releaseCtx(callsign)
end

env.info("[RedGCI] Mission-API bereit")
