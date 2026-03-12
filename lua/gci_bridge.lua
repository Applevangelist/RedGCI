--[[
  GCI Bridge — Phase 2 (DLL)
  ═══════════════════════════════════════════════════════════════
  Läuft in der DCS Mission-Sandbox.
  Nutzt gci_core.dll direkt — kein UDP, kein Export.lua nötig.

  Voraussetzung:
    MissionScripting.lua einmalig patchen (vor sanitizeModule):
      local _path = lfs.writedir() .. "Scripts\\gci_core.dll"
      if lfs.attributes(_path) then
          package.loadlib(_path, "luaopen_gci")()
      end

  Dann diese Datei per DO SCRIPT FILE Trigger laden.
]]

-- ──────────────────────────────────────────────────────────────
--  Konfiguration
-- ──────────────────────────────────────────────────────────────

local GCI_CFG = {
    fighter_group  = "Mig-29A",
    target_group   = "Target",
    callsign       = "Сокол-1",
    tick_interval  = 5.0,
    subtitle_time  = 8,
    coalition      = coalition.side.RED,
    debug          = true,

    -- MSRS (Phase 3 — noch nicht aktiv)
    -- srs_path    = "D:\\SRS",
    -- srs_freq    = 251.0,
    -- srs_voice   = MSRS.Voices.Google.Russian.Female,
}

-- Kontext-ID für diesen Intercept (1 = erster Slot im C-Pool)
local CTX_ID = 1

-- ──────────────────────────────────────────────────────────────
--  Logging
-- ──────────────────────────────────────────────────────────────

local function gci_log(msg)
    if GCI_CFG.debug then
        env.info("[GCI_BRIDGE] " .. msg)
    end
end

-- ──────────────────────────────────────────────────────────────
--  DLL-Verfügbarkeit prüfen
-- ──────────────────────────────────────────────────────────────

local function check_dll()
    if not gci_version then
        env.error("[GCI_BRIDGE] gci_core.dll nicht geladen! "
               .. "MissionScripting.lua Hook fehlt.")
        return false
    end
    gci_log("DLL geladen: " .. gci_version())
    return true
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
                unit = u,
            }
        end
    end
    return nil
end

-- ──────────────────────────────────────────────────────────────
--  Transmission anzeigen
-- ──────────────────────────────────────────────────────────────

local function display_transmission(silence, text_ru, text_en, wf, delay)
    if silence then return end

    -- Verzögerung simulieren (historisch realistisch: 3-8s)
    timer.scheduleFunction(function()
        trigger.action.outTextForCoalition(
            GCI_CFG.coalition,
            "[GCI] " .. text_ru,
            GCI_CFG.subtitle_time)

        if GCI_CFG.debug and text_en ~= "" then
            gci_log("EN: " .. text_en)
        end

        if wf then
            -- Waffenfreigabe visuell hervorheben
            trigger.action.outTextForCoalition(
                GCI_CFG.coalition,
                "*** ЦЕЛЬ РАЗРЕШЕНА ***",
                3)
        end

        return nil  -- einmaliger Timer
    end, nil, timer.getTime() + (delay or 3.0))
end

-- ──────────────────────────────────────────────────────────────
--  Pilot-Ereignisse (per F10-Menü oder Trigger aufrufbar)
-- ──────────────────────────────────────────────────────────────

GCI_pilot_radar_on = function()
    local ctx = gci_fsm_update(CTX_ID,
        0, 0, 0, 0,             -- range/aspect/closure/alt_delta (unverändert)
        -1,                      -- fuel: -1 = nicht ändern (TODO: API erweitern)
        true, false, false)
    gci_log("Pilot meldet Radar-Lock")
end

GCI_pilot_visual = function()
    gci_log("Pilot meldet Sichtkontakt")
    -- wird im nächsten Tick durch pilot_has_visual=true verarbeitet
end

GCI_target_splash = function()
    local phase, ru, en, silence =
        gci_merge_update(CTX_ID, GCI_CFG.callsign, 0, 0, 0, true)
    display_transmission(silence, ru, en, false, 1.0)
    gci_fsm_reset(CTX_ID)
    gci_log("Ziel vernichtet — Kontext zurückgesetzt")
end

-- ──────────────────────────────────────────────────────────────
--  Haupt-Tick
-- ──────────────────────────────────────────────────────────────

-- Pilot-Flags (werden durch F10-Menü oder Events gesetzt)
local pilot_flags = {
    radar   = false,
    visual  = false,
    threat  = false,
}

local function gci_tick(_, now)
    -- Einheiten holen (voller DCS-Zugriff in Sandbox)
    local f = get_unit_data(GCI_CFG.fighter_group)
    local t = get_unit_data(GCI_CFG.target_group)

    if not f then
        gci_log("Jäger '" .. GCI_CFG.fighter_group .. "' nicht gefunden")
        return now + GCI_CFG.tick_interval
    end
    if not t then
        gci_log("Ziel '" .. GCI_CFG.target_group .. "' nicht gefunden")
        return now + GCI_CFG.tick_interval
    end

    -- 1. Intercept-Geometrie berechnen (C-Kern)
    local hdg, tti, mode, wf, range, aspect, ip_x, ip_z, ip_y =
        gci_compute_intercept(
            f.x, f.z, f.y, f.spd, f.vx, f.vz, f.vy,
            t.x, t.z, t.y, t.spd, t.vx, t.vz, t.vy)

    if mode == "NONE" then
        gci_log("Keine Intercept-Lösung (Jäger zu langsam?)")
        return now + GCI_CFG.tick_interval
    end

    -- Closure Rate berechnen (für FSM)
    local dx = t.x - f.x
    local dz = t.z - f.z
    local dist = math.sqrt(dx*dx + dz*dz)
    local closure = 0
    if dist > 1 then
        closure = -((t.vx - f.vx) * dx/dist + (t.vz - f.vz) * dz/dist)
    end

    -- 2. FSM aktualisieren (C-Kern)
    local state, ticks =
        gci_fsm_update(CTX_ID,
            range, aspect, closure, t.y - f.y, f.fuel,
            pilot_flags.radar, pilot_flags.visual, pilot_flags.threat)

    -- 3. Merge-Check
    if state == "MERGE" then
        local rel_bearing = 0  -- TODO: aus Geometrie berechnen
        local phase, ru, en, silence =
            gci_merge_update(CTX_ID, GCI_CFG.callsign,
                rel_bearing, range, t.y - f.y, false)
        display_transmission(silence, ru, en, false, 2.0)
        gci_log(string.format("[%s/%s] %s", state, phase, ru))
        return now + GCI_CFG.tick_interval
    end

    -- 4. Transmission bauen (C-Kern)
    local silence, text_ru, text_en, weapons_free, delay =
        gci_fsm_transmission(CTX_ID, GCI_CFG.callsign,
            hdg, tti, mode, wf,
            ip_x, ip_z, ip_y)

    -- 5. Anzeigen
    display_transmission(silence, text_ru, text_en, weapons_free, delay)

    gci_log(string.format(
        "[%s] HDG:%d TTI:%ds MODE:%s WF:%s RANGE:%.0fm ASPECT:%.1f° → %s",
        state, math.floor(hdg), math.floor(tti), mode,
        tostring(wf), range, aspect,
        silence and "SILENCE" or text_ru))

    return now + GCI_CFG.tick_interval
end

-- ──────────────────────────────────────────────────────────────
--  F10-Menü (Pilot-Eingaben)
-- ──────────────────────────────────────────────────────────────

local function setup_f10_menu()
    local root = missionCommands.addSubMenuForCoalition(
        GCI_CFG.coalition, "GCI")

    missionCommands.addCommandForCoalition(
        GCI_CFG.coalition, "Radar Lock", root,
        function()
            pilot_flags.radar = true
            pilot_flags.visual = false
        end)

    missionCommands.addCommandForCoalition(
        GCI_CFG.coalition, "Visual Contact", root,
        function()
            pilot_flags.visual = true
        end)

    missionCommands.addCommandForCoalition(
        GCI_CFG.coalition, "Threat (RWR)", root,
        function()
            pilot_flags.threat = true
        end)

    missionCommands.addCommandForCoalition(
        GCI_CFG.coalition, "Splash / Kill", root,
        GCI_target_splash)

    missionCommands.addCommandForCoalition(
        GCI_CFG.coalition, "Reset GCI", root,
        function()
            pilot_flags = { radar=false, visual=false, threat=false }
            gci_fsm_reset(CTX_ID)
            gci_log("GCI Reset")
        end)
end

-- ──────────────────────────────────────────────────────────────
--  Initialisierung
-- ──────────────────────────────────────────────────────────────

local function GCI_init()
    if not check_dll() then return end

    gci_fsm_reset(CTX_ID)
    setup_f10_menu()

    -- Tick-Loop starten
    timer.scheduleFunction(gci_tick, nil, timer.getTime() + 2.0)

    gci_log("GCI Bridge Phase 2 bereit.")
    trigger.action.outTextForCoalition(
        GCI_CFG.coalition,
        "[GCI] Системы готовы. Жду цель.",
        5)
end

GCI_init()
