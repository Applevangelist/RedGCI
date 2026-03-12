--[[
  GCI Bridge — Mission Script
  ═══════════════════════════════════════════════════════════════
  Diese Datei wird im Mission Editor unter
  "Triggers → DO SCRIPT FILE" geladen.

  Sie ermöglicht:
  - F10-Menü für Pilot-Meldungen (Radar Lock, Visual)
  - Automatische Zielzerstörungs-Erkennung
  - Manuelle Pilot-Rückmeldungen via Trigger

  ACHTUNG: Läuft in der DCS Mission Sandbox (kein socket, kein io)
  Kommunikation mit Export.lua über globale Funktionen die
  Export.lua bereitstellt.
]]

local GCI_BRIDGE = {}

-- ──────────────────────────────────────────────────────────────
--  F10 Menü aufbauen
-- ──────────────────────────────────────────────────────────────

local function setup_radio_menu()
    local root = missionCommands.addSubMenuForCoalition(
        coalition.side.RED, "GCI Meldungen")

    -- Pilot meldet Radar-Lock
    missionCommands.addCommandForCoalition(
        coalition.side.RED,
        "Захват есть (Radar Lock)",
        root,
        function()
            -- Export.lua Funktion aufrufen (läuft im selben Lua-State)
            if GCI_pilot_has_radar then
                GCI_pilot_has_radar("f1")
                trigger.action.outTextForCoalition(
                    coalition.side.RED,
                    "→ GCI: Захват подтверждён", 4)
            end
        end)

    -- Radar-Lock verloren
    missionCommands.addCommandForCoalition(
        coalition.side.RED,
        "Захват потерян (Lock Lost)",
        root,
        function()
            if GCI_pilot_lost_radar then
                GCI_pilot_lost_radar("f1")
                trigger.action.outTextForCoalition(
                    coalition.side.RED,
                    "→ GCI: Потеря захвата", 4)
            end
        end)

    -- Visueller Kontakt
    missionCommands.addCommandForCoalition(
        coalition.side.RED,
        "Вижу цель (Visual Contact)",
        root,
        function()
            if GCI_pilot_has_visual then
                GCI_pilot_has_visual("f1")
                trigger.action.outTextForCoalition(
                    coalition.side.RED,
                    "→ GCI: Визуальный подтверждён", 4)
            end
        end)
end


-- ──────────────────────────────────────────────────────────────
--  Automatische Zielzerstörungs-Erkennung
--  (via Polling — DCS Events sind in Sandbox verfügbar)
-- ──────────────────────────────────────────────────────────────

local target_was_alive = true

local function check_target_destroyed()
    local target_grp = Group.getByName("Target")
    if not target_grp then return end

    local alive = false
    for _, u in ipairs(target_grp:getUnits()) do
        if u:isExist() and u:getLife() > 0 then
            alive = true
            break
        end
    end

    if target_was_alive and not alive then
        target_was_alive = false
        -- Splash melden
        if GCI_target_destroyed then
            GCI_target_destroyed()
        end
    end
end

-- Event-Handler für sauberere Erkennung
local splash_handler = {}
function splash_handler:onEvent(event)
    if event.id == world.event.S_EVENT_DEAD then
        local obj = event.initiator
        if obj and obj:getGroup() then
            local grp_name = obj:getGroup():getName()
            if grp_name == "Target" then
                if GCI_target_destroyed then
                    GCI_target_destroyed()
                end
            end
        end
    end
end
world.addEventHandler(splash_handler)

-- Timer alle 1s prüfen ob neue Transmission vorliegt
local function GCI_display_tick()
    if GCI_last_transmission then
        local tx = GCI_last_transmission
        GCI_last_transmission = nil  -- konsumieren

        trigger.action.outTextForCoalition(
            coalition.side.RED,
            tx.text,
            8)

        if tx.wf then
            trigger.action.outSoundForCoalition(
                coalition.side.RED, "warning.ogg")
        end
    end
    return timer.getTime() + 1.0  -- nächster Check in 1s
end

timer.scheduleFunction(GCI_display_tick, nil, timer.getTime() + 2.0)

-- ──────────────────────────────────────────────────────────────
--  Init
-- ──────────────────────────────────────────────────────────────

setup_radio_menu()

-- Polling-Fallback (falls Event-Handler nicht greift)
timer.scheduleFunction(function()
    check_target_destroyed()
    return timer.getTime() + 3
end, nil, timer.getTime() + 3)

log.write("GCI_BRIDGE", log.INFO, "GCI Bridge geladen")
