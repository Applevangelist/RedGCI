--- REDGCI - Ground Controlled Intercept for DCS World
-- MOOSE FSM class, wraps the RedGCI C DLL (gci_mission.lua).
--
-- Load order in mission:
--   1. MissionScripting.lua  → gci_mission.lua  (DLL loader)
--   2. DO SCRIPT FILE        → MOOSE.lua
--   3. DO SCRIPT FILE        → REDGCI.lua        ← this file
--   4. DO SCRIPT FILE        → my_mission.lua    (instantiate + configure)
--
-- Minimal mission script example:
--   local gci = REDGCI:New("Mig-29A", "Target", "Сокол-1", coalition.side.RED)
--   gci:SetLocale("ru")
--   gci:SetAIMode(true, AIRBASE.Caucasus.Nalchik)
--   gci:SetSRS(nil, 251)
--   gci:Start()
--
-- @type REDGCI
-- @extends Core.Fsm#FSM

--- @type REDGCI
REDGCI = {}

--- Class name
REDGCI.ClassName = "REDGCI"

--- Version
REDGCI.version = "2.0.0"

--- Waypoint lookahead: WP is clamped to this factor × speed × tick_interval (minimum 15 km)
REDGCI.WP_DISTANCE_FACTOR = 5.0

-- ─────────────────────────────────────────────────────────────
--  Localized messages — embedded (gci_messages.lua no longer needed)
-- ─────────────────────────────────────────────────────────────

--- @type REDGCI.Messages
REDGCI.Messages = {

    -- ── ENGLISH ──────────────────────────────────────────────
    en = {
        -- GCI → Pilot
        VECTOR              = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT}.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT}. Target in {TTI_M} minutes.",
        COMMIT_FIRST        = "{CALLSIGN}, BOGEY ahead, {RNG} kilometers, altitude {ALT}. Radar on.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, CORRECTION: bearing {ASPECT}, {RNG} kilometers. No lock?",
        COMMIT_NUDGE        = "{CALLSIGN}, {DIR_LR} ten degrees.",
        RADAR_LOCK_WF       = "{CALLSIGN}, lock confirmed. {RNG} kilometers. WEAPONS FREE.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, lock confirmed. {RNG} kilometers. Hold fire.",
        RADAR_WF_NOW        = "{CALLSIGN}, WEAPONS FREE.",
        VISUAL_CONFIRM      = "{CALLSIGN}, visual confirmed. WEAPONS FREE.",
        NOTCH_ENTRY         = "{CALLSIGN}, target maneuvering. Standby.",
        NOTCH_UPDATE        = "{CALLSIGN}, target {DIR_RL}, {RNG} kilometers.",
        ABORT_BINGO         = "{CALLSIGN}, BINGO. Break off. Course {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, THREAT. Break off. Course {HDG}.",
        MERGE_ENTRY         = "{CALLSIGN}, contact {DIR_RL}, {ASPECT} degrees. FIGHT.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, overshoot. Break {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, separate. Climb and reset.",
        MERGE_REATTACK      = "{CALLSIGN}, reattack. Target {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, BLIND. Heading {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, good kill. RTB.",
        RADAR_ON            = "{CALLSIGN}, radar on.",
        WEAPONS_FREE        = "{CALLSIGN}, WEAPONS FREE.",
        -- Pilot → GCI acknowledgements
        ACK_VECTOR          = "Copy, {HDG}.",
        ACK_COMMIT          = "Copy.",
        ACK_WEAPONS_FREE    = "Copy. Engaging.",
        ACK_ABORT           = "Copy. Breaking off.",
        ACK_SPLASH          = "Splash. RTB.",
    },

    -- ── GERMAN ───────────────────────────────────────────────
    de = {
        -- GCI → Pilot
        VECTOR              = "{CALLSIGN}, Kurs {HDG}, Höhe {ALT}.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, Kurs {HDG}, Höhe {ALT}. Ziel in {TTI_M} Minuten.",
        COMMIT_FIRST        = "{CALLSIGN}, Ziel voraus, {RNG} Kilometer, Höhe {ALT}. Radar an.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, Korrektur: Peilung {ASPECT}, {RNG} Kilometer. Kein Lock?",
        COMMIT_NUDGE        = "{CALLSIGN}, {DIR_LR} zehn Grad.",
        RADAR_LOCK_WF       = "{CALLSIGN}, Lock bestätigt. {RNG} Kilometer. Feuer frei.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, Lock bestätigt. {RNG} Kilometer. Warten.",
        RADAR_WF_NOW        = "{CALLSIGN}, Feuer frei.",
        VISUAL_CONFIRM      = "{CALLSIGN}, Sichtkontakt. Feuer frei.",
        NOTCH_ENTRY         = "{CALLSIGN}, Ziel manövriert. Warten.",
        NOTCH_UPDATE        = "{CALLSIGN}, Ziel {DIR_RL}, {RNG} Kilometer.",
        ABORT_BINGO         = "{CALLSIGN}, BINGO. Abbruch. Kurs {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, BEDROHUNG. Abbruch. Kurs {HDG}.",
        MERGE_ENTRY         = "{CALLSIGN}, Kontakt {DIR_RL}, {ASPECT} Grad. Angriff.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, Überschuss. {DIR_LR} ausbrechen.",
        MERGE_SEPARATION    = "{CALLSIGN}, trennen. Steigen und neu ansetzen.",
        MERGE_REATTACK      = "{CALLSIGN}, neu angreifen. Ziel {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, BLIND. Kurs {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, Treffer. Heimkurs.",
        RADAR_ON            = "{CALLSIGN}, Radar an.",
        WEAPONS_FREE        = "{CALLSIGN}, Feuer frei.",
        -- Pilot → GCI acknowledgements
        ACK_VECTOR          = "Verstanden, Kurs {HDG}.",
        ACK_COMMIT          = "Verstanden.",
        ACK_WEAPONS_FREE    = "Verstanden. Greife an.",
        ACK_ABORT           = "Verstanden. Abbruch.",
        ACK_SPLASH          = "Treffer. Heimkurs.",
    },

    -- ── RUSSIAN ───────────────────────────────────────────────
    ru = {
        -- GCI → Pilot
        VECTOR              = "{CALLSIGN}, курс {HDG}, высота {ALT}.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, курс {HDG}, высота {ALT}. До цели {TTI_M} минут.",
        COMMIT_FIRST        = "{CALLSIGN}, цель впереди, дальность {RNG}, высота {ALT}. Локатор.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, поправка: азимут {ASPECT}, дальность {RNG}. Захват?",
        COMMIT_NUDGE        = "{CALLSIGN}, довернись {DIR_LR}.",
        RADAR_LOCK_WF       = "{CALLSIGN}, захват. Дальность {RNG}. Цель разрешена.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, захват. Дальность {RNG}. Жди.",
        RADAR_WF_NOW        = "{CALLSIGN}, цель разрешена.",
        VISUAL_CONFIRM      = "{CALLSIGN}, визуальный. Цель разрешена.",
        NOTCH_ENTRY         = "{CALLSIGN}, цель маневрирует. Жди.",
        NOTCH_UPDATE        = "{CALLSIGN}, цель {DIR_RL}, дальность {RNG}.",
        ABORT_BINGO         = "{CALLSIGN}, топливо. Прекрати. Курс {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, угроза. Прекрати. Курс {HDG}.",
        MERGE_ENTRY         = "{CALLSIGN}, контакт {DIR_RL}, {ASPECT} градусов. Бой.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, перелёт. Разворот {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, выход. Высота, повтори.",
        MERGE_REATTACK      = "{CALLSIGN}, повтори. Цель {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, потеря. Курс {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, молодец. Домой.",
        RADAR_ON            = "{CALLSIGN}, локатор.",
        WEAPONS_FREE        = "{CALLSIGN}, цель разрешена.",
        -- Pilot → GCI acknowledgements (kurz und militärisch)
        ACK_VECTOR          = "Понял, курс {HDG}.",
        ACK_COMMIT          = "Понял.",
        ACK_WEAPONS_FREE    = "Понял. Атакую.",
        ACK_ABORT           = "Понял. Прекращаю.",
        ACK_SPLASH          = "Цель поражена. Домой.",
    },
}

--- @type REDGCI.DirTokens
REDGCI.DirTokens = {
    en = { left="left",   right="right",  ahead="ahead",   behind="behind", low="low",   high="high"  },
    de = { left="links",  right="rechts", ahead="voraus",  behind="hinten", low="tief",  high="hoch"  },
    ru = { left="влево",  right="вправо", ahead="впереди", behind="сзади",  low="ниже",  high="выше"  },
}

-- ─────────────────────────────────────────────────────────────
--  Constructor
-- ─────────────────────────────────────────────────────────────

--- Create a new REDGCI instance.
-- @param #REDGCI self
-- @param #string FighterGroupName  DCS group name of the interceptor(s)
-- @param #string TargetGroupName   DCS group name of the target(s)
-- @param #string Callsign          Radio callsign string (e.g. "Сокол-1")
-- @param #number Coalition         coalition.side.RED or coalition.side.BLUE
-- @return #REDGCI self
function REDGCI:New(FighterGroupName, TargetGroupName, Callsign, Coalition)
    local self = BASE:Inherit(self, FSM:New())  --#REDGCI

    -- Log prefix
    self.lid = string.format("REDGCI (%s) | ", Callsign or "GCI")

    -- ── Core identity ─────────────────────────────────────────
    self.FighterGroupName = FighterGroupName or "Mig-29A"
    self.TargetGroupName  = TargetGroupName  or "Target"
    self.Callsign         = Callsign         or "Сокол 1"
    self.Coalition        = Coalition        or coalition.side.RED

    -- ── Defaults ─────────────────────────────────────────────
    self.Locale           = "ru"
    self.TickInterval     = 10.0
    self.TxRepeatInterval = 30.0
    self.SubtitleTime     = 8
    self.IsAIPlane        = true
    self.HomeBaseName     = nil
    self.HomeBase         = nil    -- Vec2 {x,y}
    self.Debug                = false
    -- self.WFRange removed: C kernel handles WF via range + closure projection
    self.AltOffset            = -700   -- metres relative to target altitude for intercept waypoint.
    self.ContactLostTimeout   = 3      -- ticks without contact before declaring target gone
    self._contact_lost_ticks  = 0     -- internal counter
                                   -- Negative = below target (Shootup geometry, classic Soviet doctrine
                                   -- for radar-limited types like MiG-21/early MiG-23).
                                   -- Zero or positive = Lookdown/Shoot-Down geometry (MiG-29, Su-27).
                                   -- Use SetAltOffset() to override.

    -- ── SRS defaults (GCI controller voice) ──────────────────
    self.SRSPath          = nil
    self.SRSFreq          = 251
    self.SRSMod           = radio.modulation.AM
    self.SRSCulture       = "ru-RU"
    self.SRSVoice         = MSRS.Voices.Google.Standard.ru_RU_Standard_D
    self.SRSPort          = 5002

    -- ── Pilot SRS defaults (separate voice for acknowledgements) ──
    self.PilotCallsign    = nil   -- if nil, no pilot ACKs are transmitted
    self.PilotSRSCulture  = "ru-RU"
    self.PilotSRSVoice    = MSRS.Voices.Google.Standard.ru_RU_Standard_B
    self._pilot_msrs      = nil
    self._pilot_queue     = nil

    -- ── Internal state (per instance) ─────────────────────────
    self._pilot_flags = { radar=false, visual=false, threat=false }
    self._prev_state  = nil
    self._prev_wf     = false
    self._prev_radar  = false
    self._last_tx     = { text="", time=0 }
    self._msrs        = nil
    self._srs_queue   = nil
    self._gettext     = nil

    -- ── FSM transitions ───────────────────────────────────────
    self:SetStartState("Stopped")
    self:AddTransition("Stopped", "Start",  "Running")
    self:AddTransition("Running", "Status", "Running")
    self:AddTransition("Running", "Stop",   "Stopped")

    self:I(self.lid .. "v" .. REDGCI.version .. " created. Fighter=" ..
           self.FighterGroupName .. " Target=" .. self.TargetGroupName)

    return self
end

-- ─────────────────────────────────────────────────────────────
--  User API — configuration (all return self for chaining)
-- ─────────────────────────────────────────────────────────────

--- Set the locale for radio messages.
-- @param #REDGCI self
-- @param #string Locale  "en", "de", or "ru" (default "ru")
-- @return #REDGCI self
function REDGCI:SetLocale(Locale)
    self.Locale = Locale or "ru"
    return self
end

--- Enable or disable AI waypoint and radar management.
-- @param #REDGCI self
-- @param #boolean IsAI           true = push waypoints + control radar
-- @param #string  HomeBaseName   AIRBASE name for RTB (e.g. AIRBASE.Caucasus.Nalchik)
-- @return #REDGCI self
function REDGCI:SetAIMode(IsAI, HomeBaseName)
    self.IsAIPlane = IsAI ~= false
    if HomeBaseName then
        self.HomeBaseName = HomeBaseName
        local ab = AIRBASE:FindByName(HomeBaseName)
        if ab then
            self.HomeBase = ab:GetVec2()
        else
            self:E(self.lid .. "SetAIMode: AIRBASE '" .. tostring(HomeBaseName) .. "' not found!")
        end
    end
    return self
end

--- Configure SRS radio output.
-- @param #REDGCI self
-- @param #string  Path       Path to SRS (or nil to use MSRS default)
-- @param #number  Frequency  MHz, e.g. 251
-- @param #number  Modulation radio.modulation.AM or FM (default AM)
-- @param #string  Culture    BCP-47 culture string, e.g. "ru-RU"
-- @param #string  Voice      MSRS voice constant
-- @param #number  Port       SRS port (default 5002)
-- @return #REDGCI self
function REDGCI:SetSRS(Path, Frequency, Modulation, Culture, Voice, Port)
    self.SRSPath    = Path
    self.SRSFreq    = Frequency  or self.SRSFreq
    self.SRSMod     = Modulation or self.SRSMod
    self.SRSCulture = Culture    or self.SRSCulture
    self.SRSVoice   = Voice      or self.SRSVoice
    self.SRSPort    = Port       or self.SRSPort
    return self
end

--- Configure the pilot voice for radio acknowledgements.
-- The pilot uses the same frequency/modulation as the GCI controller but
-- a distinct voice so the two can be told apart on the radio.
-- Set PilotCallsign to nil (default) to disable pilot ACKs entirely.
-- @param #REDGCI self
-- @param #string  PilotCallsign  Pilot's callsign (e.g. "Сокол-1"), or nil to disable ACKs.
-- @param #string  Culture        BCP-47 culture string (default same as GCI)
-- @param #string  Voice          MSRS voice constant (default ru_RU_Standard_B)
-- @return #REDGCI self
function REDGCI:SetPilotSRS(PilotCallsign, Culture, Voice)
    self.PilotCallsign   = PilotCallsign
    self.PilotSRSCulture = Culture or self.SRSCulture
    self.PilotSRSVoice   = Voice   or MSRS.Voices.Google.Standard.ru_RU_Standard_B
    return self
end

--- Set the GCI tick interval in seconds.
-- @param #REDGCI self
-- @param #number Seconds  Default 10.0
-- @return #REDGCI self
function REDGCI:SetTickInterval(Seconds)
    self.TickInterval = Seconds or 10.0
    return self
end

--- Set minimum seconds between identical transmissions.
-- @param #REDGCI self
-- @param #number Seconds  Default 30.0
-- @return #REDGCI self
function REDGCI:SetTxRepeatInterval(Seconds)
    self.TxRepeatInterval = Seconds or 30.0
    return self
end

--- @deprecated No-op. The C kernel now decides weapons-free via range +
-- closure projection (GCI_WF_RANGE_MAX / GCI_TICK_INTERVAL). Configure the
-- threshold by recompiling the C kernel with the desired GCI_WF_RANGE_MAX.
-- @param #REDGCI self
-- @param #number Meters  (ignored)
-- @return #REDGCI self
function REDGCI:SetWFRange(Meters)
    return self
end

--- Enable or disable debug logging.
-- @param #REDGCI self
-- @param #boolean OnOff  true = verbose logging
-- @return #REDGCI self
function REDGCI:SetDebug(OnOff)
    self.Debug = OnOff ~= false
    return self
end

--- Set the altitude offset applied to intercept waypoints relative to the target altitude.
-- Models the preferred attack geometry of the fighter type:
--
--   Negative offset (below target) = classic Soviet Shootup doctrine.
--     The fighter is vectored below the target so its radar looks up
--     against a clean sky background, avoiding ground clutter.
--     Appropriate for MiG-21, early MiG-23 (limited or no LDSD capability).
--     Typical value: -700 m (default).
--
--   Zero or positive offset (at or above target) = Lookdown/Shoot-Down.
--     The fighter has a modern pulse-Doppler radar capable of suppressing
--     ground clutter and shooting downward.
--     Appropriate for MiG-29 (N019), Su-27 (N001), MiG-31 (Zaslon).
--     Typical value: 0 (level) to +300 m (slight high perch).
--
-- The offset is only applied during VECTOR and COMMIT states.
-- In RADAR_CONTACT and beyond, exact geometry is driven by the C kernel.
-- @param #REDGCI self
-- @param #number Meters  Altitude offset in metres (default -700).
-- @return #REDGCI self
function REDGCI:SetAltOffset(Meters)
    self.AltOffset = Meters or -700
    return self
end

--- Set how many consecutive ticks without a target contact are tolerated
-- before the GCI declares the intercept over.
--
-- During a contact gap the GCI transmits NOTCH_ENTRY on the first missing
-- tick and then stays silent, holding the last known vector, until either
-- the contact is re-acquired (counter resets) or the timeout is reached
-- (MERGE_SPLASH + Stop).
--
-- One tick = TickInterval seconds (default 10 s), so the default of 3 ticks
-- means ~30 s of tolerance — enough to cover a typical notch manoeuvre or
-- brief Doppler blind spot without falsely declaring a kill.
-- @param #REDGCI self
-- @param #number Ticks  Number of ticks (default 3).
-- @return #REDGCI self
function REDGCI:SetContactLostTimeout(Ticks)
    self.ContactLostTimeout = Ticks or 3
    return self
end

--- Signal that the pilot has achieved radar lock.
-- Equivalent to pressing "Radar Lock" in the F10 menu.
-- @param #REDGCI self
-- @return #REDGCI self
function REDGCI:SetPilotRadarLock(OnOff)
    self._pilot_flags.radar = OnOff ~= false
    return self
end

--- Signal that the pilot has visual contact.
-- @param #REDGCI self
-- @return #REDGCI self
function REDGCI:SetPilotVisual(OnOff)
    self._pilot_flags.visual = OnOff ~= false
    return self
end

--- Signal that the pilot's RWR is active (threat warning).
-- @param #REDGCI self
-- @return #REDGCI self
function REDGCI:SetPilotThreat(OnOff)
    self._pilot_flags.threat = OnOff ~= false
    return self
end

--- Reset FSM state and pilot flags (e.g. after a splash or new intercept).
-- @param #REDGCI self
-- @return #REDGCI self
function REDGCI:Reset()
    self._pilot_flags        = { radar=false, visual=false, threat=false }
    self._prev_state         = nil
    self._prev_wf            = false
    self._prev_radar         = false
    self._last_tx            = { text="", time=0 }
    self._contact_lost_ticks = 0
    RedGCI.reset(self.Callsign)
    self:_SetRadar(false)
    self:_SetWeaponsFree(false)
    self:T(self.lid .. "Reset.")
    return self
end

-- ─────────────────────────────────────────────────────────────
--  Internal helpers
-- ─────────────────────────────────────────────────────────────

--- @param #REDGCI self
function REDGCI:_Log(msg)
    if self.Debug then
        env.info(self.lid .. msg)
    end
end

--- Initialize TEXTANDSOUND localization from embedded Messages table.
-- @param #REDGCI self
function REDGCI:_InitLocalization()
    self._gettext = TEXTANDSOUND:New("REDGCI_" .. self.Callsign, "en")
    for locale, entries in pairs(REDGCI.Messages) do
        local loc = string.lower(tostring(locale))
        for id, text in pairs(entries) do
            self._gettext:AddEntry(loc, tostring(id), text)
        end
    end
end

--- Initialize MSRS + queue.
-- @param #REDGCI self
function REDGCI:_InitSRS()
    -- GCI controller voice
    self._msrs = MSRS:New(self.SRSPath, self.SRSFreq, self.SRSMod) -- Sound.MSRS#MSRS
    self._msrs:SetPort(self.SRSPort)
    self._msrs:SetLabel("GCI")
    self._msrs:SetCulture(self.SRSCulture)
    self._msrs:SetVoice(self.SRSVoice)
    self._msrs:SetCoalition(self.Coalition)
    self._srs_queue = MSRSQUEUE:New("REDGCI_" .. self.Callsign) -- Sound.MSRS#MSRSQUEUE

    -- Pilot voice (only when a pilot callsign has been configured)
    if self.PilotCallsign then
        self._pilot_msrs = MSRS:New(self.SRSPath, self.SRSFreq, self.SRSMod)
        self._pilot_msrs:SetPort(self.SRSPort)
        self._pilot_msrs:SetLabel("PILOT")
        self._pilot_msrs:SetCulture(self.PilotSRSCulture)
        self._pilot_msrs:SetVoice(self.PilotSRSVoice)
        self._pilot_msrs:SetCoalition(self.Coalition)
        self._pilot_queue = MSRSQUEUE:New("REDGCI_PILOT_" .. self.PilotCallsign)
        self:_Log("Pilot SRS ready: " .. self.PilotCallsign)
    end
end

--- Get live unit data from a DCS group (returns first alive unit).
-- @param #REDGCI self
-- @param #string GroupName
-- @return #table  { x, y, z, spd, vx, vy, vz, hdg, fuel } or nil
function REDGCI:_GetUnitData(GroupName)
    local grp = Group.getByName(GroupName)
    if not grp then return nil end
    for _, u in ipairs(grp:getUnits()) do
        if u and u:isExist() and u:isActive() then
            local pos3 = u:getPosition()
            local p    = pos3.p
            local fwd  = pos3.x
            local v    = u:getVelocity()
            return {
                x    = p.x,
                y    = p.y,
                z    = p.z,
                spd  = math.sqrt(v.x*v.x + v.z*v.z),
                vx   = v.x,
                vy   = v.y,
                vz   = v.z,
                hdg  = math.deg(math.atan2(fwd.z, fwd.x)) % 360,
                fuel = u:getFuel(),
            }
        end
    end
    return nil
end

--- Parse a pipe-separated token string from the C kernel.
-- Input:  "VECTOR|hdg=165|alt=4500|tti_m=8|wf=false"
-- Output: { key="VECTOR", hdg=165, alt=4500, tti_m=8, wf=false }
-- @param #REDGCI self
function REDGCI:_ParseTokens(TokenStr)
    if not TokenStr or TokenStr == "" then return nil end
    local parts = {}
    for part in string.gmatch(TokenStr, "[^|]+") do
        parts[#parts + 1] = part
    end
    local result = { key = parts[1] }
    for i = 2, #parts do
        local k, v = string.match(parts[i], "^(%w+)=(.+)$")
        if k and v then
            if     v == "true"  then result[k] = true
            elseif v == "false" then result[k] = false
            elseif tonumber(v)  then result[k] = tonumber(v)
            else                     result[k] = v
            end
        end
    end
    return result
end

--- Fill {PLACEHOLDER} tokens in a template string.
-- @param #REDGCI self
function REDGCI:_FillTemplate(Template, Vars)
    return (string.gsub(Template, "{([%w_]+)}", function(key)
        return tostring(Vars[key] or "")
    end))
end

--- Resolve a direction key to a localized word.
-- @param #REDGCI self
-- @param #string Key   "left", "right", "ahead", "behind", "low", "high"
-- @return #string
function REDGCI:_DirToken(Key)
    local t = REDGCI.DirTokens[self.Locale] or REDGCI.DirTokens["en"]
    return t[Key] or Key
end

--- Derive "left"/"right" turn instruction from aspect angle.
-- @param #REDGCI self
function REDGCI:_DeriveDirLR(AspectAngle)
    return (AspectAngle > 5.0) and "right" or "left"
end

--- Derive target position relative to fighter ("ahead"/"behind"/"left"/"right").
-- @param #REDGCI self
-- @param #table Fighter  unit data
-- @param #table Target   unit data
-- @return #string
function REDGCI:_DeriveDirRL(Fighter, Target)
    local dx     = Target.x - Fighter.x
    local dz     = Target.z - Fighter.z
    local f_hdg  = math.atan2(Fighter.vx, Fighter.vz)
    local to_tgt = math.atan2(dx, dz)
    local rel    = math.deg(to_tgt - f_hdg) % 360
    if     rel < 45  or rel > 315 then return "ahead"
    elseif rel < 135              then return "right"
    elseif rel < 225              then return "behind"
    else                               return "left"
    end
end

--- Build and dispatch a radio transmission.
-- @param #REDGCI self
-- @param #string TokenStr   Pipe-separated token string from C kernel
-- @param #string DirLR      "left"/"right" for manoeuvre cues
-- @param #string DirRL      "ahead"/"behind"/"left"/"right" for target position
function REDGCI:_Transmit(TokenStr, DirLR, DirRL)
    local tok = self:_ParseTokens(TokenStr)
    if not tok then
        self:_Log("_Transmit: empty token string")
        return
    end

    -- Look up template
    local template = self._gettext:GetEntry(tok.key, self.Locale)
    if not template then
        self:_Log("_Transmit: no template for key=" .. tostring(tok.key) ..
                  " locale=" .. self.Locale)
        return
    end

    -- Build variable table
    local vars = {
        CALLSIGN = self.Callsign,
        HDG      = tok.hdg    and string.format("%03d", tok.hdg)          or "",
        ALT      = tok.alt    and tostring(math.floor(tok.alt))           or "",
        RNG      = tok.rng    and tostring(math.floor(tok.rng))           or "",
        TTI_M    = tok.tti_m  and tostring(tok.tti_m)                     or "",
        TTI_S    = tok.tti_s  and tostring(tok.tti_s)                     or "",
        ASPECT   = tok.aspect and string.format("%03d", tok.aspect)       or "",
        DIR_LR   = self:_DirToken(DirLR or "right"),
        DIR_RL   = self:_DirToken(DirRL or "ahead"),
    }

    local text = self:_FillTemplate(template, vars)

    -- Throttle: same text repeated within TxRepeatInterval → suppress
    local now = timer.getTime()
    if text == self._last_tx.text and
       (now - self._last_tx.time) < self.TxRepeatInterval then
        self:_Log("[SRS/THROTTLED/" .. tok.key .. "] " .. text)
        return
    end
    self._last_tx.text = text
    self._last_tx.time = now

    self:_Log(string.format("[SRS/%s/%s] %s", self.Locale, tok.key, text))
      
    if self._srs_queue and self._msrs then
        local delay = tok.delay or 3.0
        --MSRSQUEUE:NewTransmission(text, duration, msrs, tstart, interval, subgroups, subtitle, subduration, frequency, modulation, gender, culture, voice, volume, label,coordinate,speed,speaker)
        self._srs_queue:NewTransmission(
            text,             -- message text
            nil,              -- duration (auto)
            self._msrs,       -- MSRS instance
            delay,            -- start delay
            1,                -- interval
            {GROUP:FindByName(RedGCI.FIGHTER_GROUP)},            -- Subgroups (Subtitle)
            text,             -- subtitle
            self.SubtitleTime,-- subtitle duration
            nil, nil,         -- channel/mod (from msrs)
            nil, nil, nil,    -- gender/culture/voice (from msrs)
            nil,              -- volume
            "GCI",            -- label
            nil,              -- coordinate
            1.2,              -- speed
            nil               -- speaker
        )
    else
        -- Fallback: on-screen text
        trigger.action.outText(text, self.SubtitleTime, false)
    end
    
    if self.Debug then
      trigger.action.outText(text, self.SubtitleTime, false)
    end
end

--- Dispatch a pilot acknowledgement transmission.
-- Uses the pilot's MSRS voice on the same frequency as GCI.
-- The ACK key is looked up in the Messages table under the pilot locale;
-- vars are filled identically to _Transmit so {HDG} etc. work.
-- The ACK fires after a short realistic reaction delay (GCI_delay + ~2s).
-- No-op when PilotCallsign is nil or pilot SRS is not initialised.
-- @param #REDGCI self
-- @param #string AckKey   Message key, e.g. "ACK_VECTOR"
-- @param #table  Vars     Variable table (same format as _Transmit vars)
-- @param #number GciDelay Delay of the preceding GCI transmission (seconds)
function REDGCI:_TransmitPilot(AckKey, Vars, GciDelay)
    if not self.IsAIPlane then return end
    if not self.PilotCallsign then return end
    if not self._pilot_queue or not self._pilot_msrs then return end

    local template = self._gettext:GetEntry(AckKey, self.Locale)
    if not template then
        self:_Log("_TransmitPilot: no template for key=" .. AckKey)
        return
    end

    -- Inject pilot callsign into vars
    local v = Vars or {}
    v.CALLSIGN = self.PilotCallsign

    local text = self:_FillTemplate(template, v)

    -- Pilot speaks ~2-3 s after GCI finishes (GCI delay + estimated GCI speech + reaction)
    local pilot_delay = (GciDelay or 3.0) + 4.0

    self:_Log(string.format("[PILOT/%s/%s] %s", self.Locale, AckKey, text))

    self._pilot_queue:NewTransmission(
        text,
        nil,
        self._pilot_msrs,
        pilot_delay,
        1,
        {GROUP:FindByName(self.FighterGroupName)},
        text,
        self.SubtitleTime,
        nil, nil,
        nil, nil, nil,
        nil,
        "PILOT",
        nil,
        1.2
    )

    if self.Debug then
        trigger.action.outText("[PILOT] " .. text, self.SubtitleTime, false)
    end
end

---
-- @param #REDGCI self
-- @param #number wx       DCS x coord (North)
-- @param #number wz       DCS z coord (East)
-- @param #number wy       altitude MSL metres
-- @param #number SpeedMps airspeed in m/s
-- @param #boolean LandHome  true = set waypoint type to LAND at HomeBase
function REDGCI:_PushWaypoint(wx, wz, wy, SpeedMps, LandHome)
    if not self.IsAIPlane then return end

    local grp = GROUP:FindByName(self.FighterGroupName)
    if not grp then return end

    -- Terrain floor + 300 m minimum clearance
    local terrain_floor = land.getHeight({ x=wx, y=wz }) + 300
    local safe_alt      = math.max(wy, terrain_floor)
    local kmph          = UTILS.MpsToKmph(SpeedMps)
    local speed_tas = UTILS.IasToTas(kmph,math.max(wy, safe_alt))
    
    local tsk = grp:TaskAerobatics()
    tsk = grp:TaskAerobaticsStraightFlight(tsk,1,math.max(wy, safe_alt),speed_tas,UseSmoke,StartImmediately,10)
    
    local startpoint = grp:GetCoordinate()
    local wp0 = startpoint:WaypointAir(
        COORDINATE.WaypointAltType.BARO,
        COORDINATE.WaypointType.TurningPoint,
        COORDINATE.WaypointAction.FlyoverPoint,
        speed_tas, true, nil, {}, "VECTOR")

    local endpoint = COORDINATE:New(wx, safe_alt, wz)
    local wp1
    if LandHome then
        local ab = self.HomeBaseName and AIRBASE:FindByName(self.HomeBaseName) or nil
        wp1 = endpoint:WaypointAir(
            COORDINATE.WaypointAltType.BARO,
            COORDINATE.WaypointType.Land,
            COORDINATE.WaypointAction.Landing,
            speed_tas, true, ab, {}, "HOME")
    else
        wp1 = endpoint:WaypointAir(
            COORDINATE.WaypointAltType.BARO,
            COORDINATE.WaypointType.TurningPoint,
            COORDINATE.WaypointAction.FlyoverPoint,
            speed_tas, true, nil, tsk, "VECTOR")
    end

    grp:Route({ wp0, wp1 }, 1)
    self:_Log(string.format("WP → x=%.0f z=%.0f alt=%.0fm spd=%.0f kph TAS=%.0f kph",
                            wx, wz, safe_alt, kmph, speed_tas))
end

--- Clamp an intercept point to max_dist from the fighter.
-- Prevents the AI from overshooting on a distant waypoint.
-- @param #REDGCI self
-- @param #table  Fighter  unit data
-- @param #number ip_x     intercept x (DCS North)
-- @param #number ip_z     intercept z (DCS East)
-- @param #number ip_y     intercept altitude
-- @return #number, #number, #number  clamped wx, wz, wy
function REDGCI:_ComputeRollingWaypoint(Fighter, ip_x, ip_z, ip_y)
    local dx   = ip_x - Fighter.x
    local dz   = ip_z - Fighter.z
    local dist = math.sqrt(dx*dx + dz*dz)

    local max_dist = math.max(
        Fighter.spd * self.TickInterval * REDGCI.WP_DISTANCE_FACTOR,
        15000)  -- minimum 15 km lookahead

    if dist <= max_dist or dist < 1 then
        return ip_x, ip_z, ip_y
    end

    local nx = dx / dist
    local nz = dz / dist
    return Fighter.x + nx * max_dist,
           Fighter.z + nz * max_dist,
           ip_y
end

--- Toggle radar emission on the fighter group.
-- @param #REDGCI self
-- @param #boolean On
function REDGCI:_SetRadar(On)
    if not self.IsAIPlane then return end
    local grp = GROUP:FindByName(self.FighterGroupName)
    if not grp then return end
    if On == true then
      grp:SetOptionRadarUsingForContinousSearch()
      --grp:OptionROEWeaponFree()
      --grp:OptionAlarmStateRed()
      --grp:OptionAAAttackRange(1)
    else
      grp:SetOptionRadarUsingNever()
      --grp:OptionROEHoldFire()
      --grp:OptionAlarmStateAuto()
      --grp:OptionAAAttackRange(3)
    end
    self:_Log("Radar " .. (On and "ON" or "OFF"))
end

--- Toggle weapons free on the fighter group.
-- @param #REDGCI self
-- @param #boolean On
function REDGCI:_SetWeaponsFree(On)
    if not self.IsAIPlane then return end
    local grp = GROUP:FindByName(self.FighterGroupName)
    if not grp then return end
    if On == true then
      --grp:SetOptionRadarUsingForContinousSearch()
      grp:OptionROEWeaponFree()
      grp:OptionAlarmStateRed()
      grp:OptionAAAttackRange(2)
    else
      --grp:SetOptionRadarUsingNever()
      grp:OptionROEHoldFire()
      grp:OptionAlarmStateAuto()
      grp:OptionAAAttackRange(3)
    end
    self:_Log("Radar " .. (On and "ON" or "OFF"))
end

--- Register F10 coalition menu entries.
-- @param #REDGCI self
function REDGCI:_SetupF10Menu()
    local root = missionCommands.addSubMenuForCoalition(self.Coalition, "GCI")

    missionCommands.addCommandForCoalition(self.Coalition, "Radar Lock", root,
        function()
            self._pilot_flags.radar  = true
            self._pilot_flags.visual = false
            self:_Log("Pilot: Radar Lock")
        end)

    missionCommands.addCommandForCoalition(self.Coalition, "Visual Contact", root,
        function()
            self._pilot_flags.visual = true
            self:_Log("Pilot: Visual Contact")
        end)

    missionCommands.addCommandForCoalition(self.Coalition, "Threat (RWR)", root,
        function()
            self._pilot_flags.threat = true
            self:_Log("Pilot: Threat")
        end)

    missionCommands.addCommandForCoalition(self.Coalition, "Splash / Kill", root,
        function()
            local _, token_str, _, _ =
                RedGCI.mergeUpdate(self.Callsign, 0, 0, 0, true)
            if token_str and token_str ~= "" then
                self:_Transmit(token_str, nil, nil)
            end
            self:Reset()
            self:_Log("Splash — Reset")
        end)

    missionCommands.addCommandForCoalition(self.Coalition, "Reset GCI", root,
        function()
            self:Reset()
            self:_Log("GCI Reset via F10 menu")
        end)

    missionCommands.addCommandForCoalition(self.Coalition, "Toggle AI Mode", root,
        function()
            self.IsAIPlane = not self.IsAIPlane
            local status = self.IsAIPlane and "ON" or "OFF"
            trigger.action.outTextForCoalition(
                self.Coalition, "[GCI] AI mode " .. status, 3)
            self:_Log("AI mode: " .. status)
        end)
end

---
-- ══════════════════════════════════════════════════════════════════
--  Part 2 — REDGCI Intel source integration
--
--  When an INTEL source is attached, REDGCI derives the intercept target
--  from the INTEL contact table instead of polling a fixed group name.
--  Selection criterion: highest threat-level aircraft contact.
--  Tie-break: closest to the fighter.
--
--  The INTEL contact's position/velocity are used directly, so the GCI
--  works even after the real unit is lost from DCS sensor view (INTEL
--  keeps a prediction window of up to 10 min for aircraft).
-- ══════════════════════════════════════════════════════════════════

--- Attach an INTEL object as the target source for this GCI instance.
-- When set, REDGCI picks the highest-threat aircraft contact from INTEL
-- on every tick instead of polling a fixed target group name.
-- The GCI continues to work with INTEL's predicted positions during
-- contact gaps (up to INTEL's configured forget window).
-- @param #REDGCI self
-- @param Ops.Intel#INTEL Intel INTEL instance (must be Started/Running).
-- @param #string Filter (optional) Only consider contacts whose group name
--                contains this substring (case-sensitive).
-- @return #REDGCI self
function REDGCI:SetIntelSource(Intel, Filter)
    self.Intel             = Intel
    self.IntelTargetFilter = Filter
    self:I(self.lid .. "Intel source set: " ..
           (Intel and Intel.alias or "nil") ..
           (Filter and (" filter='" .. Filter .. "'") or ""))
    return self
end

--- (Internal) Derive intercept target data from the attached INTEL.
-- Returns a unit-data table identical in structure to _GetUnitData(),
-- or nil when no suitable contact is available.
-- @param #REDGCI self
-- @param #table FighterData  Fighter unit data (for proximity tie-break).
-- @return #table or nil
function REDGCI:_GetTargetFromIntel(FighterData)
    if not self.Intel or not self.Intel:Is("Running") then return nil end

    local contacts = self.Intel:GetContactTable()
    if not contacts then return nil end

    local best      = nil
    local bestScore = -math.huge

    for _, contact in pairs(contacts) do --#INTEL.Contact

        -- Aircraft contacts only
        if contact.ctype == INTEL.Ctype.AIRCRAFT then

        -- Optional name filter
        if self.IntelTargetFilter and
           not string.find(contact.groupname, self.IntelTargetFilter, 1, true) then
           -- goto continue
        end

        if not contact.position then end --goto continue end

        local pos = contact.position
        local dx  = pos.x - FighterData.x
        local dz  = pos.z - FighterData.z
        local rng = math.sqrt(dx * dx + dz * dz)

        -- Score: threat level primary; range as tie-break (closer = higher)
        local score = (contact.threatlevel or 0) * 100000 - rng

        if score > bestScore then
            bestScore = score
            best = contact
        end
      end
    end

    if not best then return nil end

    local pos = best.position
    local vel = best.velocity or { x = 0, y = 0, z = 0 }
    local alt = best.altitude or (pos and pos.y) or 0

    return {
        x    = pos.x,
        y    = alt,
        z    = pos.z,
        spd  = best.speed or 0,
        vx   = vel.x or 0,
        vy   = vel.y or 0,
        vz   = vel.z or 0,
        hdg  = best.heading or 0,
        fuel = 1.0,  -- not available from INTEL
    }
end

-- ─────────────────────────────────────────────────────────────
--  FSM handlers
-- ─────────────────────────────────────────────────────────────

--- Called when Start event fires (Stopped → Running).
-- Initializes localization, SRS, context, F10 menu, and schedules first tick.
-- @param #REDGCI self
function REDGCI:onafterStart(From, Event, To)
    self:I(self.lid .. "Starting...")

    self:_InitLocalization()
    self:_InitSRS()
    self:_SetRadar(false)
    self:_SetWeaponsFree(false)
    
    RedGCI.getCtxId(self.Callsign)
    self:_SetupF10Menu()

    local mode_str = self.IsAIPlane and " [AI]" or " [Human]"
    trigger.action.outTextForCoalition(
        self.Coalition,
        "[GCI] Системы готовы. Жду цель." .. mode_str, 5)

    self:I(self.lid .. "Ready. Fighter='" .. self.FighterGroupName ..
           "' Target='" .. self.TargetGroupName ..
           "' Mode=" .. (self.IsAIPlane and "AI" or "Human"))

    -- Schedule first tick after short delay
    self:__Status(-2)
end

--- Main tick — called every TickInterval seconds while Running.
-- @param #REDGCI self
function REDGCI:onafterStatus(From, Event, To)
    local f = self:_GetUnitData(self.FighterGroupName)
    local t = self.Intel and self:_GetTargetFromIntel(f)
           or self:_GetUnitData(self.TargetGroupName)

    if not f then
        self:I(self.lid .. "Fighter '" .. self.FighterGroupName .. "' not found — stopping.")
        self:Stop()
        return
    end

    if not t then
        self._contact_lost_ticks = self._contact_lost_ticks + 1
        self:I(self.lid .. "Contact lost — tick " .. self._contact_lost_ticks ..
               "/" .. self.ContactLostTimeout)

        if self._contact_lost_ticks == 1 then
            -- First missing tick: tell pilot to stand by, keep last heading
            self:_Transmit("NOTCH_ENTRY|delay=1.5", nil, nil)
        elseif self._contact_lost_ticks >= self.ContactLostTimeout then
            -- Timeout expired: target is genuinely gone (destroyed or escaped)
            self:I(self.lid .. "Contact timeout — declaring target gone.")
            if self._prev_radar then
                self:_SetRadar(false)
            end
            self:_Transmit("MERGE_SPLASH|delay=1.5", nil, nil)
            if self.IsAIPlane and self.HomeBase then
                self:_PushWaypoint(
                    self.HomeBase.x, self.HomeBase.y,
                    1000, f.spd * 0.8, true)
            end
            self:Stop()
            return
        end
        -- Ticks 2…(timeout-1): stay silent, hold course
        self:__Status(-self.TickInterval)
        return
    end

    -- Contact (re-)acquired — reset counter
    self._contact_lost_ticks = 0

    -- ── 1. Intercept geometry (C kernel) ──────────────────────
    local hdg, tti, mode, wf, range, aspect, ip_x, ip_z, ip_y =
        RedGCI.computeIntercept(f, t)

    if self.Debug then
        env.info(string.format(
            self.lid .. "hdg=%d tti=%d mode=%s wf=%s range=%d aspect=%d ip_x=%d ip_z=%d ip_y=%d",
            hdg, tti, mode, tostring(wf), range, aspect, ip_x, ip_z, ip_y))
    end

    if mode == "NONE" then
        self:_Log("No intercept solution (fighter too slow?)")
        self:__Status(-self.TickInterval)
        return
    end

    -- ── 2. Closure rate ───────────────────────────────────────
    local dx   = t.x - f.x
    local dz   = t.z - f.z
    local dist = math.sqrt(dx*dx + dz*dz)
    local closure = 0
    if dist > 1 then
        closure = -((t.vx - f.vx) * dx/dist + (t.vz - f.vz) * dz/dist)
    end

    -- ── 3. AI radar lock at COMMIT range ─────────────────────
    local ai_radar_lock = self.IsAIPlane and (range < 30000)

    -- ── 4. FSM update (C kernel) ──────────────────────────────
    local state, _ = RedGCI.fsmUpdate(
        self.Callsign,
        range, aspect, closure, t.y - f.y, f.fuel,
        self._pilot_flags.radar or ai_radar_lock,
        self._pilot_flags.visual,
        self._pilot_flags.threat)

    if not state then
        self:_Log("FSM error from C kernel")
        self:__Status(-self.TickInterval)
        return
    end

    -- ── 5. State-transition side effects ─────────────────────
    if state ~= self._prev_state then
        self:I(self.lid .. "State: " .. (self._prev_state or "START") .. " → " .. state)

        if state == "COMMIT" then
            self:_Transmit("RADAR_ON|delay=1.5", nil, nil)
            self:_TransmitPilot("ACK_COMMIT", {}, 1.5)
        elseif state == "ABORT" or state == "RTB" then
            self:_SetRadar(false)
            self._prev_radar = false
            if self.HomeBase then
                self:_PushWaypoint(
                    self.HomeBase.x, self.HomeBase.y,
                    1000, f.spd * 0.8, true)
            end
            -- Pilot ACK for abort includes RTB heading
            local rtb_hdg = ""
            if self.HomeBase then
                local dx_h = self.HomeBase.x - f.x
                local dz_h = self.HomeBase.y - f.z
                rtb_hdg = string.format("%03d", math.floor(math.deg(math.atan2(dz_h, dx_h)) % 360))
            end
            self:_TransmitPilot("ACK_ABORT", { HDG = rtb_hdg }, 3.0)
        end
    end

    -- ── 6. Waypoint + radar per state (every tick) ────────────
    if state == "VECTOR" then
        self:_SetRadar(false)
        local cruise_spd    = math.max(f.spd, 200)
        local wx, wz, wy    = self:_ComputeRollingWaypoint(f, ip_x, ip_z, ip_y + self.AltOffset)
        self:_PushWaypoint(wx, wz, wy, cruise_spd)

    elseif state == "COMMIT" or state == "RADAR_CONTACT" then
        if self._prev_radar == false then
           self:_SetRadar(true)
           self:_SetWeaponsFree(true)
           self._prev_radar = true        
        end
        local wx, wz, wy = self:_ComputeRollingWaypoint(f, ip_x, ip_z, ip_y + self.AltOffset)
        self:_PushWaypoint(wx, wz, wy, f.spd)

    elseif state == "NOTCH" then
        if self._prev_radar == true then
           self:_SetRadar(false)
           self._prev_radar = false       
        end
    end

    -- ── 7. Merge phase ────────────────────────────────────────
    if state == "MERGE" then
        local f_hdg   = math.atan2(f.vx, f.vz)
        local to_tgt  = math.atan2(t.x - f.x, t.z - f.z)
        local rel_brg = math.deg(to_tgt - f_hdg) % 360

        local _, token_str, silence, _ =
            RedGCI.mergeUpdate(self.Callsign,
                rel_brg, range, t.y - f.y, false)

        if not silence then
            local dir_rl = self:_DeriveDirRL(f, t)
            self:_Transmit(token_str, nil, dir_rl)
        end

        self:_Log(string.format("[%s] range=%.0fm → %s",
            state, range, silence and "SILENCE" or tostring(token_str)))

        self._prev_state = state
        
        if self._prev_radar == false or self._prev_wf == false then
          self:_SetRadar(true)
          self:_SetWeaponsFree(true)
        end
        
        self:__Status(-self.TickInterval)
        return
    end

    -- ── 8. Build and send transmission ────────────────────────
    -- WF comes directly from the C kernel (range check + one-tick closure
    -- projection). No Lua-side override needed.
    local effective_wf = wf

    -- VECTOR: report intercept altitude (ip_y) so pilot climbs/descends to geometry.
    -- All other states: report real target altitude (t.y) for situational awareness.
    local silence, token_str, weapons_free
    if state == "VECTOR" then
        silence, token_str, weapons_free, _ =
            RedGCI.buildTransmission(
                self.Callsign,
                hdg, tti, mode, effective_wf,
                ip_x, ip_z, ip_y,
                ip_y + self.AltOffset)
    else
        silence, token_str, weapons_free, _ =
            RedGCI.buildTransmission(
                self.Callsign,
                hdg, tti, mode, effective_wf,
                ip_x, ip_z, ip_y,
                t.y)   -- pass real target altitude (no offset) for ALT token
    end

    if not silence then
        local dir_lr = self:_DeriveDirLR(aspect)
        local dir_rl = self:_DeriveDirRL(f, t)
        self:_Transmit(token_str, dir_lr, dir_rl)

        -- Pilot ACK for VECTOR (includes heading repeat — feels most natural)
        if state == "VECTOR" then
            local gci_delay = tonumber(token_str and token_str:match("delay=([%d%.]+)")) or 3.0
            self:_TransmitPilot("ACK_VECTOR",
                { HDG = string.format("%03d", math.floor(hdg)) },
                gci_delay)
        end
    end

    -- Weapons free edge: fire once on first transition
    if weapons_free and not self._prev_wf then
        self:_Transmit("WEAPONS_FREE|delay=1.0", nil, nil)
        self:_TransmitPilot("ACK_WEAPONS_FREE", {}, 1.0)
        self:_SetRadar(true)
        self:_SetWeaponsFree(true)
        self._prev_radar = true
        self._prev_wf = true
    end
    self._prev_wf = weapons_free or false

    self:_Log(string.format(
        "[%s] HDG:%d TTI:%ds MODE:%s WF:%s RANGE:%.0fm ASPECT:%.1f° → %s",
        state, math.floor(hdg), math.floor(tti or 0), mode,
        tostring(weapons_free), range, aspect,
        silence and "SILENCE" or tostring(token_str)))

    self._prev_state = state
    self:__Status(-self.TickInterval)
end

--- Called when Stop event fires.
-- @param #REDGCI self
function REDGCI:onafterStop(From, Event, To)
    self:I(self.lid .. "Stopped.")
end

env.info("[REDGCI] v" .. REDGCI.version .. " loaded.")
