-- ============================================================
-- BuzzardFrames: Core_Notifications.lua
-- One-time, account-wide notifications with consistent styling.
--
-- Register a notification once, at file load; the system decides whether the
-- user should ever see it and shows it on the first eligible PLAYER_LOGIN.
--
--   BF:RegisterNotification({
--       key       = "welcome_121",       -- REQUIRED, stable, never reused
--       heading   = "Welcome to Patch 12.1!",
--       body      = "...",
--       condition = function() ... end,  -- optional; retried each login
--       accept    = { text = "Open Options", func = function() ... end },
--   })
--
-- THREE RULES the system enforces, so callers never have to:
--
-- 1. ONCE PER ACCOUNT, not per profile. The seen set lives in db.global, so
--    switching or creating a profile does not replay old notices.
-- 2. NEVER FOR NEW USERS. A brand-new install has every notification marked
--    seen without showing any of it -- a first-time user does not want "what
--    changed since a version you never ran". Detection is BF._freshInstall,
--    captured in Core_DB:RegisterDB from whether the SavedVariables table
--    existed BEFORE AceDB created it, which is the only unambiguous signal:
--    OnNewProfile also fires when an EXISTING user adds a profile.
-- 3. CONDITIONS ARE RETRIED, not evaluated once. A notification whose
--    condition is false is left unseen, so it can fire on a later login when
--    the condition becomes true (e.g. the user upgrades their client). It is
--    only suppressed permanently by rule 2 or by actually being shown.
--
-- Notifications queue: if two ever come due at once they show in registration
-- order, one after the other, rather than stacking popups on top of each other.
-- ============================================================
local BF = _G["BuzzardFrames"]

-- Brand colors, shared so future notices match without restating them.
-- BRAND is the Buzzard Frames blue used for the addon's own name and for
-- anything the user types or clicks -- the same literal as the minimap and
-- compartment tooltips (Core_UI.lua) and the options panel chrome. Use it
-- for the title and for slash commands.
local BRAND_COLOR   = "11ace9"
local HEADING_COLOR = "ffd100"   -- Blizzard's standard highlight yellow

local registry = {}

-- ============================================================
-- THE SHARED POPUP
-- One StaticPopupDialogs entry for every notification, so styling is defined
-- in exactly one place. The per-notification parts arrive through `data`.
-- ============================================================
StaticPopupDialogs["BUZZARDFRAMES_NOTIFICATION"] = {
    text         = "%s",
    button1      = "OK",
    -- button2 is set per notification in _ShowNextNotification and cleared
    -- again when a notice has no action. Deliberately NOT declared statically
    -- and hidden in OnShow: StaticPopup lays its buttons out from the template
    -- at show time, so a declared-then-hidden button2 leaves button1 sitting
    -- off-center with a gap beside it.
    button2      = nil,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    OnCancel = function(self, data, reason)
        -- StaticPopup routes BOTH the button2 click and dismissal (Escape,
        -- hide-all) through OnCancel. Only a real click should run the action,
        -- or pressing Escape would silently open the options panel.
        if reason and reason ~= "clicked" then return end
        local d = data or (self and self.data)
        if d and d.acceptFunc then d.acceptFunc() end
    end,
    OnHide = function()
        -- Deferred: StaticPopup is mid-teardown, and showing the next dialog
        -- synchronously from inside OnHide can reuse the frame being released.
        C_Timer.After(0, function()
            if BF._ShowNextNotification then BF:_ShowNextNotification() end
        end)
    end,
}

-- ============================================================
-- REGISTRATION
-- ============================================================
-- `key` must be stable forever: it is what "already seen" is recorded under.
-- Renaming one re-shows the notice to everyone; reusing an old key hides a new
-- notice from everyone who saw the old one.
function BF:RegisterNotification(def)
    if type(def) ~= "table" or type(def.key) ~= "string" then return end
    for i = 1, #registry do
        if registry[i].key == def.key then return end   -- idempotent
    end
    registry[#registry + 1] = def
end

-- ============================================================
-- SEEN SET
-- ============================================================
-- Deliberately NOT declared in Defaults.lua. AceDB serves default sub-tables
-- through a metatable, and writing into one before it has been materialised
-- can land in the shared defaults table rather than the profile. Creating it
-- on demand here sidesteps that entirely.
local function seenSet()
    local g = BF.db and BF.db.global
    if not g then return nil end
    if type(g.notificationsSeen) ~= "table" then g.notificationsSeen = {} end
    return g.notificationsSeen
end

function BF:HasSeenNotification(key)
    local seen = seenSet()
    return (seen and seen[key]) and true or false
end

function BF:MarkNotificationSeen(key)
    local seen = seenSet()
    if seen then seen[key] = true end
end

-- ============================================================
-- DISPLAY
-- ============================================================
local queue, queueIndex = {}, 0

local function compose(def)
    local title = ("|cff%s%s|r"):format(BRAND_COLOR, def.title or "Buzzard Frames")
    local out = title
    if def.heading then
        out = out .. "\n\n" .. ("|cff%s%s|r"):format(HEADING_COLOR, def.heading)
    end
    if def.body then
        out = out .. "\n\n" .. def.body
    end
    -- The popup's `text` is a format string, so a literal % in any notification
    -- body would be consumed as a format spec (or error). Escape it.
    return (out:gsub("%%", "%%%%"))
end

function BF:_ShowNextNotification()
    queueIndex = queueIndex + 1
    local def = queue[queueIndex]
    if not def then
        queue, queueIndex = {}, 0
        return
    end
    -- Marked seen at SHOW time, not on dismissal: a user who reloads or
    -- disconnects with the popup open has still been told, and re-showing it
    -- every login until they click OK would be worse than missing it once.
    self:MarkNotificationSeen(def.key)

    -- Set the action button on the shared template before showing. Mutating it
    -- per show is safe because notifications are strictly sequential (one is
    -- shown, the next only after OnHide), and it must be cleared again or a
    -- later notice with no action inherits this one's button.
    local tmpl = StaticPopupDialogs["BUZZARDFRAMES_NOTIFICATION"]
    tmpl.button2 = def.accept and def.accept.text or nil

    StaticPopup_Show("BUZZARDFRAMES_NOTIFICATION", compose(def), nil, {
        acceptFunc = def.accept and def.accept.func,
    })
end

-- Force-show one registered notification NOW, ignoring all three rules: the
-- seen set, the fresh-install suppression and the condition. For a "show me
-- that again" button, and for testing a notice without wiping SavedVariables.
--
-- Ignoring `condition` is deliberate: someone on 12.0.7 clicking "Show Welcome
-- Message" wants to see the message, not nothing. Returns false if `key` is not
-- registered, so a caller can tell "no such notice" from "shown".
function BF:ShowNotificationNow(key)
    for i = 1, #registry do
        if registry[i].key == key then
            -- Replaces any queue in flight. Only reachable from a button click,
            -- and a login queue has long since drained by then.
            queue, queueIndex = { registry[i] }, 0
            self:_ShowNextNotification()
            return true
        end
    end
    return false
end

-- Called once, from BF:PLAYER_LOGIN (Core_DB.lua).
function BF:ShowPendingNotifications()
    local seen = seenSet()
    if not seen then return end

    -- Rule 2: a brand-new install is caught up on everything, silently. Note
    -- this ignores `condition` on purpose -- a new user who installs on 12.0.7
    -- should not be told "welcome to 12.1" when they later upgrade either.
    if self._freshInstall then
        for i = 1, #registry do seen[registry[i].key] = true end
        return
    end

    queue, queueIndex = {}, 0
    for i = 1, #registry do
        local def = registry[i]
        if not seen[def.key] then
            local ok = true
            if def.condition then
                local success, result = pcall(def.condition)
                -- A condition that errors must not silently mark the notice
                -- seen or spam it every login; treat it as "not yet".
                ok = success and result and true or false
            end
            if ok then queue[#queue + 1] = def end
        end
    end
    if #queue > 0 then
        queueIndex = 0
        self:_ShowNextNotification()
    end
end

-- ============================================================
-- REGISTERED NOTIFICATIONS
-- ============================================================

-- 12.1 aura rework.
-- v67: 12.0.7 branch removed (addon is 12.1-only) -- this used to carry a
-- `condition` returning the engine feature-detect so a 12.0.7 user got the
-- notice on their first 12.1 login instead. With no 12.0.7 client left the
-- condition is always true, so it is gone and the notice shows unconditionally
-- (still once, via the seen set, and never on a fresh install).
-- Exported so the options button that replays it does not hardcode the string;
-- the key is storage (the seen flag) and must never drift from this literal.
BF.NOTIFICATION_WELCOME_121 = "welcome_121_auras"

BF:RegisterNotification({
    key     = BF.NOTIFICATION_WELCOME_121,
    title   = "Buzzard Frames",
    heading = "Welcome to Patch 12.1!",
    body    = "Blizzard have made major changes to Aura handling in the new patch - please review the new Buffs and Debuffs options.\n\n"
           .. "|cff" .. BRAND_COLOR .. "/bf|r or |cff" .. BRAND_COLOR .. "/buzzardframes|r to open the options panel.",
    accept  = {
        text = "Open Options",
        func = function()
            if not BF.OpenOptions then return end
            BF:OpenOptions()
            -- Land on Raid/Party Frames -> Buffs, which is what the notice is
            -- telling them to review.
            --
            -- DEFERRED, and it has to be: ACD:SelectGroup only writes the
            -- status table and fires NotifyChange -- the selection is APPLIED
            -- by the next feed. Called inline it would run against the panel
            -- OpenOptions is still building, and GroupExists would drop the
            -- path. One frame later the tree exists and the select sticks.
            C_Timer.After(0, function()
                BF:OpenPanelAt("raidPartyFrames", "aurasBuffs")
            end)
        end,
    },
})

-- Perf plan §L5.1 load-time mark: closes the core block (.toc 55-69).
if BuzzardFrames then BuzzardFrames:LoadMark("chunk:postCore") end
