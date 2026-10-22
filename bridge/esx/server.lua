-- ESX Legacy (es_extended) bridge, server side. Answers exports.es_extended:*
-- and the 'esx:*' events from inside rps_core. Each loaded character gets ONE
-- xPlayer, refreshed from the rps player before it is handed out; money, jobs,
-- groups and metadata are written through the rps player, items through
-- ox_inventory. Nothing other resources can call yields, except the ESX APIs
-- that block by design when called without a callback (see README).

local S = require 'bridge.esx.shared'
local export = S.export
local round = S.round

local RESOURCE = GetCurrentResourceName()

local ESX = {
    Config = S.buildConfig(),
    Jobs = S.buildJobs(),
    Players = {}, -- not kept: copies across resources would be stale anyway, use GetExtendedPlayers
    Items = {},
    OneSync = {},
}
S.addHelpers(ESX)

local xPlayers = {}     -- [src] = xPlayer
local syncers = {}      -- [src] = function refreshing the xPlayer's fields
local byIdentifier = {} -- [identifier] = xPlayer
local mutedJob = {}     -- [src] = true while setJob emits its own esx:setJob
local settingMoney = {} -- [src] = true while setAccountMoney runs (esx:setAccountMoney instead of add/remove)
local dropReasons = {}  -- [src] = reason, between playerDropped and rps unload

---------------------------------------------------------------------------
-- ox_inventory
---------------------------------------------------------------------------
local function oxStarted()
    return GetResourceState('ox_inventory') == 'started'
end

local itemCache

local function items()
    if not itemCache and oxStarted() then itemCache = exports.ox_inventory:Items() end
    return itemCache or {}
end

AddEventHandler('onResourceStart', function(name)
    if name == 'ox_inventory' then itemCache = nil end
end)

AddEventHandler('onResourceStop', function(name)
    if name == 'ox_inventory' then itemCache = nil end
end)

local ACCOUNT_ITEMS = { money = true, black_money = true }

local function esxItem(name, count)
    local def = items()[name] or {}
    return {
        name = name,
        count = count,
        label = def.label or name,
        weight = def.weight or 0,
        usable = Core.UsableItems[name] ~= nil,
        rare = false,
        canRemove = true,
    }
end

local function playerSlots(src)
    return oxStarted() and exports.ox_inventory:GetInventoryItems(src) or {}
end

-- ox slots -> ESX inventory (one entry per item name, sorted by label) + carried weight
local function buildInventory(src)
    local list, byName, weight = {}, {}, 0
    for _, slot in pairs(playerSlots(src)) do
        if type(slot) == 'table' and slot.name then
            weight = weight + (slot.weight or 0)
            if not ACCOUNT_ITEMS[slot.name] then
                local entry = byName[slot.name]
                if entry then
                    entry.count = entry.count + (slot.count or 0)
                else
                    entry = esxItem(slot.name, slot.count or 0)
                    byName[slot.name] = entry
                    list[#list + 1] = entry
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    return list, weight
end

local function buildLoadout(src)
    local list = {}
    for _, slot in pairs(playerSlots(src)) do
        local def = type(slot) == 'table' and slot.name and items()[slot.name]
        if def and def.weapon then
            local meta = slot.metadata or {}
            list[#list + 1] = {
                name = slot.name,
                ammo = meta.ammo or 0,
                label = def.label or slot.name,
                components = meta.components or {},
                tintIndex = meta.tint or 0,
            }
        end
    end
    return list
end

local function blackMoney(src)
    return oxStarted() and exports.ox_inventory:GetItemCount(src, 'black_money') or 0
end

---------------------------------------------------------------------------
-- Accounts
---------------------------------------------------------------------------
local function accountValue(p, name)
    if name == 'money' then return p.getMoney('cash') end
    if name == 'bank' then return p.getMoney('bank') end
    if name == 'black_money' then return blackMoney(p.source) end
    return 0
end

local function buildAccounts(p)
    local list = {}
    for i, a in ipairs(S.accounts) do
        list[i] = { name = a.name, money = accountValue(p, a.name), label = a.label, round = true, index = i }
    end
    return list
end

AddEventHandler('rps_core:server:moneyChanged', function(src, account, balance, diff, reason)
    if not xPlayers[src] then return end
    local name = account == 'cash' and 'money' or account

    if settingMoney[src] then
        TriggerEvent('esx:setAccountMoney', src, name, balance, reason)
    elseif diff > 0 then
        TriggerEvent('esx:addAccountMoney', src, name, diff, reason)
    elseif diff < 0 then
        TriggerEvent('esx:removeAccountMoney', src, name, -diff, reason)
    end
end)

---------------------------------------------------------------------------
-- xPlayer
---------------------------------------------------------------------------
local function weaponName(name)
    return tostring(name):upper()
end

local function createXPlayer(p)
    local src, charId = p.source, p.charId
    local charinfo = p.getCharInfo()
    local identifier = S.identifier(charId)

    local self = {
        source = src,
        playerId = src,
        identifier = identifier,
        license = p.license,
        ssn = S.ssn(charId),
        charId = charId,
        variables = {
            firstName = charinfo.firstname,
            lastName = charinfo.lastname,
            dateofbirth = charinfo.dob,
            sex = charinfo.sex,
            height = 180,
        },
        loadout = {}, -- weapons are ox_inventory items; getLoadout() reads them
        maxWeight = GetConvarInt('inventory:weight', 30000),
        weight = 0,
        paycheckEnabled = true,
        lastPlaytime = 0,
        spawned = true,
    }

    local customName

    -- the rps player behind this xPlayer, or nil once the character is unloaded
    local function rps()
        local cur = Core.Players[src]
        if cur and cur.charId == charId then return cur end
    end

    local function sync()
        local cur = rps()
        if not cur then return end
        local ped = GetPlayerPed(src)

        self.name = customName or cur.getName()
        self.group = cur.getGroup()
        self.admin = self.isAdmin()
        self.job = S.toEsxJob(cur.getJob())
        self.accounts = buildAccounts(cur)
        self.money = self.accounts[3].money
        self.metadata = cur.getMeta()
        self.inventory, self.weight = buildInventory(src)
        if ped ~= 0 and DoesEntityExist(ped) then
            local c = GetEntityCoords(ped)
            self.coords = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) }
        end
    end

    -----------------------------------------------------------------------
    -- Base
    -----------------------------------------------------------------------
    function self.isCurrent()
        return xPlayers[src] == self
    end

    function self.triggerEvent(eventName, ...)
        TriggerClientEvent(eventName, src, ...)
    end

    -- rps pays every character from rps_core; this only records the flag
    function self.togglePaycheck(toggle)
        self.paycheckEnabled = toggle and true or false
    end

    function self.isPaycheckEnabled()
        return self.paycheckEnabled
    end

    function self.isAdmin()
        return Core.HasGroup(src, 'admin') or IsPlayerAceAllowed(src, 'command')
    end

    function self.setCoords(coords)
        local ped = GetPlayerPed(src)
        if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return false end
        if ped == 0 or not DoesEntityExist(ped) then return false end
        SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
        SetEntityHeading(ped, coords.w or coords.heading or GetEntityHeading(ped))
        self.coords = { x = coords.x, y = coords.y, z = coords.z, heading = coords.w or coords.heading or 0.0 }
        return true
    end

    function self.updateCoords()
        local ped = GetPlayerPed(src)
        if ped == 0 then return end
        local c = GetEntityCoords(ped)
        self.coords = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) }
    end

    function self.getCoords(vector, heading)
        self.updateCoords()
        local c = self.coords or { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }
        if vector then
            if heading then return vector4(c.x, c.y, c.z, c.heading) end
            return vector3(c.x, c.y, c.z)
        end
        local out = { x = c.x, y = c.y, z = c.z }
        if heading then out.heading = c.heading end
        return out
    end

    function self.kick(reason)
        DropPlayer(src, reason or 'Kicked')
    end

    function self.getPlayTime()
        return self.lastPlaytime + (tonumber(GetPlayerTimeOnline(src)) or 0)
    end

    function self.getIdentifier()
        return identifier
    end

    function self.getSSN()
        return self.ssn
    end

    function self.getSource()
        return src
    end

    self.getPlayerId = self.getSource

    function self.getName()
        local cur = rps()
        return customName or (cur and cur.getName()) or self.name
    end

    -- rps has no rename; the new name lives on this xPlayer for the session
    function self.setName(newName)
        customName = newName
        self.name = newName
        Player(src).state:set('name', newName, true)
    end

    function self.executeCommand(command)
        if type(command) ~= 'string' then return end
        self.triggerEvent('esx:executeCommand', command)
    end

    -----------------------------------------------------------------------
    -- Group
    -----------------------------------------------------------------------
    function self.setGroup(newGroup)
        local cur = rps()
        if not cur then return false end
        newGroup = S.groupAlias[newGroup] or newGroup
        local last = cur.getGroup()
        if not cur.setGroup(newGroup) then return false end
        self.group = newGroup
        TriggerEvent('esx:setGroup', src, newGroup, last)
        return true
    end

    function self.getGroup()
        local cur = rps()
        return cur and cur.getGroup() or self.group
    end

    -----------------------------------------------------------------------
    -- Variables
    -----------------------------------------------------------------------
    function self.set(key, value, replicate)
        self.variables[key] = value
        if replicate ~= false then
            self.triggerEvent('esx:updatePlayerData', 'variables', self.variables)
        end
    end

    function self.get(key)
        return self.variables[key]
    end

    -----------------------------------------------------------------------
    -- Accounts: money <-> rps cash, bank <-> rps bank, black_money <-> ox item
    -----------------------------------------------------------------------
    local function changeAccount(op, name, money, reason)
        local cur = rps()
        if not cur or type(name) ~= 'string' then return false end
        name = name:lower()
        money = round(tonumber(money) or -1)
        if (op == 'set' and money < 0) or (op ~= 'set' and money <= 0) then return false end
        reason = reason or 'unknown'

        if name == 'money' or name == 'bank' then
            local account = name == 'money' and 'cash' or 'bank'
            if op == 'set' then settingMoney[src] = true end
            local ok = cur[op .. 'Money'](account, money, reason)
            settingMoney[src] = nil
            return ok
        end

        if name ~= 'black_money' or not oxStarted() then return false end

        local ok
        if op == 'add' then
            ok = exports.ox_inventory:AddItem(src, 'black_money', money)
        elseif op == 'remove' then
            ok = exports.ox_inventory:RemoveItem(src, 'black_money', money)
        else
            ok = exports.ox_inventory:SetItem(src, 'black_money', money) ~= false
        end
        if not ok then return false end

        TriggerEvent(('esx:%sAccountMoney'):format(op), src, name, money, reason)
        return true
    end

    function self.getAccounts(minimal)
        local cur = rps()
        if cur then self.accounts = buildAccounts(cur) end
        if not minimal then return self.accounts end
        local out = {}
        for _, a in ipairs(self.accounts) do out[a.name] = a.money end
        return out
    end

    function self.getAccount(name)
        if type(name) ~= 'string' then return nil end
        name = name:lower()
        for _, a in ipairs(self.getAccounts()) do
            if a.name == name then return a end
        end
    end

    function self.setAccountMoney(name, money, reason) return changeAccount('set', name, money, reason) end
    function self.addAccountMoney(name, money, reason) return changeAccount('add', name, money, reason) end
    function self.removeAccountMoney(name, money, reason) return changeAccount('remove', name, money, reason) end

    function self.getMoney()
        local cur = rps()
        return cur and cur.getMoney('cash') or 0
    end

    function self.setMoney(money, reason) return changeAccount('set', 'money', money, reason) end
    function self.addMoney(money, reason) return changeAccount('add', 'money', money, reason) end
    function self.removeMoney(money, reason) return changeAccount('remove', 'money', money, reason) end

    -----------------------------------------------------------------------
    -- Inventory (ox_inventory). 'money' is routed to rps cash, never the item.
    -----------------------------------------------------------------------
    function self.getInventory(minimal)
        self.inventory, self.weight = buildInventory(src)
        if not minimal then return self.inventory end
        local out = {}
        for _, item in ipairs(self.inventory) do out[item.name] = item.count end
        return out
    end

    function self.getInventoryItem(name, metadata)
        if name == 'money' then return esxItem('money', self.getMoney()) end
        if not oxStarted() or not items()[name] then return nil end
        local item = esxItem(name, exports.ox_inventory:GetItemCount(src, name, metadata))
        item.metadata = metadata
        return item
    end

    function self.addInventoryItem(name, count, metadata, slot)
        count = tonumber(count) or 1
        if name == 'money' then return self.addMoney(count) end
        if not oxStarted() then return false end
        return exports.ox_inventory:AddItem(src, name, count, metadata, slot)
    end

    function self.removeInventoryItem(name, count, metadata, slot)
        count = tonumber(count) or 1
        if name == 'money' then return self.removeMoney(count) end
        if not oxStarted() then return false end
        return exports.ox_inventory:RemoveItem(src, name, count, metadata, slot)
    end

    function self.setInventoryItem(name, count, metadata)
        count = tonumber(count) or 0
        if name == 'money' then return self.setMoney(count) end
        if not oxStarted() then return false end
        return exports.ox_inventory:SetItem(src, name, count, metadata)
    end

    function self.getWeight()
        self.inventory, self.weight = buildInventory(src)
        return self.weight
    end

    function self.getMaxWeight()
        return self.maxWeight
    end

    function self.setMaxWeight(newWeight)
        newWeight = tonumber(newWeight)
        if not newWeight or newWeight < 0 or not oxStarted() then return false end
        self.maxWeight = newWeight
        exports.ox_inventory:SetMaxWeight(src, newWeight)
        self.triggerEvent('esx:setMaxWeight', newWeight)
        return true
    end

    function self.canCarryItem(name, count, metadata)
        if name == 'money' then return true end
        return oxStarted() and exports.ox_inventory:CanCarryItem(src, name, tonumber(count) or 1, metadata) or false
    end

    function self.canSwapItem(firstItem, firstItemCount, testItem, testItemCount)
        return oxStarted() and exports.ox_inventory:CanSwapItem(src, firstItem, firstItemCount, testItem, testItemCount) or false
    end

    function self.hasItem(name, metadata)
        local item = self.getInventoryItem(name, metadata)
        if not item or item.count < 1 then return false end
        return item, item.count
    end

    -----------------------------------------------------------------------
    -- Weapons are ox_inventory items (WEAPON_*). Components and tints have
    -- different names in ox, so those calls are harmless no-ops.
    -----------------------------------------------------------------------
    local function weaponSlot(name)
        if not oxStarted() then return end
        local slotId = exports.ox_inventory:GetSlotIdWithItem(src, weaponName(name))
        return slotId and exports.ox_inventory:GetSlot(src, slotId), slotId
    end

    local function updateWeaponMeta(name, key, fn)
        local slot, slotId = weaponSlot(name)
        if not slot then return false end
        local meta = slot.metadata or {}
        meta[key] = fn(meta[key])
        exports.ox_inventory:SetMetadata(src, slotId, meta)
        return true
    end

    function self.getLoadout(minimal)
        local loadout = buildLoadout(src)
        if not minimal then return loadout end
        local out = {}
        for _, w in ipairs(loadout) do
            out[w.name] = { ammo = w.ammo, tintIndex = w.tintIndex, components = w.components }
        end
        return out
    end

    function self.addWeapon(name, ammo)
        if not oxStarted() then return false end
        return exports.ox_inventory:AddItem(src, weaponName(name), 1, ammo and { ammo = tonumber(ammo) } or nil)
    end

    function self.removeWeapon(name)
        if not oxStarted() then return false end
        return exports.ox_inventory:RemoveItem(src, weaponName(name), 1)
    end

    function self.hasWeapon(name)
        return oxStarted() and exports.ox_inventory:GetItemCount(src, weaponName(name)) > 0 or false
    end

    function self.getWeapon(name)
        name = weaponName(name)
        for i, w in ipairs(buildLoadout(src)) do
            if w.name == name then return i, w end
        end
    end

    function self.addWeaponAmmo(name, ammo)
        return updateWeaponMeta(name, 'ammo', function(v) return (v or 0) + (tonumber(ammo) or 0) end)
    end

    function self.removeWeaponAmmo(name, ammo)
        return updateWeaponMeta(name, 'ammo', function(v) return math.max(0, (v or 0) - (tonumber(ammo) or 0)) end)
    end

    function self.updateWeaponAmmo(name, ammo)
        return updateWeaponMeta(name, 'ammo', function() return tonumber(ammo) or 0 end)
    end

    function self.setWeaponTint(name, tint)
        return updateWeaponMeta(name, 'tint', function() return tonumber(tint) or 0 end)
    end

    function self.getWeaponTint(name)
        local _, w = self.getWeapon(name)
        return w and w.tintIndex or 0
    end

    function self.addWeaponComponent() end    -- ox components are separate items
    function self.removeWeaponComponent() end
    function self.hasWeaponComponent() return false end

    -----------------------------------------------------------------------
    -- Job
    -----------------------------------------------------------------------
    function self.getJob()
        local cur = rps()
        if cur then self.job = S.toEsxJob(cur.getJob()) end
        return self.job
    end

    function self.setJob(name, grade, onDuty)
        local cur = rps()
        if not cur then return false end
        local last = S.toEsxJob(cur.getJob())

        mutedJob[src] = true
        local ok = cur.setJob(name, tonumber(grade) or 0)
        if ok and type(onDuty) == 'boolean' then cur.setDuty(onDuty) end
        mutedJob[src] = nil

        if not ok then
            print(('[rps_core] ESX setJob ignored for %s: unknown job %s grade %s'):format(src, name, grade))
            return false
        end

        self.job = S.toEsxJob(cur.getJob())
        TriggerEvent('esx:setJob', src, self.job, last)
        return true
    end

    function self.refreshJob()
        self.getJob()
        return true
    end

    -----------------------------------------------------------------------
    -- Metadata (rps metadata)
    -----------------------------------------------------------------------
    function self.getMeta(index, subIndex)
        local cur = rps()
        if not cur then return nil end
        if not index then return cur.getMeta() end
        local value = cur.getMeta(index)
        if subIndex == nil or type(value) ~= 'table' then return value end
        if type(subIndex) == 'table' then
            local out = {}
            for _, key in ipairs(subIndex) do out[key] = value[key] end
            return out
        end
        return value[subIndex]
    end

    function self.setMeta(index, value, subValue)
        local cur = rps()
        if not cur or type(index) ~= 'string' or value == nil then return end
        if subValue == nil then
            cur.setMeta(index, value)
        else
            local t = cur.getMeta(index)
            t = type(t) == 'table' and S.deepCopy(t) or {}
            t[value] = subValue
            cur.setMeta(index, t)
        end
    end

    function self.clearMeta(index, subValues)
        local cur = rps()
        if not cur or type(index) ~= 'string' then return end
        if subValues == nil then return cur.setMeta(index, nil) end

        local t = cur.getMeta(index)
        if type(t) ~= 'table' then return end
        t = S.deepCopy(t)
        if type(subValues) == 'table' then
            for _, key in ipairs(subValues) do t[key] = nil end
        else
            t[subValues] = nil
        end
        cur.setMeta(index, t)
    end

    -----------------------------------------------------------------------
    -- Notifications
    -----------------------------------------------------------------------
    function self.showNotification(msg, notifyType, length, title, position)
        self.triggerEvent('esx:showNotification', msg, notifyType, length, title, position)
    end

    function self.showAdvancedNotification(sender, subject, msg, textureDict, iconType, flash, saveToBrief, hudColorIndex)
        self.triggerEvent('esx:showAdvancedNotification', sender, subject, msg, textureDict, iconType, flash, saveToBrief, hudColorIndex)
    end

    function self.showHelpNotification(msg, thisFrame, beep, duration)
        self.triggerEvent('esx:showHelpNotification', msg, thisFrame, beep, duration)
    end

    sync()
    return self, sync
end

-- xPlayer with fresh fields, or nil
local function getXPlayer(src)
    src = tonumber(src)
    local xPlayer = src and xPlayers[src]
    if xPlayer then syncers[src]() end
    return xPlayer
end

---------------------------------------------------------------------------
-- Players
---------------------------------------------------------------------------
function ESX.GetPlayerFromId(source)
    return getXPlayer(source)
end

function ESX.GetPlayerFromIdentifier(identifier)
    local xPlayer = byIdentifier[identifier]
    return xPlayer and getXPlayer(xPlayer.source)
end

function ESX.GetPlayerIdFromIdentifier(identifier)
    local xPlayer = byIdentifier[identifier]
    return xPlayer and xPlayer.source
end

function ESX.IsPlayerLoaded(source)
    return xPlayers[tonumber(source)] ~= nil
end

-- Like upstream: numeric sources of players with a loaded character only
-- (not those still on character selection)
function ESX.GetPlayers()
    local list = {}
    for src in pairs(xPlayers) do list[#list + 1] = src end
    return list
end

local function matches(xPlayer, key, value)
    if key == 'job' then return xPlayer.job.name == value end
    return xPlayer[key] == value
end

function ESX.GetExtendedPlayers(key, val, minimal)
    local list = {}
    for src in pairs(xPlayers) do list[#list + 1] = getXPlayer(src) end

    if not key then
        if not minimal then return list end
        local ids = {}
        for i, x in ipairs(list) do ids[i] = x.source end
        return ids
    end

    if type(val) == 'table' then
        local grouped = {}
        for _, v in ipairs(val) do
            grouped[v] = {}
            for _, x in ipairs(list) do
                if matches(x, key, v) then grouped[v][#grouped[v] + 1] = minimal and x.source or x end
            end
        end
        return grouped
    end

    local out = {}
    for _, x in ipairs(list) do
        if matches(x, key, val) then out[#out + 1] = minimal and x.source or x end
    end
    return out
end

function ESX.GetNumPlayers(key, val)
    if not key then return #ESX.GetPlayers() end
    local found = ESX.GetExtendedPlayers(key, val, true)
    if type(val) ~= 'table' then return #found end
    local counts = {}
    for k, ids in pairs(found) do counts[k] = #ids end
    return counts
end

-- ESX license-style identifier (without the 'license:' prefix) for unloaded
-- players; the character identifier ('char<id>') once one is loaded
function ESX.GetIdentifier(playerId)
    local xPlayer = xPlayers[tonumber(playerId)]
    if xPlayer then return xPlayer.identifier end
    local license = GetPlayerIdentifierByType(tostring(playerId), 'license')
    return license and license:gsub('^license:', '') or nil
end

function ESX.TriggerClientEvent(eventName, playerIds, ...)
    if type(playerIds) ~= 'table' then return TriggerClientEvent(eventName, playerIds, ...) end
    for _, id in ipairs(playerIds) do TriggerClientEvent(eventName, id, ...) end
end

-- Saving waits on the database: done in a thread, cb(success) when finished
function ESX.SavePlayer(xPlayer, cb)
    local src = type(xPlayer) == 'table' and xPlayer.source or tonumber(xPlayer)
    CreateThread(function()
        local p = src and Core.Players[src]
        if p then p.save() end
        if cb then cb(p ~= nil) end
    end)
end

function ESX.SavePlayers(cb)
    CreateThread(function()
        Core.SaveAll()
        if cb then cb(true) end
    end)
end

-- xPlayer function overrides have no equivalent: the xPlayer is built here
function ESX.RegisterPlayerFunctionOverrides() end
function ESX.SetPlayerFunctionOverride() end

---------------------------------------------------------------------------
-- Jobs (from rps_core's Config.Jobs)
---------------------------------------------------------------------------
function ESX.GetJobs(jobType)
    if not jobType then return ESX.Jobs end
    local types = type(jobType) == 'table' and jobType or { jobType }
    local out = {}
    for name, job in pairs(ESX.Jobs) do
        for _, t in ipairs(types) do
            if job.type == t then out[name] = job end
        end
    end
    return out
end

function ESX.DoesJobExist(job, grade)
    local j = ESX.Jobs[job]
    return (j and j.grades[tostring(grade)] ~= nil) or false
end

function ESX.RefreshJobs()
    ESX.Jobs = S.buildJobs()
    TriggerEvent('esx:jobsRefreshed')
end

function ESX.RefreshJob(jobName)
    ESX.Jobs = S.buildJobs()
    return ESX.Jobs[jobName] ~= nil
end

-- rps jobs live in rps_core/shared/jobs.lua, not the database
function ESX.CreateJob(name)
    print(('[rps_core] ESX.CreateJob(%s) ignored: add jobs to rps_core/shared/jobs.lua'):format(tostring(name)))
    return false
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
function ESX.GetItems()
    return items()
end

function ESX.RefreshItems()
    itemCache = nil
end

function ESX.GetItemLabel(item)
    local def = items()[item]
    return def and def.label or nil
end

function ESX.RegisterUsableItem(item, cb)
    Core.RegisterUsableItem(item, cb, 'esx')
end

function ESX.UseItem(source, item, data)
    data = data or (oxStarted() and exports.ox_inventory:GetSlotWithItem(source, item)) or { name = item, count = 1 }
    return Core.UseItem(source, item, data)
end

function ESX.GetUsableItems()
    local out = {}
    for name in pairs(Core.UsableItems) do out[name] = true end
    return out
end

function ESX.GetWeapon(name)
    local def = items()[weaponName(name)]
    return def and def.weapon and def or nil
end

function ESX.GetWeaponLabel(name)
    local def = ESX.GetWeapon(name)
    return def and def.label or nil
end

function ESX.GetWeaponList()
    local out = {}
    for name, def in pairs(items()) do
        if def.weapon then out[#out + 1] = { name = name, label = def.label } end
    end
    return out
end

-- ox_inventory handles drops; ESX pickups have no equivalent
function ESX.CreatePickup(itemType, name, count)
    print(('[rps_core] ESX.CreatePickup(%s, %s, %s) is not supported (use ox_inventory drops)'):format(itemType, name, count))
end

function ESX.DiscordLog() end
function ESX.DiscordLogFields() end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
local serverCallbacks = {}  -- [name] = { cb, owner }
local clientRequests = {}   -- [id] = { cb, player }
local lastClientRequest = 0

function ESX.RegisterServerCallback(name, cb)
    serverCallbacks[name] = { cb = cb, owner = GetInvokingResource() or RESOURCE }
end

function ESX.DoesServerCallbackExist(name)
    return serverCallbacks[name] ~= nil
end

RegisterNetEvent('rps_core:esx:triggerServerCallback', function(name, requestId, ...)
    local src = source
    local entry = type(name) == 'string' and serverCallbacks[name]
    if not entry then
        return print(('[rps_core] ESX server callback "%s" does not exist'):format(tostring(name)))
    end

    local ok, err = pcall(entry.cb, src, function(...)
        TriggerClientEvent('rps_core:esx:serverCallback', src, requestId, ...)
    end, ...)

    if not ok then
        print(('[rps_core] ESX server callback "%s" errored: %s'):format(name, err))
    end
end)

function ESX.TriggerClientCallback(player, name, cb, ...)
    lastClientRequest = lastClientRequest + 1
    clientRequests[lastClientRequest] = { cb = cb, player = tonumber(player) }
    TriggerClientEvent('rps_core:esx:triggerClientCallback', player, name, lastClientRequest, ...)
end

-- Blocks: from other resources use it through imports.lua, which awaits locally
function ESX.AwaitClientCallback(player, name, ...)
    local p = promise.new()
    ESX.TriggerClientCallback(player, name, function(...) p:resolve(table.pack(...)) end, ...)
    local result = Citizen.Await(p)
    return table.unpack(result, 1, result.n)
end

RegisterNetEvent('rps_core:esx:clientCallback', function(requestId, ...)
    local request = clientRequests[requestId]
    if not request or request.player ~= source then return end
    clientRequests[requestId] = nil
    if request.cb then request.cb(...) end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local commands = {}

local function commandError(src, msg)
    if src == 0 then return print(('[^3WARNING^7] %s^7'):format(msg)) end
    TriggerClientEvent('esx:showNotification', src, msg, 'error')
end

local function parseArgs(src, args, suggestion)
    local arguments = suggestion.arguments or {}
    if suggestion.validate and #args ~= #arguments then
        return nil, ('Wrong number of arguments (passed %d, wanted %d)'):format(#args, #arguments)
    end

    local parsed = {}
    for k, v in ipairs(arguments) do
        local raw, value, err = args[k], nil, nil
        local kind = v.type

        if kind == 'number' then
            value = tonumber(raw)
            if not value then err = ('Argument #%d must be a number'):format(k) end
        elseif kind == 'player' or kind == 'playerId' then
            local target = raw == 'me' and src or tonumber(raw)
            if not target then
                err = ('Argument #%d must be a player id'):format(k)
            else
                local xTarget = getXPlayer(target)
                if not xTarget then
                    err = 'Invalid player id'
                else
                    value = kind == 'player' and xTarget or target
                end
            end
        elseif kind == 'string' then
            if raw ~= nil and not tonumber(raw) then value = raw else err = ('Argument #%d must be text'):format(k) end
        elseif kind == 'item' then
            if raw and items()[raw] then value = raw else err = 'Invalid item name' end
        elseif kind == 'weapon' then
            if raw and ESX.GetWeapon(raw) then value = weaponName(raw) else err = 'Invalid weapon name' end
        elseif kind == 'merge' then
            value = table.concat(args, ' ', k)
        elseif kind == 'coordinate' then
            value = raw and tonumber(raw:match('(-?%d+%.?%d*)'))
            if not value then err = ('Argument #%d must be a coordinate'):format(k) end
        else
            value = raw -- 'any' and untyped arguments
        end

        local validator = v.Validator
        if not err and type(validator) == 'table' and ESX.IsFunctionReference(validator.validate) then
            local ok, res = pcall(validator.validate, value)
            if not ok or res ~= true then err = validator.err or ('Argument #%d is invalid'):format(k) end
        end

        if v.validate == false then err = nil end
        if err then return nil, err end
        parsed[v.name] = value
    end

    return parsed
end

local function forGroups(group, fn)
    if type(group) == 'table' then
        for _, g in ipairs(group) do fn(S.groupAlias[g] or g) end
    elseif type(group) == 'string' then
        fn(S.groupAlias[group] or group)
    end
end

function ESX.RegisterCommand(name, group, cb, allowConsole, suggestion)
    if type(name) == 'table' then
        for _, n in ipairs(name) do ESX.RegisterCommand(n, group, cb, allowConsole, suggestion) end
        return
    end

    local previous = commands[name]

    if suggestion then
        suggestion.arguments = suggestion.arguments or {}
        suggestion.help = suggestion.help or ''
        TriggerClientEvent('chat:addSuggestion', -1, '/' .. name, suggestion.help, suggestion.arguments)
    end

    commands[name] = { group = group, cb = cb, allowConsole = allowConsole, suggestion = suggestion }

    if previous then return end

    -- Permissions are checked here rather than with ACEs, which rps_core would need
    -- add_ace rights for: an rps group at or above any listed group (they inherit
    -- upwards), or an ACE for the command (txAdmin admins, server.cfg grants).
    RegisterCommand(name, function(src, args)
        local command = commands[name]
        if src == 0 and not command.allowConsole then
            return print(('[^3WARNING^7] /%s cannot be run from the console^7'):format(name))
        end

        if src ~= 0 then
            local allowed = command.group == nil
            forGroups(command.group, function(g)
                if g == 'user' or Core.HasGroup(src, g) then allowed = true end
            end)
            if not allowed and not IsPlayerAceAllowed(src, ('command.%s'):format(name)) then
                return commandError(src, 'You do not have permission to use this command')
            end
        end

        if command.suggestion then
            local parsed, err = parseArgs(src, args, command.suggestion)
            if not parsed then return commandError(src, err) end
            args = parsed
        end

        command.cb(src ~= 0 and getXPlayer(src) or false, args, function(msg)
            commandError(src, msg)
        end)
    end, false)
end

local function sendSuggestions(src)
    for name, command in pairs(commands) do
        if command.suggestion then
            TriggerClientEvent('chat:addSuggestion', src, '/' .. name, command.suggestion.help, command.suggestion.arguments)
        end
    end
end

---------------------------------------------------------------------------
-- OneSync helpers
---------------------------------------------------------------------------
local function isCallable(cb)
    return type(cb) == 'function' or type(cb) == 'table'
end

-- Creates an entity in a thread and hands back its network id (false on failure).
-- Without a callback this blocks: other resources get the awaiting version from imports.lua.
local function spawnNetworked(create, cb, after)
    local p = not cb and promise.new()

    CreateThread(function()
        local entity = create()
        local deadline = GetGameTimer() + 5000
        while entity and entity ~= 0 and not DoesEntityExist(entity) and GetGameTimer() < deadline do
            Wait(50)
        end

        local netId = false
        if entity and entity ~= 0 and DoesEntityExist(entity) then
            if after then after(entity) end
            netId = NetworkGetNetworkIdFromEntity(entity)
        end

        if p then p:resolve(netId) elseif cb then cb(netId) end
    end)

    if p then return Citizen.Await(p) end
end

local function toVec3(coords)
    if type(coords) == 'number' then return GetEntityCoords(GetPlayerPed(coords)) end
    return vector3(coords.x, coords.y, coords.z)
end

-- vehicleType defaults to 'automobile' (upstream asks a client; pass it for boats, bikes, heli...)
function ESX.OneSync.SpawnVehicle(model, coords, heading, props, cb, vehicleType)
    if not isCallable(cb) then
        if type(cb) == 'string' and not vehicleType then vehicleType = cb end
        cb = nil
    end

    return spawnNetworked(function()
        return CreateVehicleServerSetter(type(model) == 'string' and joaat(model) or model, vehicleType or 'automobile', coords.x, coords.y, coords.z, heading or 0.0)
    end, cb, function(vehicle)
        SetEntityOrphanMode(vehicle, 2)
        if type(props) == 'table' and next(props) then
            Entity(vehicle).state:set('VehicleProperties', props, true)
        end
    end)
end

function ESX.OneSync.SpawnObject(model, coords, heading, cb)
    model = type(model) == 'string' and joaat(model) or model
    return spawnNetworked(function()
        return CreateObject(model, coords.x, coords.y, coords.z, true, true, false)
    end, isCallable(cb) and cb or nil, function(object)
        SetEntityHeading(object, heading or 0.0)
    end)
end

function ESX.OneSync.SpawnPed(model, coords, heading, cb)
    model = type(model) == 'string' and joaat(model) or model
    return spawnNetworked(function()
        return CreatePed(0, model, coords.x, coords.y, coords.z, heading or 0.0, true, true)
    end, isCallable(cb) and cb or nil)
end

function ESX.OneSync.SpawnPedInVehicle(model, vehicle, seat, cb)
    model = type(model) == 'string' and joaat(model) or model
    return spawnNetworked(function()
        return CreatePedInsideVehicle(vehicle, 1, model, seat or -1, true, true)
    end, isCallable(cb) and cb or nil)
end

local function nearbyPlayers(source, closest, maxDistance, ignore, bucket)
    local origin = toVec3(source)
    maxDistance = maxDistance or 100
    ignore = ignore or {}
    local result = {}

    for _, id in ipairs(GetPlayers()) do
        local playerId = tonumber(id)
        local ped = GetPlayerPed(playerId)
        if ped ~= 0 and not ignore[playerId] and (not bucket or GetPlayerRoutingBucket(playerId) == bucket)
            and not (closest and playerId == source) then
            local coords = GetEntityCoords(ped)
            local dist = #(origin - coords)
            local entry = { id = playerId, ped = NetworkGetNetworkIdFromEntity(ped), coords = coords, dist = dist }
            if closest then
                if dist <= (result.dist or maxDistance) then result = entry end
            elseif dist <= maxDistance then
                result[#result + 1] = entry
            end
        end
    end

    return result
end

function ESX.OneSync.GetPlayersInArea(source, maxDistance, ignore, bucket)
    return nearbyPlayers(source, false, maxDistance, ignore, bucket)
end

function ESX.OneSync.GetClosestPlayer(source, maxDistance, ignore, bucket)
    return nearbyPlayers(source, true, maxDistance, ignore, bucket)
end

local function entitiesInArea(pool, coords, maxDistance, modelFilter, skipPlayers)
    local origin, out = toVec3(coords), {}
    for _, entity in ipairs(pool) do
        if not (skipPlayers and IsPedAPlayer(entity)) and (not modelFilter or modelFilter[GetEntityModel(entity)]) then
            if not maxDistance or #(origin - GetEntityCoords(entity)) <= maxDistance then
                out[#out + 1] = NetworkGetNetworkIdFromEntity(entity)
            end
        end
    end
    return out
end

local function closestEntity(pool, coords, modelFilter, skipPlayers)
    local origin = toVec3(coords)
    local best, bestDist, bestCoords = 0, 100, vector3(0, 0, 0)
    for _, entity in ipairs(pool) do
        if not (skipPlayers and IsPedAPlayer(entity)) and (not modelFilter or modelFilter[GetEntityModel(entity)]) then
            local c = GetEntityCoords(entity)
            local dist = #(origin - c)
            if dist < bestDist then best, bestDist, bestCoords = entity, dist, c end
        end
    end
    return NetworkGetNetworkIdFromEntity(best), bestDist, bestCoords
end

function ESX.OneSync.GetPedsInArea(coords, maxDistance, modelFilter) return entitiesInArea(GetAllPeds(), coords, maxDistance, modelFilter, true) end
function ESX.OneSync.GetObjectsInArea(coords, maxDistance, modelFilter) return entitiesInArea(GetAllObjects(), coords, maxDistance, modelFilter) end
function ESX.OneSync.GetVehiclesInArea(coords, maxDistance, modelFilter) return entitiesInArea(GetAllVehicles(), coords, maxDistance, modelFilter) end
function ESX.OneSync.GetClosestPed(coords, modelFilter) return closestEntity(GetAllPeds(), coords, modelFilter, true) end
function ESX.OneSync.GetClosestObject(coords, modelFilter) return closestEntity(GetAllObjects(), coords, modelFilter) end
function ESX.OneSync.GetClosestVehicle(coords, modelFilter) return closestEntity(GetAllVehicles(), coords, modelFilter) end

---------------------------------------------------------------------------
-- rps events -> ESX events
---------------------------------------------------------------------------
AddEventHandler('rps_core:server:playerLoaded', function(src)
    local p = Core.Players[src]
    if not p then return end

    local xPlayer, sync = createXPlayer(p)
    xPlayers[src] = xPlayer
    syncers[src] = sync
    byIdentifier[xPlayer.identifier] = xPlayer
    Player(src).state:set('identifier', xPlayer.identifier, false)
    Player(src).state:set('name', xPlayer.name, true)

    -- a character that has never been saved has no position yet
    local isNew = p.getData().position == nil
    TriggerEvent('esx:playerLoaded', src, xPlayer, isNew)
    sendSuggestions(src)
end)

AddEventHandler('playerDropped', function(reason)
    if xPlayers[source] then dropReasons[source] = reason end
    for id, request in pairs(clientRequests) do
        if request.player == source then clientRequests[id] = nil end
    end
end)

-- rps unloads after saving, so playerDropped (above) has already recorded the reason
AddEventHandler('rps_core:server:playerUnloaded', function(src)
    local xPlayer = xPlayers[src]
    if not xPlayer then return end

    xPlayers[src] = nil
    syncers[src] = nil
    byIdentifier[xPlayer.identifier] = nil

    local reason = dropReasons[src] or 'esx_player_logout'
    dropReasons[src] = nil
    TriggerEvent('esx:playerDropped', src, reason)
end)

AddEventHandler('rps_core:server:jobChanged', function(src, newJob, oldJob)
    if mutedJob[src] or not xPlayers[src] then return end
    TriggerEvent('esx:setJob', src, S.toEsxJob(newJob), S.toEsxJob(oldJob))
end)

-- esx_multicharacter-style logout request: save, unload, back to character selection
AddEventHandler('esx:playerLogout', function(playerId, cb)
    playerId = tonumber(playerId)
    if not playerId or not Core.Players[playerId] then
        if cb then cb() end
        return
    end

    CreateThread(function()
        Core.UnloadPlayer(playerId)
        TriggerClientEvent('rps_core:client:logout', playerId)
        if cb then cb() end
    end)
end)

-- sent by the ESX client side; registered so scripts listening on them receive them
RegisterNetEvent('esx:onPlayerDeath', function() end)
RegisterNetEvent('esx:onPlayerSpawn', function()
    local xPlayer = xPlayers[source]
    if xPlayer then xPlayer.spawned = true end
end)

AddEventHandler('onResourceStop', function(name)
    for cbName, entry in pairs(serverCallbacks) do
        if entry.owner == name then serverCallbacks[cbName] = nil end
    end
end)

---------------------------------------------------------------------------
-- Shared object
---------------------------------------------------------------------------
local function getSharedObject()
    ESX.Items = items()
    return ESX
end

export('getSharedObject', getSharedObject)

AddEventHandler('esx:getSharedObject', function(cb)
    if ESX.IsFunctionReference(cb) then cb(getSharedObject()) end
end)

-- Used by ESX.Player() / ESX.ExtendedPlayers() from imports.lua
export('RunStaticPlayerMethod', function(src, method, ...)
    local xPlayer = getXPlayer(src)
    local fn = xPlayer and xPlayer[method]
    if type(fn) == 'function' then return fn(...) end
    return fn
end)
