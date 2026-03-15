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
           "ru-RU", MSRS.Voices.Google.Wavenet.de_DE_Wavenet_G, 5002)
gci:SetTickInterval(10)
gci:SetTxRepeatInterval(30)
gci:SetDebug(true)

-- ──────────────────────────────────────────────────────────────
--  Start
-- ──────────────────────────────────────────────────────────────

local function GCI_init()
    
    RedGCI.InitLocalization()
    RedGCI.InitSRS(path, RedGCI.SRSFREQUENCY or 124, radio.modulation.AM, culture, MSRS.Voices.Google.Wavenet.de_DE_Wavenet_G, 5002)
    
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
             
    if RedGCI.IS_AI_PLANE == true then
      set_radar(RedGCI.FIGHTER_GROUP,false)
    end
    
    if RedGCI.IS_AI_PLANE == false then
      RedGCI.PlayerCallsign = GROUP:FindByName(RedGCI.FIGHTER_GROUP):GetCustomCallSign(true,true,nil,RedGCI.GetCallsigns)
    end    
end

GCI_init()
