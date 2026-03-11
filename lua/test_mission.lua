--[[
  GCI POC — Standalone Lua Test (ohne DCS)
  ═══════════════════════════════════════════════════════════════
  Testet den UDP-Server direkt aus der Kommandozeile:
    lua test_mission.lua

  Voraussetzung: lua5.1 + luasocket installiert
    Windows: https://luabinaries.sourceforge.net/
    Linux:   sudo apt install lua5.1 lua-socket
]]

local socket = require("socket")
local udp    = socket.udp()
udp:settimeout(2.0)
udp:setpeername("127.0.0.1", 9088)

local function send_recv(msg)
    udp:send(msg)
    local resp, err = udp:receive()
    if not resp then
        return "TIMEOUT: " .. tostring(err)
    end
    return resp
end

local function sep()
    print(string.rep("─", 60))
end

print("╔══════════════════════════════════════════════════════════╗")
print("║          GCI POC — Lua Integration Test                 ║")
print("╚══════════════════════════════════════════════════════════╝")

-- 1. Verbindungstest
sep()
print("TEST 1: Verbindung")
local r = send_recv("PING")
print("  PING → " .. r)
assert(r == "PONG", "Server nicht erreichbar!")

-- 2. Reset
sep()
print("TEST 2: Reset")
r = send_recv("RESET")
print("  " .. r)

-- 3. Intercept-Sequenz simulieren
--    Jäger startet 60km hinter dem Ziel, beide fliegen Nord
sep()
print("TEST 3: Intercept-Sequenz (60km → Merge)")
print("")

-- Simulierte Positionen (DCS-Koordinaten, Meter)
-- x=Ost, z=Nord, y=Höhe
local scenarios = {
    -- Phase: VECTOR (>40km)
    {
        label = "Phase VECTOR (55km)",
        msg   = "INTERCEPT|0|0|5000|250|0|55000|5700|220|0|-220|0",
    },
    -- Phase: COMMIT (35km)
    {
        label = "Phase COMMIT (35km)",
        msg   = "INTERCEPT|0|0|5000|250|0|35000|5700|220|0|-220|0",
    },
    -- Pilot meldet Radar-Lock
    {
        label = "Pilot: Radar Lock",
        msg   = "PILOT_RADAR|f1|1",
    },
    -- Phase: RADAR_CONTACT (20km, Heckaspekt)
    {
        label = "Phase RADAR CONTACT (20km)",
        msg   = "INTERCEPT|0|0|5300|260|0|20000|5700|220|0|-220|0",
    },
    -- Sprit-Update
    {
        label = "Sprit: 72%",
        msg   = "FUEL|f1|0.72",
    },
    -- Phase: VISUAL (4km)
    {
        label = "Phase VISUAL (4km)",
        msg   = "INTERCEPT|0|0|5600|270|0|4000|5700|220|0|-220|0",
    },
    -- Phase: MERGE (1.5km)
    {
        label = "Phase MERGE (1.5km)",
        msg   = "INTERCEPT|0|0|5700|280|0|1500|5700|220|0|-220|0",
    },
    -- Splash!
    {
        label = "SPLASH",
        msg   = "MERGE_SPLASH",
    },
}

for i, sc in ipairs(scenarios) do
    r = send_recv(sc.msg)
    print(string.format("[%d] %s", i, sc.label))

    if r == "SILENCE" then
        print("    GCI: (schweigt)")
    elseif r:sub(1,2) == "OK" then
        print("    " .. r)
    else
        -- Russischen Text herausziehen
        local ru = r:match("RU:([^|]+)")
        local en = r:match("EN:([^|]+)")
        local st = r:match("STATE:([^|]+)")
        local hd = r:match("HDG:([^|]+)")
        local wf = r:match("WF:([^|]+)")

        if ru then
            print(string.format("    [%s] Kurs:%s WF:%s",
                st or "?", hd or "?", wf or "?"))
            print("    RU: " .. ru)
            if en then
                print("    EN: " .. en)
            end
        else
            print("    " .. r:sub(1, 120))
        end
    end
    print("")
    socket.sleep(0.1)
end

-- 4. Bingo-Test
sep()
print("TEST 4: Bingo-Fuel Abbruch")
send_recv("RESET")
send_recv("FUEL|f1|0.20")
r = send_recv("INTERCEPT|0|0|5000|250|0|45000|5700|220|0|-220|0")
local st = r:match("STATE:([^|]+)")
local ru = r:match("RU:([^|]+)")
print("  State: " .. (st or "?"))
print("  GCI:   " .. (ru or r))

-- 5. Stress-Test
sep()
print("TEST 5: Stress (100 Nachrichten)")
local t0 = socket.gettime()
for i = 1, 100 do
    send_recv("INTERCEPT|0|0|5000|250|0|50000|5700|220|0|-220|0")
end
local dt = socket.gettime() - t0
print(string.format("  100 Nachrichten in %.2fs (%.0f msg/s)",
      dt, 100.0/dt))

sep()
print("Alle Tests abgeschlossen.")
udp:close()
