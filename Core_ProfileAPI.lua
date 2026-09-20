-- ============================================================
-- BuzzardFrames: Core_ProfileAPI.lua
-- Read-only profile accessors and capacity-tier logic.
-- Consumers (Indicators, BFLayout, SetupMode, Options) call these
-- to ask "what settings apply right now?" given test mode state,
-- active layout, current instance capacity, etc.
-- Extracted from Core.lua in the Core split refactor.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- ============================================================
-- SHARED SLOT CONSTANTS
-- ============================================================
-- Slot -> flat type: party-typed slots only accept party flats;
-- raid-typed slots only accept raid flats. Read by the options panel
-- (Layouts page, Preview labels) and by Core_Migrations.
BF.SLOT_TYPE = {
    solo           = "party",
    openWorldParty = "party",
    dungeon        = "party",
    delve          = "party",
    arena          = "party",
    raidOpen       = "raid",
    raid20         = "raid",
    raid25         = "raid",
    raid30         = "raid",
    raid40         = "raid",
    bg15           = "raid",
    bg40           = "raid",
}

-- Human-readable slot labels (Preview labels, the "layout in use" popup
-- in Layout Management, the panel status strip).
BF.SLOT_LABELS = {
    solo           = "Solo",
    openWorldParty = "Party (Open World)",
    dungeon        = "Dungeon",
    delve          = "Delve",
    arena          = "Arena",
    raidOpen       = "Raid (Open World)",
    raid20         = "Raid (20 Man)",
    raid25         = "Raid (25 Man)",
    raid30         = "Raid (30 Man)",
    raid40         = "Raid (40 Man)",
    bg15           = "Battleground (15 Man)",
    bg40           = "Battleground (40 Man)",
}

-- ============================================================
-- CAPACITY TIER HELPERS
-- ============================================================
-- Returns true when the player is in a raid group of more than 5 members
-- while inside an instance type that normally always resolves as "party"
-- (dungeon, scenario, arena). In that case the group cannot be rendered as
-- a party (only 5 party units exist), so callers fall back to raid tab /
-- slot / context resolution until the raid shrinks to 5 or is converted.
function BF:IsOversizedRaidInPartyInstance()
    local _, instanceType = GetInstanceInfo()
    if instanceType ~= "party" and instanceType ~= "scenario" and instanceType ~= "arena" then
        return false
    end
    return IsInRaid() and (GetNumGroupMembers() or 0) > 5
end

-- Determine which capacity tier to use based on instance max players
function BF:GetCapacityTier()
    local _, instanceType, _, _, maxPlayers = GetInstanceInfo()

    -- Use maxPlayers for actual raid instances AND battlegrounds ("pvp").
    -- GetInstanceInfo returns the true BG capacity for pvp instances, not the
    -- current fill — so this gives the correct tier immediately on zone-in.
    -- For "party" (dungeons), "scenario", "arena", and "none" we fall back to
    -- group size. This prevents follower dungeons (instanceType="party",
    -- maxPlayers=20) from incorrectly triggering raid20 mode.
    -- Guard against transient 0/nil from GetInstanceInfo during roster changes.
    -- The raid25 rung is the Midnight "Mythic Flex" capacity (25). It sits
    -- between 20 and 30 so a 25-player raid stops resolving as raid30 and
    -- gets a slot of its own -- see the raid25 entry in BF.SLOT_TYPE.
    if (instanceType == "raid" or instanceType == "pvp") and maxPlayers and maxPlayers > 0 then
        if maxPlayers <= 20 then
            return "raid20", maxPlayers
        elseif maxPlayers <= 25 then
            return "raid25", maxPlayers
        elseif maxPlayers <= 30 then
            return "raid30", maxPlayers
        else
            return "raid40", maxPlayers
        end
    end

    -- Open world, dungeons, or no instance data: use actual group size
    local groupSize = IsInRaid() and GetNumGroupMembers() or 0
    if groupSize <= 20 then
        return "raid20", groupSize
    elseif groupSize <= 25 then
        return "raid25", groupSize
    elseif groupSize <= 30 then
        return "raid30", groupSize
    else
        return "raid40", groupSize
    end
end

-- ============================================================
-- ACTIVE TAB (group-type key) RESOLUTION
-- ============================================================
-- Returns the frames sub-tab key that reflects the currently active settings
-- Under the flat model there are no tier-specific test-mode flags to sync,
-- so SyncOpenWorldSetupMode has been removed. Open World dropdown changes
-- simply save to the flat profile and let the next live resolve pick them up.

function BF:GetActiveTab()
    -- Kept as a thin alias for GetTrueActiveTab. Setup mode no longer pins
    -- a tab; the options chrome drives editing via _modifyingFlat instead.
    return self:GetTrueActiveTab()
end

-- Returns the truly active tab based purely on game state, ignoring setup/test mode.
function BF:GetTrueActiveTab()
    local _, instanceType = GetInstanceInfo()
    -- Neighborhood (player housing, added in 12.0.5) routes through the same
    -- tab-selection logic as the open world. Explicit branch for visibility;
    -- the unknown-type fallthrough below would produce the same result.
    local inOpenWorld = instanceType == "none" or instanceType == "neighborhood"

    if inOpenWorld then
        if IsInRaid() then
            -- Phase L: ResolveTier is gone (the enableRaid* walk it did was
            -- consumed nowhere -- every caller of this function only tests
            -- gt == "party"); return the raw tier.
            local groupSize = GetNumGroupMembers()
            if groupSize <= 20 then
                return "raid20"
            elseif groupSize <= 25 then
                return "raid25"
            elseif groupSize <= 30 then
                return "raid30"
            else
                return "raid40"
            end
        elseif IsInGroup() then
            -- In a party (not raid) in the open world: always party.
            -- Matches the reference design's group-changed rule: "party" when
            -- GetNumGroupMembers() > 0 and not IsInRaid().
            return "party"
        else
            -- Actually solo in the open world: setup mode reflects the
            -- party tab. Solo-slot layout assignment (including the "none"
            -- hide route) is handled downstream in UpdateVisibility via
            -- openWorldNoneOverride; this function only picks the tab.
            return "party"
        end
    end

    -- Battlegrounds (pvp): use raid tier logic — they use raid frames.
    -- GetCapacityTier reads maxPlayers from GetInstanceInfo for pvp, so this
    -- returns the correct tier (e.g. raid40 for a 40-man BG).
    if instanceType == "pvp" then
        return (self:GetCapacityTier())
    end

    -- Inside a dungeon, delve, Torghast, or arena: always party, unless we
    -- are in a raid group of 6+ (cannot be shown as a party) -- then fall
    -- back to the raid tier resolved from actual group size.
    if instanceType == "party" or instanceType == "scenario"
            or instanceType == "arena" then
        if self:IsOversizedRaidInPartyInstance() then
            return (self:GetCapacityTier())
        end
        return "party"
    end

    -- Inside a raid instance: use tier logic
    if instanceType == "raid" then
        return (self:GetCapacityTier())
    end

    -- Unknown / unrecognized instance types (e.g. "neighborhood" added by
    -- Blizzard in 12.0.5, or anything else GetInstanceInfo returns that we
    -- don't explicitly handle above): resolve by actual group composition
    -- the same way the open-world branch does. Defaulting to raid tier here
    -- forced _contextIsParty=false in ReloadLayout for party-sized groups
    -- visiting these zones and made the render pull settings off the raid
    -- flat — see resolveSlotFromContext / ResolveContext which already use
    -- this group-based fallback for unknown types.
    if IsInRaid() then
        return (self:GetCapacityTier())
    elseif IsInGroup() then
        return "party"
    else
        return "party"
    end
end

-- ============================================================
-- AUTO HIDE GROUPS BY INSTANCE SIZE
-- ============================================================
-- The highest raid group index (1-8) the CURRENT INSTANCE can fill.
--
-- Derived from GetInstanceInfo's maxPlayers -- the same source
-- GetCapacityTier already trusts, and the reason this needs no difficulty
-- table: 20-man Mythic -> 4, 25-man Mythic Flex (Midnight) -> 5, 30-man
-- flex -> 6, 40-man -> 8. A difficulty added after this was written falls
-- out correctly on its own; a hardcoded difficultyID map would not, and
-- would be wrong silently.
--
-- Raid instances ONLY. Open world (instanceType "none"), dungeons,
-- scenarios, arenas and battlegrounds all answer 8 -- "hide nothing".
-- Open world is an explicit requirement (a 12-man open-world raid must
-- still show all eight groups), and the others have no raid-group
-- capacity worth honoring. A transient 0/nil maxPlayers during a zone
-- change also answers 8, so a bad frame hides nothing rather than
-- collapsing the raid.
function BF:GetInstanceMaxGroup()
    local _, instanceType, _, _, maxPlayers = GetInstanceInfo()
    if instanceType ~= "raid" then return 8 end
    if not maxPlayers or maxPlayers <= 0 then return 8 end
    local g = math.ceil(maxPlayers / 5)
    if g < 1 then g = 1 elseif g > 8 then g = 8 end
    return g
end

-- The single answer to "which raid groups should render for this flat?",
-- returned as a pair so a caller pays for it ONCE and then loops:
--
--   local cap, sg = self:GetGroupVisibilityRule(ap)
--   for i = 1, 8 do
--       if i <= cap and not (sg and sg[i] == false) then ... end
--   end
--
-- Auto ON  -> cap = the instance's capacity, sg = nil. The per-group
--             toggles are not consulted (and the options page hides them),
--             so the two mechanisms can never half-apply.
-- Auto OFF -> cap = 8, sg = the flat's showGroup. Exactly the old rule.
--
-- ap may be nil or a party flat; both answer (8, nil).
function BF:GetGroupVisibilityRule(ap)
    if not ap then return 8, nil end
    if ap.autoHideGroupsByInstance then
        return self:GetInstanceMaxGroup(), nil
    end
    return 8, ap.showGroup
end

-- Counts the number of raid groups (1-8) that currently have at least one
-- member assigned. Returns 0 when not in a raid. Thin wrapper around
-- GetPopulatedGroups (ApplyProfile.lua).
function BF:GetOccupiedGroupCount()
    if not IsInRaid() then return 0 end
    local pg = self:GetPopulatedGroups()
    local c = 0
    if pg then
        for i = 1, 8 do
            if pg[i] then c = c + 1 end
        end
    end
    return c
end

-- Returns an adjusted frame width so that the actual raid's columns fill the
-- same total horizontal span as a full 40-man raid would, keeping frame height
-- unchanged.  Only meaningful when p.scaleRaidToFit is true.
--
-- Formula: solve for fittedWidth in
--   actualCols * fittedWidth + (actualCols-1) * spacingH
--     == fullCols * baseWidth + (fullCols-1) * spacingH
-- → fittedWidth = (fullCols * (baseWidth + spacingH) - spacingH) / actualCols
-- Result is floored to a whole pixel and clamped to at least 1.
--
-- testCount: pass a specific frame count when in test/setup mode; pass nil to
-- derive it from the live group size.
function BF:GetFitFrameWidth(baseWidth, spacingH, testCount)
    -- Sorting settings moved to rpDB.profile.sorting.* (or flat.sorting.*
    -- when the per-layout toggle is ON). Route reads through
    -- GetSectionProfile using the active raid flat so per-layout
    -- overrides are respected at runtime.
    local sp = self:GetSectionProfile("sorting", self:GetRaidProfile())
    local unitsPerColumn = (sp and sp.sortingMode == "GROUP") and 5 or (sp and sp.unitsPerColumn or 5)
    local fullCount = 40  -- the reference size we always fit to

    -- Determine the visible column count. In GROUP mode, columns = number
    -- of occupied raid groups (the visually meaningful unit). In ROLE mode,
    -- columns = ceil(playerCount / unitsPerColumn).
    --
    -- When testCount is passed, we're in setup/test mode and it directly
    -- represents a frame count; derive columns from it the same way a live
    -- raid with that many players would.
    local isGroupMode = sp and sp.sortingMode == "GROUP"
    local fullCols = math.ceil(fullCount / unitsPerColumn)
    local actualCols
    if testCount then
        actualCols = math.ceil(testCount / unitsPerColumn)
    elseif isGroupMode then
        -- In GROUP mode each occupied raid group renders as its own
        -- column. 3 players in 3 different groups = 3 columns.
        actualCols = self:GetOccupiedGroupCount() or 0
    else
        -- ROLE mode: flat list, columns derive from total player count.
        local n = IsInRaid() and GetNumGroupMembers() or 0
        if n < 0 then n = 0 elseif n > 40 then n = 40 end
        actualCols = math.ceil(n / unitsPerColumn)
    end

    local maxW = self.rpDB.profile.layouts.scaleRaidToFitMaxWidth or 80

    -- No fit needed: not in a raid (actualCols == 0) or already at full
    -- width (actualCols >= fullCols). Still apply the max-width cap so
    -- the user's Frame Max Width setting is honored everywhere.
    if actualCols <= 0 or actualCols >= fullCols then
        if baseWidth > maxW then return maxW end
        return baseWidth
    end

    local fittedWidth = (fullCols * (baseWidth + spacingH) - spacingH) / actualCols
    fittedWidth = math.max(1, math.floor(fittedWidth))
    -- Cap at the user-configured max so very small raids don't produce
    -- enormous frames.
    if fittedWidth > maxW then fittedWidth = maxW end
    return fittedWidth
end

-- ============================================================
-- SLOT RESOLUTION (Phase 2: Layouts by Instance Type)
-- ============================================================
-- GetActiveSlot returns one of the 11 slot keys based on current
-- game context (instance type, group composition, test-mode flags).
-- ResolveActiveFlat walks the override precedence chain
-- (spec > role > global) to pick a flat ID for that slot.
-- GetRaidProfile / GetActivePartyProfile / etc. are thin wrappers
-- around those two that return the flat's data table.

-- Shared instance/group resolver. Does NOT consult test-mode flags.
local function resolveSlotFromContext(self)
    local _, instanceType, _, _, maxPlayers = GetInstanceInfo()
    -- Raid of 6+ inside a dungeon/scenario/arena: cannot render as party,
    -- use the open-world raid slot until the raid shrinks or is converted.
    if self:IsOversizedRaidInPartyInstance() then return "raidOpen" end
    if instanceType == "arena"    then return "arena"   end
    if instanceType == "party"    then return "dungeon" end
    if instanceType == "scenario" then return "delve"   end
    if instanceType == "pvp" then
        if maxPlayers and maxPlayers <= 15 then return "bg15" end
        return "bg40"
    end
    if instanceType == "raid" then
        return self:GetCapacityTier()
    end
    -- Neighborhood (player housing, added in 12.0.5): route to the open-world
    -- slots based on group composition. Explicit branch for visibility; the
    -- unknown-type fallthrough below would produce the same result, but
    -- naming neighborhood here documents the intent for future readers.
    if instanceType == "neighborhood" then
        if IsInRaid()  then return "raidOpen"       end
        if IsInGroup() then return "openWorldParty" end
        return "solo"
    end
    -- instanceType == "none" (open world) and any other unrecognized
    -- type fall through to the same group-based slot resolution.
    if IsInRaid()  then return "raidOpen"       end
    if IsInGroup() then return "openWorldParty" end
    return "solo"
end

-- GetActiveSlot: pure context resolution. Setup mode no longer pins a slot --
-- instead, setup mode renders test frames directly from _modifyingFlat, leaving
-- the real-frame render path operating on actual game context.
function BF:GetActiveSlot()
    return resolveSlotFromContext(self)
end

-- ResolveActiveFlat: walks the override precedence chain for a slot.
--   1. specOverrides[specIDStr][slot] if an entry exists for this spec
--   2. roleOverrides[role][slot]      if an entry exists for this role
--   3. instanceLayoutAssignment[slot] (the global)
-- Presence in the overrides table (added via the Role/Spec Layouts UI)
-- is the sole enable gate; there are no enableRoleLayouts/enableSpecLayouts
-- toggles anymore. If a role/spec entry was added but no per-slot override
-- is set for this slot, falls through to the next layer.
-- Returns a flat ID, the literal string "none" (solo-hide), or nil.
function BF:ResolveActiveFlat(slot)
    local lp = self.rpDB.profile.layouts
    local specIDStr = self.playerSpecID and tostring(self.playerSpecID)

    if specIDStr
       and lp.specOverrides and lp.specOverrides[specIDStr]
       and lp.specOverrides[specIDStr][slot]
    then
        return lp.specOverrides[specIDStr][slot]
    end

    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "NONE"
    if role == "NONE" or role == "" then role = self.playerSpecRole or "NONE" end
    if lp.roleOverrides and lp.roleOverrides[role]
       and lp.roleOverrides[role][slot]
    then
        return lp.roleOverrides[role][slot]
    end

    local ila = lp.instanceLayoutAssignment or {}
    return ila[slot]
end

-- ResolveValidFlatForSlot: walks the same precedence chain as
-- ResolveActiveFlat but only accepts entries that point to an existing
-- flat of the requested type. Used by GetRaidProfile / GetActivePartyProfile
-- to keep the "one slot → one flat" invariant intact when the user's stored
-- assignment for the current context is missing or wrong-typed (e.g. a
-- legacy profile that has a raid-typed flat stored against the dungeon slot).
--
-- Returns:
--   • flatID (string) when one of the three precedence layers points to a
--     valid type-matching flat.
--   • the literal string "none" when an override at spec/role/global layer
--     explicitly selects "none" (only meaningful for the solo slot).
--   • nil when none of the three layers yielded a valid choice. Callers
--     (the two getters below) supply their own last-resort fallback.
--
-- requiredType is "party" or "raid". Pass nil to accept any type (current
-- callers always pass one of those two literals so the nil branch is just
-- defensive).
--
-- Hot-path notes: no closures, no growing tables; at most three table
-- lookups plus the type check. The UI in Options_Layouts.lua filters the
-- dropdown values so the entries we walk here will almost always be valid
-- on the first try, making this no slower than ResolveActiveFlat in the
-- common case.
function BF:ResolveValidFlatForSlot(slot, requiredType)
    local lp = self.rpDB.profile.layouts
    local fl = lp.flatLayouts or {}

    -- 1. Spec override
    local specIDStr = self.playerSpecID and tostring(self.playerSpecID)
    if specIDStr
       and lp.specOverrides and lp.specOverrides[specIDStr]
    then
        local id = lp.specOverrides[specIDStr][slot]
        if id then
            if id == "none" then
                return id
            else
                local f = fl[id]
                if f and (not requiredType or f.type == requiredType) then
                    return id
                end
            end
        end
    end

    -- 2. Role override
    local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or "NONE"
    if role == "NONE" or role == "" then role = self.playerSpecRole or "NONE" end
    if lp.roleOverrides and lp.roleOverrides[role] then
        local id = lp.roleOverrides[role][slot]
        if id then
            if id == "none" then
                return id
            else
                local f = fl[id]
                if f and (not requiredType or f.type == requiredType) then
                    return id
                end
            end
        end
    end

    -- 3. Global instance assignment
    local ila = lp.instanceLayoutAssignment
    if ila then
        local id = ila[slot]
        if id then
            if id == "none" then
                return id
            else
                local f = fl[id]
                if f and (not requiredType or f.type == requiredType) then
                    return id
                end
            end
        end
    end

    return nil
end

-- Get the appropriate settings based on the currently-resolved slot.
-- Result is cached and only recomputed when invalidated by group/instance changes.
-- Sets openWorldPartyOverride = true when the resolved flat is party-typed,
-- and openWorldNoneOverride = true when the slot resolves to the literal "none"
-- (solo open-world with the "None" dropdown option).
function BF:GetRaidProfile()
    if self.raidProfileCache then
        return self.raidProfileCache
    end

    local lp = self.rpDB.profile.layouts
    local fl = lp.flatLayouts or {}

    self.openWorldPartyOverride = false
    self.openWorldNoneOverride  = false

    local slot   = self:GetActiveSlot()
    -- Step 1: read the raw resolution. We need this because the "none"
    -- sentinel and the party-typed-flat compatibility flag both depend on
    -- what the user *actually* picked, not on the type-validated fallback.
    -- The openWorldNoneOverride flag must fire whenever the user explicitly
    -- selected "None" for the solo slot, regardless of any "valid raid flat"
    -- recovery we do below.
    local flatID = self:ResolveActiveFlat(slot)
    local flat   = flatID and fl[flatID] or nil

    if flatID == "none" then
        self.openWorldNoneOverride = true
        -- "none" never resolves to a real flat; fall through to the
        -- last-resort default below. (Don't try ResolveValidFlatForSlot
        -- here -- the user explicitly asked for "no frames" and we should
        -- respect that signal; the flat we return is only there so anchor
        -- code etc. doesn't nil-deref.)
        flat = nil
    end

    -- When the resolved flat is party-typed, set the compatibility flag
    -- so callers keyed on openWorldPartyOverride still work (anchor frame
    -- sizing, etc.). This must be set off the raw resolution -- if the
    -- user assigned a party-typed flat to this slot, that's a legitimate
    -- party-render scenario and downstream code expects the flag.
    if flat and flat.type == "party" then
        self.openWorldPartyOverride = true
    end

    -- Step 2: if the raw resolution didn't yield a usable raid flat
    -- (missing, "none", or party-typed), walk the precedence chain again
    -- looking for the first valid raid-typed entry. This recovers from
    -- stale assignments without silently swapping to a hardcoded
    -- flat_raid40 the user never picked.
    if not flat or flat.type ~= "raid" then
        local recoveredID = self:ResolveValidFlatForSlot(slot, "raid")
        if recoveredID and recoveredID ~= "none" then
            local recovered = fl[recoveredID]
            if recovered then
                flat = recovered
            end
        end
    end

    -- Final fallback: never return nil. flat_raid40 is seeded by the
    -- defaults and migration; flat_party is the absolute floor since
    -- it is also guaranteed seeded (Core_FlatDefaults.lua).
    if not flat then
        flat = fl.flat_raid40 or fl.flat_party
    end

    self.raidProfileCache = flat
    return flat
end

-- (Phase L: BF:ResolveTier was removed. It walked the raid tier toward the
-- nearest one flagged enabled via the pre-flat enableRaid20/30/40 keys --
-- but its tier distinction was consumed nowhere: every GetTrueActiveTab
-- consumer only tests gt == "party", so callers now use the raw tier.)


-- ============================================================
-- BF:GetActiveContextFlat()  (dbVersion 65, §6.3a)
-- ============================================================
-- The Layout flat the user's raid/party frames are rendering from RIGHT NOW,
-- as a table, or nil when there isn't one.
--
-- This is what "a Custom Frame Group with its section override OFF" reads
-- from: the group follows the active Layout instead of the global
-- pseudo-layout, so editing the Layout you are currently in also moves the
-- Custom Frame Groups that share it. With per-Layout OFF the active flat and
-- the global resolve to the same values anyway, so nothing changes in the
-- common case.
--
-- Deliberately NOT GetRaidProfile / GetActivePartyProfile: those apply a
-- last-resort default flat when the slot resolves to "none", which would hand
-- a soloing user with a hide-assignment some arbitrary Layout's settings.
-- Here "none" (and an unresolvable / missing flat) must return nil, so that
-- the GetSectionProfile / GetAurasSubcatProfile call downstream falls back to
-- the global exactly as it did before §6.3a.
--
-- Cached like raidProfileCache and dropped by InvalidateRaidProfileCache
-- below, which already fires on every context change (zone, roster, profile
-- switch, per-Layout toggle, instance tier). Without the cache this would add
-- a slot resolve + UnitGroupRolesAssigned to every indicator that reads a
-- section through GetSectionProfileForFrame -- exactly the per-frame work the
-- standing no-resolution-in-:Update rule exists to prevent.
function BF:GetActiveContextFlat()
    local cached = self._activeContextFlat
    if cached ~= nil then
        -- false is the memoised "no active flat" answer; nil means "not
        -- resolved since the last invalidate".
        if cached == false then return nil end
        return cached
    end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    local flat
    if fl then
        local flatID = self:ResolveActiveFlat(self:GetActiveSlot())
        -- "none" is the solo-hide sentinel, never a flat ID.
        if flatID and flatID ~= "none" then
            local f = fl[flatID]
            if type(f) == "table" then flat = f end
        end
    end
    self._activeContextFlat = flat or false
    return flat
end

-- Invalidate the cached raid profile (call when group or instance changes)
function BF:InvalidateRaidProfileCache()
    self.raidProfileCache = nil
    -- §6.3a: the active-Layout flat that override-OFF Custom Frame Groups
    -- follow. Same lifetime as raidProfileCache -- if that is stale, so is
    -- this.
    self._activeContextFlat = nil
    -- Also drop the active-profile cache (UnitFrames.lua) so the next
    -- per-unit update rebuilds it from the new context.
    if self.InvalidateActiveProfileCache then
        self:InvalidateActiveProfileCache()
    end
    -- Drop the resolved-section-profile cache (Perf 1A). Every hot-path
    -- indicator :Update that reads a section profile goes through
    -- BF:GetCachedSection, which memoises the result of
    -- GetSectionProfile(section, activeFlat) keyed by section name.
    -- We must wipe here because raidProfileCache being stale implies the
    -- active flat may have changed, which means every cached section
    -- resolved against the old flat is also stale.
    if self._sectionProfileCache then
        -- Wipe without reallocating the table -- keeps the GC pressure
        -- lower than creating a fresh table on every context change.
        for k in pairs(self._sectionProfileCache) do
            self._sectionProfileCache[k] = nil
        end
        -- v94 PERF (Win 4): bump the section-config generation so per-frame
        -- stamped section config (HealthText._bf_htCfg; same pattern as
        -- AbsorbBars._absorbStyleGen) re-resolves on the next Update.
        self._sectionCfgGen = (self._sectionCfgGen or 0) + 1
    end
    -- Also wipe per-CFG-flat section caches. CFG frames cache their
    -- resolved section profiles on the flat to avoid re-resolving
    -- per-unit in :Update (same principle as the global cache above).
    -- NOTE: _auraCache is NOT wiped here. It is a derived data structure
    -- that must always be complete (indicators read buffSize, debuffSize,
    -- etc. from it). Only UpdateAuraSizeCache may wipe+rebuild it
    -- atomically. Wiping here without repopulating leaves an empty table
    -- that causes indicators to fall back to hardcoded defaults.
    local cfgp = self.cfgDB and self.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    if groups then
        for _, grp in ipairs(groups) do
            local flat = grp and grp.flat
            if flat then
                if flat._sectionCache then
                    for k in pairs(flat._sectionCache) do
                        flat._sectionCache[k] = nil
                    end
                end
            end
        end
    end
    -- 2026-08-24: RP flats now carry _sectionCache too -- it holds the
    -- merged views the per-subtab sections serve to render paths
    -- (GetMergedSectionView). Same staleness rule as the CFG store.
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if fl then
        for _, flat in pairs(fl) do
            local cache = type(flat) == "table" and rawget(flat, "_sectionCache")
            if cache then
                for k in pairs(cache) do cache[k] = nil end
            end
        end
    end
end

-- ============================================================
-- PERF 1A: RESOLVED SECTION PROFILE CACHE
--
-- Grid2 pattern: Indicators resolve their config once in UpdateDB into
-- local upvalues, never re-resolving in hot paths (see Grid2
-- IndicatorBar.lua Bar_UpdateDB). BF's indicator :Update methods were
-- re-resolving the section profile on every event (UNIT_HEALTH,
-- UNIT_POWER_UPDATE, UNIT_AURA), each call paying:
--   * 2 IsInRaid() API calls + openWorldPartyOverride check
--   * GetRaidProfile or GetActivePartyProfile call (cached, but still
--     a table lookup chain)
--   * GetSectionProfile: IsPerLayoutSection (3 table lookups) + flat
--     type check + flat[section] type check + rpDB fallback chain
--
-- GetCachedSection memoises the fully-resolved section table keyed by
-- section name. First call per tick does the full resolution; every
-- subsequent call for the same section is one hash lookup. Invalidated
-- by InvalidateRaidProfileCache (above), which is already called from
-- every known context-changing site (zone change, roster update,
-- profile switch, per-layout toggle, instance tier change).
--
-- The cache is per-section, not per-(section, flat). Callers that want
-- a specific flat (options panel code, preview frames) must keep using
-- GetSectionProfile directly -- this helper is for hot-path live-frame
-- :Update methods only. GetSectionProfileForFrame handles preview
-- frames and has its own code path that we do NOT touch.
--
-- Contract:
--   * Returns the same table GetSectionProfile would have returned for
--     the current active flat.
--   * Callers MUST treat the return value as read-only. Writes to the
--     returned table would bypass AceDB's metatable fallback chain and
--     corrupt the defaults layer.
--   * Safe to call during addon load; before the first
--     InvalidateRaidProfileCache, the cache is empty and each call
--     resolves fresh.
-- ============================================================
BF._sectionProfileCache = {}

function BF:GetCachedSection(section, parent)
    -- CFG frame path: cache on the flat so each CFG gets its own
    -- memoised section profiles, resolved via GetSectionProfileForFrame.
    if parent then
        local header = parent._bf_parentHeader
        if header == nil then
            header = parent:GetParent()
            parent._bf_parentHeader = header or false
        end
        if header and header._cfgFlat then
            local flat = header._cfgFlat
            local cache = flat._sectionCache
            if not cache then
                cache = {}
                flat._sectionCache = cache
            end
            local cached = cache[section]
            if cached ~= nil then
                return cached
            end
            local resolved = self:GetSectionProfileForFrame(section, parent)
            if resolved ~= nil then
                cache[section] = resolved
            end
            return resolved
        end
    end

    -- RP frame path: global cache keyed by section name.
    local cache = self._sectionProfileCache
    local cached = cache[section]
    if cached ~= nil then
        return cached
    end

    local isRaid = self:ResolveActiveIsRaid()
    local activeFlat = isRaid and self:GetRaidProfile() or self:GetActivePartyProfile()
    local resolved = self:GetSectionProfile(section, activeFlat)

    if resolved ~= nil then
        cache[section] = resolved
    end
    return resolved
end

-- Returns the party-typed flat for the current context.
-- Callers use this to size the party anchor frame even when the active
-- render slot is raid-typed (e.g. inside a raid instance).
function BF:GetActivePartyProfile()
    local lp = self.rpDB.profile.layouts
    local fl = lp.flatLayouts or {}

    local slot   = self:GetActiveSlot()
    local flatID = self:ResolveActiveFlat(slot)
    local flat   = flatID and fl[flatID] or nil

    -- Caller wants party-typed data specifically. If the slot's primary
    -- assignment is missing or raid-typed, walk the same precedence chain
    -- ResolveActiveFlat used and pick the first valid party-typed entry.
    -- This prevents the historical bleed bug where this getter silently
    -- returned a hardcoded flat_party while GetRaidProfile returned the
    -- slot's actual (raid-typed) assignment -- the two getters now agree
    -- on which user-chosen flat to consult for the current context.
    if not flat or flat.type ~= "party" then
        local recoveredID = self:ResolveValidFlatForSlot(slot, "party")
        if recoveredID and recoveredID ~= "none" then
            local recovered = fl[recoveredID]
            if recovered then flat = recovered end
        end
    end

    -- Absolute last resort: flat_party is always seeded (Core_FlatDefaults),
    -- so this guarantees the function never returns nil.
    if not flat or flat.type ~= "party" then
        flat = fl.flat_party
    end
    return flat
end

-- ── _resolvedProfile setter ─────────────────────────────────────────────────
-- The render path reads frame size, grow direction, anchor, etc. from
-- self._resolvedProfile (set once per context change, cached for the duration
-- of the render). self._lastResolvedFlatID is the cache key that
-- BF:ReloadLayout's gate (BFLayout.lua) uses to detect whether the resolved
-- flat changed since the last reload — when it has not changed and force=true,
-- the gate skips the redundant GetRaidProfile()/GetActivePartyProfile() call
-- but still performs cache invalidation. For that gate to work correctly,
-- every writer of _resolvedProfile MUST keep _lastResolvedFlatID in sync.
--
-- Funnel every writer through this single helper so the two fields cannot
-- drift apart. Callers pick the context (raid vs party) via the boolean
-- argument; the helper does the rest. If you find yourself wanting to write
-- _resolvedProfile directly, route through here instead.
--
-- Hot-path note: this runs on context changes (zone, roster, profile switch,
-- options edits) — NOT in the per-frame indicator update loop. The extra
-- function-call frame and the one ResolveActiveFlat(GetActiveSlot()) call are
-- negligible compared to the secure-header rebuild that follows. The bigger
-- win is preventing the bleed bug class entirely: it is structurally
-- impossible to update _resolvedProfile without also updating the cache key.
function BF:SetResolvedProfile(useRaid)
    if useRaid then
        self._resolvedProfile = self:GetRaidProfile()
    else
        self._resolvedProfile = self:GetActivePartyProfile()
    end
    self._lastResolvedFlatID = self:ResolveActiveFlat(self:GetActiveSlot())
end

-- ── Active / Modifying profile helpers ──────────────────────────────────────
-- "Active"    = the flat that is actually rendering (real frames).
-- "Modifying" = the flat the options panel is currently editing (_modifyingFlat).
-- They may differ whenever the user has selected a non-active flat in the
-- chrome Modifying Layout dropdown.

-- Returns the flat for the *truly* active context (ignoring test mode).
-- isParty is true when the flat is party-typed.
function BF:GetTrueActiveProfile()
    local lp = self.rpDB.profile.layouts
    local fl = lp.flatLayouts or {}

    local slot   = self:GetActiveSlot()
    local flatID = self:ResolveActiveFlat(slot)
    local flat   = (flatID and fl[flatID]) or fl.flat_party
    local isParty = (flat and flat.type == "party") or false
    return flat, isParty
end

-- Returns the flat the options panel is currently editing.
-- Falls back to the true active profile when _modifyingFlat is unset
-- or references a missing flat.
function BF:GetModifyingProfile()
    local lp = self.rpDB.profile.layouts
    local fl = lp.flatLayouts or {}
    local flatID = self._modifyingFlat
    local flat = flatID and fl[flatID]
    if not flat then
        return self:GetTrueActiveProfile()
    end
    local isParty = (flat.type == "party") or false
    return flat, isParty
end

-- Returns true when the flat being edited is also the flat currently
-- rendering, meaning edits in the options panel affect the live frames.
function BF:ActiveMatchesModifying()
    if not self._modifyingFlat then return true end
    local activeFlat = self:ResolveActiveFlat(self:GetActiveSlot())
    if self._modifyingFlat == activeFlat then return true end
    -- v53 Phase 2.2 (setup-mode exit): this predicate is the single gate every
    -- caller uses to decide whether an edit has to reach the REAL frames --
    -- BF:RefreshAll (Core_Refresh.lua), BF:ResizeAllFrames (BFLayout.lua), the
    -- setters in Options/Options_Frames.lua, and the setup-mode drag handlers.
    -- A false answer while setup mode is open means real-frame work was
    -- SKIPPED, and making that good is the entire purpose of the rebuild in
    -- BF:ToggleSetupMode(false). Recording it here -- rather than in each of
    -- the ~20 callers -- is what lets a session that skipped nothing exit
    -- without paying for that rebuild. Deliberately conservative: a caller
    -- that only READS this predicate still marks the session dirty, which
    -- costs the pre-2.2 exit path and nothing more.
    -- MarkSetupDirty (SetupMode.lua) is inert while setup mode is off, so
    -- every other caller pays one method lookup and one table read.
    if self.MarkSetupDirty then self:MarkSetupDirty("raid") end
    return false
end

-- ============================================================
-- PER-LAYOUT SECTION ROUTING
-- ============================================================
-- Each Raid/Party Frames section (auras, icons, text, borders,
-- healthPower, tooltips, auraText, absorbs, sorting) can optionally
-- store its settings per-flat rather than globally. The toggle lives at
-- rpDB.profile.layouts.perLayoutToggles[section]. When ON, reads/writes
-- go to flat[section]; when OFF, they go to the global pseudo-layout at
-- rpDB.profile[section]. The Frames section is inherently per-flat (and
-- not routed through this layer); roleSpecLayouts and preview are
-- excluded from the toggle by design.

-- Resolve "is the active context a raid?" for profile routing.
--
-- v60 BUGFIX: this logic was inlined at two call sites as
--     local isRaid = self._contextIsRaid ~= nil and self._contextIsRaid
--                    or (IsInRaid() and not self.openWorldPartyOverride)
-- which is wrong for an explicit PARTY context: when _contextIsRaid is false
-- the first branch evaluates to false, so the `or` falls through to IsInRaid()
-- and the resolved context is silently discarded. ResolveContext
-- (ApplyProfile.lua) genuinely sets _contextIsRaid = false for the
-- arena / party / scenario instance types, so wherever one of those coexists
-- with IsInRaid() being true the raid flat was read against the addon's own
-- decision. Hoisted here so both callers share one correct implementation.
function BF:ResolveActiveIsRaid()
    if self._contextIsRaid ~= nil then return self._contextIsRaid end
    return IsInRaid() and not self.openWorldPartyOverride
end

-- Returns true when the given section's per-layout toggle is ON.
--
-- dbVersion 65: "auras" is not a real toggle key. Every aura SUB-CATEGORY owns its own
-- toggle (BF.AURAS_SUBCAT_TOGGLE below: auras_buffs, auras_bigDef,
-- auras_debuffs, auras_dispelIndicator), and "auras" survives as the ONE
-- COARSE alias meaning "is any aura sub-category per-Layout?".
--
-- That alias is correct for the things that ask a genuinely whole-section
-- question -- whether to show the Modifying Layout chrome, whether to wire
-- fallbacks -- but it is NOT sufficient for routing a read or a write,
-- because the sub-categories can disagree. Data routing must go through
-- IsPerLayoutAurasSubcat / GetAurasSubcatProfile instead. Per-CFG override
-- questions are per aura GROUP, via BF.AURAS_GROUP_CFG_FLAG.
--
-- This is not a hot path (options predicates, Layout-time resolution,
-- cache-invalidation gates), so the loops are fine. If profiling ever says
-- otherwise, memoise a dirty-flagged boolean in SetSectionPerLayout -- but do
-- not pre-optimize.
function BF:IsPerLayoutSection(section)
    if not section then return false end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local t = lp and lp.perLayoutToggles
    if not t then return false end
    if section == "auras" then
        -- 2026-08-25: iterate EVERY aura toggle key -- the four
        -- auras_<subcat> ones AND the in-sub-category scope toggles
        -- (AURAS_SUBCAT_SCOPES, e.g. auras_debuffFilter), all of which are
        -- keys of AURAS_GROUP_STORAGE_SECTION.
        for key in pairs(BF.AURAS_GROUP_STORAGE_SECTION) do
            if t[key] == true then return true end
        end
        return false
    end
    -- 2026-08-24: the five per-subtab sections get the same coarse-alias
    -- treatment as "auras": the section name answers "is ANY subtab
    -- per-Layout" -- correct for chrome, fallback wiring and the
    -- does-any-flat-have-X event gates, NEVER for routing a read or a
    -- write (per-key routing / GetMergedSectionView do that).
    local subTogs = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    if subTogs then
        for _, key in pairs(subTogs) do
            if t[key] == true then return true end
        end
        return false
    end
    return t[section] == true
end

-- Is this section subtab's own per-Layout toggle ON? The exact question
-- for the five per-subtab sections. Unknown subtab ids fall back to the
-- coarse section answer (defensive, mirrors IsPerLayoutAurasSubcat).
function BF:IsPerLayoutSectionSubtab(section, subtabId)
    local togMap = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    local key = togMap and subtabId and togMap[subtabId]
    if not key then return self:IsPerLayoutSection(section) end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local t = lp and lp.perLayoutToggles
    return (t and t[key]) == true
end

-- ============================================================
-- BF:WriteSectionKey(section, key, val)  (2026-08-24)
-- ============================================================
-- The options-side WRITE router for the five per-subtab sections: the
-- key's subtab decides the scope. Subtab toggle ON -> rawset onto the
-- MODIFYING flat's section table (created + fallback-wired on demand);
-- OFF, or key unmapped -> the shared global. Returns
-- (wrotePerFlat, flat, subtabToggleKey) so callers can route cache
-- invalidation the way makeRpSet does. Also correct (and inert) for
-- non-split sections: no key map -> global write, same as before.
-- Wipe every cached merged view of one section -- the global section
-- cache slot plus the per-flat stores (RP flats and CFG flats alike).
-- Called by the two write routers below on EVERY write to a split
-- section: view tables copy scalar values at build time, so any write
-- (global- or flat-scoped) makes cached views stale. Cheap: a handful of
-- table-slot nils per keystroke.
function BF:_InvalidateSectionViews(section)
    -- v94 PERF (Win 4): see the wipe in InvalidateActiveProfileCache -- any
    -- section edit must also move the generation so stamped per-frame cfg
    -- (HealthText._bf_htCfg) re-resolves.
    self._sectionCfgGen = (self._sectionCfgGen or 0) + 1
    if self._sectionProfileCache then
        self._sectionProfileCache[section] = nil
    end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if fl then
        for _, flat in pairs(fl) do
            local cache = type(flat) == "table" and rawget(flat, "_sectionCache")
            if cache then cache[section] = nil end
        end
    end
    local cfgp = self.cfgDB and self.cfgDB.profile
    local groups = cfgp and cfgp.customFrameGroups
    if groups then
        for _, grp in ipairs(groups) do
            local flat = grp and grp.flat
            local cache = flat and rawget(flat, "_sectionCache")
            if cache then cache[section] = nil end
        end
    end
end

function BF:WriteSectionKey(section, key, val)
    local keyMap = BF.SECTION_KEY_SUBTAB and BF.SECTION_KEY_SUBTAB[section]
    local subtab = keyMap and keyMap[key]
    local togKey = subtab and BF.SECTION_SUBTAB_TOGGLE[section][subtab] or nil
    if subtab and self:IsPerLayoutSectionSubtab(section, subtab) then
        local flat = self:GetModifyingProfile()
        if type(flat) == "table" then
            local tbl = rawget(flat, section)
            if type(tbl) ~= "table" then
                tbl = {}
                flat[section] = tbl
                self:WireSectionFallback(flat, section)
            end
            tbl[key] = val
            self:_InvalidateSectionViews(section)
            return true, flat, togKey
        end
    end
    local gp = self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
    if gp then gp[key] = val end
    if subtab then self:_InvalidateSectionViews(section) end
    return false, nil, togKey
end

-- ============================================================
-- BF:SectionKeyTable(section, key)  (2026-08-24)
-- ============================================================
-- The in-place-mutation companion to WriteSectionKey, for the nested
-- value tables (positions, colors) that setters mutate field-by-field
-- (`pos.x = v`). Returns the table to MUTATE, scoped by the key's
-- subtab: toggle ON -> the modifying flat's OWN copy, materialized
-- copy-on-write from the resolved value on first touch; OFF/unmapped ->
-- the global's table (created empty if the key is unset). Never returns
-- a merged-view table.
function BF:SectionKeyTable(section, key)
    local keyMap = BF.SECTION_KEY_SUBTAB and BF.SECTION_KEY_SUBTAB[section]
    local subtab = keyMap and keyMap[key]
    if subtab and self:IsPerLayoutSectionSubtab(section, subtab) then
        local flat = self:GetModifyingProfile()
        if type(flat) == "table" then
            local tbl = rawget(flat, section)
            if type(tbl) ~= "table" then
                tbl = {}
                flat[section] = tbl
                self:WireSectionFallback(flat, section)
            end
            local v = rawget(tbl, key)
            if type(v) ~= "table" then
                local gp = self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
                local gv = gp and gp[key]
                v = (type(gv) == "table") and self:DeepCopy(gv) or {}
                tbl[key] = v
            end
            self:_InvalidateSectionViews(section)
            return v
        end
    end
    local gp = self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
    if not gp then return nil end
    local v = gp[key]
    if type(v) ~= "table" then
        v = {}
        gp[key] = v
    end
    if subtab then self:_InvalidateSectionViews(section) end
    return v
end

-- ============================================================
-- BF:GetMergedSectionView(section, flat)  (2026-08-24)
-- ============================================================
-- The whole-section READ answer for a per-subtab section: a cached table
-- holding, for every key, the flat's value when that key's subtab toggle
-- is ON (and the flat has the rawkey), else the global's. Render paths
-- keep asking for whole sections (GetSectionProfileForFrame /
-- GetCachedSection are unchanged); this is what they get.
--
-- Guarantees:
--   * Stale rawkeys of an OFF subtab are NEVER read (the per-subtab
--     isolation rule, matching GetAurasSubcatProfile).
--   * Keys absent from SECTION_KEY_SUBTAB always resolve global.
--   * READ-ONLY by convention: every writer routes per-key onto
--     flat[section] or the global -- nothing writes through views.
--
-- Caching: on flat._sectionCache[section] (the store CFG flats already
-- carry; RP flats gain it here). InvalidateRaidProfileCache wipes both
-- stores, and every options setter plus SetSectionPerLayout already call
-- it -- so no new invalidation hook is needed. _sectionCache is already
-- excluded from exports (RUNTIME keys).
-- ============================================================
-- BF:BuildMergedSectionView(section, raw, fallback, isSubtabOn)  (2026-09-13)
-- ============================================================
-- The per-subtab MERGE on its own, with the two things that differ between
-- its callers passed in. A Raid/Party Layout and a Custom Frame Group ask
-- the same question of a split section -- "for each subtab, does this
-- scope use its own copy or the shared layer?" -- and differ only in what
-- the shared layer is and where the per-subtab answer lives:
--
--   * Raid/Party: `fallback` is the global pseudo-layout and `isSubtabOn`
--     reads rpDB.profile.layouts.perLayoutToggles (GetMergedSectionView).
--   * Custom Frame Group: `fallback` is the ACTIVE Layout's own resolution
--     and `isSubtabOn` reads the group's master flag and grp.overrides
--     (GetCFGSectionProfile).
--
-- Rules, in order:
--   1. Every key starts at the FALLBACK -- the split section's own keys by
--      indexed read (so an AceDB default served by metatable is picked up,
--      see the 2026-08-27 note below), then whatever else the fallback
--      holds, by pairs(). Unmapped keys therefore always resolve to the
--      fallback, in both scopes -- one rule, not two.
--   2. For each subtab that is ON: the scope's own rawkey; where the scope
--      has none, the GLOBAL -- which is what WireSectionFallback's
--      metatable answers for a raw read, and for a Custom Frame Group is
--      deliberately NOT the active Layout: a key the group never stored
--      must not change with the instance the player is standing in.
--
-- `raw` may be an empty table (a scope whose copy is not materialised).
-- Returns a fresh plain table; callers cache it. READ-ONLY by convention.
function BF:BuildMergedSectionView(section, raw, fallback, isSubtabOn)
    local global  = self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
    local togMap  = BF.SECTION_SUBTAB_TOGGLE[section]
    local keyList = BF.SECTION_SUBTAB_KEYS[section]
    local view = {}
    -- 2026-08-27 FIX: seed from the section's KEY LIST via indexed reads, not
    -- only from pairs(). A default-only key served by a metatable is never
    -- visited by pairs(); seeding by pairs() alone dropped every such key
    -- (useCustomHostileColor, hostileColor, the offline/dead colors, ...)
    -- from the merged view whenever the section was per-layout --
    -- Health:GetColor read nil and the hostile / mind-control color
    -- silently stopped applying (owner repro, 5.2.x).
    for _, keys in pairs(keyList) do
        for _, k in ipairs(keys) do
            local v = fallback[k]
            if v ~= nil then view[k] = v end
        end
    end
    -- Keys the subtab lists do not name (legacy / migrated / unsplit) still
    -- come across as before, so nothing that resolved previously is lost.
    for k, v in pairs(fallback) do
        if view[k] == nil then view[k] = v end
    end
    for st, togKey in pairs(togMap) do
        if isSubtabOn(st, togKey) then
            for _, k in ipairs(keyList[st]) do
                local fv = rawget(raw, k)
                if fv == nil and type(global) == "table" then fv = global[k] end
                if fv ~= nil then view[k] = fv end
            end
        end
    end
    return view
end

function BF:GetMergedSectionView(section, flat)
    local global = self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
    if type(flat) ~= "table" then return global end
    local raw = rawget(flat, section)
    if type(raw) ~= "table" then return global end
    if not self:IsPerLayoutSection(section) then return global end
    if type(global) ~= "table" then return raw end
    local cache = rawget(flat, "_sectionCache")
    if not cache then
        cache = {}
        flat._sectionCache = cache
    end
    local view = cache[section]
    if view ~= nil then return view end
    -- 2026-09-13: the merge itself lives in BuildMergedSectionView, shared
    -- with the Custom Frame Group resolver. Here the fallback is the global
    -- and a subtab is ON when its per-Layout toggle is.
    local lp = self.rpDB.profile.layouts
    local toggles = lp and lp.perLayoutToggles or {}
    view = self:BuildMergedSectionView(section, raw, global,
        function(_, togKey) return toggles[togKey] == true end)
    cache[section] = view
    return view
end

-- Returns the appropriate profile sub-table for this section given a flat.
-- When the section's per-layout toggle is ON and the flat has a non-nil
-- [section] sub-table, that sub-table is returned. Otherwise the global
-- pseudo-layout at rpDB.profile[section] is returned -- this matches the
-- existing storage location so toggle-OFF behavior is unchanged.
function BF:GetSectionProfile(section, flat)
    if not section then return nil end
    -- v60 guard: "auras" is NOT routable as a whole section. Its two halves
    -- have independent per-Layout toggles (and independent per-CFG override
    -- flags), so any single answer here is wrong for one of them -- and the
    -- failure mode is silently WRONG DATA, not nil. Every aura read must go
    -- through GetAurasSubcatProfile / GetAurasSubcatProfileForFrame /
    -- BF.ResolveCFGAurasSubcat with a specific sub-category.
    if section == "auras" then
        error("BuzzardFrames: GetSectionProfile(\"auras\") is not supported -- "
              .. "use GetAurasSubcatProfile(subcat, flat) instead", 2)
    end
    -- An aura TOGGLE key is rejected for the same reason as "auras" above.
    -- Keying off AURAS_GROUP_STORAGE_SECTION covers every per-sub-category
    -- toggle key (auras_buffs and friends): each one names a toggle whose data
    -- lives inside the shared "auras" table, so handing back that whole table
    -- cannot be correct for any of them. Use GetAurasSubcatProfile with a
    -- specific sub-category.
    if BF.AURAS_GROUP_STORAGE_SECTION and BF.AURAS_GROUP_STORAGE_SECTION[section] then
        error("BuzzardFrames: GetSectionProfile(\"" .. section .. "\") is not "
              .. "supported -- use GetAurasSubcatProfile(subcat, flat) instead", 2)
    end
    -- 2026-08-24: per-subtab sections answer with the merged view (which
    -- itself degrades to the global when no subtab is ON or the flat has
    -- no data) -- see GetMergedSectionView.
    if BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section] then
        return self:GetMergedSectionView(section, flat)
    end
    if self:IsPerLayoutSection(section)
       and type(flat) == "table"
       and type(flat[section]) == "table"
    then
        return flat[section]
    end
    return self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
end

-- Frame-scoped variant of GetSectionProfile. Resolves the appropriate
-- flat to use based on what KIND of frame is being rendered:
--
--   • CFG frame (header._cfgFlat set) → CFG flats are fully independent.
--     The CFG override flag alone decides (v65 §6.3 — it used to be
--     short-circuited by the section's per-Layout toggle, which made the
--     checkbox and the behavior disagree):
--       - Override ON → CFG's own section data.
--       - Override OFF → the ACTIVE Layout's flat (§6.3a), falling back to
--         global rpDB.profile[section] when there is no active flat.
--     Non-overridable sections delegate to GetSectionProfile(section, cfgFlat).
--   • Preview frame with _flatID set → that specific flat (so each
--     preview in the options panel shows its own per-layout settings).
--   • Preview frame without _flatID (e.g. Custom Frame Group previews,
--     which aren't per-flat) → falls through to the global.
--   • Live unit frame (no _isPreviewFrame flag) → resolves via the
--     active game context (raid vs party), matching the runtime
--     indicator :Update paths.
--
-- Use this from ALL indicator methods — both :Layout and :Update.
function BF:GetSectionProfileForFrame(section, frame)
    if frame then
        -- CFG preview frames: stamped with _cfgFlat + _cfgGroup in
        -- RefreshPreview so per-section override logic works correctly.
        if frame._isPreviewFrame and frame._cfgFlat then
            -- 2026-09-13: one resolver for every Custom Frame Group read --
            -- see GetCFGSectionProfile. It carries the v65 §6.3 rule (the
            -- override flag alone decides, whatever the section's
            -- per-Layout toggle says) and the per-subtab split.
            return self:GetCFGSectionProfile(section, frame._cfgGroup, frame._cfgFlat)
        end
        -- RP preview frames: resolve via _flatID.
        if frame._isPreviewFrame then
            local lp   = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
            local fl   = lp and lp.flatLayouts
            local flat = (frame._flatID and fl) and fl[frame._flatID] or nil
            return self:GetSectionProfile(section, flat)
        end
        -- CFG frames: resolve via the CFG flat stored on the header.
        local header = frame._bf_parentHeader
        if header == nil then
            header = frame:GetParent()
            frame._bf_parentHeader = header or false
        end
        if header and header._cfgFlat then
            -- Same resolver as the preview branch above.
            return self:GetCFGSectionProfile(section, header._cfgGroup, header._cfgFlat)
        end
    end
    -- Normal RP frame: resolve via active game context.
    local activeFlat = self:ResolveActiveIsRaid() and self:GetRaidProfile()
                       or self:GetActivePartyProfile()
    return self:GetSectionProfile(section, activeFlat)
end

-- ============================================================
-- Custom Frame Group section overrides  (2026-09-13)
-- ============================================================
-- A Custom Frame Group's "override" and a Raid/Party Layout's "per-Layout
-- config" are the same question asked of two scopes: does this subtab's
-- settings come from the shared layer, or from this scope's own copy? The
-- Raid/Party side was split per subtab by dbVersion 75; this is that split
-- for groups.
--
--   grp.<flag>                the section MASTER (overrideText, ...), as
--                             before. OFF = the whole section follows the
--                             active Layout (v65 §6.3a).
--   grp.overrides[togKey]     the per-SUBTAB answer, under the SAME
--                             generated keys the Raid/Party toggles use
--                             (text_names, ...). ABSENT = ON; only an
--                             explicit `false` is stored. So an untouched
--                             group behaves exactly as before in both
--                             master states, no migration is needed, the
--                             table stays sparse, and the legacy Ace panel
--                             (master-only) keeps working untouched.
--   effective override        master AND subtab.
--
-- Only the five split sections (BF.SECTION_SUBTAB_TOGGLE) have subtab
-- flags. auraText, tooltips and castBar are master-only and keep answering
-- with their RAW table -- Pages_Tooltips / Pages_AuraText write THROUGH the
-- table this hands back, and a merged view would swallow every write. The
-- two aura groups keep their own masters (BF.AURAS_GROUP_CFG_FLAG) and are
-- resolved by ResolveCFGAurasSubcat, not here.
--
-- EVERY call below goes through the file-level `BF`, never `self`. The
-- options panel reaches these through a proxy whose GetSectionProfile
-- re-enters the group's scope; a resolver that asked `self` for its
-- fallback would ask the proxy, which would ask the resolver, without end.

-- The section's own copy on the group's flat, materialised and wired.
-- Returns the RAW table (never a view). nil when the group has no flat.
function BF:MaterializeCFGSection(grp, section)
    local flat = grp and grp.flat
    if type(flat) ~= "table" or not section then return nil end
    local t = rawget(flat, section)
    if type(t) ~= "table" then
        t = {}
        -- Cast bars: a freshly materialised group castBar section always
        -- seeds OFF (owner rule 2026-08-13).
        if section == "castBar" then t.enabled = false end
        flat[section] = t
        BF:WireSectionFallback(flat, section)
        if section == "auras" and BF.WireAurasSubCategoryFallbacks then
            BF:WireAurasSubCategoryFallbacks(t)
        end
    end
    return t
end

-- Does this group use its OWN copy of `section` for `subtabId`?
-- master AND subtab. A section with no override flag (sorting, frames
-- size/position) is always the group's own; a subtab id the section does
-- not split on answers with the master alone.
function BF:IsCFGSubtabOverride(grp, section, subtabId)
    if type(grp) ~= "table" then return false end
    local flag = BF.CFG_SECTION_TO_FLAG and BF.CFG_SECTION_TO_FLAG[section]
    if not flag then return true end
    if not grp[flag] then return false end
    local togMap = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    local togKey = togMap and subtabId and togMap[subtabId]
    if not togKey then return true end
    local ov = grp.overrides
    return not (type(ov) == "table" and ov[togKey] == false)
end

-- The coarse alias, matching IsPerLayoutSection's "is ANY subtab on":
-- master AND some subtab not false. Right for chrome and gates, never for
-- routing a read or a write.
function BF:IsCFGSectionOverride(grp, section)
    if type(grp) ~= "table" then return false end
    local flag = BF.CFG_SECTION_TO_FLAG and BF.CFG_SECTION_TO_FLAG[section]
    if not flag then return true end
    if not grp[flag] then return false end
    local togMap = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    if not togMap then return true end
    local ov = grp.overrides
    if type(ov) ~= "table" then return true end
    for _, togKey in pairs(togMap) do
        if ov[togKey] ~= false then return true end
    end
    return false
end

-- Does ANY part of this section, for this group, read the active Layout?
-- Master off, or a split section with some subtab off. What decides
-- whether a group's caches go stale when the active Layout moves.
function BF:CFGSectionFollowsActiveLayout(grp, section)
    if type(grp) ~= "table" then return false end
    local flag = BF.CFG_SECTION_TO_FLAG and BF.CFG_SECTION_TO_FLAG[section]
    if not flag then return false end
    if not grp[flag] then return true end
    local togMap = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    local ov = grp.overrides
    if not (togMap and type(ov) == "table") then return false end
    for _, togKey in pairs(togMap) do
        if ov[togKey] == false then return true end
    end
    return false
end

-- THE resolver: the section table a Custom Frame Group's frames read.
--
--   no override flag        -> GetSectionProfile(section, flat), as before
--   master OFF              -> the active Layout's resolution (§6.3a); nil
--                              active flat falls back to the global inside
--                              GetSectionProfile
--   master ON, not split    -> the group's RAW table (or the global when
--                              the flat carries none), as before
--   master ON, split        -> a merged view: OFF subtabs from the active
--                              Layout's resolution, ON subtabs from the
--                              group's own copy with the GLOBAL under it
--                              (BuildMergedSectionView), cached on
--                              flat._sectionCache[section] -- the slot
--                              GetCachedSection uses, same value by
--                              construction; every flag flip and every
--                              section write invalidates it
--                              (_InvalidateSectionViews), and so does an
--                              active-Layout change (InvalidateRaidProfileCache).
function BF:GetCFGSectionProfile(section, grp, flat)
    if not section then return nil end
    local flag = BF.CFG_SECTION_TO_FLAG and BF.CFG_SECTION_TO_FLAG[section]
    if not (type(grp) == "table" and flag) then
        return BF:GetSectionProfile(section, flat)
    end
    local global = BF.rpDB and BF.rpDB.profile and BF.rpDB.profile[section]
    if not grp[flag] then
        return BF:GetSectionProfile(section, BF:GetActiveContextFlat())
    end
    local split = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    if not split then
        return (type(flat) == "table" and flat[section]) or global
    end
    local raw = (type(flat) == "table") and rawget(flat, section) or nil
    local fallback = BF:GetSectionProfile(section, BF:GetActiveContextFlat())
    if type(fallback) ~= "table" then fallback = global end
    if type(fallback) ~= "table" then return raw end
    local cache
    if type(flat) == "table" then
        cache = rawget(flat, "_sectionCache")
        if not cache then
            cache = {}
            flat._sectionCache = cache
        end
        local view = cache[section]
        if view ~= nil then return view end
    end
    local ov = grp.overrides
    local view = BF:BuildMergedSectionView(section, type(raw) == "table" and raw or {},
        fallback, function(_, togKey)
            return not (type(ov) == "table" and ov[togKey] == false)
        end)
    if cache then cache[section] = view end
    return view
end

-- Copy one subtab's keys onto the group's copy from `src` -- what the
-- group was rendering with before the flip -- wherever the copy has no
-- rawkey yet, so turning a subtab on is a visual no-op. Table values are
-- DeepCopied: a view copies them by reference, and a shallow seed would
-- make the group's nameColor literally the raid Layout's table.
local function SeedCFGSubtab(tbl, section, subtabId, src)
    local keys = BF.SECTION_SUBTAB_KEYS[section]
                 and BF.SECTION_SUBTAB_KEYS[section][subtabId]
    if not (type(keys) == "table" and type(tbl) == "table" and type(src) == "table") then
        return
    end
    for _, k in ipairs(keys) do
        if rawget(tbl, k) == nil then
            local v = src[k]
            if type(v) == "table" then
                tbl[k] = BF:DeepCopy(v)
            elseif v ~= nil then
                tbl[k] = v
            end
        end
    end
end

-- Flip the section MASTER. Returns true when it changed. On the way ON:
-- materialise the group's copy and, for a split section, seed every
-- subtab that is (still) on from what the group rendered with, so the
-- flip changes nothing on screen. Rawkeys the group already holds (an
-- earlier ON -> OFF -> ON) are preserved as cache, as SetSectionPerLayout
-- does. Master-only sections are materialised and not seeded, as before.
-- Caches for the live frames are the caller's (the panel's refresh chain
-- wipes _sectionCache and _auraCache and repaints).
function BF:SetCFGSectionOverride(grp, section, enabled)
    local flag = BF.CFG_SECTION_TO_FLAG and BF.CFG_SECTION_TO_FLAG[section]
    if not (type(grp) == "table" and flag) then return false end
    local newVal = enabled and true or false
    if (grp[flag] and true or false) == newVal then return false end
    local flat = grp.flat
    local before = (type(flat) == "table") and BF:GetCFGSectionProfile(section, grp, flat) or nil
    grp[flag] = newVal
    if newVal and type(flat) == "table" then
        local tbl = BF:MaterializeCFGSection(grp, section)
        local togMap = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
        if togMap and type(before) == "table" then
            for st in pairs(togMap) do
                if BF:IsCFGSubtabOverride(grp, section, st) then
                    SeedCFGSubtab(tbl, section, st, before)
                end
            end
        end
    end
    BF:_InvalidateSectionViews(section)
    return true
end

-- Flip one SUBTAB's override. Stores only `false`; ON is the key's
-- absence, and an overrides table with nothing left in it goes away.
-- Returns true when it changed. On the way ON under a master that is on,
-- the subtab's keys are seeded from what the group rendered with.
function BF:SetCFGSubtabOverride(grp, section, subtabId, enabled)
    local togMap = BF.SECTION_SUBTAB_TOGGLE and BF.SECTION_SUBTAB_TOGGLE[section]
    local togKey = togMap and subtabId and togMap[subtabId]
    if not (type(grp) == "table" and togKey) then return false end
    local newVal = enabled and true or false
    local ov = grp.overrides
    local cur = not (type(ov) == "table" and ov[togKey] == false)
    if cur == newVal then return false end
    local flat = grp.flat
    local before = (type(flat) == "table") and BF:GetCFGSectionProfile(section, grp, flat) or nil
    if newVal then
        if type(ov) == "table" then
            ov[togKey] = nil
            if next(ov) == nil then grp.overrides = nil end
        end
        local flag = BF.CFG_SECTION_TO_FLAG and BF.CFG_SECTION_TO_FLAG[section]
        if type(flat) == "table" and flag and grp[flag] and type(before) == "table" then
            local tbl = BF:MaterializeCFGSection(grp, section)
            SeedCFGSubtab(tbl, section, subtabId, before)
        end
    else
        if type(ov) ~= "table" then
            ov = {}
            grp.overrides = ov
        end
        ov[togKey] = false
    end
    BF:_InvalidateSectionViews(section)
    return true
end

-- ============================================================
-- BF:WireSectionFallback(flat, section)
--
-- Attach a metatable to flat[section] whose __index points at the
-- global pseudo-layout rpDB.profile[section]. Any rawkey missing from
-- the per-flat sub-table falls through to the global -- which AceDB's
-- defaults layer re-materializes from Defaults_RaidPartyFrames.lua on
-- every login.
--
-- This mirrors the flat-level defaults pattern in Core_FlatDefaults.lua
-- (WireFlatDefaults), which does the same for the flat root itself.
-- Without this fallback, adding a new key to a section's defaults
-- after users have already seeded per-flat copies would leave that
-- key missing from the per-flat tables -- readers would get nil
-- instead of the default.
--
-- Idempotent: if the metatable already points at the same global, the
-- function returns early. Safe to call repeatedly from RehydrateFlats
-- and migration paths.
--
-- Writes: __newindex is intentionally NOT hooked. Writes use Lua's
-- default rawset semantics and land on the flat sub-table, not on the
-- shared global -- which is what the per-layout feature requires.
--
-- Iteration: pairs(flat[section]) visits only rawkeys (user-modified
-- values). This matches the sparse-storage pattern and is what the
-- Copy Settings dropdown relies on (only user-modified values get
-- copied between flats; defaults flow through via fallback on both
-- source and destination).
-- ============================================================
function BF:WireSectionFallback(flat, section)
    if type(flat) ~= "table" then return end
    if type(section) ~= "string" then return end
    local tbl = flat[section]
    if type(tbl) ~= "table" then return end
    local global = self.rpDB and self.rpDB.profile and self.rpDB.profile[section]
    if type(global) ~= "table" then return end
    local mt = getmetatable(tbl)
    if mt and mt.__index == global then return end  -- already wired
    setmetatable(tbl, { __index = global })
end

-- ============================================================
-- BF:GetOrCreateAurasSubCategory(flat, subcat) -> subTable
--
-- Lazy sub-category materialization + metatable wiring. Called from
-- Options_Auras.lua setters to ensure writes always land on the flat's
-- own sparse storage rather than the shared global, while reads for
-- un-customized keys still fall through to the global via the
-- two-tier metatable chain (flat.auras -> global.auras, and each
-- flat.auras.<subcat> -> global.auras.<subcat>).
--
-- Creates flat.auras if missing (and wires the first-tier fallback
-- via WireSectionFallback), then creates flat.auras.<subcat> if
-- missing (and attaches the second-tier __index metatable pointing
-- at rpDB.profile.auras.<subcat>). Returns the sub-category table.
--
-- Idempotent: if everything is already in place, returns the existing
-- sub-table without re-wiring. Safe to call from any Options setter.
--
-- Returns nil only when flat is not a table or subcat is not a string
-- -- callers should guard against nil if they need defensive behavior.
-- ============================================================
function BF:GetOrCreateAurasSubCategory(flat, subcat)
    if type(flat) ~= "table" or type(subcat) ~= "string" then return nil end
    local aurasP = rawget(flat, "auras")
    if not aurasP then
        aurasP = {}
        flat.auras = aurasP
        self:WireSectionFallback(flat, "auras")
    end
    local subTable = rawget(aurasP, subcat)
    if not subTable then
        subTable = {}
        aurasP[subcat] = subTable
        local globalSub = self.rpDB and self.rpDB.profile
            and self.rpDB.profile.auras and self.rpDB.profile.auras[subcat]
        if type(globalSub) == "table" then
            setmetatable(subTable, { __index = globalSub })
        end
    end
    return subTable
end

-- ============================================================
-- BF:WireAurasSubCategoryFallbacks(aurasTable)
--
-- Walks an auras table (flat.auras) and attaches the second-tier
-- metatable fallback to every existing sub-category rawkey. For each
-- sub-category in BF.AURAS_SUBCATEGORIES, if rawget(aurasTable, subcat)
-- is a table, its __index is pointed at rpDB.profile.auras[subcat].
--
-- Sub-categories that don't exist as rawkeys on the flat are left
-- alone -- they resolve through the first-tier fallback
-- (flat.auras -> global.auras), which returns the fully-populated
-- global sub-category table.
--
-- Called from RehydrateFlats after the existing WireSectionFallback
-- loop, so every flat's existing sub-category tables get their
-- metatables re-wired on login, profile change, reset, and copy.
-- Idempotent: if the metatable already points at the correct global,
-- it's left alone.
-- ============================================================
function BF:WireAurasSubCategoryFallbacks(aurasTable)
    if type(aurasTable) ~= "table" then return end
    local globals = self.rpDB and self.rpDB.profile and self.rpDB.profile.auras
    if type(globals) ~= "table" then return end
    for _, subcat in ipairs(self.AURAS_SUBCATEGORIES or {}) do
        local subTable = rawget(aurasTable, subcat)
        local globalSub = globals[subcat]
        if type(subTable) == "table" and type(globalSub) == "table" then
            local mt = getmetatable(subTable)
            if not mt or mt.__index ~= globalSub then
                setmetatable(subTable, { __index = globalSub })
            end
        end
    end
end

-- List of sections that support the "Separate configuration per Layout"
-- toggle. Consumed by RehydrateFlats (to wire fallbacks on every flat at
-- login/profile-change) and by the v24 retrofit migration.
BF._perLayoutSections = {
    "sorting", "tooltips",
    "auras", "icons", "text", "borders",
    "healthPower", "auraText", "absorbs", "castBar",
}

-- ============================================================
-- AURAS SECTION: SUB-CATEGORY MAP (v27)
-- ============================================================
-- The auras section is nested one level deeper than the other
-- per-layout sections: keys are grouped into sub-categories matching
-- the Options UI subtabs. Four of the original eight survive -- Buffs,
-- Big Defensive (under the Buffs nav section) and Debuffs, Dispel
-- Indicator (under Debuffs). Important went in v64, Private Auras in
-- v67, Crowd Control in v69; the retired names stay in
-- AURAS_SUBCATEGORY_OF below for the migrations that need them (see the
-- note further down).
--
-- AURAS_SUBCATEGORIES: ordered list of the live sub-category names (four
-- of them since v67 -- see the list itself below; it was eight in v27).
-- Consumed by WireAurasSubCategoryFallbacks (iterates them to wire
-- per-sub-category metatable fallbacks) and by Options UI code that
-- needs to enumerate sub-categories.
--
-- AURAS_SUBCATEGORY_OF: key -> sub-category map. Consumed by the v27
-- migration (MigrateAurasToSection) to relocate flat-root aura keys
-- into their sub-category, and by Options setters to route writes to
-- the correct sub-category via GetOrCreateAurasSubCategory.
--
-- (The note that used to stand here about the pvpSwapDebuffsPrivate* toggles
-- routing under the privateAuras sub-category went with the Private Auras
-- feature in v67; there is no privateAuras sub-category any more.)
-- ============================================================
-- v60: "blizzardDebuffs" removed with the experimental Blizzard-native
-- debuff container (Auras/PrivateAuraDebuffs.lua deleted). Its four keys
-- (enabled / containerPosition / iconSize / blizzardDebuffMaxCount) are
-- gone from AURAS_SUBCATEGORY_OF below -- note that three of them were
-- generic names, so nothing may reintroduce a widget key called
-- "enabled" or "iconSize" under the auras section.
BF.AURAS_SUBCATEGORIES = {
    "buffs", "debuffs", "bigDef", "dispelIndicator",
}   -- v64: "important" removed. v67: "privateAuras" removed.
    -- v69 removed the Crowd Control feature (it became a seeded custom debuff
    -- container, MigrateCrowdControlToContainer); "crowdControl" leaves this
    -- list now that the retired data is purged at load. Consumers of this list
    -- are enumeration/wiring only -- WireAurasSubCategoryFallbacks stops
    -- re-wiring a dead sub-table on every login, and the generated
    -- AURAS_SUBCAT_TOGGLE map below mints exactly the four live subtab keys.
    --
    -- DELIBERATELY still present in AURAS_SUBCATEGORY_OF below: for a profile
    -- below dbVersion 27 the v27 migration is what CREATES
    -- flat.auras.crowdControl from the flat-root crowdControl* geometry keys,
    -- and migration 62 then reads exactly that sub-table. Same story for
    -- AURA_TEXT_SUBCATEGORY_OF / migration 30 / the duration half. Removing
    -- those entries in this build would silently degrade migration 62 to
    -- factory defaults for legacy profiles. Retire them in a later build, once
    -- no supported profile can arrive below dbVersion 62.

BF.AURAS_SUBCATEGORY_OF = {
    -- buffs
    showBuffs           = "buffs",
    buffSize            = "buffs",
    buffsPerRow         = "buffs",
    maxBuffs            = "buffs",
    buffGrowDirection   = "buffs",
    buffAnchorPoint     = "buffs",
    buffOffsetX         = "buffs",
    buffOffsetY         = "buffs",
    buffSpacing         = "buffs",
    buffRowSpacing      = "buffs",
    buffBorderColor     = "buffs",
    buffBorderThickness = "buffs",
    buffBlizzardBorders = "buffs",
    buffBorderStyle     = "buffs",
    -- debuffs
    showDebuffs         = "debuffs",
    debuffSize          = "debuffs",
    debuffsPerRow       = "debuffs",
    maxDebuffs          = "debuffs",
    debuffGrowDirection = "debuffs",
    debuffAnchorPoint   = "debuffs",
    debuffOffsetX       = "debuffs",
    debuffOffsetY       = "debuffs",
    debuffSpacing       = "debuffs",
    debuffRowSpacing    = "debuffs",
    -- v84 (Stage 5 §9.6 + §9.10): the debuff TYPE model replaces
    -- debuffShowMode and the four enlarge*Debuffs toggles. Every one of these
    -- keys has to be routed here or setAuras writes it to the section root
    -- instead of the debuffs sub-category and the runtime never sees it.
    debuffBaseFilter       = "debuffs",
    debuffShowOther        = "debuffs",
    debuffSortOrder        = "debuffs",
    debuffMaxDuration      = "debuffs",
    -- v95 (owner-approved plan 2026-08-25): Simple Mode. Routed here so
    -- setAuras writes them into the debuffs sub-category (and therefore
    -- dispatches RefreshDebuffsOnly like every other debuffs key); they are
    -- ALSO listed in AURAS_SUBCAT_SCOPES.debuffs.debuffFilter.keys below,
    -- which is what makes them follow the Preset/Filter subtab's own
    -- per-Layout toggle rather than the Debuffs tab's.
    debuffSimpleMode        = "debuffs",
    debuffSimpleSeparateBoss = "debuffs",
    -- 2026-08-25 (owner request): Simple Mode's own "Exclude Applied by
    -- Friendly" box. Normal mode expresses the same filter as the "noplayer"
    -- Base Filter value, which Simple Mode does not read -- hence a key of
    -- its own rather than a reuse of debuffBaseFilter.
    debuffSimpleExcludeFriendly = "debuffs",
    -- v91 (owner ruling 2026-08-17): the DEBUFF PRIORITY LIST. The per-type
    -- Order dropdowns become UNIQUE ranks 1..7 (debuffRank*), Dispellable
    -- splits into two independent types (DispMe / DispOthers, retiring
    -- debuffDispellableMode + debuffType|SizeDispellable), and three Combine
    -- flags plus the two "Dispellable by Me" resolver toggles are new. The
    -- retired keys are REMOVED from this map: debuffOrderBoss/Role/CC/Priority/
    -- Dispellable, debuffOtherOrder, debuffDispellableMode,
    -- debuffTypeDispellable, debuffSizeDispellable (Core_Migrations dbVersion
    -- 71 prunes them from saved profiles).
    debuffTypeBoss         = "debuffs",
    debuffSizeBoss         = "debuffs",
    debuffRankBoss         = "debuffs",
    debuffMaxBoss          = "debuffs",
    debuffTypeRole         = "debuffs",
    debuffSizeRole         = "debuffs",
    debuffRankRole         = "debuffs",
    debuffMaxRole          = "debuffs",
    debuffTypeCC           = "debuffs",
    debuffSizeCC           = "debuffs",
    debuffRankCC           = "debuffs",
    debuffMaxCC            = "debuffs",
    debuffTypeDispMe       = "debuffs",
    debuffSizeDispMe       = "debuffs",
    debuffRankDispMe       = "debuffs",
    debuffMaxDispMe        = "debuffs",
    debuffTypeDispOthers   = "debuffs",
    debuffSizeDispOthers   = "debuffs",
    debuffRankDispOthers   = "debuffs",
    debuffMaxDispOthers    = "debuffs",
    debuffTypePriority     = "debuffs",
    debuffSizePriority     = "debuffs",
    debuffMaxPriority      = "debuffs",
    debuffMaxOther         = "debuffs",
    debuffRankPriority     = "debuffs",
    debuffRankOther        = "debuffs",
    -- 2026-08-25: Simple Mode's own priority list. Same sub-category and the
    -- same Preset/Filter scope as the normal ranks below -- only the MODE that
    -- reads them differs (BF:DebuffRankOf, Indicators/DebuffIcons.lua).
    debuffSimpleRankBoss       = "debuffs",
    debuffSimpleRankRole       = "debuffs",
    debuffSimpleRankCC         = "debuffs",
    debuffSimpleRankDispMe     = "debuffs",
    debuffSimpleRankDispOthers = "debuffs",
    debuffSimpleRankPriority   = "debuffs",
    debuffSimpleRankOther      = "debuffs",
    debuffCombineBossRole      = "debuffs",
    debuffCombineDispel        = "debuffs",
    debuffCombinePriorityOther = "debuffs",
    -- The two governors of BF:MyDispelTypes (the By Me / By Others boundary).
    debuffDispMeTalented   = "debuffs",
    debuffDispMeLongCd     = "debuffs",
    -- 2026-09-14: per-preset Relative Size of a CLAIMED debuff category
    -- (a table: preset key -> percent). Edited on the Preset/Filter subtab
    -- and read by PresetRatio (Indicators/DebuffIcons.lua) from the debuffs
    -- profile. Unrouted, the Options write fell to the legacy flat-root path
    -- and the slider snapped back to the old value on every edit.
    presetRelativeSize     = "debuffs",
    debuffBorderColor     = "debuffs",
    debuffDispelBorderThickness = "debuffs",
    debuffColorBorderByDispel   = "debuffs",
    showDebuffDispelTypeIcon    = "debuffs",
    debuffDispelTypeIconScale   = "debuffs",
    debuffBorderThickness = "debuffs",
    debuffBlizzardBorders = "debuffs",
    debuffBorderStyle     = "debuffs",
    -- v67: the whole privateAuras block (8 keys) removed with the Private
    -- Auras icon feature, which was 12.0.7-only. Nothing may reintroduce a
    -- widget under showPrivateAuras / privateAuraSize / maxPrivateAuras /
    -- privateAuraAnchorPoint / privateAuraGrowDirection /
    -- privateAuraIconSpacing / privateAuraOffsetX / privateAuraOffsetY.
    -- The already-removed pvpSwapDebuffsPrivate* keys belonged here too.
    -- Blizzard's native private-aura DISPEL overlay is a separate feature
    -- and keeps its keys under dispelIndicator.
    -- bigDef
    showBigDef          = "bigDef",
    bigDefSize          = "bigDef",
    bigDefAnchor        = "bigDef",
    bigDefOffsetX       = "bigDef",
    bigDefOffsetY       = "bigDef",
    bigDefMaxCount      = "bigDef",
    bigDefGrowDirection = "bigDef",
    bigDefIconsPerRow   = "bigDef",
    bigDefSpacing       = "bigDef",
    bigDefRowSpacing    = "bigDef",
    bigDefShowGlow      = "bigDef",
    bigDefGlowColor     = "bigDef",
    bigDefGlowStyle     = "bigDef",
    bigDefBorderColor     = "bigDef",
    bigDefBorderThickness = "bigDef",
    bigDefBlizzardBorders = "bigDef",
    bigDefBorderStyle     = "bigDef",
    -- v64: important keys removed with the feature.
    -- crowdControl
    showCrowdControl          = "crowdControl",
    crowdControlMaxIcons      = "crowdControl",
    crowdControlSize          = "crowdControl",
    crowdControlAnchor        = "crowdControl",
    crowdControlOffsetX       = "crowdControl",
    crowdControlOffsetY       = "crowdControl",
    crowdControlGrowDirection = "crowdControl",
    crowdControlIconsPerRow   = "crowdControl",
    crowdControlSpacing       = "crowdControl",
    crowdControlRowSpacing    = "crowdControl",
    crowdControlShowGlow      = "crowdControl",
    crowdControlBorderColor     = "crowdControl",
    crowdControlBorderThickness = "crowdControl",
    crowdControlBlizzardBorders = "crowdControl",
    crowdControlBorderStyle     = "crowdControl",
    -- dispelIndicator
    showDispelIndicator     = "dispelIndicator",
    dispelIndicatorSize     = "dispelIndicator",
    dispelIndicatorPosition = "dispelIndicator",
    dispelIndicatorOffsetX  = "dispelIndicator",
    dispelIndicatorOffsetY  = "dispelIndicator",
    dispelIndicatorStyle       = "dispelIndicator",
    dispelIndicatorMaxIcons    = "dispelIndicator",
    dispelIndicatorMode        = "dispelIndicator",
    dispelIndicatorOnlyIfReady = "dispelIndicator",
    -- 2026-08-25 (owner request): the dispel VISUALS' own copy of the two
    -- BF:MyDispelTypes governors. Same question as debuffDispMeTalented /
    -- debuffDispMeLongCd, asked separately: those stay the DEBUFF ICONS'
    -- answer, these drive the custom dispel indicator, border, color overlay
    -- and health tint (BF.DispelVisualFilterFor, Auras/ContainerFactory.lua).
    dispelVisualDispMeTalented = "dispelIndicator",
    dispelVisualDispMeLongCd   = "dispelIndicator",
    -- v35: debuff highlight / overlay keys migrated from borders.
    -- privateAuraDispelOverlayMode was renamed to blizzardDispelOverlayMode
    -- at the same time since under the new UI it drives the Blizzard-style
    -- dispel overlay in the Dispel Indicator tab, not a private-aura setting.
    enableDebuffBorder        = "dispelIndicator",
    debuffBorderMode          = "dispelIndicator",
    debuffBorderWidth         = "dispelIndicator",
    dispelBorderOnlyIfReady   = "dispelIndicator",
    enableDebuffOverlay       = "dispelIndicator",
    -- debuffOverlayStyle removed in v35 follow-up: the select only had
    -- two options (custom / blizzard) and the Blizzard path is now gated
    -- by the unified dispelIndicatorOverlayMode dropdown, leaving the key
    -- with no meaningful state. The mapping entry is dropped so the
    -- setAuras_shared router doesn't try to route writes for a key that
    -- no widget emits.
    debuffOverlayMode         = "dispelIndicator",
    debuffOverlayAlpha        = "dispelIndicator",
    debuffOverlayHeight       = "dispelIndicator",
    debuffOverlayFillOnly     = "dispelIndicator",
    dispelOverlayOnlyIfReady  = "dispelIndicator",
    -- Debuff Health Color Change (owner): dispellable-debuff-triggered health
    -- bar tint, the dispelHealthColor kind of the merged dispel-visual slot.
    enableDebuffHealthColor      = "dispelIndicator",
    debuffHealthColorMode        = "dispelIndicator",
    debuffHealthColorAlpha       = "dispelIndicator",
    dispelHealthColorOnlyIfReady = "dispelIndicator",
    blizzardDispelOverlayMode = "dispelIndicator",
    blizzardDispelOverlayOpacity = "dispelIndicator",
    blizzardDispelOverlayColorMode = "dispelIndicator",
    blizzardDispelOverlayFlash = "dispelIndicator",
    blizzardDispelShowIcons = "dispelIndicator",
    blizzardDispelOrgType = "dispelIndicator",
    blizzardDispelShowOverlay = "dispelIndicator",
    -- v67: blizzardDispelPrivateOnly and showBlizzardPrivateAuraDispel
    -- removed. Neither had a widget (the showBlizzardPrivateAuraDispel
    -- toggle was deleted, see Options_Auras.lua) and neither was read at
    -- runtime -- the only surviving mentions are comments in
    -- Auras/PrivateAuraDispelOverlay.lua. They were dead weight that the
    -- Themes snapshot still serialized into every theme. Do NOT
    -- reintroduce a widget under either name: it would be routed straight
    -- back into auras.dispelIndicator and start riding along again.
    -- v36: boolean showBlizzardDispelIndicator replaced by two-option
    -- select dispelIndicatorOverlayMode ("blizzard" / "custom").
    dispelIndicatorOverlayMode = "dispelIndicator",
}

-- ============================================================
-- AURAS PER-LAYOUT GROUPS (v60, re-split per sub-category in v65)
-- ============================================================
-- The single "Auras" nav section was split into two nav sections, Buffs and
-- Debuffs; v65 gave each of their four subtabs its own "Enable per-Layout
-- configuration" toggle (BF.AURAS_SUBCAT_TOGGLE below). STORAGE DID NOT MOVE
-- through either split: every aura setting still lives at
-- rpDB.profile.auras.<subcat> (per-layout OFF) or flat.auras.<subcat>
-- (per-layout ON), exactly as before. Only the TOGGLE changed.
--
-- Because the sub-categories can disagree, a flat's auras table can legally
-- hold rawkeys for a sub-category whose toggle is currently OFF (left behind
-- by an earlier ON, kept as cache exactly like every other section toggle).
-- Those rawkeys MUST NOT be read. That is why aura reads resolve PER
-- SUB-CATEGORY via GetAurasSubcatProfile / ResolveCFGAurasSubcat rather
-- than resolving flat.auras once and indexing subcats off it: the
-- per-subcat form is correct no matter what stale rawkeys exist, so
-- nothing has to be pruned or normalized to keep reads honest.
--
-- New aura readers should call BF:GetAurasSubcatProfile(subcat, flat) --
-- or, in a CFG-aware runtime path, BF.ResolveCFGAurasSubcat -- and NOT
-- BF:GetSectionProfile("auras", flat).
--
-- The v60 list BF.AURAS_PERLAYOUT_GROUPS = { "aurasBuffs", "aurasDebuffs" }
-- is gone with the v65 transitional alias: nothing consumed it once the
-- toggles stopped being per-group. The group NAMES survive as the two aura
-- nav-page identities below (AURAS_SUBCAT_GROUP values) and as the keys of
-- BF.AURAS_GROUP_CFG_FLAG; they are no longer per-Layout toggle keys.

-- Sub-category -> owning group. The group is a UI/nav grouping and the unit
-- the per-CFG override flag is keyed on -- NOT a per-Layout toggle key.
BF.AURAS_SUBCAT_GROUP = {
    buffs           = "aurasBuffs",
    bigDef          = "aurasBuffs",
    debuffs         = "aurasDebuffs",
    dispelIndicator = "aurasDebuffs",
}   -- v69: "crowdControl" removed with the feature (see AURAS_SUBCATEGORIES).

-- ── dbVersion 65: sub-category -> its OWN per-Layout toggle key ───────────
-- The two group toggles above are being replaced by one toggle per
-- sub-category, so that every aura subtab owns its own "Enable per-Layout
-- configuration" switch instead of sharing one with its sibling subtab.
--
-- GENERATED, never hand-written, for two reasons. First, it cannot drift from
-- AURAS_SUBCATEGORIES -- adding or retiring a sub-category moves this map with
-- it. Second, the underscore form "auras_buffs" is mechanically derivable,
-- which is the whole reason it was chosen over "auraBuffs": that would differ
-- from the retired "aurasBuffs" by a single character, and a one-character typo
-- class in a key space whose failure mode is "silently reads the wrong table"
-- is not acceptable.
--
-- With crowdControl retired from AURAS_SUBCATEGORIES this yields exactly the
-- four live subtabs: auras_buffs, auras_bigDef, auras_debuffs,
-- auras_dispelIndicator.
BF.AURAS_SUBCAT_TOGGLE = {}
for _, sc in ipairs(BF.AURAS_SUBCATEGORIES) do
    BF.AURAS_SUBCAT_TOGGLE[sc] = "auras_" .. sc
end

-- Toggle key -> the storage section its data actually lives in. Every aura
-- toggle shares the one "auras" table; this map is what lets a toggle-only
-- name be passed to the section helpers below without them going looking for a
-- non-existent rpDB.profile.auras_buffs. SeedAllFlatsForSection consults it,
-- and a key missing from here silently seeds nothing.
--
-- v65: the two transitional GROUP entries (aurasBuffs / aurasDebuffs) are
-- gone with the alias -- no caller passes a group name to these helpers any
-- more, and the group keys cannot exist in saved variables now that
-- BF:NormalizeAuraPerLayoutKeys runs at load.
BF.AURAS_GROUP_STORAGE_SECTION = {}
for _, key in pairs(BF.AURAS_SUBCAT_TOGGLE) do
    BF.AURAS_GROUP_STORAGE_SECTION[key] = "auras"
end

-- ============================================================
-- AURA SUB-CATEGORY KEY SCOPES (2026-08-25)
-- ============================================================
-- A second per-Layout toggle INSIDE one aura sub-category, for a subtab
-- that shares the sub-category's storage table but wants its own scope.
-- The v65 model is one toggle per sub-category (auras_<subcat>); the
-- 2026-08-24 per-subtab model is one toggle per subtab over one flat
-- section table. This is the latter applied to a sub-category: storage
-- stays rpDB.profile.auras.<subcat> / flat.auras.<subcat>, NOTHING in
-- saved data moves, and a key's scope toggle is decided per KEY.
--
-- Today there is exactly one: the Debuff Preset/Filter subtab
-- (Options_Auras.lua, the PRESET_KEYS partition) over the "debuffs"
-- sub-category, toggle key auras_debuffFilter. Every key on that subtab
-- that routes through AURAS_SUBCATEGORY_OF -> "debuffs" is listed here;
-- every OTHER "debuffs" key (the Debuffs tab: Show Debuffs, size,
-- position, spacing, border, dispel-type icon, and the widget-less
-- maxDebuffs) keeps following auras_debuffs. The Long-Term Non-Combat
-- Debuffs toggles on the same subtab are acDB-stored and profile-wide;
-- they route through neither toggle and are deliberately absent.
--
-- THE ROUTING AUTHORITY for the split: a key added to the Preset/Filter
-- subtab later MUST be added here, or it silently follows auras_debuffs
-- (the Debuffs tab's toggle) instead of the subtab it renders on.
-- Consumers: BF:AurasKeyToggle (per-key scope), GetAurasSubcatProfile
-- (merged view when the two toggles disagree), SeedAllFlatsForSection
-- (seeds ONLY these keys for the scope toggle), IsPerLayoutSection's
-- coarse "auras" alias, NormalizeAuraPerLayoutKeys (day-one seed), and
-- the Options write / Copy routers (Options.lua).
BF.AURAS_SUBCAT_SCOPES = {
    debuffs = {
        debuffFilter = {
            toggle = "auras_debuffFilter",
            label  = "Debuff Preset/Filter",
            keys   = {
                -- Sorting & Filtering
                "debuffBaseFilter", "debuffSortOrder", "debuffMaxDuration",
                -- v95 (2026-08-25): Simple Mode and its one combine box. They
                -- render on this subtab (order 0.15 / 20.1), so they must be
                -- scoped to it -- omitted, they would silently follow the
                -- Debuffs tab's auras_debuffs toggle and a Layout that had
                -- Preset/Filter per-Layout would share its Simple Mode with
                -- every other Layout.
                "debuffSimpleMode", "debuffSimpleSeparateBoss",
                -- 2026-08-25: Simple Mode's Exclude Applied by Friendly box
                -- (order 0.16), same subtab and therefore the same scope.
                "debuffSimpleExcludeFriendly",
                -- Debuff Category Priority: one row per type -- Show /
                -- Relative Size / Max Debuffs / rank (arrows)
                "debuffTypeBoss",       "debuffSizeBoss",       "debuffMaxBoss",       "debuffRankBoss",
                "debuffTypeRole",       "debuffSizeRole",       "debuffMaxRole",       "debuffRankRole",
                "debuffTypeCC",         "debuffSizeCC",         "debuffMaxCC",         "debuffRankCC",
                "debuffTypeDispMe",     "debuffSizeDispMe",     "debuffMaxDispMe",     "debuffRankDispMe",
                "debuffTypeDispOthers", "debuffSizeDispOthers", "debuffMaxDispOthers", "debuffRankDispOthers",
                "debuffTypePriority",   "debuffSizePriority",   "debuffMaxPriority",   "debuffRankPriority",
                -- Other Debuffs row (Show / Max / rank)
                "debuffShowOther", "debuffMaxOther", "debuffRankOther",
                -- 2026-08-25: Simple Mode's parallel rank set. On this subtab,
                -- so scoped with everything else on it.
                "debuffSimpleRankBoss",   "debuffSimpleRankRole",
                "debuffSimpleRankCC",     "debuffSimpleRankDispMe",
                "debuffSimpleRankDispOthers", "debuffSimpleRankPriority",
                "debuffSimpleRankOther",
                -- The two Dispellable-by-Me governors (ride the DispMe row)
                "debuffDispMeTalented", "debuffDispMeLongCd",
                -- Combine Similar Debuff Types
                "debuffCombineBossRole", "debuffCombinePriorityOther", "debuffCombineDispel",
                -- 2026-09-14: the claimed-category Relative Size table. It
                -- renders on this subtab, so it follows THIS toggle: Party
                -- and Raid can size a claimed category independently no
                -- matter how the claiming container's own toggle is set.
                "presetRelativeSize",
            },
        },
    },
}

-- GENERATED from AURAS_SUBCAT_SCOPES (the v65 rule: never hand-written).
--   AURAS_KEY_SCOPE_TOGGLE[key]       -> scope toggle key, for a scoped key
--   AURAS_SCOPE_TOGGLE_INFO[toggle]   -> { subcat = , scope = , keys = ,
--                                         keySet = , label = }
-- Scope toggles are folded into AURAS_GROUP_STORAGE_SECTION (and so into
-- TOGGLE_STORAGE_SECTION below) so every helper that accepts an aura
-- toggle key accepts these too.
BF.AURAS_KEY_SCOPE_TOGGLE = {}
BF.AURAS_SCOPE_TOGGLE_INFO = {}
for subcat, scopes in pairs(BF.AURAS_SUBCAT_SCOPES) do
    for scope, def in pairs(scopes) do
        local keySet = {}
        for _, k in ipairs(def.keys) do
            keySet[k] = true
            BF.AURAS_KEY_SCOPE_TOGGLE[k] = def.toggle
        end
        BF.AURAS_SCOPE_TOGGLE_INFO[def.toggle] = {
            subcat = subcat, scope = scope, keys = def.keys,
            keySet = keySet, label = def.label,
        }
        BF.AURAS_GROUP_STORAGE_SECTION[def.toggle] = "auras"
    end
end

-- The per-Layout toggle key that governs one aura KEY: its scope toggle
-- when it has one, else its sub-category's toggle. nil for a key that is
-- not in AURAS_SUBCATEGORY_OF at all (flat-root legacy keys).
function BF:AurasKeyToggle(key)
    local tog = BF.AURAS_KEY_SCOPE_TOGGLE[key]
    if tog then return tog end
    local subcat = BF.AURAS_SUBCATEGORY_OF[key]
    return subcat and BF.AURAS_SUBCAT_TOGGLE[subcat] or nil
end

-- Is this aura KEY per-Layout right now? The per-key form of
-- IsPerLayoutAurasSubcat; the routers below (and Options.lua's
-- writeAurasValue) ask this rather than the sub-category question.
function BF:IsPerLayoutAurasKey(key)
    local tog = self:AurasKeyToggle(key)
    if not tog then return false end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local t = lp and lp.perLayoutToggles
    return (t and t[tog]) == true
end

-- ============================================================
-- PER-SUBTAB PER-LAYOUT SECTIONS (2026-08-24)
-- Docs/_PLAN_PerLayoutSubtabToggles.md -- design B, owner-approved.
-- The v65 aura model generalized to five flat-storage sections: the
-- per-Layout toggle moves to one per SUBTAB, storage stays flat, and
-- whole-section reads are served by a cached merged view
-- (GetMergedSectionView below). auraText and castBar are EXCLUDED by
-- owner ruling and keep their single section toggle; tooltips and
-- sorting have no subtabs.
--
-- THE ROUTING AUTHORITY: a key added to one of these sections later
-- MUST be added to its subtab's list here -- an unmapped key always
-- resolves GLOBAL (deliberate: healthPower.customPowerColors /
-- useCustomPowerColors are written unrouted from Global Styles ->
-- Colors and shared with the oUF frames).
-- ============================================================
BF.SECTION_SUBTABS = {
    text        = { "names", "healthText", "statusText", "levelText", "labels", "vehicle" },
    icons       = { "roleIcons", "raidTarget", "pingIndicator", "leaderAssistant", "missingRaidBuff", "statusIcons" },
    borders     = { "border", "targetHighlight", "mouseover", "aggro" },
    healthPower = { "health", "background", "status", "power", "range" },
    absorbs     = { "absorbs", "healAbsorbs", "healPrediction", "reducedMax" },
}

BF.SECTION_SUBTAB_KEYS = {
    text = {
        names = { "adjustNameFont", "nameFont", "nameFontBorder", "nameFontSize",
            "adjustNameColors", "classColorNames", "nameColor", "namePosition",
            "abbreviateNames", "maxNameChars", "capitalizeNames",
            "transliterateCyrillicNames" },
        healthText = { "showHealthText", "healthTextFormat", "healthTextPctSymbol",
            "healthTextPosition", "healthTextX", "healthTextY", "adjustHealthFont",
            "healthFont", "healthFontBorder", "healthFontSize",
            "adjustHealthTextColor", "classColorHealthText", "healthTextColor" },
        statusText = { "statusTextPosition", "statusTextX", "statusTextY",
            "appendStatusTextToNames", "statusAppendSeparator", "statusBeforeName",
            "abbreviateStatusNames", "maxStatusNameChars", "adjustStatusFont",
            "statusFont", "statusFontBorder", "statusFontSize",
            "capitalizeStatusText", "applyStatusColorsToNames", "showDeadStatus",
            "deadColorUseClassColor", "deadColor", "showOfflineStatus",
            "abbreviateOffline", "offlineColorUseClassColor", "offlineColor",
            "fadeOfflineNameText", "showAFKStatus", "afkColorUseClassColor",
            "afkColor" },
        levelText = { "showLevelText", "hideLevelTextAtMaxLevel",
            "levelTextPosition", "levelTextX", "levelTextY", "adjustLevelFont",
            "levelFont", "levelFontBorder", "levelFontSize",
            "adjustLevelTextColor", "classColorLevelText", "levelTextColor" },
        labels = { "showGroupLabels", "groupLabelColor", "groupLabelYOffset",
            "groupLabelNumberOnly", "adjustGroupLabelFont", "groupLabelFont",
            "groupLabelFontBorder", "groupLabelFontSize" },
        vehicle = { "showVehicleName", "abbreviateVehicleNames",
            "maxVehicleNameChars", "adjustVehicleFont", "vehicleFont",
            "vehicleFontBorder", "vehicleFontSize", "vehicleNamePosition" },
    },
    icons = {
        roleIcons = { "showRoleIcons", "roleIconStyle", "roleIconSize",
            "roleIconPosition", "showRoleIconTank", "showRoleIconHealer",
            "showRoleIconDPS" },
        raidTarget = { "showRaidTargetIcon", "raidTargetIconSize",
            "raidTargetIconPosition" },
        pingIndicator = { "showPingIndicator", "pingIndicatorSize",
            "pingIndicatorPosition" },
        leaderAssistant = { "showLeaderIcon", "leaderIconSize",
            "leaderIconPosition", "showAssistantIcon", "assistantIconSize",
            "assistantIconPosition" },
        missingRaidBuff = { "showMissingRaidBuff", "showMissingRaidBuffInCombat",
            "showMissingSymbiotic", "missingRaidBuffSize",
            "missingRaidBuffShowGlow", "missingRaidBuffAnchor",
            "missingRaidBuffOffsetX", "missingRaidBuffOffsetY" },
        statusIcons = { "showReadyCheck", "showPhased", "showSummonPending",
            "showResurrectPending", "showVehicleIcon",
            "resurrectPendingIconStyle", "statusIconSize", "statusIconPosition" },
    },
    borders = {
        border = { "enableBorder", "borderStyle", "borderColor",
            "borderThickness" },
        targetHighlight = { "enableTargetHighlight", "targetHighlightColor",
            "targetHighlightOpacity", "targetHighlightWidth" },
        mouseover = { "enableMouseoverHighlight", "mouseoverHighlightColor",
            "mouseoverHighlightOpacity" },
        aggro = { "aggroEnabled", "aggroStyle", "aggroScale", "aggroBorderWidth",
            "aggroBorderWidthBlizzard", "aggroColor1", "aggroColor2",
            "aggroColor3", "aggroCornersScale", "aggroArrowDirection",
            "aggroArrowPosition", "aggroArrowSize", "aggroArrowOffsetX",
            "aggroArrowOffsetY" },
    },
    healthPower = {
        health = { "useCustomHealthColor", "useHealthGradient", "healthColor",
            "healthBarOpacity", "useCustomHealthBarTexture", "healthBarTexture" },
        background = { "useCustomBackgroundColor", "useBgClass", "useBgGradient",
            "backgroundColor", "backgroundAlpha", "bgClassDarken" },
        status = { "useCustomOfflineColor", "offlineBackgroundColor",
            "fadeOfflineFrames", "useCustomDeadColor", "deadBackgroundColor",
            "deadBackgroundOpacity", "useCustomHostileColor", "hostileColor" },
        power = { "showAllPowerBars", "showPowerBarHealers",
            "showPowerBarBloodDK", "powerBarHeight", "aurasAbovePowerBar",
            "useCustomPowerBarBgColor", "powerBarBgColor", "powerBarBgOpacity",
            "useCustomPowerBarTexture", "powerBarTexture" },
        range = { "enableRangeFade", "rangeFadeAlpha", "enableRangeDesaturate",
            "rangeDesaturation", "deadColorOORFactor" },
    },
    absorbs = {
        absorbs = { "showAbsorbsMissingHealth", "showOvershield",
            "overshieldStyle", "overshieldAnchor", "useCustomAbsorbColor",
            "absorbBaseColor", "absorbOverlayColor", "showAbsorbShadow",
            "absorbShadowColor", "useCustomOvershieldColor",
            "overshieldBaseColor", "overshieldOverlayColor",
            "useCustomAbsorbBarTexture", "absorbBarTexture",
            "useCustomOvershieldBarTexture", "overshieldBarTexture" },
        healAbsorbs = { "showHealAbsorb", "healAbsorbStyle", "healAbsorbColor",
            "useCustomHealAbsorbSymbolColor", "healAbsorbSymbolColor",
            "healAbsorbBarHeight", "useCustomHealAbsorbTexture",
            "healAbsorbTexture" },
        healPrediction = { "showHealPrediction", "healPredictionAnchor",
            "healPredictionColor", "useCustomHealPredictionTexture",
            "healPredictionTexture" },
        reducedMax = { "showReducedMaxHealth", "useCustomReducedMaxTexture",
            "reducedMaxHealthTexture", "reducedMaxHealthColor",
            "showReducedMaxHealthText", "reducedMaxHealthTextColor",
            "appendReducedMaxText", "appendReducedMaxTarget",
            "reducedMaxHealthTextPosition", "reducedMaxHealthTextX",
            "reducedMaxHealthTextY", "reducedMaxHealthFontSize",
            "reducedMaxHealthFontBorder" },
    },
}

-- GENERATED, never hand-written -- the v65 rule. Toggle keys are
-- "<section>_<subtabId>" (text_names, healthPower_range, ...).
BF.SECTION_KEY_SUBTAB    = {}   -- section -> key -> subtabId
BF.SECTION_SUBTAB_TOGGLE = {}   -- section -> subtabId -> toggle key
-- Toggle key -> storage section, for EVERY per-subtab toggle key in the
-- addon (the generalized AURAS_GROUP_STORAGE_SECTION -- the aura entries
-- are folded in below so SeedAllFlatsForSection has one map to consult).
BF.TOGGLE_STORAGE_SECTION = {}
for section, subtabs in pairs(BF.SECTION_SUBTABS) do
    local keyMap, togMap = {}, {}
    for _, st in ipairs(subtabs) do
        local togKey = section .. "_" .. st
        togMap[st] = togKey
        BF.TOGGLE_STORAGE_SECTION[togKey] = section
        for _, k in ipairs(BF.SECTION_SUBTAB_KEYS[section][st]) do
            keyMap[k] = st
        end
    end
    BF.SECTION_KEY_SUBTAB[section]    = keyMap
    BF.SECTION_SUBTAB_TOGGLE[section] = togMap
end
for togKey, sec in pairs(BF.AURAS_GROUP_STORAGE_SECTION) do
    BF.TOGGLE_STORAGE_SECTION[togKey] = sec
end

-- ============================================================
-- BF:NormalizeAuraPerLayoutKeys(rp)  (dbVersion 65)
-- ============================================================
-- Translates the retired per-Layout aura toggle keys onto the four
-- auras_<subcat> keys, then nils them. Takes an rpDB PROFILE table (raw or
-- active), not a flat.
--
--   auras        (pre-v60, one toggle for the whole section)
--   aurasBuffs   (v60, buffs + bigDef)
--   aurasDebuffs (v60, debuffs + dispelIndicator)
--
-- Runs at LOAD -- hooked from RehydrateFlats -- rather than from a dbVersion
-- block, and that placement is the whole point. Three separate holes make a
-- version-gated rename insufficient:
--
--   * IMPORT. Imports never run migrations (dbVersion lives on the main
--     db.profile, which is not imported). Current strings can't carry the
--     retired keys — the format-4 exporter is whitelist-driven and the
--     legacy decoder strips them (StripLegacyExportKeys, §L.7) — but a
--     LEGACY string predating that strip can still land its toggle keys
--     verbatim in a build that only understands auras_*.
--   * MIGRATION ORDERING. Three pre-v60 migrations still write
--     perLayoutToggles.auras = true. Within one login the dispatcher runs
--     those before the aura blocks, so ordering saves it -- but
--     EnsureAurasMigratedForProfile can stamp _aurasUnifiedV65 on an rp
--     profile from an acDB profile callback BEFORE those low-version blocks
--     run, leaving the key written and never cleaned.
--   * PROFILE COPY / RESET, which reintroduce data no versioned block re-runs
--     over.
--
-- SEED-ONLY-WHEN-NIL, so a re-run can never stomp a choice the user made after
-- the upgrade -- the same guard the v60 stage uses, and what makes this safe to
-- call from anywhere, at any time, as often as you like.
--
-- The legacy whole-section `auras` value stands in for a MISSING group key
-- rather than being discarded: a profile can legitimately hold only
-- perLayoutToggles.auras (sentinel stamped early via the acDB callback, so the
-- v60 split -- which seeds from t.auras -- never ran), and nilling it unread
-- would silently revert that user to the global settings.
--
-- Once this is guaranteed to have run before any read, the retired keys cannot
-- exist in saved variables, which is what licenses deleting the transitional
-- group alias in stage 4 rather than carrying it forever.
function BF:NormalizeAuraPerLayoutKeys(rp)
    if type(rp) ~= "table" then return end
    local lp = rp.layouts
    if type(lp) ~= "table" then return end
    local t = lp.perLayoutToggles
    if type(t) ~= "table" then return end

    local legacyAll = t.auras
    for sc, key in pairs(BF.AURAS_SUBCAT_TOGGLE) do
        if t[key] == nil then
            local grp = BF.AURAS_SUBCAT_GROUP[sc]
            local old = grp and t[grp]
            if old == nil then old = legacyAll end
            -- Only write when there is something to translate. Writing an
            -- explicit false for a profile that never held a legacy key would
            -- add four dead rawkeys to every profile on every login.
            if old ~= nil then t[key] = old and true or false end
        end
    end

    t.auras, t.aurasBuffs, t.aurasDebuffs = nil, nil, nil

    -- 2026-08-25: in-sub-category SCOPE toggles (AURAS_SUBCAT_SCOPES). A
    -- scope toggle that has never been written inherits its sub-category's
    -- toggle, so a profile that had Debuffs per-Layout keeps its
    -- Preset/Filter settings per-Layout on day one -- exactly the values it
    -- was reading yesterday, from the same rawkeys. Same SEED-ONLY-WHEN-NIL
    -- guard and same write-only-when-translatable rule as above; no saved
    -- DATA is touched, only the toggle key.
    for togKey, info in pairs(BF.AURAS_SCOPE_TOGGLE_INFO) do
        if t[togKey] == nil then
            local parent = t[BF.AURAS_SUBCAT_TOGGLE[info.subcat]]
            if parent ~= nil then t[togKey] = parent and true or false end
        end
    end
end

-- ============================================================
-- BF:NormalizeSectionPerLayoutKeys(rp)  (2026-08-24)
-- ============================================================
-- The NormalizeAuraPerLayoutKeys twin for the five per-subtab sections
-- (text / icons / borders / healthPower / absorbs): translates a retired
-- whole-section toggle key onto ALL of that section's subtab keys, then
-- nils it. Same placement rationale (runs at LOAD from RehydrateFlats --
-- import, migration ordering, and profile copy/reset are the holes a
-- version-gated rename cannot cover), same SEED-ONLY-WHEN-NIL guard, same
-- write-only-when-translatable rule. Copying the old value onto EVERY
-- subtab key is what keeps an upgrader's behavior identical on day one
-- (the v60 _AuraMig_SplitPerLayoutToggle precedent).
function BF:NormalizeSectionPerLayoutKeys(rp)
    if type(rp) ~= "table" then return end
    local lp = rp.layouts
    if type(lp) ~= "table" then return end
    local t = lp.perLayoutToggles
    if type(t) ~= "table" then return end
    for section, togMap in pairs(BF.SECTION_SUBTAB_TOGGLE) do
        local old = t[section]
        if old ~= nil then
            for _, key in pairs(togMap) do
                if t[key] == nil then t[key] = old and true or false end
            end
            t[section] = nil
        end
    end
end

-- Is this sub-category's own per-Layout toggle ON?
-- Unknown sub-categories (legacy/defensive) fall back to the coarse
-- IsPerLayoutSection("auras") alias -- "is ANY aura sub-category per-Layout".
-- Cost is one map lookup plus one table index, the same as the v60
-- subcat -> group -> table form it replaces.
function BF:IsPerLayoutAurasSubcat(subcat)
    local key = subcat and BF.AURAS_SUBCAT_TOGGLE[subcat]
    if key then return self:IsPerLayoutSection(key) end
    return self:IsPerLayoutSection("auras")
end

-- Per-sub-category counterpart of GetSectionProfile. Returns the table a
-- given aura sub-category's keys should be read from for this flat.
--
-- Reads flat.auras via normal indexing (not rawget) on purpose: when the
-- group is ON but this particular flat never materialized its own
-- sub-table, the WireSectionFallback metatable hands back the global
-- sub-category -- which is the correct source until a write materializes
-- the flat's own copy through GetOrCreateAurasSubCategory.
--
-- 2026-08-25: a sub-category with SCOPE toggles (AURAS_SUBCAT_SCOPES --
-- "debuffs", whose Preset/Filter keys own auras_debuffFilter) can have its
-- toggles DISAGREE. Then neither the flat's sub-table nor the global is
-- the right answer for every key, and this returns a MERGED VIEW instead:
-- per key, the flat's rawkey where that key's toggle is ON (and the flat
-- has it), else the global's value -- the GetMergedSectionView rule.
-- Whole-table callers (the aura cache builders, ResolveCFGAurasSubcat, the
-- Options getters) are unchanged: they get a table that indexes the same.
--
-- The view is READ-ONLY by convention (every writer routes per key through
-- Options.lua's writeAurasValue / GetOrCreateAurasSubCategory -- nothing
-- writes through a view) and is cached on flat._sectionCache under
-- "auras.<subcat>"; InvalidateRaidProfileCache wipes that store, and
-- BF:InvalidateAurasSubcatViews wipes just this sub-category's slot for
-- the write paths that do not go through it.
--
-- When the toggles AGREE the pre-existing single-table answers stand, so
-- a profile that never touches the scope toggle sees no view at all.
function BF:GetAurasSubcatProfile(subcat, flat)
    if type(subcat) ~= "string" then return nil end
    local gp = self.rpDB and self.rpDB.profile and self.rpDB.profile.auras
    local global = gp and gp[subcat]
    local scopes = BF.AURAS_SUBCAT_SCOPES[subcat]
    local subcatOn = self:IsPerLayoutAurasSubcat(subcat)
    if scopes and type(flat) == "table" then
        local lp = self.rpDB.profile.layouts
        local toggles = lp and lp.perLayoutToggles or {}
        local split = false
        for _, def in pairs(scopes) do
            if (toggles[def.toggle] == true) ~= subcatOn then split = true break end
        end
        if split then
            local aurasP = flat.auras
            local raw = type(aurasP) == "table" and rawget(aurasP, subcat) or nil
            -- No per-flat data at all: every key resolves global regardless
            -- of which toggle it follows.
            if type(raw) ~= "table" or type(global) ~= "table" then return global end
            local cache = rawget(flat, "_sectionCache")
            if not cache then
                cache = {}
                flat._sectionCache = cache
            end
            local slot = "auras." .. subcat
            local view = cache[slot]
            if view ~= nil then return view end
            view = {}
            for k, v in pairs(global) do view[k] = v end
            -- Scoped keys: the flat's rawkey only while THEIR toggle is ON.
            local scopedOn = {}
            for _, def in pairs(scopes) do
                if toggles[def.toggle] == true then
                    for _, k in ipairs(def.keys) do
                        scopedOn[k] = true
                        local fv = rawget(raw, k)
                        if fv ~= nil then view[k] = fv end
                    end
                else
                    for _, k in ipairs(def.keys) do scopedOn[k] = false end
                end
            end
            -- Unscoped keys: the flat's rawkey only while the sub-category's
            -- own toggle is ON. Walk the flat's rawkeys (sparse) rather than
            -- AURAS_SUBCATEGORY_OF, so a stray rawkey of an OFF scope stays
            -- unread (the per-subtab isolation rule).
            if subcatOn then
                for k, fv in pairs(raw) do
                    if scopedOn[k] == nil then view[k] = fv end
                end
            end
            cache[slot] = view
            return view
        end
    end
    if subcatOn and type(flat) == "table" then
        local aurasP = flat.auras
        if type(aurasP) == "table" then
            local sub = aurasP[subcat]
            if type(sub) == "table" then return sub end
        end
    end
    return global
end

-- Wipe the cached merged views of one aura sub-category on every RP flat
-- (CFG flats never hold one: ResolveCFGAurasSubcat's override-ON branch
-- reads the CFG flat's sub-table directly, and its override-OFF branch
-- resolves against the ACTIVE Layout's RP flat). Called by the aura write
-- and Copy paths in Options.lua after every write to a scoped
-- sub-category; SetSectionPerLayout reaches the same store through
-- InvalidateRaidProfileCache. Cheap: one slot nil per flat.
function BF:InvalidateAurasSubcatViews(subcat)
    if not (subcat and BF.AURAS_SUBCAT_SCOPES[subcat]) then return end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if not fl then return end
    local slot = "auras." .. subcat
    for _, flat in pairs(fl) do
        local cache = type(flat) == "table" and rawget(flat, "_sectionCache")
        if cache then cache[slot] = nil end
    end
end

-- Frame-scoped convenience wrapper, mirroring GetSectionProfileForFrame.
-- Resolves the flat the frame renders from, then resolves the sub-category
-- against it.
--
-- The two CFG branches must delegate to ResolveCFGAurasSubcat (AuraConfig.lua)
-- rather than calling GetAurasSubcatProfile directly, because a Custom Frame
-- Group has a SECOND override dimension: when the sub-category's per-layout
-- group is OFF but that group's per-CFG override flag is ON, the CFG reads its own
-- flat, not the global. GetAurasSubcatProfile only knows about the per-layout
-- dimension and would hand back the global. ResolveCFGAurasSubcat is a runtime
-- lookup on BF (AuraConfig.lua loads later), hence the presence check.
-- File-local rather than a closure inside GetAurasSubcatProfileForFrame: that
-- allocated a function on EVERY call, including the non-CFG paths that never
-- used it.
local function ResolveCFGSubcatOrPlain(self, subcat, flat, grp)
    if BF.ResolveCFGAurasSubcat then
        return BF.ResolveCFGAurasSubcat(self, flat, grp, subcat)
    end
    return self:GetAurasSubcatProfile(subcat, flat)
end

function BF:GetAurasSubcatProfileForFrame(subcat, frame)
    if frame then
        if frame._isPreviewFrame and frame._cfgFlat then
            return ResolveCFGSubcatOrPlain(self, subcat, frame._cfgFlat, frame._cfgGroup)
        end
        if frame._isPreviewFrame then
            local lp   = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
            local fl   = lp and lp.flatLayouts
            local flat = (frame._flatID and fl) and fl[frame._flatID] or nil
            return self:GetAurasSubcatProfile(subcat, flat)
        end
        local header = frame._bf_parentHeader
        if header == nil then
            header = frame:GetParent()
            frame._bf_parentHeader = header or false
        end
        if header and header._cfgFlat then
            return ResolveCFGSubcatOrPlain(self, subcat, header._cfgFlat, header._cfgGroup)
        end
    end
    local activeFlat = self:ResolveActiveIsRaid() and self:GetRaidProfile()
                       or self:GetActivePartyProfile()
    return self:GetAurasSubcatProfile(subcat, activeFlat)
end

-- ============================================================
-- AURA TEXT SECTION: SUB-CATEGORY MAP (v30)
-- ============================================================
-- The auraText section is nested one level deeper than the other
-- per-layout sections, mirroring the auras v27 pattern: keys are
-- grouped into sub-categories matching the Options UI subtabs
-- (Stack Text, Global Duration, Buffs, Debuffs, Big Defensive,
-- Important, Crowd Control, Private Auras).
--
-- globalAuraTextConfig is NOT listed in AURA_TEXT_SUBCATEGORY_OF
-- because it lives at the top of auraText (NOT inside any sub-
-- category). Setters that write it route directly to
-- flat.auraText.globalAuraTextConfig (or rpDB.profile.auraText.
-- globalAuraTextConfig when the per-layout toggle is OFF).
--
-- AURA_TEXT_SUBCATEGORIES: ordered list of the live sub-category names
-- (five of them since v69 -- see the list itself below; it was eight in
-- v30). Consumed by WireAuraTextSubCategoryFallbacks (iterates to
-- wire per-sub-category metatable fallbacks).
--
-- AURA_TEXT_SUBCATEGORY_OF: key -> sub-category map. Consumed by
-- the v30 migration (MigrateAuraTextToSubcats) to relocate flat-root
-- auraText keys into their sub-category, and by Options setters to
-- route writes to the correct sub-category via
-- GetOrCreateAuraTextSubCategory.
-- ============================================================
BF.AURA_TEXT_SUBCATEGORIES = {
    "stackText", "global", "buffs", "debuffs", "bigDef",
}   -- v64: "important" removed. v67: "privateAuras" removed.
    -- v69: "crowdControl" removed with the feature. As above, the entries in
    -- AURA_TEXT_SUBCATEGORY_OF stay -- migration 30 needs them to build the
    -- sub-table migration 62 reads.

BF.AURA_TEXT_SUBCATEGORY_OF = {
    -- stackText
    showStackText   = "stackText",
    stackAutoScale  = "stackText",
    stackTimerScale = "stackText",
    stackTextFont   = "stackText",
    stackTextBorder = "stackText",
    stackTextSize   = "stackText",
    stackTextAnchor = "stackText",
    stackTextX      = "stackText",
    stackTextY      = "stackText",

    -- global (unified config)
    globalDurationShow              = "global",
    globalAutoScale                 = "global",
    globalTimerScale                = "global",
    globalFontSize                  = "global",
    globalDurationFont              = "global",
    globalDurationBorder            = "global",
    globalFontColor                 = "global",
    globalColorAuraBorder           = "global",
    globalReverseSwipe              = "global",
    globalDisableSwipe              = "global",
    globalDisableSpark              = "global",
    globalDebuffDurationDispelColor = "global",
    globalHideDurationAbove1Min     = "global",
    globalThresholdColorEnabled     = "global",
    globalThresholdColorThreshold   = "global",
    globalThresholdColor            = "global",
    globalThreshold2ColorEnabled    = "global",
    globalThreshold2ColorThreshold  = "global",
    globalThreshold2Color           = "global",

    -- buffs
    showBuffDuration             = "buffs",
    buffAutoScale                = "buffs",
    buffTimerScale               = "buffs",
    buffFontSize                 = "buffs",
    buffDurationFont             = "buffs",
    buffDurationBorder           = "buffs",
    buffFontColor                = "buffs",
    buffColorAuraBorder          = "buffs",
    reverseBuffSwipe             = "buffs",
    disableBuffSwipe             = "buffs",
    disableBuffSpark             = "buffs",
    buffHideDurationAbove1Min    = "buffs",
    buffThresholdColorEnabled    = "buffs",
    buffThresholdColorThreshold  = "buffs",
    buffThresholdColor           = "buffs",
    buffThreshold2ColorEnabled   = "buffs",
    buffThreshold2ColorThreshold = "buffs",
    buffThreshold2Color          = "buffs",

    -- debuffs
    showDebuffDuration             = "debuffs",
    debuffAutoScale                = "debuffs",
    debuffTimerScale               = "debuffs",
    debuffFontSize                 = "debuffs",
    debuffDurationFont             = "debuffs",
    debuffDurationBorder           = "debuffs",
    debuffFontColor                = "debuffs",
    reverseDebuffSwipe             = "debuffs",
    disableDebuffSwipe             = "debuffs",
    disableDebuffSpark             = "debuffs",
    debuffDurationDispelColor      = "debuffs",
    debuffHideDurationAbove1Min    = "debuffs",
    debuffThresholdColorEnabled    = "debuffs",
    debuffThresholdColorThreshold  = "debuffs",
    debuffThresholdColor           = "debuffs",
    debuffThresholdBorderEnabled   = "debuffs",
    debuffThreshold2ColorEnabled   = "debuffs",
    debuffThreshold2ColorThreshold = "debuffs",
    debuffThreshold2Color          = "debuffs",
    debuffThreshold2BorderEnabled  = "debuffs",

    -- bigDef
    showBigDefDuration             = "bigDef",
    bigDefAutoScale                = "bigDef",
    bigDefTimerScale               = "bigDef",
    bigDefFontSize                 = "bigDef",
    bigDefDurationFont             = "bigDef",
    bigDefDurationBorder           = "bigDef",
    bigDefFontColor                = "bigDef",
    bigDefColorAuraBorder          = "bigDef",
    reverseBigDefSwipe             = "bigDef",
    disableBigDefSwipe             = "bigDef",
    disableBigDefSpark             = "bigDef",
    bigDefHideDurationAbove1Min    = "bigDef",
    bigDefThresholdColorEnabled    = "bigDef",
    bigDefThresholdColorThreshold  = "bigDef",
    bigDefThresholdColor           = "bigDef",
    bigDefThreshold2ColorEnabled   = "bigDef",
    bigDefThreshold2ColorThreshold = "bigDef",
    bigDefThreshold2Color          = "bigDef",

    -- v64: important keys removed with the feature.

    -- crowdControl
    showCrowdControlDuration   = "crowdControl",
    crowdControlAutoScale      = "crowdControl",
    crowdControlTimerScale     = "crowdControl",
    crowdControlFontSize       = "crowdControl",
    crowdControlDurationFont   = "crowdControl",
    crowdControlDurationBorder = "crowdControl",
    crowdControlFontColor      = "crowdControl",
    reverseCrowdControlSwipe   = "crowdControl",
    disableCrowdControlSwipe   = "crowdControl",
    disableCrowdControlSpark   = "crowdControl",
    crowdControlHideDurationAbove1Min = "crowdControl",

    -- v67: showPrivateAuraDuration / disablePrivateAuraSwipe removed with
    -- the Private Auras icon feature.
}

-- ============================================================
-- BF:GetOrCreateAuraTextSubCategory(flat, subcat) -> subTable
--
-- Lazy sub-category materialization + metatable wiring for auraText.
-- Direct mirror of BF:GetOrCreateAurasSubCategory (v27). Called from
-- Options_AuraText.lua setters to ensure writes always land on the
-- flat's own sparse storage rather than the shared global, while
-- reads for un-customized keys still fall through to the global via
-- the two-tier metatable chain (flat.auraText -> global.auraText,
-- and each flat.auraText.<subcat> -> global.auraText.<subcat>).
-- ============================================================
function BF:GetOrCreateAuraTextSubCategory(flat, subcat)
    if type(flat) ~= "table" or type(subcat) ~= "string" then return nil end
    local atP = rawget(flat, "auraText")
    if not atP then
        atP = {}
        flat.auraText = atP
        self:WireSectionFallback(flat, "auraText")
    end
    local subTable = rawget(atP, subcat)
    if not subTable then
        subTable = {}
        atP[subcat] = subTable
        local globalSub = self.rpDB and self.rpDB.profile
            and self.rpDB.profile.auraText and self.rpDB.profile.auraText[subcat]
        if type(globalSub) == "table" then
            setmetatable(subTable, { __index = globalSub })
        end
    end
    return subTable
end

-- ============================================================
-- BF:WireAuraTextSubCategoryFallbacks(auraTextTable)
--
-- Walks an auraText table (flat.auraText) and attaches the second-
-- tier metatable fallback to every existing sub-category rawkey.
-- Direct mirror of WireAurasSubCategoryFallbacks (v27). Called from
-- RehydrateFlats after the first-tier WireSectionFallback pass so
-- every flat's existing auraText sub-category tables get their
-- metatables re-wired on login, profile change, reset, and copy.
-- ============================================================
function BF:WireAuraTextSubCategoryFallbacks(auraTextTable)
    if type(auraTextTable) ~= "table" then return end
    local globals = self.rpDB and self.rpDB.profile and self.rpDB.profile.auraText
    if type(globals) ~= "table" then return end
    for _, subcat in ipairs(self.AURA_TEXT_SUBCATEGORIES or {}) do
        local subTable = rawget(auraTextTable, subcat)
        local globalSub = globals[subcat]
        if type(subTable) == "table" and type(globalSub) == "table" then
            local mt = getmetatable(subTable)
            if not mt or mt.__index ~= globalSub then
                setmetatable(subTable, { __index = globalSub })
            end
        end
    end
end

-- Seeds flat[section] for every flat that does not yet have one. Uses the
-- current global rpDB.profile[section] as the seed source (NOT factory
-- defaults) so the flat starts from whatever the user last had configured
-- globally. Idempotent: flats with an existing sub-table (e.g. from a
-- previous ON -> OFF -> ON cycle) are preserved as cache and not overwritten.
-- Every seeded (or pre-existing) sub-table is wired with the section
-- fallback metatable via WireSectionFallback.
function BF:SeedAllFlatsForSection(section)
    if not section then return end
    -- 2026-08-25: an aura SCOPE toggle (AURAS_SUBCAT_SCOPES, e.g.
    -- auras_debuffFilter) seeds ONLY its own keys into every flat's
    -- auras.<subcat> sub-table -- the per-subtab rule, so the sub-category's
    -- other keys never become live rawkeys through this toggle. Where the
    -- flat already holds the rawkey (an earlier ON -> OFF -> ON cycle, or a
    -- period with the sub-category toggle ON) it is preserved as cache,
    -- exactly like every other seed here.
    local scopeInfo = BF.AURAS_SCOPE_TOGGLE_INFO[section]
    if scopeInfo then
        local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
        local fl = lp and lp.flatLayouts
        if type(fl) ~= "table" then return end
        local gp = self.rpDB.profile.auras
        local src = gp and gp[scopeInfo.subcat]
        if type(src) ~= "table" then return end
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                local sub = self:GetOrCreateAurasSubCategory(flat, scopeInfo.subcat)
                if sub then
                    for _, k in ipairs(scopeInfo.keys) do
                        if rawget(sub, k) == nil then
                            local v = src[k]
                            if type(v) == "table" then
                                sub[k] = self:DeepCopy(v)
                            elseif v ~= nil then
                                sub[k] = v
                            end
                        end
                    end
                end
            end
        end
        self:InvalidateAurasSubcatViews(scopeInfo.subcat)
        return
    end
    -- dbVersion 65: an aura TOGGLE key (auras_<subcat>, or a transitional group
    -- seeds the shared "auras" table. Seeding the whole table -- including the
    -- other sub-categories -- is harmless because reads resolve per
    -- sub-category and ignore rawkeys belonging to a sub-category whose toggle
    -- is OFF.
    -- 2026-08-24: TOGGLE_STORAGE_SECTION generalizes the aura map to the
    -- five per-subtab sections. For those, seeding is PER-SUBTAB: only
    -- that subtab's keys are copied (where the flat lacks the rawkey), so
    -- an OFF subtab's keys never become live rawkeys on the flat.
    local storage = BF.TOGGLE_STORAGE_SECTION and BF.TOGGLE_STORAGE_SECTION[section]
    local subtabId
    if storage and BF.SECTION_SUBTAB_TOGGLE[storage] then
        subtabId = section:sub(#storage + 2)   -- "<section>_<subtabId>"
        section = storage
    elseif storage then
        section = storage
    else
        section = (BF.AURAS_GROUP_STORAGE_SECTION
            and BF.AURAS_GROUP_STORAGE_SECTION[section]) or section
    end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    local fl = lp and lp.flatLayouts
    if type(fl) ~= "table" then return end
    local src = self.rpDB.profile[section]
    if type(src) ~= "table" then return end
    if subtabId then
        local keys = BF.SECTION_SUBTAB_KEYS[section]
            and BF.SECTION_SUBTAB_KEYS[section][subtabId]
        if type(keys) ~= "table" then return end
        for _, flat in pairs(fl) do
            if type(flat) == "table" then
                local tbl = rawget(flat, section)
                if type(tbl) ~= "table" then
                    tbl = {}
                    flat[section] = tbl
                end
                for _, k in ipairs(keys) do
                    if rawget(tbl, k) == nil then
                        local v = src[k]
                        if type(v) == "table" then
                            tbl[k] = self:DeepCopy(v)
                        elseif v ~= nil then
                            tbl[k] = v
                        end
                    end
                end
                self:WireSectionFallback(flat, section)
            end
        end
        return
    end
    for _, flat in pairs(fl) do
        if type(flat) == "table" then
            if flat[section] == nil then
                flat[section] = self:DeepCopy(src)
                -- Cast bars: RAID-typed flats always seed with the feature
                -- OFF regardless of the global value (owner rule 2026-08-13:
                -- cast bars are opt-in per raid layout — a global ON must not
                -- fan out to every raid layout at seed time). Party flats
                -- seed faithfully. Fresh-seed only: an existing sub-table
                -- (ON→OFF→ON toggle cache) is never touched.
                if section == "castBar" and flat.type == "raid" then
                    flat[section].enabled = false
                end
            end
            self:WireSectionFallback(flat, section)
            -- v60: a DeepCopy'd auras table arrives with no second-tier
            -- metatables on its sub-categories, so keys added to the
            -- defaults later would read nil until the next login re-ran
            -- RehydrateFlats. Wire them now instead.
            if section == "auras" then
                self:WireAurasSubCategoryFallbacks(rawget(flat, "auras"))
            end
        end
    end
end

-- Sets the per-layout toggle for a section and performs the associated
-- side effects. Turning a toggle ON eagerly seeds any flat that does not
-- yet have a sub-table (see SeedAllFlatsForSection). Turning it OFF
-- preserves the per-flat sub-tables as cache so toggling ON again later
-- restores the same per-flat values the user had before.
function BF:SetSectionPerLayout(section, enabled)
    if not section then return end
    local lp = self.rpDB and self.rpDB.profile and self.rpDB.profile.layouts
    if not lp then return end
    lp.perLayoutToggles = lp.perLayoutToggles or {}
    local newVal = enabled and true or false

    -- Nothing to do when the key already holds newVal. Checked before the
    -- write so the (expensive) refresh tail below still runs exactly once per
    -- real change.
    if lp.perLayoutToggles[section] == newVal then return end

    -- Per-step timing, printed only when db.global.debugTiming is on.
    -- `step()` is a no-op call otherwise.
    local dbg = self.db and self.db.global and self.db.global.debugTiming
    local mark = dbg and debugprofilestop() or 0
    local function step(label)
        if not dbg then return end
        local now = debugprofilestop()
        print(("|cff11ace9BF|r   %-22s %7.1f ms"):format(label, now - mark))
        mark = now
    end
    -- §T5.3 #1/#3: per-flip counters, reset here so every number printed
    -- from the panel-rebuild wrapper and from UpdateAuraSizeCache is scoped
    -- to THIS click. `_flipFrame` is the click frame's GetTime(); the
    -- rebuild wrapper prints its own stamp, and a differing stamp is the
    -- proof that the second rebuild landed on the NEXT frame (T1.4b).
    if dbg then
        self._acdOpenCount  = 0
        self._uascFlipCount = 0
        self._flipFrame     = GetTime()
        print(("|cff11ace9BF|r %s SetSectionPerLayout(%s -> %s)  frame=%.3f")
            :format("[flip]", tostring(section), tostring(newVal), self._flipFrame))
    end

    lp.perLayoutToggles[section] = newVal
    if newVal then self:SeedAllFlatsForSection(section) end
    step("SeedAllFlats")
    -- Drop caches so the next read resolves via the new routing.
    if self.InvalidateRaidProfileCache then self:InvalidateRaidProfileCache() end
    step("InvalidateRPCache")
    -- Every flat's source for this section just flipped (flat-scoped <-> global),
    -- so every flat's _auraCache may be stale. The conservative answer is to
    -- invalidate them all; UpdateAuraSizeCache rebuilds the dirty set lazily.
    if self.InvalidateAllFlatAuraCaches then self:InvalidateAllFlatAuraCaches() end
    step("InvalidateAuraCaches")
    -- Refresh chrome "Modifying Layout" dropdown visibility if the options
    -- panel is currently open.
    self:RefreshPanelChrome("layoutDropdown")
    step("LayoutDDVisibility")
    -- Push a live refresh of the raid/party frames.
    if self.RefreshAll then self:RefreshAll() end
    step("RefreshAll")
    -- Toggling per-layout changes which sorting profile setup mode reads,
    -- so refresh setup frames to pick up the new routing.
    if self.UpdateSetupFrames then self:UpdateSetupFrames() end
    step("UpdateSetupFrames")
    -- NO NotifyChange here.
    --
    -- AceConfigDialog's ActivateControl already performs a synchronous,
    -- full AceConfigDialog:Open for a `toggle` the moment set() returns --
    -- the unconditional `else` branch at
    -- Libs/AceConfig-3.0/AceConfigDialog-3.0/AceConfigDialog-3.0.lua:866-870.
    -- That rebuild re-evaluates every hidden/disabled predicate, which is
    -- the only thing this call was here for.
    --
    -- Adding an explicit NotifyChange on top scheduled a SECOND full
    -- rebuild, and each rebuild is expensive well beyond the tree walk:
    -- BF wraps ACD.Open so SetupOptionsPanel -> RefreshPreviewFrames runs
    -- after every one, and that sweeps EVERY flat layout's preview frames
    -- (Preview/PreviewSystem.lua) regardless of how many real unit
    -- frames exist -- which is why the stall reproduced while solo.
end

-- ============================================================
-- Optional timing for the per-layout toggle.
--
-- Enable with:  /run BuzzardFrames.db.global.debugTiming = true
-- Disable with: /run BuzzardFrames.db.global.debugTiming = false
--
-- Prints the cost of each step of SetSectionPerLayout. Note the two
-- deferred tails (ApplyProfile's C_Timer.After(0) and LoadLayout's) are
-- NOT captured here -- if the printed total is small but the game still
-- hitches, the cost is in those tails or in the panel rebuild that
-- happens after this function returns.
-- ============================================================
function BF:_TimeSectionPerLayout(section, enabled)
    local g = self.db and self.db.global
    if not (g and g.debugTiming) then
        return self:SetSectionPerLayout(section, enabled)
    end
    local t0 = debugprofilestop()
    self:SetSectionPerLayout(section, enabled)
    print(("|cff11ace9BF|r SetSectionPerLayout(%s) = %.1f ms")
        :format(tostring(section), debugprofilestop() - t0))
end

-- Phase 2 stub: the flat model no longer tracks "setup-mode active"
-- layout/tab state (the _setupModeActive* fields are dead under the
-- new accessors). Kept as a no-op so existing callers don't error.
-- Callers will be removed in phase 3.
function BF:EnsureSetupModeSnapshot()
end

-- Announce when the effective raid settings tier changes

-- Returns true whenever the party anchor position (not a raid tier position)
-- should be used for the main anchor frame.  This covers:
--   • open-world solo resolving to the party flat (openWorldPartyOverride)
--   • actual party group (IsInGroup and not IsInRaid)
--   • party test mode (partyTestMode flag)
-- ShouldUsePartyAnchor: shim. Real logic in BF:ResolveContext() (ApplyProfile.lua).
function BF:ShouldUsePartyAnchor()
    if self._contextIsRaid == nil then self:ResolveContext() end
    return self._contextIsParty
end

function BF:AnnounceRaidSizeChange()
    if not IsInRaid() then
        self.lastAnnouncedTier = nil
        return
    end

    local lp = self.rpDB.profile.layouts
    -- Don't announce while setup mode is active
    if BF.db.global.setupModeActive then
        return
    end
    if not lp.showLayoutAnnounce then return end

    -- Suppress if a zone-change announce just fired (or is about to fire);
    -- AnnounceInstanceContext already prints a more detailed line.
    if self._lastAnnouncedZone and (GetTime() - self._lastAnnouncedZone) < 3 then
        return
    end

    -- Resolve the actual flat that will render for the current slot,
    -- mirroring the render path (ResolveActiveFlat(GetActiveSlot())).
    -- Pre-Phase-2 this used GetCapacityTier + ResolveTier to build a
    -- synthetic label (e.g. "40 man settings"), which doesn't match the
    -- Layouts by Instance Type model — the user's resolved flat for a
    -- raid slot may have any user-editable name. Cache invalidation is
    -- required before ResolveActiveFlat because we may have been called
    -- from a GROUP_ROSTER_UPDATE that flipped the slot.
    self:InvalidateRaidProfileCache()
    local slot   = self:GetActiveSlot()
    local flatID = self:ResolveActiveFlat(slot)
    local flat   = self:GetRaidProfile()
    local flatLabel = (flat and flat.name) or "Raid"

    -- Dedup key: the resolved flat ID (falling back to the label when no
    -- ID is available, e.g. solo-"none" override). Using the flat identity
    -- rather than a tier code means we re-announce whenever the slot
    -- resolution picks a different flat — including role/spec override
    -- flips — and stay quiet when only the group size changed within the
    -- same flat.
    local dedupKey = flatID or flatLabel
    if not self.lastAnnouncedTier then
        self.lastAnnouncedTier = dedupKey
        return
    end
    if dedupKey == self.lastAnnouncedTier then return end
    self.lastAnnouncedTier = dedupKey

    local groupSize = GetNumGroupMembers()
    print(string.format("|cffd3ff7dBuzzardFrames:|r Entered %d man raid, applied %s layout", groupSize, flatLabel))
end

-- Announce current instance context and active layout whenever we zone.
-- Prints a single line showing: instance type, group type, and which BF layout is active.
-- Only prints if the layout or group type has actually changed since the last announcement.
function BF:AnnounceInstanceContext()
    local instanceName, instanceType, _, _, maxPlayers = GetInstanceInfo()
    self:InvalidateRaidProfileCache()

    -- Friendly instance type label
    local instanceLabel
    if instanceType == "none" then
        instanceLabel = "Open World"
    elseif instanceType == "party" then
        instanceLabel = "Dungeon"
    elseif instanceType == "raid" then
        instanceLabel = string.format("Raid (%d man)", maxPlayers or 0)
    elseif instanceType == "scenario" then
        instanceLabel = "Scenario / Delve / Torghast"
    elseif instanceType == "pvp" then
        instanceLabel = "Battleground"
    elseif instanceType == "arena" then
        instanceLabel = "Arena"
    elseif instanceType == "neighborhood" then
        instanceLabel = "Neighborhood"
    else
        instanceLabel = instanceType
    end

    -- Actual WoW group type
    local groupType
    if instanceType == "pvp" and maxPlayers and maxPlayers > 0 then
        -- For battlegrounds use the true BG capacity from GetInstanceInfo,
        -- not GetNumGroupMembers() which only reflects current fill.
        groupType = string.format("Raid (%d Man BG)", maxPlayers)
    elseif IsInRaid() then
        groupType = string.format("Raid (%d members)", GetNumGroupMembers())
    elseif IsInGroup() then
        groupType = string.format("Party (%d members)", GetNumGroupMembers())
    else
        groupType = "Solo"
    end

    -- Which BF layout is active. Setup mode does NOT influence this label
    -- under the new model — the announce reflects live context only.
    --
    -- Read the name off the actually-resolved flat. GetCapacityTier /
    -- ResolveTier are pre-Phase-2 tier logic and don't know about the
    -- Layouts by Instance Type model; using them here would print a
    -- synthetic "Raid 40 Man" string that doesn't correspond to any of
    -- the user's flat names. The render path picks the flat via
    -- ResolveActiveFlat(GetActiveSlot()) — mirror that here so the
    -- announce label is always the flat's real, user-editable name.
    -- ShouldUsePartyAnchor covers both actual party groups and the
    -- openWorldPartyOverride case (set as a side effect of GetRaidProfile
    -- when the resolved flat is party-typed), so the two prior branches
    -- collapse into a single party check.
    local layoutLabel
    if self:ShouldUsePartyAnchor() then
        local flat = self:GetActivePartyProfile()
        layoutLabel = (flat and flat.name) or "Party"
    else
        local flat = self:GetRaidProfile()
        layoutLabel = (flat and flat.name) or "Raid"
    end

    -- Only print if the layout or group type has actually changed
    if layoutLabel == self._lastAnnouncedLayout and groupType == self._lastAnnouncedGroupType then
        return
    end
    self._lastAnnouncedLayout = layoutLabel
    self._lastAnnouncedGroupType = groupType

    if not self.rpDB.profile.layouts.showLayoutAnnounce then return end

    local zoneName = instanceName ~= "" and instanceName or GetZoneText() or "Unknown"
    print(string.format(
        "|cffd3ff7dBuzzardFrames:|r [%s] Instance: %s  |  Group: %s  |  Layout: %s",
        zoneName, instanceLabel, groupType, layoutLabel))
end

-- ============================================================
-- MODULE-LOCAL STATE
-- Tables and flags populated by later-loaded files (UnitFrames,
-- BFLayout, SetupMode, etc.) but declared here so they exist from
-- addon load and can be read safely from any code path.
-- ============================================================
BF.classColors = {}
-- Default class colors (never modified at runtime -- used as pristine
-- baseline by ApplyCustomClassColors). Seeded from RAID_CLASS_COLORS in
-- OnEnable once Blizzard globals are available.
BF._DefaultClassColors = {}
BF.unitFrames  = {}
BF.activeFrames = {}

BF.anchorFrame = nil
BF.testAnchorFrame = nil

-- ============================================================
-- SHARED POWER TYPE COLORS (Grid2 pattern)
-- Keyed by the string token returned by select(2, UnitPowerType(unit)).
-- Used by both raid/party power bars (BFStatus Power:GetColor) and
-- oUF unit frame power bars (_GetOUFPowerColor).
-- Colors match Grid2's StatusMana.lua defaults.
-- ============================================================
BF.PowerTypeColors = {
    MANA         = { r = 0.00, g = 0.44, b = 1.00 },
    RAGE         = { r = 1.00, g = 0.00, b = 0.00 },
    FOCUS        = { r = 1.00, g = 0.64, b = 0.07 },
    ENERGY       = { r = 0.79, g = 0.67, b = 0.20 },
    COMBO_POINTS = { r = 1.00, g = 0.91, b = 0.27 },
    RUNES        = { r = 0.77, g = 0.12, b = 0.23 },
    RUNIC_POWER  = { r = 0.00, g = 0.82, b = 1.00 },
    SOUL_SHARDS  = { r = 0.58, g = 0.51, b = 0.79 },
    LUNAR_POWER  = { r = 0.32, g = 0.22, b = 0.95 },  -- Astral Power
    HOLY_POWER   = { r = 0.95, g = 0.87, b = 0.35 },
    MAELSTROM    = { r = 0.00, g = 0.50, b = 1.00 },
    INSANITY     = { r = 0.40, g = 0.00, b = 0.80 },
    FURY         = { r = 0.78, g = 0.25, b = 0.14 },
    PAIN         = { r = 0.73, g = 0.46, b = 0.82 },
    ESSENCE      = { r = 0.40, g = 0.80, b = 0.60 },
    -- Non-standard tokens returned by UnitPowerType() for friendly NPCs
    -- in follower dungeons and proving grounds (Grid2 StatusMana.lua pattern)
    POWER_TYPE_FOCUS     = { r = 1.00, g = 0.64, b = 0.07 },  -- same as FOCUS
    POWER_TYPE_RED_POWER = { r = 1.00, g = 0.00, b = 0.00 },  -- same as RAGE
    POWER_TYPE_ENERGY    = { r = 0.79, g = 0.67, b = 0.20 },  -- same as ENERGY
}
-- Default colors (never modified — used as fallback by ApplyCustomPowerColors)
BF._DefaultPowerTypeColors = {}
for k, v in pairs(BF.PowerTypeColors) do
    BF._DefaultPowerTypeColors[k] = { r = v.r, g = v.g, b = v.b, a = v.a }
end

-- Apply saved custom power colors from the profile onto the shared table.
-- Called on login, profile change, and when the user edits a color.
-- Also hooked into RefreshProfileCache so profile switches pick up colors.
function BF:ApplyCustomPowerColors()
    -- Reset to defaults first
    for k, v in pairs(self._DefaultPowerTypeColors) do
        self.PowerTypeColors[k] = { r = v.r, g = v.g, b = v.b, a = v.a }
    end
    -- Overlay custom colors if enabled
    local hp = self.rpDB and self.rpDB.profile and self.rpDB.profile.healthPower
    if hp and hp.useCustomPowerColors and hp.customPowerColors then
        for token, c in pairs(hp.customPowerColors) do
            if self.PowerTypeColors[token] then
                self.PowerTypeColors[token] = { r = c.r, g = c.g, b = c.b, a = c.a }
            end
            -- Also update the POWER_TYPE_* variant that some NPCs/bosses return
            local altToken = "POWER_TYPE_" .. token
            if self.PowerTypeColors[altToken] then
                self.PowerTypeColors[altToken] = { r = c.r, g = c.g, b = c.b, a = c.a }
            end
        end
    end
end

-- Lookup helper: returns r, g, b, a for a unit's current power type.
function BF:GetPowerColor(unit)
    local _, token = UnitPowerType(unit)
    local c = token and self.PowerTypeColors[token] or self.PowerTypeColors.MANA
    return c.r, c.g, c.b, c.a or 1
end

-- ============================================================
-- SHARED CLASS COLORS (Grid2 pattern, mirrors ApplyCustomPowerColors)
-- BF.classColors is read by:
--   * oUF_Shared.lua _GetOUFHealthColor / _GetOUFNameColor (unit frames)
--   * BFStatus.lua Name:GetClassColor, Death:GetColor, Flags:GetColor
--   * BFStatus.lua Health:GetColor  -- only when useCustomClassColors
--     is ON; otherwise Health:GetColor reads CUSTOM_CLASS_COLORS or
--     RAID_CLASS_COLORS directly, preserving current behavior and
--     external class-color-addon compatibility.
--
-- useCustomClassColors OFF: BF.classColors is a straight copy of
--   RAID_CLASS_COLORS (same as the original OnEnable behavior).
-- useCustomClassColors ON:  BF.classColors = RAID_CLASS_COLORS overlaid
--   with rpDB.profile.colors.customClassColors[className].
--
-- Called from OnEnable, from the Options_Colors.lua setters, and from
-- the RefreshProfileCache hook (LayoutFrame.lua) so profile switches
-- re-apply.
-- ============================================================
function BF:ApplyCustomClassColors()
    -- Reset to defaults first. _DefaultClassColors is seeded once in
    -- OnEnable from RAID_CLASS_COLORS and never mutated; mutating
    -- RAID_CLASS_COLORS directly would leak our overrides into every
    -- other addon that reads it.
    for k, v in pairs(self._DefaultClassColors) do
        self.classColors[k] = { r = v.r, g = v.g, b = v.b }
    end
    -- Overlay custom colors if enabled
    local cp = self.rpDB and self.rpDB.profile and self.rpDB.profile.colors
    if cp and cp.useCustomClassColors and cp.customClassColors then
        for className, c in pairs(cp.customClassColors) do
            if self.classColors[className] then
                self.classColors[className] = { r = c.r, g = c.g, b = c.b }
            end
        end
    end
    -- IncomingCasts caches the player's class color for its target-name
    -- text (static per session, so it is resolved once). Nothing else
    -- invalidates that cache, so a class-color edit would otherwise leave
    -- the name on the old color until a reload. Cache-drop only -- this
    -- function also runs from the RefreshProfileCache hook, and IC:Refresh
    -- would tear down every live cast on each context change.
    if self.IncomingCasts and self.IncomingCasts.InvalidatePlayerIdentity then
        self.IncomingCasts:InvalidatePlayerIdentity()
    end
end


-- Perf plan §L5.1 load-time mark: 96 KB (.toc 56).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:coreProfileAPI") end
