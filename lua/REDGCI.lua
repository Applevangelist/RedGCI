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
        VECTOR              = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, VECTOR {HDG}, altitude {ALT} meters, 900 kph. Target in {TTI_M} minutes.",
        COMMIT_FIRST        = "{CALLSIGN}, BOGEY ahead, {RNG} kilometers, altitude {ALT} meters. Search radar. Look.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, CORRECTION: bearing {ASPECT}, {RNG} kilometers. Why no lock?",
        COMMIT_NUDGE        = "{CALLSIGN}, turn {DIR_LR} ten degrees.",
        RADAR_LOCK_WF       = "{CALLSIGN}, lock confirmed. {RNG} kilometers. WEAPONS FREE. Attack.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, lock confirmed. {RNG} kilometers. Await clearance.",
        RADAR_WF_NOW        = "{CALLSIGN}, WEAPONS FREE.",
        VISUAL_CONFIRM      = "{CALLSIGN}, visual confirmed. WEAPONS FREE.",
        NOTCH_ENTRY         = "{CALLSIGN}, target maneuvering. Standby.",
        NOTCH_UPDATE        = "{CALLSIGN}, target {DIR_RL}, {RNG} kilometers. Hold.",
        ABORT_BINGO         = "{CALLSIGN}, BINGO FUEL. Break off. RTB immediately. Course {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, THREAT WARNING. Break off. Course {HDG}, descend.",
        MERGE_ENTRY         = "{CALLSIGN}, contact {DIR_RL}, {ASPECT} degrees. FIGHT.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, overshoot. Break {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, separate. Climb and reset.",
        MERGE_REATTACK      = "{CALLSIGN}, reattack. Target {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, BLIND. Reset heading {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, good kill. Return to base.",
        RADAR_ON            = "{CALLSIGN}, radar on. Search.",
        WEAPONS_FREE        = "{CALLSIGN}, WEAPONS FREE.",
    },

    -- ── GERMAN ───────────────────────────────────────────────
    de = {
        VECTOR              = "{CALLSIGN}, Kurs {HDG}, Höhe {ALT} Meter, neunhundert.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, Kurs {HDG}, Höhe {ALT} Meter, neunhundert. Ziel in {TTI_M} Minuten.",
        COMMIT_FIRST        = "{CALLSIGN}, Ziel voraus, {RNG} Kilometer, Höhe {ALT} Meter. Radar an. Such.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, Korrektur: Peilung {ASPECT}, {RNG} Kilometer. Warum kein Lock?",
        COMMIT_NUDGE        = "{CALLSIGN}, zehn Grad nach {DIR_LR}.",
        RADAR_LOCK_WF       = "{CALLSIGN}, Lock bestätigt. {RNG} Kilometer. Feuer frei. Angriff.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, Lock bestätigt. {RNG} Kilometer. Warte auf Freigabe.",
        RADAR_WF_NOW        = "{CALLSIGN}, Feuer frei.",
        VISUAL_CONFIRM      = "{CALLSIGN}, Sichtkontakt bestätigt. Feuer frei.",
        NOTCH_ENTRY         = "{CALLSIGN}, Ziel manövriert. Warten.",
        NOTCH_UPDATE        = "{CALLSIGN}, Ziel {DIR_RL}, {RNG} Kilometer. Halten.",
        ABORT_BINGO         = "{CALLSIGN}, BINGO Kraftstoff. Abbruch. Sofort zurück. Kurs {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, BEDROHUNG. Abbruch. Kurs {HDG}, sinken.",
        MERGE_ENTRY         = "{CALLSIGN}, Kontakt {DIR_RL}, {ASPECT} Grad. Angriff!",
        MERGE_OVERSHOOT     = "{CALLSIGN}, Überschuss. Ausbrechen {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, trennen. Steigen und neu ansetzen.",
        MERGE_REATTACK      = "{CALLSIGN}, neu angreifen. Ziel {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, BLIND. Kurs {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, Treffer bestätigt. Kurs nach Hause.",
        RADAR_ON            = "{CALLSIGN}, Radar an. Such.",
        WEAPONS_FREE        = "{CALLSIGN}, Feuer frei.",
    },

    -- ── RUSSIAN ───────────────────────────────────────────────
    ru = {
        VECTOR              = "{CALLSIGN}, курс {HDG}, высота {ALT}, скорость девятьсот.",
        VECTOR_WITH_TTI     = "{CALLSIGN}, курс {HDG}, высота {ALT}, скорость девятьсот. До цели {TTI_M} минут.",
        COMMIT_FIRST        = "{CALLSIGN}, цель впереди, дальность {RNG}, высота {ALT}. Включи локатор. Ищи.",
        COMMIT_NO_LOCK      = "{CALLSIGN}, поправка: азимут {ASPECT}, дальность {RNG}. Почему нет захвата?",
        COMMIT_NUDGE        = "{CALLSIGN}, довернись {DIR_LR} десять градусов.",
        RADAR_LOCK_WF       = "{CALLSIGN}, захват подтверждён. Дальность {RNG}. Цель разрешена. Атакуй.",
        RADAR_LOCK_HOLD     = "{CALLSIGN}, захват подтверждён. Дальность {RNG}. Жди разрешения.",
        RADAR_WF_NOW        = "{CALLSIGN}, цель разрешена.",
        VISUAL_CONFIRM      = "{CALLSIGN}, визуальный. Цель разрешена.",
        NOTCH_ENTRY         = "{CALLSIGN}, цель маневрирует. Жди команды.",
        NOTCH_UPDATE        = "{CALLSIGN}, цель {DIR_RL}, дальность {RNG}. Держи.",
        ABORT_BINGO         = "{CALLSIGN}, топливо критическое. Прекрати атаку. Немедленно домой. Курс {HDG}.",
        ABORT_THREAT        = "{CALLSIGN}, угроза. Прекрати атаку. Курс {HDG}, снижайся.",
        MERGE_ENTRY         = "{CALLSIGN}, контакт {DIR_RL}, {ASPECT} градусов. Бой.",
        MERGE_OVERSHOOT     = "{CALLSIGN}, перелёт. Разворот {DIR_LR}.",
        MERGE_SEPARATION    = "{CALLSIGN}, выход. Набери высоту и повтори.",
        MERGE_REATTACK      = "{CALLSIGN}, повторная атака. Цель {DIR_RL}.",
        MERGE_LOST          = "{CALLSIGN}, потеря контакта. Курс {HDG}.",
        MERGE_SPLASH        = "{CALLSIGN}, молодец. Курс домой.",
        RADAR_ON            = "{CALLSIGN}, включи локатор.",
        WEAPONS_FREE        = "{CALLSIGN}, цель разрешена.",
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
    self.Callsign         = Callsign         or "Сокол-1"
    self.Coalition        = Coalition        or coalition.side.RED

    -- ── Defaults ─────────────────────────────────────────────
    self.Locale           = "ru"
    self.TickInterval     = 10.0
    self.TxRepeatInterval = 30.0
    self.SubtitleTime     = 8
    self.IsAIPlane        = true
    self.HomeBaseName     = nil
    self.HomeBase         = nil    -- Vec2 {x,y}
    self.Debug            = false
    self.WFRange          = 15000  -- metres: AI weapons-free range (C kernel wf=false workaround)

    -- ── SRS defaults ─────────────────────────────────────────
    self.SRSPath          = nil
    self.SRSFreq          = 251
    self.SRSMod           = radio.modulation.AM
    self.SRSCulture       = "ru-RU"
    self.SRSVoice         = MSRS.Voices.Google.Standard.ru_RU_Standard_D
    self.SRSPort          = 5002

    -- ── Internal state (per instance) ─────────────────────────
    self._pilot_flags = { radar=false, visual=false, threat=false }
    self._prev_state  = nil
    self._prev_wf     = false
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

--- Set the AI weapons-free range threshold in metres.
-- Weapons free is declared when the C kernel wf flag is true OR (AI mode AND
-- state is RADAR_CONTACT AND range <= WFRange). Set to 0 to disable the
-- Lua-side override and rely solely on the C kernel.
-- @param #REDGCI self
-- @param #number Meters  Default 15000
-- @return #REDGCI self
function REDGCI:SetWFRange(Meters)
    self.WFRange = Meters or 15000
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
    self._pilot_flags = { radar=false, visual=false, threat=false }
    self._prev_state  = nil
    self._prev_wf     = false
    self._last_tx     = { text="", time=0 }
    RedGCI.reset(self.Callsign)
    self:_SetRadar(false)
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
    self._msrs = MSRS:New(self.SRSPath, self.SRSFreq, self.SRSMod) -- Sound.MSRS#MSRS
    self._msrs:SetPort(self.SRSPort)
    self._msrs:SetLabel("GCI")
    self._msrs:SetCulture(self.SRSCulture)
    self._msrs:SetVoice(self.SRSVoice)
    self._msrs:SetCoalition(self.Coalition)
    self._srs_queue = MSRSQUEUE:New("REDGCI_" .. self.Callsign) -- Sound.MSRS#MSRSQUEUE
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
        self._srs_queue:NewTransmission(
            text,             -- message text
            nil,              -- duration (auto)
            self._msrs,       -- MSRS instance
            delay,            -- start delay
            2,                -- priority
            {GROUP:FindByName(RedGCI.FIGHTER_GROUP)},            -- Subgroups (Subtitle)
            text,             -- subtitle
            self.SubtitleTime,-- subtitle duration
            nil, nil,         -- channel/mod (from msrs)
            nil, nil, nil,    -- gender/culture/voice (from msrs)
            nil,              -- volume
            "GCI"             -- label
        )
    else
        -- Fallback: on-screen text
        trigger.action.outText(text, self.SubtitleTime, false)
    end
end

--- Push a new rolling waypoint to the AI group.
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

    grp:Route({ wp0, wp1 }, 0.2)
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
      grp:OptionROEWeaponFree()
      grp:OptionAlarmStateRed()
      grp:OptionAAAttackRange(1)
    else
      grp:SetOptionRadarUsingNever()
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
    local t = self:_GetUnitData(self.TargetGroupName)

    if not f then
        self:I(self.lid .. "Fighter '" .. self.FighterGroupName .. "' not found — stopping.")
        self:Stop()
        return
    end

    if not t then
        self:I(self.lid .. "Target '" .. self.TargetGroupName .. "' gone — splash/mission end.")
        self:_SetRadar(false)
        self:_Transmit("MERGE_SPLASH|delay=1.5", nil, nil)
        trigger.action.outTextForCoalition(
            self.Coalition, "[GCI] Зона чистая.", 10)
        if self.IsAIPlane and self.HomeBase then
            self:_PushWaypoint(
                self.HomeBase.x, self.HomeBase.y,
                1000, f.spd * 0.8, true)
        end
        self:Stop()
        return
    end

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
        elseif state == "ABORT" or state == "RTB" then
            self:_SetRadar(false)
            if self.HomeBase then
                self:_PushWaypoint(
                    self.HomeBase.x, self.HomeBase.y,
                    1000, f.spd * 0.8, true)
            end
        end
    end

    -- ── 6. Waypoint + radar per state (every tick) ────────────
    if state == "VECTOR" then
        self:_SetRadar(false)
        local cruise_spd    = math.max(f.spd, 200)
        local wx, wz, wy    = self:_ComputeRollingWaypoint(f, ip_x, ip_z, ip_y)
        self:_PushWaypoint(wx, wz, wy, cruise_spd)

    elseif state == "COMMIT" or state == "RADAR_CONTACT" then
        self:_SetRadar(true)
        local wx, wz, wy = self:_ComputeRollingWaypoint(f, ip_x, ip_z, ip_y)
        self:_PushWaypoint(wx, wz, wy, f.spd)

    elseif state == "NOTCH" then
        self:_SetRadar(false)
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
        self:__Status(-self.TickInterval)
        return
    end

    -- ── 8. Build and send transmission ────────────────────────
    -- Effective WF: C kernel flag OR Lua-side override when AI has lock inside WEZ.
    -- (C kernel currently always returns wf=false; remove override once fixed.)
    local effective_wf = wf or (
        self.IsAIPlane              and
        self.WFRange > 0            and
        state == "RADAR_CONTACT"    and
        range <= self.WFRange)

    -- VECTOR: report intercept altitude (ip_y) so pilot climbs/descends to geometry.
    -- All other states: report real target altitude (t.y) for situational awareness.
    local silence, token_str, weapons_free
    if state == "VECTOR" then
        silence, token_str, weapons_free, _ =
            RedGCI.buildTransmission(
                self.Callsign,
                hdg, tti, mode, effective_wf,
                ip_x, ip_z, ip_y,
                ip_y)
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
    end

    -- Weapons free edge: fire once on first transition
    if weapons_free and not self._prev_wf then
        self:_Transmit("WEAPONS_FREE|delay=1.0", nil, nil)
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
