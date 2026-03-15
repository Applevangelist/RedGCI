--- REDGCI_Intel.lua
-- Two independent extensions loaded after MOOSE.lua and REDGCI.lua:
--
--   1.  INTEL:SetDopplerRadar()   — 70/80s pulse-Doppler ground-clutter model
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
--   intel:SetDopplerRadar()        -- 70/80s defaults
--   intel:__Start(2)
--
--   local gci = REDGCI:New("MiG-29", nil, "Сокол-1", coalition.side.RED)
--   gci:SetIntelSource(intel)
--   gci:Start()

-- ══════════════════════════════════════════════════════════════════
--  Part 1 — INTEL Doppler radar extension
--
--  Models three phenomena of 1970/80s pulse-Doppler ground-radar:
--
--   A) GROUND CLUTTER (AGL threshold)
--      Low-flying targets blend into terrain returns. Below DopplerMinAltAGL
--      detection probability drops linearly to 0 at 0 m AGL.
--
--   B) VELOCITY NOTCH (beam aspect)
--      The MTI (Moving Target Indicator) filter suppresses returns with
--      near-zero Doppler shift.  Targets flying perpendicular to the radar
--      beam (radial-velocity fraction < sin(NotchHalfDeg)) are rejected.
--      Classic P-18/P-37 notch was ≈ ±12–18° around 90° aspect.
--
--   C) MINIMUM SPEED GATE
--      Very slow targets (taxiing aircraft, hovering) can't be separated
--      from ground clutter by their Doppler shift alone.
-- ══════════════════════════════════════════════════════════════════

--- Enable 70/80s era pulse-Doppler ground-clutter simulation.
-- Only affects contacts detected via radar (DetectRadar=true paths).
-- Has no effect on visual, optical, IRST, RWR or datalink detections.
-- @param #INTEL self
-- @param #number MinAltAGL   Min AGL altitude in metres for reliable detection.
--                            Below this the detection probability drops linearly.
--                            Default 500 m (≈ typical clutter floor for P-18 / P-37).
-- @param #number NotchHalfDeg Half-width of the velocity notch in degrees.
--                            Targets whose radial-velocity fraction falls within
--                            sin(NotchHalfDeg) of zero are suppressed.
--                            Default 15° (gives a ±15° notch around 90° beam).
-- @param #number MinSpeedMps Minimum speed in m/s that the MTI filter can track.
--                            Slower targets are treated as ground clutter.
--                            Default 50 m/s (≈ 100 kt).
-- @return #INTEL self
function INTEL:SetDopplerRadar(MinAltAGL, NotchHalfDeg, MinSpeedMps)
    self.DopplerRadar        = true
    self.DopplerMinAltAGL    = MinAltAGL    or 500
    self.DopplerNotchSin     = math.sin(math.rad(NotchHalfDeg or 15))
    self.DopplerMinSpeedMps  = MinSpeedMps  or 50
    return self
end

--- Disable Doppler radar simulation.
-- @param #INTEL self
-- @return #INTEL self
function INTEL:SetDopplerRadarOff()
    self.DopplerRadar = false
    return self
end

--- (Internal) Check whether a target unit would be detected by a 70/80s
-- pulse-Doppler radar located at the given radar unit position.
-- Returns true = detected, false = suppressed.
-- @param #INTEL self
-- @param Wrapper.Unit#UNIT TargetUnit
-- @param Wrapper.Unit#UNIT RadarUnit
-- @return #boolean
-- @return #string Rejection reason: "speed", "clutter", "notch"
function INTEL:_CheckDopplerDetection(TargetUnit, RadarUnit)

    -- ── A. Minimum speed gate ──────────────────────────────────
    local spd = TargetUnit:GetVelocityMPS()
    if spd < self.DopplerMinSpeedMps then
        return false, "speed"
    end

    -- ── B. AGL ground-clutter rejection ───────────────────────
    local agl = TargetUnit:GetAltitude(true)   -- AGL in metres
    if agl < self.DopplerMinAltAGL then
        -- Probability of detection rises linearly from 0 at ground to 1 at MinAltAGL
        local p = agl / self.DopplerMinAltAGL
        if math.random() > p then
            return false, "clutter"
        end
    end

    -- ── C. Velocity notch ─────────────────────────────────────
    -- Compute radial velocity fraction: |v_radial| / |v_total|
    -- A fraction near 0 means the target is flying across the beam → notched out.
    local rpos = RadarUnit:GetVec3()
    local tpos = TargetUnit:GetVec3()
    local tvel = TargetUnit:GetVelocity()

    local dx    = tpos.x - rpos.x
    local dz    = tpos.z - rpos.z
    local slant = math.sqrt(dx * dx + dz * dz)

    if slant > 1 then
        -- Unit vector radar → target (horizontal plane)
        local nx = dx / slant
        local nz = dz / slant
        -- Radial component of target velocity
        local vr     = tvel.x * nx + tvel.z * nz
        local vr_frac = math.abs(vr) / math.max(spd, 1)

        -- vr_frac < sin(NotchHalf)  →  target is within the beam notch
        if vr_frac < self.DopplerNotchSin then
            return false, "notch"
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
        -- Only filter UNIT objects (not STATICs) that are airborne
        if unit:IsInstanceOf("UNIT") and unit:IsAir() then
            local ok, reason = self:_CheckDopplerDetection(unit, Unit)
            if not ok then
                table.insert(remove, name)
                if self.verbose and self.verbose >= 2 then
                    self:T(string.format(
                        "%sDoppler: suppressed %s [%s] by radar %s",
                        self.lid, name, reason, Unit:GetName()))
                end
            end
        end
    end

    for _, name in ipairs(remove) do
        DetectedUnits[name]   = nil
        RecceDetecting[name]  = nil
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
--                contains this substring (case-sensitive).  Useful when
--                multiple INTEL instances share the same contact table.
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

        -- Need a position
        if not contact.position then goto continue end

        local pos = contact.position
        local dx  = pos.x - FighterData.x
        local dz  = pos.z - FighterData.z
        local rng = math.sqrt(dx * dx + dz * dz)

        -- Score: prioritise threat level; use range as tie-break (closer = higher)
        local score = (contact.threatlevel or 0) * 100000 - rng

        if score > bestScore then
            bestScore = score
            best = contact
        end

        ::continue::
    end

    if not best then return nil end

    -- Build unit-data table from INTEL contact
    -- INTEL.Contact uses MOOSE COORDINATE for position; extract raw Vec3
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
        fuel = 1.0,  -- not available from INTEL; assume full
    }
end
