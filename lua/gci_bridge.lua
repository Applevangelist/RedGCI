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
--  Nachrichten-Tabellen (aus gci_messages.lua)
-- ──────────────────────────────────────────────────────────────

if not RedGCI.Messages or not RedGCI.DirTokens then
    env.error("[GCI_BRIDGE] RedGCI.Messages fehlt — gci_messages.lua vor gci_bridge.lua laden!")
    return
end

-- ──────────────────────────────────────────────────────────────
--  Konfiguration
-- ──────────────────────────────────────────────────────────────

-- ──────────────────────────────────────────────────────────────
--  Standardwerte (nach Config-Load, or-Pattern)
-- ────────────────────────────────────────────────────────────── 

RedGCI.IS_AI_PLANE = true --RedGCI.IS_AI_PLANE or false
RedGCI.HOMEBASENAME = AIRBASE.Caucasus.Nalchik
RedGCI.DEBUG = true
RedGCI.AIRBASE = AIRBASE:FindByName(RedGCI.HOMEBASENAME)
RedGCI.HOME_BASE   = RedGCI.AIRBASE:GetVec2() --RedGCI.HOME_BASE   or nil
RedGCI.FIGHTER_GROUP  = "Mig-29A"
RedGCI.TARGET_GROUP   = "Target"
RedGCI.CALLSIGN       = "Сокол-1"
RedGCI.TICK_INTERVAL  = 10
RedGCI.SUBTITLE_TIME  = 8
RedGCI.COALITION      = 1   -- 1=RED
RedGCI.DEBUG          = true
-- Locale-Einstellung (einmalig beim Start setzen)
RedGCI.LOCALE = "de"   -- "en" | "de" | "ru"
RedGCI.TX_REPEAT_INTERVAL = 30.0  -- Sekunden bis Wiederholung

-- Wegpunkt-Lookahead: WP wird auf diesen Faktor × speed × tick geclampt
-- 1.5 = AI bekommt Wegpunkt 1.5 Ticks voraus — verhindert Überschießen
local WP_DISTANCE_FACTOR = 5.0

-- ──────────────────────────────────────────────────────────────
--  Logging
-- ──────────────────────────────────────────────────────────────

local function gci_log(msg)
    if RedGCI.DEBUG then
        env.info("[GCI_BRIDGE] " .. msg)
    end
end

-- ─────────────────────────────────────────────────────────────
--  RedGCI — Token-System + MSRS Ausgabe
--  Abhängigkeiten: gci_messages.lua, MOOSE (TEXTANDSOUND, MSRSQUEUE)
-- ─────────────────────────────────────────────────────────────

-- ── 1. TextAndSound Instanz initialisieren ────────────────────
function RedGCI.InitLocalization()
    RedGCI.gettext = TEXTANDSOUND:New("RedGCI", "en")
    for locale, entries in pairs(RedGCI.Messages) do
        local loc = string.lower(tostring(locale))
        for id, text in pairs(entries) do
            RedGCI.gettext:AddEntry(loc, tostring(id), text)
        end
    end
end

-- ── 2. MSRS Queue initialisieren ─────────────────────────────
function RedGCI.InitSRS(path, channel, modulation, culture, voice, port)
    RedGCI.msrs = MSRS:New(path, channel, modulation)
    RedGCI.msrs:SetPort(port or 5002)
    RedGCI.msrs:SetLabel("GCI")
    RedGCI.msrs:SetCulture(culture or "ru-RU")
    RedGCI.msrs:SetVoice(voice or MSRS.Voices.Google.Standard.ru_RU_Standard_D)
    RedGCI.msrs:SetCoalition(coalition.side.RED)
    RedGCI.SRSQueue = MSRSQUEUE:New("RedGCI")
end

-- ── 3. Token-String parsen ────────────────────────────────────
--  Eingabe:  "VECTOR|hdg=165|alt=4500|tti_m=8|wf=false"
--  Ausgabe:  { key="VECTOR", hdg=165, alt=4500, tti_m=8, wf=false }
local function parse_tokens(token_str)
    if not token_str or token_str == "" then return nil end
    local parts = {}
    for part in string.gmatch(token_str, "[^|]+") do
        parts[#parts + 1] = part
    end
    local result = { key = parts[1] }
    for i = 2, #parts do
        local k, v = string.match(parts[i], "^(%w+)=(.+)$")
        if k and v then
            -- Typen-Konvertierung
            if v == "true"  then result[k] = true
            elseif v == "false" then result[k] = false
            elseif tonumber(v)  then result[k] = tonumber(v)
            else                     result[k] = v
            end
        end
    end
    return result
end

-- ── 4. gsub Platzhalter füllen ────────────────────────────────
--  Ersetzt {KEY} im Template mit Werten aus der vars-Tabelle
local function fill_template(template, vars)
    return (string.gsub(template, "{([%w_]+)}", function(key)
        return tostring(vars[key] or "")
    end))
end

-- ── 5. Richtungstoken auflösen ────────────────────────────────
local function dir_token(locale, key)
    local t = RedGCI.DirTokens[locale] or RedGCI.DirTokens["en"]
    return t[key] or key
end

-- ── 6. Haupt-Dispatcher ───────────────────────────────────────
--  token_str : Token-String aus C-Kern
--  callsign  : Rufzeichen des Jägers
--  locale    : "en" | "de" | "ru"
--  dir_lr    : "left"|"right" (für Manöver-Anweisungen)
--  dir_rl    : "left"|"right"|"ahead"|"behind" (Zielposition)

-- Cache: letzter gesendeter Token-Key + Inhalt + Timestamp
local last_tx = { key = "", text = "", time = 0 }

function RedGCI.Transmit(token_str, callsign, locale, dir_lr, dir_rl)
    locale = locale or "en"
    
    local TX_REPEAT_INTERVAL = RedGCI.TX_REPEAT_INTERVAL or 30
    
    -- Token parsen
    local tok = parse_tokens(token_str)
    if not tok then
        gci_log("Transmit: leerer Token-String")
        return
    end

    -- Template aus TextAndSound holen
    local template = RedGCI.gettext:GetEntry(tok.key, locale)
    if not template then
        gci_log("Transmit: kein Template für key=" .. tostring(tok.key)
                .. " locale=" .. locale)
        return
    end

    -- Variablen zusammenstellen
    local vars = {
        CALLSIGN = callsign or RedGCI.CALLSIGN,
        HDG      = tok.hdg  and string.format("%03d", tok.hdg)  or "",
        ALT      = tok.alt  and tostring(math.floor(tok.alt))   or "",
        RNG      = tok.rng  and tostring(math.floor(tok.rng))   or "",
        TTI_M    = tok.tti_m and tostring(tok.tti_m)            or "",
        TTI_S    = tok.tti_s and tostring(tok.tti_s)            or "",
        ASPECT   = tok.aspect and string.format("%03d", tok.aspect) or "",
        DIR_LR   = dir_token(locale, dir_lr or "right"),
        DIR_RL   = dir_token(locale, dir_rl or "ahead"),
    }

    -- Template füllen
    local text = fill_template(template, vars)
    
        -- Throttle: gleicher Text → nur alle 30s wiederholen
    local now = timer.getTime()
    if text == last_tx.text and (now - last_tx.time) < TX_REPEAT_INTERVAL then
        gci_log(string.format("[SRS/THROTTLED/%s] %s", tok.key, text))
        return
    end
    last_tx.text = text
    last_tx.time = now
    
    gci_log(string.format("[SRS/%s/%s] %s", locale, tok.key, text))

    -- An MSRS schicken
    if RedGCI.SRSQueue and RedGCI.msrs then
        local delay = tok.delay or 3.0
        RedGCI.SRSQueue:NewTransmission(
            text,           -- Nachricht
            nil,            -- Dauer (auto)
            RedGCI.msrs,    -- MSRS Instanz
            delay,          -- Startverzögerung
            2,              -- Priorität
            {GROUP:FindByName(RedGCI.FIGHTER_GROUP)},            -- Subgroups (Subtitel)
            text,           -- Subtitle
            10,             -- Subtitle-Dauer
            nil, nil,       -- Channel/Mod (aus msrs)
            nil, nil, nil,  -- Gender/Culture/Voice (aus msrs)
            nil,            -- Volume
            "GCI"           -- Label
        )
    else
        -- Fallback: nur Textausgabe
        trigger.action.outText(text, 8, false)
    end
    if RedGCI.DEBUG == true then
      MESSAGE:New("[DEBUG_MESSAGES] "..text,8):ToAll():ToLog()
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
--  Helper
-- ──────────────────────────────────────────────────────────────

-- Richtung aus Geometrie ableiten
-- Gibt "left"/"right" für Manöver-Anweisungen zurück
local function derive_dir_lr(aspect_angle)
    return (aspect_angle > 5.0) and "right" or "left"
end

-- Zielposition relativ zum Jäger
-- Gibt "ahead"/"behind"/"left"/"right" zurück
local function derive_dir_rl(f, t)
    local dx = t.x - f.x
    local dz = t.z - f.z
    -- Jäger-Heading in Radianten
    local f_hdg = math.atan2(f.vx, f.vz)
    -- Winkel zum Ziel
    local to_tgt = math.atan2(dx, dz)
    local rel = math.deg(to_tgt - f_hdg) % 360
    if rel < 45 or rel > 315 then
        return "ahead"
    elseif rel >= 45 and rel < 135 then
        return "right"
    elseif rel >= 135 and rel < 225 then
        return "behind"
    else
        return "left"
    end
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

local function push_waypoint(group_name, wx, wz, wy, speed_mps, land_home)
    if not RedGCI.IS_AI_PLANE then return end
    
    local minheight = land.getHeight( {x=wx,y=wz} ) + 300 
    
    local route = {}
    local grp = GROUP:FindByName(group_name)
    local tsk = grp:TaskAerobatics()
    tsk = grp:TaskAerobaticsStraightFlight(tsk,1,math.max(wy, minheight), UTILS.MpsToKmph(speed_mps),UseSmoke,StartImmediately,10)
    local startpoint = grp:GetCoordinate()
    local wp0 = startpoint:WaypointAir(COORDINATE.WaypointAltType.BARO,COORDINATE.WaypointType.TurningPoint,COORDINATE.WaypointAction.FlyoverPoint,
      UTILS.MpsToKmph(speed_mps),true,airbase,DCSTasks,"VECTOR")    
  
    local endpoint = COORDINATE:New(wx,math.max(wy, minheight),wz)
    endpoint:MarkToAll("Vector",ReadOnly,"Vector")
    
    local wp1
    if land_home == true then
      wp1 = endpoint:WaypointAir(COORDINATE.WaypointAltType.BARO,COORDINATE.WaypointType.Land,COORDINATE.WaypointAction.Landing,
      UTILS.MpsToKmph(speed_mps),true,RedGCI.AIRBASE,DCSTasks,"HOME")
    else
      wp1 = endpoint:WaypointAir(COORDINATE.WaypointAltType.BARO,COORDINATE.WaypointType.TurningPoint,COORDINATE.WaypointAction.FlyoverPoint,
      UTILS.MpsToKmph(speed_mps),true,airbase,DCSTasks,"VECTOR")
    end
    table.insert(route,wp0)
    table.insert(route,wp1) 
    
    grp:Route(route,0.2)
    
    gci_log(string.format("WP → x=%.0f z=%.0f alt=%.0fm", wx or 0, wz or 0, wy or 0))
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

    -- Statt TICK_INTERVAL * WP_DISTANCE_FACTOR
    -- Fester größerer Lookahead
    local max_dist = math.max(
    fighter.spd * RedGCI.TICK_INTERVAL * WP_DISTANCE_FACTOR,15000)  -- mindestens 15km voraus

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
        gci_log("Jäger '" .. RedGCI.FIGHTER_GROUP .. "' nicht gefunden — Timer gestoppt")
        return nil  -- Timer stoppen
    end

    if not t then
        gci_log("Ziel '" .. RedGCI.TARGET_GROUP .. "' nicht gefunden — Mission beendet")
        set_radar(RedGCI.FIGHTER_GROUP, false)
        RedGCI.Transmit("MERGE_SPLASH|delay=1.5",RedGCI.CALLSIGN, RedGCI.LOCALE, nil, nil)
        trigger.action.outTextForCoalition(RedGCI.COALITION, "[GCI] Зона чистая.", 10)
        
        push_waypoint(RedGCI.FIGHTER_GROUP, RedGCI.HOME_BASE.x, 0, RedGCI.HOME_BASE.y, 200, true)    
        
        return nil  -- Timer stoppen
    end

    -- 1. Intercept-Geometrie (C-Kern)
    local hdg, tti, mode, wf, range, aspect, ip_x, ip_z, ip_y =
        RedGCI.computeIntercept(f, t)

    env.info(string.format(
        "[DEBUG] hdg=%d | tti=%d | mode=%s | wf= %s | range= %d |aspect= %d |ip_x= %d | ip_z=%d | ip_y=%d",
        hdg, tti, mode, tostring(wf), range, aspect, ip_x, ip_z, ip_y))

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

    -- 3. AI: Radar-Lock ab COMMIT-Range
    local ai_radar_lock = RedGCI.IS_AI_PLANE and range < 30000

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

        if state == "ABORT" or state == "RTB" then
            set_radar(RedGCI.FIGHTER_GROUP, false)
            if RedGCI.HOME_BASE then
                push_waypoint(RedGCI.FIGHTER_GROUP,
                    RedGCI.HOME_BASE.x,
                    RedGCI.HOME_BASE.z,
                    1000, f.spd * 0.8, true)
            end
        end
    end

    -- 6. WP + Radar je nach State (jeden Tick)
    if state == "VECTOR" then
        set_radar(RedGCI.FIGHTER_GROUP, false)
        local cruise_spd = math.max(f.spd, 200)
        local wp_x, wp_z, wp_y = compute_rolling_waypoint(f, ip_x, ip_z, ip_y)
        push_waypoint(RedGCI.FIGHTER_GROUP, wp_x, wp_z, wp_y, cruise_spd)

    elseif state == "COMMIT" or state == "RADAR_CONTACT" then
        set_radar(RedGCI.FIGHTER_GROUP, true)
        local wp_x, wp_z, wp_y = compute_rolling_waypoint(f, ip_x, ip_z, ip_y)
        push_waypoint(RedGCI.FIGHTER_GROUP, wp_x, wp_z, wp_y, f.spd)

    elseif state == "NOTCH" then
        set_radar(RedGCI.FIGHTER_GROUP, false)
    end

    -- 7. Merge-Phase
    if state == "MERGE" then
        local fighter_hdg = math.atan2(f.vx, f.vz)
        local to_target   = math.atan2(t.x - f.x, t.z - f.z)
        local rel_bearing = math.deg(to_target - fighter_hdg) % 360

        local phase, token_str, silence, delay =
            RedGCI.mergeUpdate(RedGCI.CALLSIGN,
                rel_bearing, range, t.y - f.y, false)

        if not silence then
            local dir_rl = derive_dir_rl(f, t)
            RedGCI.Transmit(token_str, RedGCI.CALLSIGN,
                            RedGCI.LOCALE, nil, dir_rl)
        end

        gci_log(string.format("[%s/%s] %.0fm → %s",
            state, phase, range,
            silence and "SILENCE" or token_str))

        prev_state = state
        return now + RedGCI.TICK_INTERVAL
    end

    -- 8. Transmission bauen + senden
    local silence, token_str, weapons_free, delay =
        RedGCI.buildTransmission(
            RedGCI.CALLSIGN,
            hdg, tti, mode, wf,
            ip_x, ip_z, ip_y,
            t.y)   -- target_alt = echte Zielhöhe ohne Offset

    if not silence then
        local dir_lr = derive_dir_lr(aspect)
        local dir_rl = derive_dir_rl(f, t)
        RedGCI.Transmit(token_str, RedGCI.CALLSIGN,
                        RedGCI.LOCALE, dir_lr, dir_rl)
    end

    gci_log(string.format(
        "[%s] HDG:%d TTI:%ds MODE:%s WF:%s RANGE:%.0fm ASPECT:%.1f° → %s",
        state, math.floor(hdg), math.floor(tti or 0), mode,
        tostring(weapons_free), range, aspect,
        silence and "SILENCE" or token_str))

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
    
    RedGCI.InitLocalization()
    RedGCI.InitSRS(path, 251, radio.modulation.AM, culture, MSRS.Voices.Google.Wavenet.de_DE_Wavenet_G, 5002)
    
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
