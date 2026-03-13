--[[
  GCI Bridge — Phase 2 (DLL)
  ═══════════════════════════════════════════════════════════════
  Läuft in der DCS Mission-Sandbox.
  Nutzt RedGCI API aus gci_mission.lua — kein UDP, kein Export.lua.

  Voraussetzung:
    gci_mission.lua muss via MissionScripting.lua geladen sein:
      dofile(lfs.writedir()..[[Mods\Services\RedGCI\Scripts\gci_mission.lua]])

  Diese Datei per DO SCRIPT FILE Trigger in der Mission laden.
]]

-- ──────────────────────────────────────────────────────────────
--  Sicherheitscheck
-- ──────────────────────────────────────────────────────────────

if not RedGCI then
    env.error("[GCI_BRIDGE] RedGCI nicht geladen — gci_mission.lua fehlt!")
    return
end

-- ──────────────────────────────────────────────────────────────
--  Logging
-- ──────────────────────────────────────────────────────────────

local function gci_log(msg)
    if RedGCI.DEBUG then
        env.info("[GCI_BRIDGE] " .. msg)
    end
end

-- ──────────────────────────────────────────────────────────────
--  Unit-Daten aus DCS (voller Sandbox-Zugriff)
-- ──────────────────────────────────────────────────────────────

local function get_unit_data(group_name)
    local grp = Group.getByName(group_name)
    if not grp then return nil end
    for _, u in ipairs(grp:getUnits()) do
        if u and u:isExist() and u:isActive() then
            local p   = u:getPoint()
            local v   = u:getVelocity()
            local spd = math.sqrt(v.x^2 + v.z^2)
            return {
                x    = p.x,
                z    = p.z,
                y    = p.y,
                spd  = spd,
                vx   = v.x,
                vz   = v.z,
                vy   = v.y,
                fuel = u:getFuel(),
            }
        end
    end
    return nil
end

-- ──────────────────────────────────────────────────────────────
--  Transmission anzeigen (mit Funkverzögerung)
-- ──────────────────────────────────────────────────────────────

local function display_transmission(silence, text_ru, text_en, wf, delay)
    if silence or not text_ru or text_ru == "" then return end

    timer.scheduleFunction(function()
        trigger.action.outTextForCoalition(
            RedGCI.COALITION,
            "[GCI] " .. text_ru,
            RedGCI.SUBTITLE_TIME)

        if wf then
            trigger.action.outTextForCoalition(
                RedGCI.COALITION,
                "*** ЦЕЛЬ РАЗРЕШЕНА ***",
                3)
        end

        if RedGCI.DEBUG and text_en and text_en ~= "" then
            env.info("[GCI_BRIDGE] EN: " .. text_en)
        end

        return nil
    end, nil, timer.getTime() + (delay or 3.0))
end

-- ──────────────────────────────────────────────────────────────
--  Pilot-Flags (gesetzt via F10-Menü oder Events)
-- ──────────────────────────────────────────────────────────────

local pilot_flags = {
    radar  = false,
    visual = false,
    threat = false,
}

-- ──────────────────────────────────────────────────────────────
--  Haupt-Tick
-- ──────────────────────────────────────────────────────────────

local function gci_tick(_, now)
    -- Einheiten holen
    local f = get_unit_data(RedGCI.FIGHTER_GROUP)
    local t = get_unit_data(RedGCI.TARGET_GROUP)

    if not f then
        gci_log("Jäger '" .. RedGCI.FIGHTER_GROUP .. "' nicht gefunden")
        return now + RedGCI.TICK_INTERVAL
    end
    if not t then
        gci_log("Ziel '" .. RedGCI.TARGET_GROUP .. "' nicht gefunden")
        return now + RedGCI.TICK_INTERVAL
    end

    -- 1. Intercept-Geometrie berechnen (C-Kern via RedGCI API)
    local hdg, tti, mode, wf, range, aspect, ip_x, ip_z, ip_y =
        RedGCI.computeIntercept(f, t)

    if mode == "NONE" then
        gci_log("Keine Intercept-Lösung (Jäger zu langsam?)")
        return now + RedGCI.TICK_INTERVAL
    end

    -- Closure Rate berechnen
    local dx   = t.x - f.x
    local dz   = t.z - f.z
    local dist = math.sqrt(dx*dx + dz*dz)
    local closure = 0
    if dist > 1 then
        closure = -((t.vx - f.vx) * dx/dist + (t.vz - f.vz) * dz/dist)
    end

    -- 2. FSM aktualisieren (C-Kern)
    local state, ticks = RedGCI.fsmUpdate(
        RedGCI.CALLSIGN,
        range, aspect, closure, t.y - f.y, f.fuel,
        pilot_flags.radar,
        pilot_flags.visual,
        pilot_flags.threat)

    if not state then
        gci_log("FSM Fehler")
        return now + RedGCI.TICK_INTERVAL
    end

    -- 3. Merge-Phase
    if state == "MERGE" then
        -- Relative Peilung berechnen
        local fighter_hdg = math.atan2(f.vx, f.vz)
        local to_target   = math.atan2(t.x - f.x, t.z - f.z)
        local rel_bearing = math.deg(to_target - fighter_hdg) % 360

        local phase, ru, en, silence =
            RedGCI.mergeUpdate(RedGCI.CALLSIGN,
                rel_bearing, range, t.y - f.y, false)

        display_transmission(silence, ru, en, false, 2.0)
        gci_log(string.format("[%s/%s] %.0fm → %s",
            state, phase, range, silence and "SILENCE" or ru))
        return now + RedGCI.TICK_INTERVAL
    end

    -- 4. Transmission bauen (C-Kern)
    local silence, text_ru, text_en, weapons_free, delay =
        RedGCI.buildTransmission(RedGCI.CALLSIGN,
            hdg, tti, mode, wf, ip_x, ip_z, ip_y)

    -- 5. Anzeigen
    display_transmission(silence, text_ru, text_en, weapons_free, delay)

    gci_log(string.format("[%s] HDG:%d TTI:%ds MODE:%s WF:%s RANGE:%.0fm ASPECT:%.1f° → %s",
        state, math.floor(hdg), math.floor(tti or 0), mode,
        tostring(wf), range, aspect,
        silence and "SILENCE" or text_ru))

    return now + RedGCI.TICK_INTERVAL
end

-- ──────────────────────────────────────────────────────────────
--  F10-Menü
-- ──────────────────────────────────────────────────────────────

local function setup_f10_menu()
    local root = missionCommands.addSubMenuForCoalition(
        RedGCI.COALITION, "GCI")

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Radar Lock", root,
        function()
            pilot_flags.radar  = true
            pilot_flags.visual = false
            gci_log("Pilot: Radar Lock")
        end)

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Visual Contact", root,
        function()
            pilot_flags.visual = true
            gci_log("Pilot: Visual Contact")
        end)

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Threat (RWR)", root,
        function()
            pilot_flags.threat = true
            gci_log("Pilot: Threat")
        end)

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Splash / Kill", root,
        function()
            local phase, ru, en, silence =
                RedGCI.mergeUpdate(RedGCI.CALLSIGN, 0, 0, 0, true)
            display_transmission(silence, ru, en, false, 1.0)
            RedGCI.reset(RedGCI.CALLSIGN)
            pilot_flags = { radar=false, visual=false, threat=false }
            gci_log("Ziel vernichtet — Reset")
        end)

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Reset GCI", root,
        function()
            pilot_flags = { radar=false, visual=false, threat=false }
            RedGCI.reset(RedGCI.CALLSIGN)
            gci_log("GCI Reset")
        end)
end

-- ──────────────────────────────────────────────────────────────
--  Initialisierung
-- ──────────────────────────────────────────────────────────────

local function GCI_init()
    -- Kontext initialisieren
    RedGCI.getCtxId(RedGCI.CALLSIGN)

    -- F10-Menü aufbauen
    setup_f10_menu()

    -- Tick-Loop starten (erste Ausführung nach 2s)
    timer.scheduleFunction(gci_tick, nil, timer.getTime() + 2.0)

    -- Startmeldung
    trigger.action.outTextForCoalition(
        RedGCI.COALITION,
        "[GCI] Системы готовы. Жду цель.",
        5)

    env.info("[GCI_BRIDGE] Bereit. Jäger='" .. RedGCI.FIGHTER_GROUP ..
             "' Ziel='" .. RedGCI.TARGET_GROUP .. "'")
end

GCI_init()
