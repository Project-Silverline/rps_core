-- QBCore bridge: shared helpers, loaded with require 'bridge.qb.shared' by the
-- qb server and client files (it defines no globals and runs nothing itself).
-- RPS has no gangs, so every player is in gang 'none'.

local M = {}

M.version = '1.3.0'

M.settings = {
    nationality = 'USA',
    phonePrefix = '555',
    -- QB job types (PlayerData.job.type). A job's own `type` field wins, then this map.
    jobTypes = { police = 'leo', ambulance = 'ems' },
    -- licences a character has unless rps metadata says otherwise
    defaultLicences = { driver = true, business = false, weapon = false },
    -- QB permission levels -> rps groups (QB 'god' has no rps equivalent)
    permissionGroups = { god = 'admin', admin = 'admin', mod = 'mod' },
}

M.bloodtypes = { 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-' }

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = deepCopy(v) end
    return copy
end

M.deepCopy = deepCopy

function M.isCallable(value)
    if type(value) == 'function' then return true end
    if type(value) == 'table' then
        if type(rawget(value, '__cfx_functionReference')) == 'string' then return true end
        local mt = getmetatable(value)
        return mt ~= nil and mt.__call ~= nil
    end
    return false
end

---------------------------------------------------------------------------
-- QBCore.Config
---------------------------------------------------------------------------
function M.buildConfig()
    local spawn = Config.DefaultSpawn
    return {
        MaxPlayers = GetConvarInt('sv_maxclients', 48),
        DefaultSpawn = vector4(spawn.x, spawn.y, spawn.z, spawn.w),
        UpdateInterval = 5,
        StatusInterval = 5000,
        Money = {
            MoneyTypes = { cash = Config.StartingAccounts.cash or 0, bank = Config.StartingAccounts.bank or 0 },
            DontAllowMinus = { 'cash', 'bank' },
            MinusLimit = 0,
            PayCheckTimeOut = math.floor(Config.PaycheckInterval / 60000),
            PayCheckSociety = false,
        },
        Player = { HungerRate = 4.2, ThirstRate = 3.8, Bloodtypes = M.bloodtypes },
        Server = {
            Closed = false,
            ClosedReason = 'Server Closed',
            Uptime = 0,
            Whitelist = false,
            WhitelistPermission = 'admin',
            PVP = true,
            Discord = '',
            CheckDuplicateLicense = true,
            Permissions = { 'god', 'admin', 'mod' },
        },
        Commands = { OOCColor = { 255, 151, 133 } },
        Notify = {
            NotificationStyling = { group = false, position = 'right', progress = true },
            VariantDefinitions = {},
        },
    }
end

---------------------------------------------------------------------------
-- QBCore.Shared
---------------------------------------------------------------------------
local LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'

-- arm drawables that count as bare hands (IsWearingGloves)
local function toSet(list)
    local set = {}
    for _, v in ipairs(list) do set[v] = true end
    return set
end

function M.buildShared()
    local Shared = {
        Jobs = {},
        Gangs = { none = { label = 'No Gang', grades = { ['0'] = { name = 'Unaffiliated' } } } },
        Items = {},
        Vehicles = {},
        VehicleHashes = {},
        Weapons = {},
        Locations = {},
        StarterItems = {},
        ForceJobDefaultDutyAtLogin = true,
        MaleNoGloves = toSet({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 18, 26, 52, 53, 54, 55, 56, 57,
            58, 59, 60, 61, 62, 112, 113, 114, 118, 125, 132 }),
        FemaleNoGloves = toSet({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 19, 59, 60, 61, 62, 63, 64, 65,
            66, 67, 68, 69, 70, 71, 129, 130, 131, 135, 142, 149, 153, 157, 161, 165 }),
    }

    function Shared.RandomStr(length)
        local out = {}
        for i = 1, length or 0 do
            local n = math.random(1, #LETTERS)
            out[i] = LETTERS:sub(n, n)
        end
        return table.concat(out)
    end

    function Shared.RandomInt(length)
        local out = {}
        for i = 1, length or 0 do out[i] = tostring(math.random(0, 9)) end
        return table.concat(out)
    end

    function Shared.SplitStr(str, delimiter)
        local result, from = {}, 1
        local s, e = string.find(str, delimiter, from)
        while s do
            result[#result + 1] = string.sub(str, from, s - 1)
            from = e + 1
            s, e = string.find(str, delimiter, from)
        end
        result[#result + 1] = string.sub(str, from)
        return result
    end

    function Shared.Trim(value)
        if not value then return nil end
        return (string.gsub(value, '^%s*(.-)%s*$', '%1'))
    end

    function Shared.FirstToUpper(value)
        if not value then return nil end
        return (value:gsub('^%l', string.upper))
    end

    function Shared.Round(value, decimals)
        if not decimals then return math.floor(value + 0.5) end
        local power = 10 ^ decimals
        return math.floor(value * power + 0.5) / power
    end

    function Shared.IsFunction(value)
        return M.isCallable(value)
    end

    function Shared.ChangeVehicleExtra(vehicle, extra, enable)
        if not DoesExtraExist(vehicle, extra) then return end
        -- SetVehicleExtra's third argument is "disable"
        for _ = 1, 5 do
            SetVehicleExtra(vehicle, extra, not enable)
            if (IsVehicleExtraTurnedOn(vehicle, extra) and true or false) == (enable and true or false) then return end
        end
    end

    function Shared.SetDefaultVehicleExtras(vehicle, config)
        for i = 1, 20 do
            if DoesExtraExist(vehicle, i) then SetVehicleExtra(vehicle, i, true) end
        end
        for id, enabled in pairs(config or {}) do
            Shared.ChangeVehicleExtra(vehicle, tonumber(id), type(enabled) ~= 'boolean' or enabled)
        end
    end

    return Shared
end

---rps Config.Jobs -> QB jobs with string grade keys ('0', '1', ...)
function M.buildJobs()
    local jobs = {}
    for name, def in pairs(Config.Jobs) do
        local grades = {}
        for level, grade in pairs(def.grades or {}) do
            grades[tostring(level)] = {
                name = grade.label,
                payment = grade.salary or 0,
                isboss = grade.boss and true or nil,
            }
        end
        jobs[name] = {
            label = def.label,
            type = def.type or M.settings.jobTypes[name] or 'none',
            defaultDuty = def.defaultDuty ~= false,
            offDutyPay = false,
            grades = grades,
        }
    end
    return jobs
end

---rps getJob() -> QB PlayerData.job
function M.convertJob(job)
    local def = Config.Jobs[job.name]
    return {
        name = job.name,
        label = job.label,
        payment = job.salary or 0,
        onduty = job.onduty and true or false,
        isboss = job.boss and true or false,
        type = def and def.type or M.settings.jobTypes[job.name] or 'none',
        grade = {
            name = job.gradeLabel,
            level = job.grade,
            payment = job.salary or 0,
            isboss = job.boss and true or false,
        },
    }
end

function M.noGang()
    return { name = 'none', label = 'No Gang', isboss = false, grade = { name = 'none', level = 0, isboss = false } }
end

---------------------------------------------------------------------------
-- Items (ox_inventory -> QB shapes)
---------------------------------------------------------------------------
local function itemType(name)
    return name:sub(1, 7):lower() == 'weapon_' and 'weapon' or 'item'
end

---ox_inventory Items() -> QBCore.Shared.Items. Weapons are keyed both as ox
---names them (WEAPON_PISTOL) and as QB does (weapon_pistol).
function M.buildItems(oxItems)
    local items = {}
    for name, def in pairs(oxItems or {}) do
        local client = type(def.client) == 'table' and def.client or {}
        local server = type(def.server) == 'table' and def.server or {}
        local item = {
            name = name,
            label = def.label or name,
            weight = def.weight or 0,
            type = itemType(name),
            image = client.image or (name .. '.png'),
            unique = def.stack == false,
            useable = def.consume ~= nil or client.export ~= nil or server.export ~= nil,
            shouldClose = def.close ~= false,
            description = def.description or '',
        }
        items[name] = item
        items[name:lower()] = item
    end
    return items
end

---ox_inventory slot -> QB inventory item (amount/info alongside ox's count/metadata)
function M.convertSlot(slot, sharedItems)
    local def = sharedItems[slot.name] or {}
    local metadata = slot.metadata or {}
    return {
        name = slot.name,
        label = slot.label or def.label or slot.name,
        amount = slot.count,
        count = slot.count,
        info = metadata,
        metadata = metadata,
        slot = slot.slot,
        weight = slot.weight or def.weight or 0,
        type = def.type or itemType(slot.name),
        image = metadata.image or def.image or (slot.name .. '.png'),
        unique = def.unique or false,
        useable = def.useable or false,
        shouldClose = def.shouldClose ~= false,
        description = metadata.description or def.description,
    }
end

---ox slot table ([slot] = data) -> QB items ([slot] = item)
function M.convertInventory(slots, sharedItems)
    local items = {}
    if type(slots) ~= 'table' then return items end
    for _, slot in pairs(slots) do
        if type(slot) == 'table' and slot.name and (slot.count or 0) > 0 then
            items[slot.slot] = M.convertSlot(slot, sharedItems)
        end
    end
    return items
end

---QB HasItem semantics. items: 'name' | { 'a', 'b' } | { a = 2, b = 1 }
function M.hasItems(countOf, items, amount)
    if type(items) == 'string' then
        return countOf(items) >= (tonumber(amount) or 1)
    end
    if type(items) ~= 'table' or not next(items) then return false end

    if table.type(items) == 'array' then
        for _, name in ipairs(items) do
            if countOf(name) < (tonumber(amount) or 1) then return false end
        end
    else
        for name, need in pairs(items) do
            if countOf(name) < (tonumber(need) or 1) then return false end
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Character identifiers QB has and rps doesn't. Derived from charId so they
-- are stable and unique without storing anything.
---------------------------------------------------------------------------
function M.phoneNumber(charId)
    return M.settings.phonePrefix .. ('%07d'):format(charId % 10000000)
end

function M.accountNumber(charId)
    return ('US0%dRPS%08d'):format(charId % 9 + 1, charId)
end

function M.qbMetaDefaults(charId)
    return {
        hunger = 100,
        thirst = 100,
        stress = 0,
        isdead = false,
        inlaststand = false,
        armor = 0,
        ishandcuffed = false,
        tracker = false,
        injail = 0,
        jailitems = {},
        status = {},
        phone = {},
        rep = {},
        callsign = 'NO CALLSIGN',
        bloodtype = M.bloodtypes[charId % #M.bloodtypes + 1],
        -- multiplying by an odd constant mod 2^32 is a bijection, so these stay unique
        fingerprint = ('FP%08X'):format((charId * 2654435761) % 4294967296),
        walletid = ('QB-%08d'):format(charId % 100000000),
        criminalrecord = { hasRecord = false },
        licences = deepCopy(M.settings.defaultLicences),
        inside = { apartment = {} },
        phonedata = { SerialNumber = 10000000 + charId % 90000000, InstalledApps = {} },
    }
end

---rps metadata -> QB metadata (QB defaults, then rps values, then the renamed keys)
function M.convertMetadata(meta, charId, isDead)
    local md = M.qbMetaDefaults(charId)
    for k, v in pairs(meta or {}) do md[k] = deepCopy(v) end

    md.isdead = isDead and true or false

    local licences = deepCopy(M.settings.defaultLicences)
    if type(meta.licenses) == 'table' then
        for k, v in pairs(meta.licenses) do licences[k] = v end
    end
    md.licences = licences

    return md
end

-- QB metadata keys stored under another name in rps
M.metaKeyToRps = { isdead = 'isDead', licences = 'licenses' }

---Answers exports['qb-core']:<name>(...) from inside rps_core
function M.export(name, fn)
    AddEventHandler(('__cfx_export_qb-core_%s'):format(name), function(setCB)
        setCB(fn)
    end)
end

return M
