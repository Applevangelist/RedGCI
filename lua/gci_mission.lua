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
RedGCI.TICK_INTERVAL  = RedGCI.TICK_INTERVAL  or 5.0
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

local ok, _gci = pcall(require, "gci_core")
if not ok then
    env.error("[RedGCI] gci_core.dll konnte nicht geladen werden: " .. tostring(_gci))
    return
end

-- gci_version() ist jetzt global (registriert von luaopen_gci)
env.info("[RedGCI] " .. gci_version() .. " geladen")

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
        gci_fsm_reset(RedGCI._ctx_map[callsign])
        env.info("[RedGCI] Neuer Kontext " .. RedGCI._ctx_map[callsign] ..
                 " für " .. callsign)
    end
    return RedGCI._ctx_map[callsign]
end

function RedGCI.releaseCtx(callsign)
    local id = RedGCI._ctx_map[callsign]
    if id then
        gci_fsm_reset(id)
        RedGCI._ctx_map[callsign] = nil
        env.info("[RedGCI] Kontext " .. id .. " freigegeben (" .. callsign .. ")")
    end
end

-- Wrapper: Intercept berechnen
function RedGCI.computeIntercept(fighter, target)
    return gci_compute_intercept(
        fighter.x,   fighter.z,   fighter.y,   fighter.spd,
        fighter.vx,  fighter.vz,  fighter.vy,
        target.x,    target.z,    target.y,    target.spd,
        target.vx,   target.vz,   target.vy)
end

-- Wrapper: FSM-State aktualisieren
function RedGCI.fsmUpdate(callsign, range, aspect, closure, alt_delta, fuel,
                           pilot_radar, pilot_visual, threat)
    local id = RedGCI.getCtxId(callsign)
    if not id then return nil, nil end
    return gci_fsm_update(id, range, aspect, closure, alt_delta, fuel,
                           pilot_radar or false,
                           pilot_visual or false,
                           threat or false)
end

-- Wrapper: Transmission bauen
function RedGCI.buildTransmission(callsign, hdg, tti, mode, wf, ip_x, ip_z, ip_y)
    local id = RedGCI.getCtxId(callsign)
    if not id then return true, "", "", false, 3.0 end
    return gci_fsm_transmission(id, callsign, hdg, tti, mode, wf,
                                 ip_x or 0, ip_z or 0, ip_y or 0)
end

-- Wrapper: Merge aktualisieren
function RedGCI.mergeUpdate(callsign, rel_bearing, range, alt_delta, splash)
    local id = RedGCI.getCtxId(callsign)
    if not id then return "ENTRY", "", "", true end
    return gci_merge_update(id, callsign, rel_bearing, range, alt_delta,
                             splash or false)
end

-- Wrapper: Reset nach Splash oder RTB
function RedGCI.reset(callsign)
    RedGCI.releaseCtx(callsign)
end

env.info("[RedGCI] Mission-API bereit")