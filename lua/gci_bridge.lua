--[[
  GCI Bridge — Phase 2 (DLL) + AI-Steuerung
  ═══════════════════════════════════════════════════════════════
  Läuft in der DCS Mission-Sandbox.
  Nutzt RedGCI API aus gci_mission.lua.

  Voraussetzung:
    gci_mission.lua muss via MissionScripting.lua geladen sein.
    Diese Datei per DO SCRIPT FILE Trigger in der Mission laden.

  AI-Modus (RedGCI.IS_AI_PLANE = true in Config\RedGCI.lua):
    VECTOR:         Rollender Wegpunkt zum Intercept-Punkt (jeden Tick)
                    Geclampt auf WP_DISTANCE_FACTOR × speed × tick_interval
    COMMIT:         Radar AN + Wegpunkt auf Intercept-Punkt
    RADAR_CONTACT:  Kein weiterer WP-Push — AI hält Kurs
    ABORT/RTB:      Radar AUS + Wegpunkt auf HOME_BASE
]]

-- ──────────────────────────────────────────────────────────────
--  Sicherheitscheck
-- ──────────────────────────────────────────────────────────────

if not RedGCI then
    env.error("[GCI_BRIDGE] RedGCI nicht geladen — gci_mission.lua fehlt!")
    return
end

-- ──────────────────────────────────────────────────────────────
--  Konfiguration
-- ──────────────────────────────────────────────────────────────

-- AI-Steuerung: true = Bridge pusht Wegpunkte und schaltet Radar
-- Kann auch in Config\RedGCI.lua gesetzt werden:
--   RedGCI.IS_AI_PLANE = true
--   RedGCI.HOME_BASE   = { x = -125000, z = 760000 }
RedGCI.IS_AI_PLANE = true --RedGCI.IS_AI_PLANE or false
RedGCI.HOME_BASE   = AIRBASE:FindByName(AIRBASE.Caucasus.Nalchik):GetVec2() --RedGCI.HOME_BASE   or nil
RedGCI.DEBUG = true

-- Wegpunkt-Lookahead: WP wird auf diesen Faktor × speed × tick geclampt
-- 1.5 = AI bekommt Wegpunkt 1.5 Ticks voraus — verhindert Überschießen
local WP_DISTANCE_FACTOR = 1.5

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
            local pos3 = u:getPosition()  -- Position3: .p=Vec3, .x=forward, .y=up, .z=right
            local p    = pos3.p           -- Vec3: x=Nord, y=Höhe, z=Ost
            local fwd  = pos3.x           -- forward Vec3: x=Nord, z=Ost
            local v    = u:getVelocity()  -- Vec3: x=Nord, y=Vertikal, z=Ost (m/s)
            return {
                x    = p.x,
                y    = p.y,
                z    = p.z,
                spd  = math.sqrt(v.x*v.x + v.z*v.z),
                vx   = v.x, vy = v.y, vz = v.z,
                hdg  = math.deg(math.atan2(fwd.z, fwd.x)) % 360,
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
--  AI: Wegpunkt setzen
--
--  DCS route.points Koordinaten:
--    x   = Ost  (gleich wie DCS Vec3.x)
--    y   = Nord (gleich wie DCS Vec3.z — NICHT Vec3.y!)
--    alt = Höhe MSL in Metern
-- ──────────────────────────────────────────────────────────────

local function push_waypoint(group_name, wx, wz, wy, speed_mps)
    if not RedGCI.IS_AI_PLANE then return end
    
    local route = {}
    local grp = GROUP:FindByName(group_name)
    local tsk = grp:TaskAerobatics()
    tsk = grp:TaskAerobaticsStraightFlight(tsk,1,math.max(wy, 300), UTILS.MpsToKmph(speed_mps),UseSmoke,StartImmediately,10)
    local startpoint = grp:GetCoordinate()
    local wp0 = startpoint:WaypointAir(COORDINATE.WaypointAltType.BARO,COORDINATE.WaypointType.TurningPoint,COORDINATE.WaypointAction.FlyoverPoint,
      UTILS.MpsToKmph(speed_mps),true,airbase,DCSTasks,"VECTOR")
    
    local endpoint = COORDINATE:New(wx,math.max(wy, 300),wz)
    endpoint:MarkToAll("Vector",ReadOnly,"Vector")
    local wp1 = endpoint:WaypointAir(COORDINATE.WaypointAltType.BARO,COORDINATE.WaypointType.TurningPoint,COORDINATE.WaypointAction.FlyoverPoint,
      UTILS.MpsToKmph(speed_mps),true,airbase,DCSTasks,"VECTOR")
    
    table.insert(route,wp0)
    table.insert(route,wp1) 
    
    grp:Route(route,0.2)
    
    gci_log(string.format("WP → x=%.0f z=%.0f alt=%.0fm", wx, wz, wy))
end

-- ──────────────────────────────────────────────────────────────
--  AI: Rollenden Wegpunkt berechnen
--
--  Clampt den Intercept-Punkt auf max_dist vom Jäger.
--  Verhindert dass die AI bei fernem WP zu weit überschießt.
-- ──────────────────────────────────────────────────────────────

local function compute_rolling_waypoint(fighter, ip_x, ip_z, ip_y)
    local dx   = ip_x - fighter.x
    local dz   = ip_z - fighter.z
    local dist = math.sqrt(dx*dx + dz*dz)

    -- Maximale Lookahead-Distanz
    local max_dist = fighter.spd * RedGCI.TICK_INTERVAL * WP_DISTANCE_FACTOR

    if dist <= max_dist or dist < 1 then
        return ip_x, ip_z, ip_y
    end

    -- Auf max_dist clampen — Richtung beibehalten
    local nx = dx / dist
    local nz = dz / dist
    return fighter.x + nx * max_dist,
           fighter.z + nz * max_dist,
           ip_y
end

-- ──────────────────────────────────────────────────────────────
--  AI: Radar schalten
-- ──────────────────────────────────────────────────────────────

local function set_radar(group_name, on)
    if not RedGCI.IS_AI_PLANE then return end
    
    local grp = GROUP:FindByName(group_name)
    
    if on == true then
      grp:SetOptionRadarUsingForContinousSearch()
    else
      grp:SetOptionRadarUsingNever()
    end
    
   -- local grp = Group.getByName(group_name)
    --if not grp then return end

    --for _, u in ipairs(grp:getUnits()) do
      --  if u and u:isExist() then
        --    u:enableEmission(on)
        --end
    --end
    gci_log("Radar " .. (on and "AN" or "AUS"))
end

-- ──────────────────────────────────────────────────────────────
--  State-Tracking
-- ──────────────────────────────────────────────────────────────

local pilot_flags = {
    radar  = false,
    visual = false,
    threat = false,
}

local prev_state = nil

-- ──────────────────────────────────────────────────────────────
--  Haupt-Tick
-- ──────────────────────────────────────────────────────────────

local function gci_tick(_, now)
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

    -- 1. Intercept-Geometrie (C-Kern)
    local hdg, tti, mode, wf, range, aspect, ip_x, ip_z, ip_y =
        RedGCI.computeIntercept(f, t)
    
     env.info(string.format("hdg=%d | tti=%d | mode=%s | wf= %s | range= %d |aspect= %d |ip_x= %d | ip_z=%d | ip_y=%d",hdg, tti, mode, tostring(wf), range, aspect, ip_x, ip_z, ip_y))
    
    if mode == "NONE" then
        gci_log("Keine Intercept-Lösung (Jäger zu langsam?)")
        return now + RedGCI.TICK_INTERVAL
    end

    -- 2. Closure Rate
    local dx   = t.x - f.x
    local dz   = t.z - f.z
    local dist = math.sqrt(dx*dx + dz*dz)
    local closure = 0
    if dist > 1 then 
        closure = -((t.vx - f.vx) * dx/dist + (t.vz - f.vz) * dz/dist)
    end

    -- 3. AI: automatischer Radar-Lock wenn in COMMIT und Range < 40km
    local ai_radar_lock = RedGCI.IS_AI_PLANE
                          and prev_state == "COMMIT"
                          and range < 40000

    -- 4. FSM aktualisieren (C-Kern)
    local state, ticks = RedGCI.fsmUpdate(
        RedGCI.CALLSIGN,
        range, aspect, closure, t.y - f.y, f.fuel,
        pilot_flags.radar or ai_radar_lock,
        pilot_flags.visual,
        pilot_flags.threat)

    if not state then
        gci_log("FSM Fehler")
        return now + RedGCI.TICK_INTERVAL
    end

    -- 5. State-Transition Aktionen
    if state ~= prev_state then
        gci_log("State: " .. (prev_state or "START") .. " → " .. state)

        if state == "COMMIT" then
            -- Radar AN + präziser Wegpunkt auf Intercept-Punkt
            set_radar(RedGCI.FIGHTER_GROUP, true)
            push_waypoint(RedGCI.FIGHTER_GROUP,
                ip_x, ip_z, ip_y, f.spd)

        elseif state == "ABORT" or state == "RTB" then
            set_radar(RedGCI.FIGHTER_GROUP, false)
            if RedGCI.HOME_BASE then
                push_waypoint(RedGCI.FIGHTER_GROUP,
                    RedGCI.HOME_BASE.x,
                    RedGCI.HOME_BASE.z,
                    1000, f.spd * 0.8)
            end
        end
    end

    -- 6. VECTOR: rollender Wegpunkt jeden Tick
    if state == "VECTOR" then
        local wp_x, wp_z, wp_y = compute_rolling_waypoint(
            f, ip_x, ip_z,
            ip_y + 700)  -- +700m Look-Down Offset (N019 Doktrin)
        set_radar(RedGCI.FIGHTER_GROUP,false)
        push_waypoint(RedGCI.FIGHTER_GROUP, wp_x, wp_z, wp_y, f.spd)
    end

    -- 7. Merge-Phase
    if state == "MERGE" then
        local fighter_hdg = math.atan2(f.vx, f.vz)
        local to_target   = math.atan2(t.x - f.x, t.z - f.z)
        local rel_bearing = math.deg(to_target - fighter_hdg) % 360

        local phase, ru, en, silence =
            RedGCI.mergeUpdate(RedGCI.CALLSIGN,
                rel_bearing, range, t.y - f.y, false)

        display_transmission(silence, ru, en, false, 2.0)
        gci_log(string.format("[%s/%s] %.0fm → %s",
            state, phase, range, silence and "SILENCE" or ru))

        prev_state = state
        return now + RedGCI.TICK_INTERVAL
    end

    -- 8. Transmission bauen + anzeigen
    local silence, text_ru, text_en, weapons_free, delay =
        RedGCI.buildTransmission(RedGCI.CALLSIGN,
            hdg, tti, mode, wf, ip_x, ip_z, ip_y)

    display_transmission(silence, text_ru, text_en, weapons_free, delay)

    gci_log(string.format(
        "[%s] HDG:%d TTI:%ds MODE:%s WF:%s RANGE:%.0fm ASPECT:%.1f° → %s",
        state, math.floor(hdg), math.floor(tti or 0), mode,
        tostring(wf), range, aspect,
        silence and "SILENCE" or text_ru))

    prev_state = state
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
            set_radar(RedGCI.FIGHTER_GROUP, false)
            pilot_flags = { radar=false, visual=false, threat=false }
            prev_state  = nil
            gci_log("Splash — Reset")
        end)

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Reset GCI", root,
        function()
            pilot_flags = { radar=false, visual=false, threat=false }
            prev_state  = nil
            RedGCI.reset(RedGCI.CALLSIGN)
            set_radar(RedGCI.FIGHTER_GROUP, false)
            gci_log("GCI Reset")
        end)

    missionCommands.addCommandForCoalition(
        RedGCI.COALITION, "Toggle AI Mode", root,
        function()
            RedGCI.IS_AI_PLANE = not RedGCI.IS_AI_PLANE
            local status = RedGCI.IS_AI_PLANE and "AN" or "AUS"
            trigger.action.outTextForCoalition(
                RedGCI.COALITION, "[GCI] AI-Modus " .. status, 3)
            gci_log("AI-Modus: " .. status)
        end)
end

-- ──────────────────────────────────────────────────────────────
--  Initialisierung
-- ──────────────────────────────────────────────────────────────

local function GCI_init()
    RedGCI.getCtxId(RedGCI.CALLSIGN)
    setup_f10_menu()

    timer.scheduleFunction(gci_tick, nil, timer.getTime() + 2.0)

    local mode_str = RedGCI.IS_AI_PLANE and " [AI]" or " [Human]"
    trigger.action.outTextForCoalition(
        RedGCI.COALITION,
        "[GCI] Системы готовы. Жду цель." .. mode_str,
        5)

    env.info("[GCI_BRIDGE] Bereit. Jäger='" .. RedGCI.FIGHTER_GROUP ..
             "' Ziel='" .. RedGCI.TARGET_GROUP ..
             "' Modus=" .. (RedGCI.IS_AI_PLANE and "AI" or "Human"))
end

GCI_init()
