-- Data export script for DCS, version 1.2.
-- Copyright (C) 2006-2014, Eagle Dynamics.
-- See http://www.lua.org for Lua script system info 
-- We recommend to use the LuaSocket addon (http://www.tecgraf.puc-rio.br/luasocket) 
-- to use standard network protocols in Lua scripts.
-- LuaSocket 2.0 files (*.dll and *.lua) are supplied in the Scripts/LuaSocket folder
-- and in the installation folder of the DCS. 
-- Expand the functionality of following functions for your external application needs.
-- Look into Saved Games\DCS\Logs\dcs.log for this script errors, please.
local Tacviewlfs=require('lfs');dofile(Tacviewlfs.writedir()..'Scripts/TacviewGameExport.lua')

pcall(function() local dcsSr=require('lfs');dofile(dcsSr.writedir()..[[Mods\Services\DCS-SRS\Scripts\DCS-SimpleRadioStandalone.lua]]); end,nil)

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
    fighter_group = "Mig-29A",    -- Gruppenname des Jägers in der Mission
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
    local objects = LoGetWorldObjects()
    if not objects then return nil end
    for _, obj in pairs(objects) do
        if obj and obj.GroupName == group_name then
            return obj
        end
    end
    return nil
end


-- ──────────────────────────────────────────────────────────────
--  Rohdaten aus DCS-Einheit extrahieren
-- ──────────────────────────────────────────────────────────────

-- Letzte bekannte Positionen für Velocity-Berechnung
local last_positions = {}
local last_pos_time  = 0

local function get_aircraft_data(obj, now)
    if not obj then return nil end
    local pos = obj.Position
    if not pos or not pos.x then return nil end

    local key = obj.UnitName or obj.GroupName
    local vx, vy, vz = 0, 0, 0

    local last = last_positions[key]
    if last and (now - last.t) > 0.01 then
        local dt = now - last.t
        vx = (pos.x - last.x) / dt
        vy = (pos.y - last.y) / dt
        vz = (pos.z - last.z) / dt
    end

    -- Position für nächsten Tick speichern
    last_positions[key] = { x=pos.x, y=pos.y, z=pos.z, t=now }

    local spd = math.sqrt(vx^2 + vz^2)
    return {
        x   = pos.x, z = pos.z, y = pos.y,
        spd = spd,
        vx  = vx,    vz = vz,   vy = vy,
        fuel = obj.fuel or 1.0,
    }
end


-- ──────────────────────────────────────────────────────────────
--  GCI-Antwort parsen und anzeigen
-- ──────────────────────────────────────────────────────────────

-- Globale Variable als Kommunikationskanal zur Bridge
GCI_last_transmission = nil

local function parse_and_display(resp)
    if not resp or resp == "SILENCE" then return end
    if resp:sub(1, 3) == "ERR" then
        GCI_log("GCI Server Error: " .. resp)
        return
    end
    if resp:sub(1, 2) == "OK" then return end

    local ru    = resp:match("RU:([^|]+)")
    local state = resp:match("STATE:([^|]+)")
    local hdg   = resp:match("HDG:([^|]+)")
    local wf    = resp:match("WF:([^|]+)")

    if ru then
        GCI_last_transmission = {
            text = "[GCI] " .. ru,
            wf   = (wf == "1"),
        }
        GCI_log(string.format("GCI [%s] HDG:%s WF:%s → %s",
                state or "?", hdg or "?", wf or "?", ru))
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

    local f = get_aircraft_data(fighter_unit, now)
    local t = get_aircraft_data(target_unit, now)
    if not f or not t then return end

    -- Sprit senden
    udp:send(string.format("FUEL|f1|%.3f", f.fuel))
    local fuel_resp = udp:receive()
    --GCI_log("GCI: FUEL Antwort: '" .. tostring(fuel_resp) .. "'")

    -- Intercept berechnen lassen
    local msg = string.format(
        "INTERCEPT|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f|%.1f",
        f.x, f.z, f.y, f.spd,
        t.x, t.z, t.y, t.spd,
        t.vx, t.vz, t.vy)

    udp:send(msg)
    local resp = udp:receive()
    --GCI_log("GCI: Server Antwort: '" .. tostring(resp) .. "'")  -- ← NEU
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
