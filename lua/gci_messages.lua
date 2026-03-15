--[[
  gci_messages.lua — Lokalisierte GCI-Nachrichten + Richtungstoken
  ═══════════════════════════════════════════════════════════════
  Muss VOR gci_bridge.lua geladen sein.
  Lädt per DO SCRIPT FILE Trigger in der Mission.

  Platzhalter: {CALLSIGN} {HDG} {ALT} {RNG} {TTI_M} {TTI_S}
               {ASPECT} {DIR_LR} {DIR_RL}
  Alle Strings werden via gsub() gefüllt bevor sie an MSRS gehen
]]

if not RedGCI then
    env.error("[GCI_MESSAGES] RedGCI nicht geladen — gci_mission.lua fehlt!")
    return
end

-- ─────────────────────────────────────────────────────────────
--  Lokalisierte Nachrichten
-- ─────────────────────────────────────────────────────────────

RedGCI.Messages = {

    -- ── ENGLISCH ─────────────────────────────────────────────
    en = {
        -- VECTOR
        VECTOR              = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph. Target in {TTI_M} minutes.",

        -- COMMIT
        COMMIT_FIRST        = "{CALLSIGN}, BOGEY ahead, {RNG} kilometers, altitude {ALT} meters. Search radar. Look.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, CORRECTION: bearing {ASPECT}, {RNG} kilometers. Why no lock?",
        COMMIT_NUDGE        = "{CALLSIGN}, turn {DIR_LR} ten degrees.",

        -- RADAR CONTACT
        RADAR_LOCK_WF       = "{CALLSIGN}, lock confirmed. {RNG} kilometers. WEAPONS FREE. Attack.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, lock confirmed. {RNG} kilometers. Await clearance.",
        RADAR_WF_NOW        = "{CALLSIGN}, WEAPONS FREE.",

        -- VISUAL
        VISUAL_CONFIRM      = "{CALLSIGN}, visual confirmed. WEAPONS FREE.",

        -- NOTCH
        NOTCH_ENTRY         = "{CALLSIGN}, target maneuvering. Standby.",
        NOTCH_UPDATE        = "{CALLSIGN}, target {DIR_RL}, {RNG} kilometers. Hold.",

        -- ABORT
        ABORT_BINGO         = "{CALLSIGN}, BINGO FUEL. Break off. RTB immediately. Course {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, THREAT WARNING. Break off. Course {HDG}, descend.",

        -- MERGE
        MERGE_ENTRY         = "{CALLSIGN}, contact {DIR_RL}, {ASPECT} degrees. FIGHT.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, overshoot. Break {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, separate. Climb and reset.",
        MERGE_REATTACK      = "{CALLSIGN}, reattack. Target {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, BLIND. Reset heading {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, good kill. Return to base.",

        -- STATE TRANSITIONS
        RADAR_ON            = "{CALLSIGN}, radar on. Search.",
        WEAPONS_FREE        = "{CALLSIGN}, WEAPONS FREE.",
    },

    -- ── DEUTSCH ──────────────────────────────────────────────
    de = {
        -- VECTOR
        VECTOR              = "{CALLSIGN}, Kurs {HDG}, Höhe {ALT} Meter, neunhundert.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, Kurs {HDG}, Höhe {ALT} Meter, neunhundert. Ziel in {TTI_M} Minuten.",

        -- COMMIT
        COMMIT_FIRST        = "{CALLSIGN}, Ziel voraus, {RNG} Kilometer, Höhe {ALT} Meter. Radar an. Suchen.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, Korrektur: Peilung {ASPECT}, {RNG} Kilometer. Warum kein Lock?",
        COMMIT_NUDGE        = "{CALLSIGN}, zehn Grad nach {DIR_LR}.",

        -- RADAR CONTACT
        RADAR_LOCK_WF       = "{CALLSIGN}, Lock bestätigt. {RNG} Kilometer. Feuer frei. Angriff.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, Lock bestätigt. {RNG} Kilometer. Warte auf Freigabe.",
        RADAR_WF_NOW        = "{CALLSIGN}, Feuer frei.",

        -- VISUAL
        VISUAL_CONFIRM      = "{CALLSIGN}, Sichtkontakt bestätigt. Feuer frei.",

        -- NOTCH
        NOTCH_ENTRY         = "{CALLSIGN}, Ziel manövriert. Warten.",
        NOTCH_UPDATE        = "{CALLSIGN}, Ziel {DIR_RL}, {RNG} Kilometer. Halten.",

        -- ABORT
        ABORT_BINGO         = "{CALLSIGN}, BINGO Kraftstoff. Abbruch. Sofort zurück. Kurs {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, BEDROHUNG. Abbruch. Kurs {HDG}, sinken.",

        -- MERGE
        MERGE_ENTRY         = "{CALLSIGN}, Kontakt {DIR_RL}, {ASPECT} Grad. KAMPF.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, Überschuss. Ausbrechen {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, trennen. Steigen und neu ansetzen.",
        MERGE_REATTACK      = "{CALLSIGN}, neu angreifen. Ziel {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, BLIND. Kurs {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, Treffer bestätigt. Kurs nach Hause.",

        -- STATE TRANSITIONS
        RADAR_ON            = "{CALLSIGN}, Radar an. Suchen.",
        WEAPONS_FREE        = "{CALLSIGN}, Feuer frei.",
    },

    -- ── RUSSISCH ─────────────────────────────────────────────
    ru = {
        -- VECTOR
        VECTOR              = "{CALLSIGN}, курс {HDG}, высота {ALT}, скорость девятьсот.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, курс {HDG}, высота {ALT}, скорость девятьсот. До цели {TTI_M} минут.",

        -- COMMIT
        COMMIT_FIRST        = "{CALLSIGN}, цель впереди, дальность {RNG}, высота {ALT}. Включи локатор. Ищи.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, поправка: азимут {ASPECT}, дальность {RNG}. Почему нет захвата?",
        COMMIT_NUDGE        = "{CALLSIGN}, довернись {DIR_LR} десять градусов.",

        -- RADAR CONTACT
        RADAR_LOCK_WF       = "{CALLSIGN}, захват подтверждён. Дальность {RNG}. Цель разрешена. Атакуй.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, захват подтверждён. Дальность {RNG}. Жди разрешения.",
        RADAR_WF_NOW        = "{CALLSIGN}, цель разрешена.",

        -- VISUAL
        VISUAL_CONFIRM      = "{CALLSIGN}, визуальный. Цель разрешена.",

        -- NOTCH
        NOTCH_ENTRY         = "{CALLSIGN}, цель маневрирует. Жди команды.",
        NOTCH_UPDATE        = "{CALLSIGN}, цель {DIR_RL}, дальность {RNG}. Держи.",

        -- ABORT
        ABORT_BINGO         = "{CALLSIGN}, топливо критическое. Прекрати атаку. Немедленно домой. Курс {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, угроза. Прекрати атаку. Курс {HDG}, снижайся.",

        -- MERGE
        MERGE_ENTRY         = "{CALLSIGN}, контакт {DIR_RL}, {ASPECT} градусов. Бой.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, перелёт. Разворот {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, выход. Набери высоту и повтори.",
        MERGE_REATTACK      = "{CALLSIGN}, повторная атака. Цель {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, потеря контакта. Курс {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, молодец. Курс домой.",

        -- STATE TRANSITIONS
        RADAR_ON            = "{CALLSIGN}, включи локатор.",
        WEAPONS_FREE        = "{CALLSIGN}, цель разрешена.",
    },
}

-- ─────────────────────────────────────────────────────────────
--  Richtungstoken je Locale
-- ─────────────────────────────────────────────────────────────

RedGCI.DirTokens = {
    en = { left = "left",   right = "right",  ahead = "ahead",
           behind = "behind", low = "low",    high = "high" },
    de = { left = "links",  right = "rechts", ahead = "voraus",
           behind = "hinten", low = "tief",   high = "hoch"  },
    ru = { left = "влево",  right = "вправо", ahead = "впереди",
           behind = "сзади",  low = "ниже",   high = "выше"  },
}

env.info("[GCI_MESSAGES] Nachrichten geladen.")

