Config = {}

Config.MaxCharacters = 3
Config.MinAge = 18

-- Valid accounts and the balance a new character starts with
Config.StartingAccounts = {
    cash = 500,
    bank = 5000,
}

Config.DefaultMetadata = {
    hunger = 100,
    thirst = 100,
    stress = 0,
}

-- Groups map to ACE principals: group.<name>. Each inherits from the next one down.
Config.DefaultGroup = 'user'
Config.Groups = { 'user', 'mod', 'admin' } -- lowest -> highest

Config.DefaultModel = {
    m = 'mp_m_freemode_01',
    f = 'mp_f_freemode_01',
}

Config.DefaultSpawn = vec4(-269.4, -955.3, 31.2, 205.0)

-- Notifications (ox_lib). position: top, top-right, top-left, bottom, bottom-right,
-- bottom-left, center-right, center-left. Top-right is where rps_hud shows money.
Config.Notify = {
    position = 'top',
    duration = 5000, -- ms
}

Config.SaveInterval = 5 * 60 * 1000      -- ms
Config.PaycheckInterval = 15 * 60 * 1000 -- ms

-- Player commands
Config.Commands = {
    meDistance = 20.0,      -- /me and /do are shown to players this close
    meDuration = 7,         -- seconds the text floats above the player
    giveCashDistance = 5.0, -- /givecash range
    reportCooldown = 60,    -- seconds between /report uses
}

-- Hunger and thirst (0-100, saved in metadata as `hunger` / `thirst`)
Config.Needs = {
    enabled = true,
    interval = 60,       -- seconds between decay ticks
    hungerRate = 1.0,    -- lost per tick (1.0/min = empty after 100 minutes)
    thirstRate = 1.5,
    damage = 5,          -- health lost every damageInterval while either is at 0
    damageInterval = 10, -- seconds

    -- Fixed amounts per item, used instead of the item's ox_inventory `status`.
    -- Items not listed restore what their `client.status` says (1000000 = 100).
    items = {
        -- burger = { hunger = 25 },
        -- water = { thirst = 30 },
    },
}

-- Stress (0-100, saved in metadata as `stress`)
Config.Stress = {
    enabled = true,

    -- gained while shooting (per second of firing) and while speeding (per 10 s)
    shootingGain = 2,
    speedingGain = 3,
    speedingThreshold = 100,      -- mph, for drivers only
    ignoreWeapons = {             -- these never add stress
        `WEAPON_STUNGUN`, `WEAPON_PETROLCAN`, `WEAPON_FIREEXTINGUISHER`, `WEAPON_HAZARDCAN`,
    },
    ignoreJobs = {                -- on-duty players in these jobs don't gain stress
        police = true,
        ambulance = true,
    },

    -- relief
    decay = 1,                    -- lost every decayInterval seconds
    decayInterval = 30,
    items = {                     -- ox_inventory items that relieve stress when used
        -- joint = 15,
    },

    -- effects: from effectsAt the camera shakes now and then, more often as stress rises;
    -- from blurAt the screen also blurs briefly
    effectsAt = 50,
    blurAt = 85,

    -- largest single change accepted from a client event (other scripts' gain/relieve calls)
    maxClientChange = 10,
}
