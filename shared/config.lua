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
}

-- Groups map to ACE principals: group.<name>. Each inherits from the next one down.
Config.DefaultGroup = 'user'
Config.Groups = { 'user', 'mod', 'admin' } -- lowest -> highest

Config.DefaultModel = {
    m = 'mp_m_freemode_01',
    f = 'mp_f_freemode_01',
}

Config.DefaultSpawn = vec4(-269.4, -955.3, 31.2, 205.0)

-- Camera shown behind the character selection menu
Config.SelectionScene = {
    coords = vec3(-150.0, -1010.0, 120.0),
    rot = vec3(-15.0, 0.0, 330.0),
    fov = 60.0,
}

Config.SaveInterval = 5 * 60 * 1000      -- ms
Config.PaycheckInterval = 15 * 60 * 1000 -- ms
