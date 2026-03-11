--[[
  GCI POC — Export.lua
  ═══════════════════════════════════════════════════════════════
  Installation:
    Kopiere diese Datei nach:
    %USERPROFILE%\Saved Games\DCS\Scripts\Export.lua

    Falls bereits eine Export.lua existiert, den Inhalt ans Ende anhängen
    und GCI_init() aus LuaExportStart() aufrufen.

  Voraussetzung:
    gci_server.exe muss laufen (UDP 127.0.0.1:9088)
]]

local GCI = {}

-- ──────────────────────────────────────────────────────────────
--  Konfiguration
-- ──────────────────────────────────────────────────────────────

GCI.config = {
    host          = "127.0.0.1",
    port          = 9088,
    tick_interval = 5.0,        -- Sekunden zwischen GCI-Updates
    coalition     = 1,          -- 0=Neutral, 1=RED, 2=BLUE
    subtitle_time = 8,          -- Sekunden Untertitel sichtbar
    debug         = true,       -- Debug-Log in dcs.log
    fighter_group = "Сокол",    -- Gruppenname des Jägers in der Mission
    target_group  = "Target",   -- Gruppenname des Ziels
}

-- ──────────────────────────────────────────────────────────────
--  Socket-Setup
-- ──────────────────────────────────────────────────────────────

local socket = require("socket")
local udp    = nil

local function GCI_log(msg)
    if GCI.config.debug then
        log.write("GCI_POC", log.INFO, msg)
    end
end

local function GCI_connect()
    udp = socket.udp()
    udp:settimeout(0.1)
    local ok, err = udp:setpeername(GCI.config.host, GCI.config.port)
    if not ok then
        GCI_log("GCI: Verbindung fehlgeschlagen: " .. tostring(err))
        return false
    end
    -- Verbindungstest
    udp:send("PING")
    local resp = udp:receive()
    if resp == "PONG" then
        GCI_log("GCI: Server verbunden auf " ..
                GCI.config.host .. ":" .. GCI.config.port)
        return true
    end
    GCI_log("GCI: Server antwortet nicht (PING timeout)")
    return false
end


-- ──────────────────────────────────────────────────────────────
--  Unit-Finder (sucht erste lebende Einheit einer Gruppe)
-- ──────────────────────────────────────────────────────────────

local function find_unit_in_group(group_name)
    local grp = Group.getByName(group_name)
    if not grp then return nil end
    local units = grp:getUnits()
    for _, u in ipairs(units) do
        if u and u:isExist() and u:isActive() then
            return u
        end
    end
    return nil
end


-- ──────────────────────────────────────────────────────────────
--  Rohdaten aus DCS-Einheit extrahieren
-- ──────────────────────────────────────────────────────────────

local function get_aircraft_data(unit)
    if not unit then return nil end
    local p = unit:getPoint()
    local v = unit:getVelocity()
    local spd = math.sqrt(v.x^2 + v.z^2)
    return {
        x    = p.x,
        z    = p.z,
        y    = p.y,
        spd  = spd,
        vx   = v.x,
        vz   = v.z,
        vy   = v.y,
        fuel = unit:getFuel(),
    }
end


-- ──────────────────────────────────────────────────────────────
--  GCI-Antwort parsen und anzeigen
-- ──────────────────────────────────────────────────────────────

local function parse_and_display(resp)
    if not resp or resp == "SILENCE" then return end
    if resp:sub(1, 3) == "ERR" then
        GCI_log("GCI Server Error: " .. resp)
        return
    end
    if resp:sub(1, 2) == "OK" then return end

    -- Russischen Text extrahieren
    local ru = resp:match("RU:([^|]+)")
    local en = resp:match("EN:([^|]+)")
    local state = resp:match("STATE:([^|]+)")
    local hdg   = resp:match("HDG:([^|]+)")
    local wf    = resp:match("WF:([^|]+)")

    if ru then
        -- Primär: russischer Text als Untertitel
        trigger.action.outTextForCoalition(
            GCI.config.coalition,
            "[GCI] " .. ru,
            GCI.config.subtitle_time)

        GCI_log(string.format("GCI [%s] HDG:%s WF:%s → %s",
                state or "?", hdg or "?", wf or "?", ru))
    end

    -- Optional: englische Übersetzung als zweite Zeile
    if en and GCI.config.debug then
        GCI_log("GCI_EN: " .. en)
    end

    -- Waffenfreigabe visuell hervorheben
    if wf == "1" then
        trigger.action.outSoundForCoalition(
            GCI.config.coalition, "warning.ogg")  -- falls vorhanden
    end
end


-- ──────────────────────────────────────────────────────────────
--  Pilot-Meldungen (via F10 Menü oder Trigger)
--  Diese Funktionen können auch aus mission triggers aufgerufen werden
-- ──────────────────────────────────────────────────────────────

function GCI_pilot_has_radar(flight_id)
    if udp then
        udp:send("PILOT_RADAR|" .. (flight_id or "f1") .. "|1")
    end
end

function GCI_pilot_lost_radar(flight_id)
    if udp then
        udp:send("PILOT_RADAR|" .. (flight_id or "f1") .. "|0")
    end
end

function GCI_pilot_has_visual(flight_id)
    if udp then
        udp:send("PILOT_VISUAL|" .. (flight_id or "f1") .. "|1")
    end
end

function GCI_target_destroyed()
    if udp then
        udp:send("MERGE_SPLASH")
        local resp = udp:receive()
        parse_and_display(resp)
    end
end


-- ──────────────────────────────────────────────────────────────
--  Haupttakt (wird von LuaExportAfterNextFrame aufgerufen)
-- ──────────────────────────────────────────────────────────────

local last_tick = 0

local function GCI_tick()
    if not udp then return end

    local now = LoGetModelTime and LoGetModelTime() or os.clock()
    if now - last_tick < GCI.config.tick_interval then return end
    last_tick = now

    -- Einheiten finden
    local fighter_unit = find_unit_in_group(GCI.config.fighter_group)
    local target_unit  = find_unit_in_group(GCI.config.target_group)

    if not fighter_unit then
        GCI_log("GCI: Jäger-Gruppe '" ..
                GCI.config.fighter_group .. "' nicht gefunden")
        return
    end
    if not target_unit then
        GCI_log("GCI: Ziel-Gruppe '" ..
                GCI.config.target_group .. "' nicht gefunden")
        return
    end

    local f = get_aircraft_data(fighter_unit)
    local t = get_aircraft_data(target_unit)
    if not f or not t then return end

    -- Sprit senden
    udp:send(string.format("FUEL|f1|%.3f", f.fuel))
    udp:receive()  -- OK wegwerfen

    -- Intercept berechnen lassen
    local msg = string.format(
        "INTERCEPT|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f",
        f.x, f.z, f.y, f.spd,
        t.x, t.z, t.y, t.spd,
        t.vx, t.vz, t.vy)

    udp:send(msg)
    local resp = udp:receive()
    parse_and_display(resp)
end


-- ──────────────────────────────────────────────────────────────
--  DCS Lifecycle Hooks
-- ──────────────────────────────────────────────────────────────

function LuaExportStart()
    GCI_log("GCI POC: LuaExportStart")
    GCI_connect()
end

function LuaExportStop()
    GCI_log("GCI POC: LuaExportStop")
    if udp then
        udp:send("RESET")
        udp:close()
        udp = nil
    end
end

-- Diese Funktion ruft DCS automatisch nach jedem Frame auf
function LuaExportAfterNextFrame()
    local ok, err = pcall(GCI_tick)
    if not ok then
        GCI_log("GCI tick error: " .. tostring(err))
    end
end
