--[[
  gci_bridge.lua — Mission setup script for RedGCI
  ═══════════════════════════════════════════════
  Läuft in der DCS Mission-Sandbox (DO SCRIPT FILE Trigger).

  Ladereihenfolge:
    1. MissionScripting.lua  → gci_mission.lua   (DLL via dofile)
    2. DO SCRIPT FILE        → MOOSE.lua
    3. DO SCRIPT FILE        → REDGCI.lua
    4. DO SCRIPT FILE        → gci_bridge.lua    ← diese Datei

  Dieses Skript nur anpassen — keine Logik hier.
]]

if not RedGCI then
    env.error("[gci_bridge] RedGCI nicht geladen — gci_mission.lua fehlt!")
    return
end

if not REDGCI then
    env.error("[gci_bridge] REDGCI-Klasse nicht geladen — REDGCI.lua fehlt!")
    return
end

-- ──────────────────────────────────────────────────────────────
--  Instanz erzeugen + konfigurieren
-- ──────────────────────────────────────────────────────────────

local gci = REDGCI:New("Mig-29A", "Target", "Сокол-1", coalition.side.RED)

gci:SetLocale("ru")
gci:SetAIMode(true, AIRBASE.Caucasus.Nalchik)
gci:SetSRS(nil, 251, radio.modulation.AM,
           "ru-RU", MSRS.Voices.Google.Wavenet.ru_RU_Wavenet_D, 5002)
gci:SetPilotSRS("Сокол-1",
           "ru-RU", MSRS.Voices.Google.Wavenet.ru_RU_Wavenet_B)
gci:SetTickInterval(10)
gci:SetTxRepeatInterval(30)
gci:SetAltOffset(0)    -- MiG-29: N019-Radar, LDSD-fähig → kein Höhenversatz nötig
gci:SetDebug(true)

-- ──────────────────────────────────────────────────────────────
--  Start
-- ──────────────────────────────────────────────────────────────

gci:Start()
