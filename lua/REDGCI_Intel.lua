--- REDGCI_Intel.lua
-- Two independent extensions loaded after MOOSE.lua and REDGCI.lua:
--
--   1.  INTEL:SetDopplerRadar()   — 70/80s pulse-Doppler ground-clutter model
--                                   including RCS-based range scaling and
--                                   aspect-dependent RCS for known DCS types
--   2.  REDGCI:SetIntelSource()   — use an INTEL object as the target source
--
-- Load order in mission script:
--   DO SCRIPT FILE  MOOSE.lua
--   DO SCRIPT FILE  REDGCI.lua
--   DO SCRIPT FILE  REDGCI_Intel.lua   ← this file
--   DO SCRIPT FILE  my_mission.lua
--
-- Example — AI intercept using INTEL + Doppler filter:
--
--   local ewrSet = SET_GROUP:New():FilterPrefixes({"Red EWR"}):FilterOnce()
--   local intel  = INTEL:New(ewrSet, coalition.side.RED, "КГБ")
--   intel:SetDopplerRadar()        -- 70/80s defaults (all sub-options enabled)
--   intel:__Start(2)
--
--   local gci = REDGCI:New("MiG-29", nil, "Сокол-1", coalition.side.RED)
--   gci:SetIntelSource(intel)
--   gci:Start()

-- ══════════════════════════════════════════════════════════════════
--  Part 1 — INTEL Doppler radar extension
--
--  Models four phenomena of a 1970/80s pulse-Doppler ground radar
--  (representative types: Soviet P-18 Spoon Rest, P-37 Bar Lock,
--   P-80 Back Net / NATO AN/TPS-43 / Hughes AN/TPS-70):
--
--   A) GROUND CLUTTER (AGL threshold)
--      Low-flying targets blend into terrain returns. Below DopplerMinAltAGL
--      detection probability drops linearly to 0 at 0 m AGL.
--
--   B) VELOCITY NOTCH (beam aspect)
--      The MTI (Moving Target Indicator) filter suppresses returns with
--      near-zero Doppler shift. Targets flying perpendicular to the radar
--      beam (radial-velocity fraction < sin(NotchHalfDeg)) are rejected.
--      Classic P-18/P-37 notch was ≈ ±12–18° around 90° aspect.
--
--   C) MINIMUM SPEED GATE
--      Very slow targets (taxiing aircraft, hovering) cannot be separated
--      from ground clutter by their Doppler shift alone.
--
--   D) RADAR CROSS SECTION (RCS)
--      Larger targets are detectable at longer ranges. The radar range
--      equation gives R_max ∝ σ^0.25, so detection range is scaled by
--      (σ / σ_ref)^0.25 relative to a reference aircraft (default: 5 m²).
--      RCS also varies with aspect: nose-on ≈ 15% of side-on value.
--      Known DCS aircraft values are stored in INTEL.RCS_Table; unknowns
--      fall back to a category default (fighter/bomber/helicopter).
--      Values are approximate averages from public IISS/Jane's data.
-- ══════════════════════════════════════════════════════════════════

-- ── RCS lookup table (nominal side-on RCS in m²) ─────────────────
-- Frontal (nose-on / tail-on) RCS is modelled as 15% of these values
-- via aspect interpolation in _GetAspectRCS().
-- Sources: public declassified estimates, Jane's, IISS assessments.
INTEL.RCS_Table = {
    -- ── US / NATO fixed-wing ──────────────────────────────────────
    ["A-10C"]              =  8.0,   -- large, flat surfaces, no LO shaping
    ["A-10C_2"]            =  8.0,
    ["F-14A-135-GR"]       =  6.0,   -- variable-sweep; larger than F-16
    ["F-14B"]              =  6.0,
    ["F-15C"]              =  5.0,
    ["F-15E"]              =  5.0,   -- CFTs add modest signature
    ["F-15ESE"]            =  5.0,
    ["F-16A"]              =  1.2,
    ["F-16C bl.50"]        =  1.2,
    ["F-16C bl.52d"]       =  1.2,
    ["F/A-18C"]            =  1.5,
    ["FA-18C_hornet"]      =  1.5,
    ["F/A-18C_hornet"]     =  1.5,
    ["F/A-18F"]            =  2.0,   -- slightly larger two-seater
    ["F-117A"]             =  0.003, -- faceted LO design
    ["F-22A"]              =  0.0001,-- VLO
    ["F-35A"]              =  0.001, -- VLO, approx
    ["B-52H"]              = 100.0,  -- very large, many flat reflectors
    ["B-1B"]               =  0.75,  -- blended-wing LO shaping
    ["B-2A"]               =  0.001, -- VLO flying wing
    ["AV8BNA"]             =  2.0,
    ["Harrier"]            =  2.0,
    ["A-4E-C"]             =  3.0,
    ["Tornado_IDS"]        =  5.0,
    ["Tornado_GR4"]        =  5.0,
    ["F-111F"]             =  5.0,
    ["F-4E"]               =  6.0,   -- large, blunt nose
    ["F-5E"]               =  1.0,   -- small fighter
    ["F-5E-3"]             =  1.0,
    ["Mirage-F1CE"]        =  2.5,
    ["Mirage-F1EE"]        =  2.5,
    ["M-2000C"]            =  2.0,
    ["M-2000-5"]           =  2.0,
    ["C-17A"]              = 50.0,
    ["C-130"]              = 40.0,
    ["KC-130"]             = 40.0,
    ["KC-135"]             = 50.0,
    ["IL-76MD"]            = 45.0,
    ["E-3A"]               = 50.0,   -- plus large rotodome
    -- ── Soviet / Russian fixed-wing ──────────────────────────────
    ["MiG-15bis"]          =  4.0,
    ["MiG-19P"]            =  3.5,
    ["MiG-21Bis"]          =  2.5,   -- small delta
    ["MiG-23MLD"]          =  7.0,   -- variable-sweep, large intakes
    ["MiG-25PD"]           = 14.0,   -- very large, all-metal, Mach-3 design
    ["MiG-25RBT"]          = 14.0,
    ["MiG-29A"]            =  5.0,
    ["MiG-29S"]            =  5.0,
    ["MiG-29G"]            =  5.0,
    ["MiG-29K"]            =  4.0,
    ["MiG-31"]             = 14.0,   -- similar to MiG-25
    ["Su-7B"]              =  6.0,
    ["Su-17M4"]            =  7.0,   -- variable-sweep
    ["Su-24M"]             =  6.0,
    ["Su-24MR"]            =  6.0,
    ["Su-25"]              = 10.0,
    ["Su-25T"]             = 10.0,
    ["Su-25TM"]            = 10.0,
    ["Su-27"]              = 15.0,
    ["Su-30"]              = 15.0,
    ["Su-33"]              = 15.0,   -- wing fold + canards
    ["Su-34"]              = 10.0,   -- some reduction vs Su-27
    ["Su-57"]              =  0.01,  -- PAK-FA LO shaping
    ["Tu-22M3"]            = 20.0,
    ["Tu-95MS"]            = 80.0,
    ["Tu-142"]             = 80.0,
    ["Tu-160"]             = 12.0,   -- blended wing reduces vs Tu-95
    ["An-26B"]             = 30.0,
    ["An-30M"]             = 30.0,
    ["IL-78M"]             = 45.0,
    ["A-50"]               = 50.0,   -- plus rotodome
    -- ── Helicopters ──────────────────────────────────────────────
    ["Mi-8MT"]             =  5.0,
    ["Mi-8MSB"]            =  5.0,
    ["Mi-8MSB-V"]          =  5.0,
    ["Mi-8AMTSh"]          =  5.0,
    ["Mi-24V"]             =  3.5,
    ["Mi-24P"]             =  3.5,
    ["Mi-28N"]             =  2.5,
    ["Ka-50"]              =  2.0,
    ["Ka-52"]              =  2.0,
    ["AH-64D"]             =  3.5,
    ["AH-64D_BLK_II"]      =  3.5,
    ["UH-1H"]              =  3.0,
    ["UH-60L"]             =  3.0,
    ["CH-47D"]             =  8.0,   -- large tandem-rotor
    ["OH-58D"]             =  0.8,   -- small scout
    ["SA342M"]             =  0.8,
    ["SA342L"]             =  0.8,
}

-- Category-based defaults for aircraft types not in the table.
-- Keyed by DCS Group.Category integer.
INTEL.RCS_CategoryDefault = {
    [Group.Category.AIRPLANE]   = 5.0,  -- generic fighter-sized
    [Group.Category.HELICOPTER] = 2.5,  -- generic helicopter
}

-- Reference RCS (m²) for range scaling.  Detection range in SetDopplerRadar
-- is the range at which this reference aircraft is reliably detected.
INTEL.RCS_Reference = 5.0   -- m²

-- Nose-on/tail-on RCS as a fraction of the side-on value.
-- Public estimates for conventional (non-LO) aircraft: ~0.10–0.20.
INTEL.RCS_NoseOnFraction = 0.15


--- Enable 70/80s era pulse-Doppler ground-clutter simulation.
-- Only affects contacts detected via radar (DetectRadar=true paths).
-- Has no effect on visual, optical, IRST, RWR or datalink detections.
-- @param #INTEL self
-- @param #number MinAltAGL     Min AGL altitude in metres for reliable detection.
--                              Below this the detection probability drops linearly.
--                              Default 500 m (≈ clutter floor for P-18 / P-37).
-- @param #number NotchHalfDeg  Half-width of the velocity notch in degrees.
--                              Targets with radial-velocity fraction < sin(NotchHalf)
--                              are suppressed.  Default 15° (≈ P-18 / Bar Lock spec).
-- @param #number MinSpeedMps   Minimum speed in m/s that the MTI filter can track.
--                              Default 50 m/s (≈ 100 kt).
-- @param #number RadarRangeKm  Nominal detection range in km for the reference aircraft
--                              (RCS_Reference, default 5 m²). Used only for RCS range
--                              scaling; has no effect when DopplerRCS is false.
--                              Default 200 km (≈ P-37 instrumented range vs fighter).
-- @param #boolean RCS          If false, disable RCS range scaling (keep A–C only).
--                              Default true.
-- @return #INTEL self
function INTEL:SetDopplerRadar(MinAltAGL, NotchHalfDeg, MinSpeedMps, RadarRangeKm, RCS)
    self.DopplerRadar        = true
    self.DopplerMinAltAGL    = MinAltAGL    or 500
    self.DopplerNotchSin     = math.sin(math.rad(NotchHalfDeg or 15))
    self.DopplerMinSpeedMps  = MinSpeedMps  or 50
    self.DopplerRCS          = (RCS ~= false)   -- default true
    self.DopplerRadarRangeM  = (RadarRangeKm or 200) * 1000
    return self
end

--- Disable Doppler radar simulation.
-- @param #INTEL self
-- @return #INTEL self
function INTEL:SetDopplerRadarOff()
    self.DopplerRadar = false
    return self
end

--- Override the per-type RCS value for a DCS unit type name.
-- Useful for modded aircraft or mission-specific tweaks.
-- @param #INTEL self
-- @param #string TypeName  DCS unit type name (e.g. "MiG-29A")
-- @param #number RCS_m2    Side-on RCS in m²
-- @return #INTEL self
function INTEL:SetTypeRCS(TypeName, RCS_m2)
    INTEL.RCS_Table[TypeName] = RCS_m2
    return self
end

--- (Internal) Compute the aspect-weighted RCS for a target unit as seen
-- from a given radar position.
--
-- The model blends the side-on (maximum) and nose/tail-on (minimum) RCS
-- using the geometry of the target's velocity relative to the radar line:
--
--   σ_eff = σ_base × ( f_nose + (1 − f_nose) × sin²(aspect_from_radial) )
--
-- where aspect_from_radial is 0° when the target flies toward/away from
-- the radar (nose-on) and 90° when the target crosses the beam (side-on).
--
-- @param #INTEL self
-- @param Wrapper.Unit#UNIT TargetUnit
-- @param #table  rpos  Radar position as Vec3 {x,y,z}
-- @param #number spd   Target speed in m/s (pre-computed for efficiency)
-- @param DCS#Vec3 tvel  Target velocity vector (pre-computed)
-- @return #number Effective RCS in m²
function INTEL:_GetAspectRCS(TargetUnit, rpos, spd, tvel)
    -- Look up base (side-on) RCS
    local typename = TargetUnit:GetTypeName()
    local base_rcs = INTEL.RCS_Table[typename]

    if not base_rcs then
        -- Fallback: category default
        local cat = TargetUnit:GetGroup() and TargetUnit:GetGroup():GetCategory()
        base_rcs = (cat and INTEL.RCS_CategoryDefault[cat]) or INTEL.RCS_Reference
    end

    -- Aspect-dependent factor
    if spd < 1 then return base_rcs end

    local tpos = TargetUnit:GetVec3()
    local dx   = rpos.x - tpos.x   -- vector target → radar (horizontal)
    local dz   = rpos.z - tpos.z
    local d    = math.sqrt(dx * dx + dz * dz)
    if d < 1 then return base_rcs end

    -- cos of angle between target velocity and target→radar line
    -- = 1: nose/tail directly toward radar; = 0: pure crossing (beam)
    local cos_a = (tvel.x * dx + tvel.z * dz) / (spd * d)
    -- sin²(aspect_from_radial) = 1 − cos² ; gives 0 nose-on, 1 beam-on
    local sin2_a = 1.0 - cos_a * cos_a

    local f = INTEL.RCS_NoseOnFraction
    return base_rcs * (f + (1.0 - f) * sin2_a)
end

--- (Internal) Check whether a target unit would be detected by a 70/80s
-- pulse-Doppler radar located at the given radar unit position.
-- @param #INTEL self
-- @param Wrapper.Unit#UNIT TargetUnit
-- @param Wrapper.Unit#UNIT RadarUnit
-- @return #boolean  true = detected
-- @return #string   rejection reason: "speed" | "clutter" | "notch" | "rcs"
function INTEL:_CheckDopplerDetection(TargetUnit, RadarUnit)

    -- Pre-compute common geometry (shared by notch + RCS checks)
    local spd  = TargetUnit:GetVelocityMPS()
    local rpos = RadarUnit:GetVec3()
    local tpos = TargetUnit:GetVec3()
    local tvel = TargetUnit:GetVelocity()

    local dx    = tpos.x - rpos.x
    local dz    = tpos.z - rpos.z
    local slant = math.sqrt(dx * dx + dz * dz)  -- 2-D slant range in metres

    -- ── A. Minimum speed gate ──────────────────────────────────
    if spd < self.DopplerMinSpeedMps then
        return false, "speed"
    end

    -- ── B. AGL ground-clutter rejection ───────────────────────
    local agl = TargetUnit:GetAltitude(true)   -- metres AGL
    if agl < self.DopplerMinAltAGL then
        -- P(detect) rises linearly from 0 at deck to 1 at DopplerMinAltAGL
        if math.random() > (agl / self.DopplerMinAltAGL) then
            return false, "clutter"
        end
    end

    -- ── C. Velocity notch ─────────────────────────────────────
    if slant > 1 then
        local nx     = dx / slant
        local nz     = dz / slant
        local vr     = tvel.x * nx + tvel.z * nz   -- radial velocity (m/s)
        local vr_frac = math.abs(vr) / math.max(spd, 1)

        if vr_frac < self.DopplerNotchSin then
            return false, "notch"
        end
    end

    -- ── D. RCS-based range scaling ─────────────────────────────
    -- R_max ∝ σ^0.25  (from the radar range equation).
    -- Effective detection range = DopplerRadarRangeM × (σ_eff / σ_ref)^0.25
    -- Beyond that range: target not detected (hard cutoff at 100%; soft fade
    -- starts at 80% of R_max to smooth the transition).
    if self.DopplerRCS and slant > 1 then
        local sigma = self:_GetAspectRCS(TargetUnit, rpos, spd, tvel)
        -- (σ/σ_ref)^0.25 — clamp to avoid log of 0 for VLO aircraft
        local scale  = (sigma / INTEL.RCS_Reference) ^ 0.25
        local R_max  = self.DopplerRadarRangeM * scale

        if slant > R_max then
            return false, "rcs"
        end

        -- Soft fade zone: linear probability drop from 1 at 80% R_max to 0 at R_max
        local fade_start = R_max * 0.80
        if slant > fade_start then
            local p = (R_max - slant) / (R_max - fade_start)  -- 1→0
            if math.random() > p then
                return false, "rcs"
            end
        end
    end

    return true
end


-- ── Monkey-patch GetDetectedUnits to apply Doppler filter ─────────
--
-- We wrap the original function so the Doppler post-filter is transparent:
-- the existing RadarBlur / RadarAcceptRange logic is unchanged, and the
-- Doppler check runs once after all units have been collected.

local _INTEL_GetDetectedUnits_orig = INTEL.GetDetectedUnits

function INTEL:GetDetectedUnits(Unit, DetectedUnits, RecceDetecting,
                                  DetectVisual, DetectOptical, DetectRadar,
                                  DetectIRST, DetectRWR, DetectDLINK)

    -- Run the original detection
    _INTEL_GetDetectedUnits_orig(self, Unit, DetectedUnits, RecceDetecting,
                                   DetectVisual, DetectOptical, DetectRadar,
                                   DetectIRST, DetectRWR, DetectDLINK)

    -- Apply Doppler post-filter only when radar channel is active
    if not self.DopplerRadar then return end
    if DetectRadar == false   then return end

    local remove = {}
    for name, unit in pairs(DetectedUnits) do
        -- Only filter live UNIT objects (not STATICs) that are airborne
        if unit:IsInstanceOf("UNIT") and unit:IsAir() then
            local ok, reason = self:_CheckDopplerDetection(unit, Unit)
            if not ok then
                table.insert(remove, name)
                if self.verbose and self.verbose >= 2 then
                    self:T(string.format(
                        "%sDoppler: suppressed %s [%s] by %s",
                        self.lid, name, reason, Unit:GetName()))
                end
            end
        end
    end

    for _, name in ipairs(remove) do
        DetectedUnits[name]  = nil
        RecceDetecting[name] = nil
    end
end


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
        if contact.ctype ~= INTEL.Ctype.AIRCRAFT then
            goto continue
        end

        -- Optional name filter
        if self.IntelTargetFilter and
           not string.find(contact.groupname, self.IntelTargetFilter, 1, true) then
            goto continue
        end

        if not contact.position then goto continue end

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

        ::continue::
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
