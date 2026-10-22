-- QBCore (qb-core) bridge, server side. Answers exports['qb-core']:* from
-- inside rps_core. Each loaded character gets ONE QB Player object whose
-- PlayerData is refreshed in place from rps_core events; money, jobs and
-- metadata are written through the rps player, items through ox_inventory.
-- Everything other resources can call returns without yielding.

local Q = require 'bridge.qb.shared'
local export = Q.export
local deepCopy = Q.deepCopy
local settings = Q.settings

local QBCore = {
    Config = Q.buildConfig(),
    Shared = Q.buildShared(),
    Functions = {},
    Players = {},
    PlayersByCitizenId = {},
    Player = {},
    Commands = { List = {}, IgnoreList = { god = true, user = true } },
    ServerCallbacks = {},
    ClientCallbacks = {},
    UsableItems = {},
    Player_Buckets = {},
    Entity_Buckets = {},
}
QBCore.Shared.Jobs = Q.buildJobs()

local Functions = QBCore.Functions
local ACCOUNTS = { cash = true, bank = true }

---------------------------------------------------------------------------
-- ox_inventory helpers (ox_inventory starts after rps_core, so items load lazily)
---------------------------------------------------------------------------
local function oxStarted()
    return GetResourceState('ox_inventory') == 'started'
end

local function sharedItems()
    if not next(QBCore.Shared.Items) and oxStarted() then
        local ok, list = pcall(function() return exports.ox_inventory:Items() end)
        if ok and list then QBCore.Shared.Items = Q.buildItems(list) end
    end
    return QBCore.Shared.Items
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= 'ox_inventory' then return end
    QBCore.Shared.Items = {}
    sharedItems()
end)

local function ox(method, ...)
    if not oxStarted() then return end
    local inv = exports.ox_inventory
    return inv[method](inv, ...)
end

local function inventoryOf(src)
    return Q.convertInventory(ox('GetInventoryItems', src), sharedItems())
end

local function itemCount(src, name)
    return ox('GetItemCount', src, name) or 0
end

---------------------------------------------------------------------------
-- PlayerData
---------------------------------------------------------------------------
local function rpsPlayer(src, charId)
    local player = Core.Players[src]
    if player and (not charId or player.charId == charId) then return player end
end

local function buildMoney(player)
    local accounts = player.getAccounts()
    return { cash = accounts.cash or 0, bank = accounts.bank or 0, crypto = 0 }
end

local function buildCharinfo(player)
    local ci = player.getCharInfo()
    return {
        firstname = ci.firstname,
        lastname = ci.lastname,
        birthdate = ci.dob,
        gender = ci.sex == 'f' and 1 or 0,
        nationality = settings.nationality,
        phone = Q.phoneNumber(player.charId),
        account = Q.accountNumber(player.charId),
        cid = player.charId,
    }
end

local function buildMetadata(src, player)
    local meta = player.getMeta()
    local dead = meta.isDead == true or Player(src).state.isDead == true
    return Q.convertMetadata(meta, player.charId, dead)
end

-- extra[src] holds PlayerData keys QB scripts set that rps doesn't own (optin, custom fields)
local extra = {}

local function refreshPlayerData(qbPlayer)
    local pd = qbPlayer.PlayerData
    local src = pd.source
    local player = rpsPlayer(src, pd.cid)
    if not player then return end

    pd.citizenid = tostring(player.charId)
    pd.cid = player.charId
    pd.license = player.license
    pd.name = GetPlayerName(src) or pd.name
    pd.money = buildMoney(player)
    pd.charinfo = buildCharinfo(player)
    pd.job = Q.convertJob(player.getJob())
    pd.gang = Q.noGang()
    pd.metadata = buildMetadata(src, player)
    pd.items = inventoryOf(src)
    pd.position = deepCopy(player.getPosition())
    for k, v in pairs(extra[src] or {}) do pd[k] = v end
end

---Sends a change to the client and fires QB's update events (upstream UpdateClient)
local function pushUpdate(qbPlayer, key, value)
    local pd = qbPlayer.PlayerData
    if key then
        TriggerEvent('QBCore:Server:OnPlayerUpdated', pd.source, key, value)
        TriggerClientEvent('QBCore:Client:OnPlayerUpdated', pd.source, key, value)
    else
        pd.items = inventoryOf(pd.source)
        TriggerEvent('QBCore:Player:SetPlayerData', pd)
        TriggerEvent('QBCore:Server:OnPlayerUpdated', pd.source, 'all', pd)
        TriggerClientEvent('QBCore:Client:OnPlayerUpdated', pd.source, 'all', pd)
    end
end

---------------------------------------------------------------------------
-- QB Player object
---------------------------------------------------------------------------
local pendingMoneyOp = {} -- [src] = 'set' while SetMoney runs, so the money event reports it as QB does

local function createQBPlayer(src, charId)
    local self = { PlayerData = { source = src, cid = charId }, Offline = false, Functions = {} }
    local F = self.Functions
    extra[src] = extra[src] or { optin = true }

    local function live() return rpsPlayer(src, charId) end

    function F.GetPlayerData()
        self.PlayerData.items = inventoryOf(src)
        return self.PlayerData
    end

    function F.UpdateClient(key, value)
        if not live() then return end
        if key == nil then refreshPlayerData(self) end
        pushUpdate(self, key, value)
    end

    F.UpdatePlayerData = F.UpdateClient

    function F.SetJob(job, grade)
        local player = live()
        if not player or type(job) ~= 'string' then return false end
        return player.setJob(job:lower(), tonumber(grade) or 0)
    end

    -- RPS has no gangs
    function F.SetGang()
        return false
    end

    function F.SetJobDuty(onDuty)
        local player = live()
        if player then player.setDuty(onDuty and true or false) end
    end

    function F.Notify(text, notifyType, length)
        TriggerClientEvent('QBCore:Notify', src, text, notifyType, length)
    end

    function F.HasItem(items, amount)
        return Functions.HasItem(src, items, amount)
    end

    function F.GetName()
        local ci = self.PlayerData.charinfo or {}
        return ('%s %s'):format(ci.firstname, ci.lastname)
    end

    function F.SetMetaData(meta, value)
        local player = live()
        if not player or type(meta) ~= 'string' then return end
        if meta == 'hunger' or meta == 'thirst' then
            value = math.min(100, math.max(0, tonumber(value) or 0))
        end
        if meta == 'isdead' then
            -- rps_ambulance owns death: it sets isDead itself when the player goes down,
            -- and reviving has to go through it so the downed state bags clear too
            if not value and GetResourceState('rps_ambulance') == 'started' and exports.rps_ambulance:IsDead(src) then
                exports.rps_ambulance:Revive(src)
            end
            return
        end
        -- metaChanged refreshes PlayerData.metadata and notifies the client
        player.setMeta(Q.metaKeyToRps[meta] or meta, deepCopy(value))
    end

    function F.GetMetaData(meta)
        if type(meta) ~= 'string' then return end
        return self.PlayerData.metadata[meta]
    end

    function F.SetPlayerData(key, value)
        if type(key) ~= 'string' then return end
        if key == 'metadata' and type(value) == 'table' then
            for k, v in pairs(value) do
                if type(v) == 'table' or v ~= self.PlayerData.metadata[k] then F.SetMetaData(k, v) end
            end
        elseif key == 'job' and type(value) == 'table' then
            F.SetJob(value.name, type(value.grade) == 'table' and value.grade.level or value.grade)
        elseif key == 'money' and type(value) == 'table' then
            for account in pairs(ACCOUNTS) do
                if value[account] and value[account] ~= self.PlayerData.money[account] then F.SetMoney(account, value[account]) end
            end
        elseif key == 'gang' or key == 'items' or key == 'charinfo' or key == 'citizenid' or key == 'cid'
            or key == 'license' or key == 'source' or key == 'name' or key == 'position' then
            return -- owned by rps_core / ox_inventory
        else
            extra[src][key] = value
            self.PlayerData[key] = value
            pushUpdate(self, key, value)
        end
    end

    function F.AddRep(rep, amount)
        if not rep or not tonumber(amount) then return end
        local reps = deepCopy(self.PlayerData.metadata.rep or {})
        reps[rep] = (reps[rep] or 0) + tonumber(amount)
        F.SetMetaData('rep', reps)
    end

    function F.RemoveRep(rep, amount)
        if not rep or not tonumber(amount) then return end
        local reps = deepCopy(self.PlayerData.metadata.rep or {})
        reps[rep] = math.max(0, (reps[rep] or 0) - tonumber(amount))
        F.SetMetaData('rep', reps)
    end

    function F.GetRep(rep)
        if not rep then return end
        return (self.PlayerData.metadata.rep or {})[rep] or 0
    end

    -- Money: only cash and bank exist in rps; crypto always reads 0
    local function moneyArgs(moneytype, amount)
        moneytype = type(moneytype) == 'string' and moneytype:lower() or nil
        amount = tonumber(amount)
        return moneytype, amount
    end

    function F.AddMoney(moneytype, amount, reason)
        moneytype, amount = moneyArgs(moneytype, amount)
        if not amount or amount < 0 then return end
        local player = live()
        if not player or not ACCOUNTS[moneytype] then return false end
        if math.floor(amount) == 0 then return true end
        return player.addMoney(moneytype, amount, reason or 'unknown')
    end

    function F.RemoveMoney(moneytype, amount, reason)
        moneytype, amount = moneyArgs(moneytype, amount)
        if not amount or amount < 0 then return end
        local player = live()
        if not player or not ACCOUNTS[moneytype] then return false end
        if math.floor(amount) == 0 then return true end
        return player.removeMoney(moneytype, amount, reason or 'unknown')
    end

    function F.SetMoney(moneytype, amount, reason)
        moneytype, amount = moneyArgs(moneytype, amount)
        if not amount or amount < 0 then return false end
        local player = live()
        if not player or not ACCOUNTS[moneytype] then return false end
        pendingMoneyOp[src] = 'set'
        local ok = player.setMoney(moneytype, amount, reason or 'unknown')
        pendingMoneyOp[src] = nil
        return ok
    end

    function F.GetMoney(moneytype)
        if type(moneytype) ~= 'string' then return false end
        moneytype = moneytype:lower()
        local player = live()
        if player and ACCOUNTS[moneytype] then return player.getMoney(moneytype) end
        return self.PlayerData.money[moneytype]
    end

    -- Items (older QB API, now qb-inventory's; served by ox_inventory)
    function F.AddItem(item, amount, slot, info)
        local ok = ox('AddItem', src, item, tonumber(amount) or 1, info, tonumber(slot))
        return ok and true or false
    end

    function F.RemoveItem(item, amount, slot)
        local ok = ox('RemoveItem', src, item, tonumber(amount) or 1, nil, tonumber(slot))
        return ok and true or false
    end

    function F.GetItemByName(item)
        local slot = ox('GetSlotWithItem', src, item)
        return slot and Q.convertSlot(slot, sharedItems()) or nil
    end

    function F.GetItemsByName(item)
        local result = {}
        for _, slot in ipairs(ox('GetSlotsWithItem', src, item) or {}) do
            result[#result + 1] = Q.convertSlot(slot, sharedItems())
        end
        return result
    end

    function F.GetItemBySlot(slot)
        local data = ox('GetSlot', src, tonumber(slot))
        return data and Q.convertSlot(data, sharedItems()) or nil
    end

    function F.ClearInventory(filterItems)
        -- the money item mirrors rps cash, so it is never cleared here
        local keep = { 'money' }
        if type(filterItems) == 'string' then
            keep[2] = filterItems
        elseif type(filterItems) == 'table' then
            for _, name in pairs(filterItems) do keep[#keep + 1] = name end
        end
        ox('ClearInventory', src, keep)
    end

    -- No equivalents: ox_inventory owns item storage, and there are no bank cards
    function F.SetInventory() end
    function F.GetCardSlot() end
    function F.SetCreditCard() end

    function F.Save()
        -- saving waits on MySQL
        CreateThread(function()
            local player = live()
            if player then player.save() end
        end)
    end

    function F.Logout()
        if live() then exports.rps_core:Logout(src) end
    end

    function F.AddMethod(methodName, handler)
        if type(methodName) ~= 'string' or not Q.isCallable(handler) then return false end
        self[methodName] = handler
        F[methodName] = handler
        return true
    end

    function F.AddField(fieldName, data)
        if type(fieldName) ~= 'string' or Q.isCallable(data) then return false end
        self[fieldName] = data
        return true
    end

    refreshPlayerData(self)
    return self
end

---------------------------------------------------------------------------
-- Load / unload, driven by rps_core
---------------------------------------------------------------------------
local loadedSent = {} -- [src] = true once QBCore:Client:OnPlayerLoaded went out for this character
local dropped = {}

local function onPlayerLoaded(src)
    local player = Core.Players[src]
    if not player then return end

    local qbPlayer = createQBPlayer(src, player.charId)
    QBCore.Players[src] = qbPlayer
    QBCore.PlayersByCitizenId[qbPlayer.PlayerData.citizenid] = qbPlayer
    loadedSent[src] = nil

    TriggerEvent('QBCore:Server:PlayerLoaded', qbPlayer)
    -- the client answers with QBCore:Server:OnPlayerLoaded once it has spawned
    pushUpdate(qbPlayer)
    QBCore.Commands.Refresh(src)
end

AddEventHandler('rps_core:server:playerLoaded', onPlayerLoaded)

AddEventHandler('playerDropped', function()
    dropped[source] = true
end)

AddEventHandler('rps_core:server:playerUnloaded', function(src)
    local qbPlayer = QBCore.Players[src]
    if qbPlayer then
        if dropped[src] or not GetPlayerName(src) then
            TriggerEvent('QBCore:Server:PlayerDropped', src)
        end
        TriggerEvent('QBCore:Server:OnPlayerUnload', src)
        QBCore.PlayersByCitizenId[qbPlayer.PlayerData.citizenid] = nil
        QBCore.Players[src] = nil
        QBCore.Player_Buckets[qbPlayer.PlayerData.license] = nil
    end
    loadedSent[src] = nil
    pendingMoneyOp[src] = nil
    extra[src] = nil
    dropped[src] = nil
end)

-- Sent by our client (and by QB spawn scripts) once the character is in the world
RegisterNetEvent('QBCore:Server:OnPlayerLoaded', function()
    local src = source
    if not QBCore.Players[src] or loadedSent[src] then return end
    loadedSent[src] = true
    TriggerClientEvent('QBCore:Client:OnPlayerLoaded', src)
end)

AddEventHandler('rps_core:server:moneyChanged', function(src, account, balance, diff, reason)
    local qbPlayer = QBCore.Players[src]
    if not qbPlayer then return end
    qbPlayer.PlayerData.money[account] = balance

    local op, amount = pendingMoneyOp[src], math.abs(diff)
    if op == 'set' then
        amount = balance
    else
        op = diff >= 0 and 'add' or 'remove'
    end
    reason = reason or 'unknown'

    pushUpdate(qbPlayer, 'money', qbPlayer.PlayerData.money)
    TriggerClientEvent('hud:client:OnMoneyChange', src, account, math.abs(diff), diff < 0)
    TriggerClientEvent('QBCore:Client:OnMoneyChange', src, account, amount, op, reason)
    TriggerEvent('QBCore:Server:OnMoneyChange', src, account, amount, op, reason)
end)

AddEventHandler('rps_core:server:jobChanged', function(src, new, old)
    local qbPlayer = QBCore.Players[src]
    if not qbPlayer then return end
    qbPlayer.PlayerData.job = Q.convertJob(new)
    pushUpdate(qbPlayer, 'job', qbPlayer.PlayerData.job)

    if old and old.onduty ~= new.onduty then
        TriggerEvent('QBCore:Server:SetDuty', src, new.onduty)
        TriggerClientEvent('QBCore:Client:SetDuty', src, new.onduty)
    end
end)

AddEventHandler('rps_core:server:metaChanged', function(src)
    local qbPlayer = QBCore.Players[src]
    local player = qbPlayer and rpsPlayer(src, qbPlayer.PlayerData.cid)
    if not player then return end
    qbPlayer.PlayerData.metadata = buildMetadata(src, player)
    pushUpdate(qbPlayer, 'metadata', qbPlayer.PlayerData.metadata)
end)

-- Re-fires QB's older per-field events, as upstream does
AddEventHandler('QBCore:Server:OnPlayerUpdated', function(src, key, value)
    if key == 'job' then
        TriggerEvent('QBCore:Server:OnJobUpdate', src, value)
    elseif key == 'gang' then
        TriggerEvent('QBCore:Server:OnGangUpdate', src, value)
    elseif key == 'all' then
        TriggerEvent('QBCore:Server:OnJobUpdate', src, value.job)
        TriggerEvent('QBCore:Server:OnGangUpdate', src, value.gang)
    end
end)

---------------------------------------------------------------------------
-- Getters
---------------------------------------------------------------------------
function Functions.GetCoords(entity)
    local coords = GetEntityCoords(entity)
    return vector4(coords.x, coords.y, coords.z, GetEntityHeading(entity))
end

function Functions.GetIdentifier(source, idtype)
    return GetPlayerIdentifierByType(source, idtype or 'license')
end

function Functions.GetSource(identifier)
    for src in pairs(QBCore.Players) do
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if id == identifier then return src end
        end
    end
    return 0
end

local function getPlayer(source)
    local src = tonumber(source)
    local qbPlayer = QBCore.Players[src or Functions.GetSource(source)]
    if qbPlayer then qbPlayer.PlayerData.items = inventoryOf(qbPlayer.PlayerData.source) end
    return qbPlayer
end

Functions.GetPlayer = getPlayer

function Functions.GetPlayerByCitizenId(citizenid)
    local qbPlayer = QBCore.PlayersByCitizenId[tostring(citizenid)]
    return qbPlayer and getPlayer(qbPlayer.PlayerData.source)
end

-- Offline characters would need database reads (which yield); not supported
function Functions.GetOfflinePlayerByCitizenId() return nil end
function Functions.GetOfflinePlayerByLicense() return nil end

function Functions.GetPlayerByLicense(license)
    for src, qbPlayer in pairs(QBCore.Players) do
        if qbPlayer.PlayerData.license == license then return getPlayer(src) end
    end
end

local function findByCharinfo(property, value)
    for src, qbPlayer in pairs(QBCore.Players) do
        local charinfo = qbPlayer.PlayerData.charinfo
        if charinfo[property] ~= nil and charinfo[property] == value then return getPlayer(src) end
    end
end

function Functions.GetPlayerByPhone(number) return findByCharinfo('phone', tostring(number)) end
function Functions.GetPlayerByAccount(account) return findByCharinfo('account', account) end
Functions.GetPlayerByCharInfo = findByCharinfo

function Functions.GetPlayers()
    local sources = {}
    for src in pairs(QBCore.Players) do sources[#sources + 1] = src end
    return sources
end

function Functions.GetQBPlayers()
    return QBCore.Players
end

function Functions.GetPlayersByJob(job, checkOnDuty)
    local players, count = {}, 0
    for src, qbPlayer in pairs(QBCore.Players) do
        local pj = qbPlayer.PlayerData.job
        if (pj.name == job or pj.type == job) and (not checkOnDuty or pj.onduty) then
            count += 1
            players[count] = src
        end
    end
    return players, count
end

function Functions.GetPlayersOnDuty(job)
    return Functions.GetPlayersByJob(job, true)
end

function Functions.GetDutyCount(job)
    local _, count = Functions.GetPlayersByJob(job, true)
    return count
end

local function toVec3(coords)
    return vector3(coords.x, coords.y, coords.z)
end

local function closestOf(source, coords, list, skip)
    coords = coords and toVec3(coords) or GetEntityCoords(GetPlayerPed(source))
    local closest, closestDist = -1, -1
    for i = 1, #list do
        local entity = list[i]
        if entity ~= skip then
            local dist = #(GetEntityCoords(entity) - coords)
            if closestDist == -1 or dist < closestDist then closest, closestDist = entity, dist end
        end
    end
    return closest, closestDist
end

function Functions.GetClosestPlayer(source, coords)
    local ped = GetPlayerPed(source)
    coords = coords and toVec3(coords) or GetEntityCoords(ped)
    local closest, closestDist = -1, -1
    for _, id in ipairs(GetPlayers()) do
        local otherPed = GetPlayerPed(id)
        if otherPed ~= ped then
            local dist = #(GetEntityCoords(otherPed) - coords)
            if closestDist == -1 or dist < closestDist then closest, closestDist = tonumber(id), dist end
        end
    end
    return closest, closestDist
end

function Functions.GetClosestObject(source, coords)
    return closestOf(source, coords, GetAllObjects())
end

function Functions.GetClosestVehicle(source, coords)
    return closestOf(source, coords, GetAllVehicles())
end

function Functions.GetClosestPed(source, coords)
    return closestOf(source, coords, GetAllPeds(), GetPlayerPed(source))
end

---------------------------------------------------------------------------
-- Routing buckets
---------------------------------------------------------------------------
function Functions.GetBucketObjects()
    return QBCore.Player_Buckets, QBCore.Entity_Buckets
end

function Functions.SetPlayerBucket(source, bucket)
    if not source or not bucket then return false end
    Player(source).state:set('instance', bucket, true)
    SetPlayerRoutingBucket(source, bucket)
    QBCore.Player_Buckets[Functions.GetIdentifier(source, 'license')] = { id = source, bucket = bucket }
    return true
end

function Functions.SetEntityBucket(entity, bucket)
    if not entity or not bucket then return false end
    SetEntityRoutingBucket(entity, bucket)
    QBCore.Entity_Buckets[entity] = { id = entity, bucket = bucket }
    return true
end

function Functions.GetPlayersInBucket(bucket)
    local list = {}
    for _, v in pairs(QBCore.Player_Buckets) do
        if v.bucket == bucket then list[#list + 1] = v.id end
    end
    return list
end

function Functions.GetEntitiesInBucket(bucket)
    local list = {}
    for _, v in pairs(QBCore.Entity_Buckets) do
        if v.bucket == bucket then list[#list + 1] = v.id end
    end
    return list
end

---------------------------------------------------------------------------
-- Vehicles. Upstream waits for the entity here; these return straight away
-- (callers in other resources can't be yielded) and warp from a thread.
---------------------------------------------------------------------------
local function spawnArgs(source, model, coords)
    model = type(model) == 'string' and joaat(model) or model
    coords = coords or GetEntityCoords(GetPlayerPed(source))
    return model, coords, (coords.w or 0.0) + 0.0
end

local function warpInto(source, veh)
    CreateThread(function()
        local ped = GetPlayerPed(source)
        for _ = 1, 100 do
            if not DoesEntityExist(veh) or GetVehiclePedIsIn(ped, false) == veh then return end
            TaskWarpPedIntoVehicle(ped, veh, -1)
            Wait(0)
        end
    end)
end

function Functions.SpawnVehicle(source, model, coords, warp)
    local hash, pos, heading = spawnArgs(source, model, coords)
    local veh = CreateVehicle(hash, pos.x, pos.y, pos.z, heading, true, true)
    if warp then warpInto(source, veh) end
    return veh
end

function Functions.CreateAutomobile(source, model, coords, warp)
    local hash, pos, heading = spawnArgs(source, model, coords)
    local veh = Citizen.InvokeNative(`CREATE_AUTOMOBILE`, hash, pos.x, pos.y, pos.z, heading, true, true)
    if warp then warpInto(source, veh) end
    return veh
end

function Functions.CreateVehicle(source, model, vehtype, coords, warp)
    local hash, pos, heading = spawnArgs(source, model, coords)
    local veh = CreateVehicleServerSetter(hash, vehtype or 'automobile', pos.x, pos.y, pos.z, heading)
    if warp then warpInto(source, veh) end
    return veh
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
function Functions.CreateCallback(name, cb)
    QBCore.ServerCallbacks[name] = cb
end

local pendingClientCallbacks = {} -- [name .. source] = cb

-- Upstream awaits the answer when no cb is given; a yield can't cross back into
-- the calling resource, so only the callback form is supported.
function Functions.TriggerClientCallback(name, source, ...)
    if not source then return end
    local args = table.pack(...)
    local cb
    if Q.isCallable(args[1]) then
        cb = args[1]
        table.remove(args, 1)
        args.n -= 1
    else
        print(('^3[qb-core] TriggerClientCallback(%s) without a callback function is not supported on RPS^0'):format(name))
    end
    pendingClientCallbacks[name .. source] = cb or false
    TriggerClientEvent('QBCore:Client:TriggerClientCallback', source, name, table.unpack(args, 1, args.n))
end

RegisterNetEvent('QBCore:Server:TriggerClientCallback', function(name, ...)
    local key = tostring(name) .. source
    local cb = pendingClientCallbacks[key]
    if cb == nil then return end
    pendingClientCallbacks[key] = nil
    if cb then cb(...) end
end)

RegisterNetEvent('QBCore:Server:TriggerCallback', function(name, ...)
    local cb = QBCore.ServerCallbacks[name]
    if not cb then return end
    local src = source
    cb(src, function(...)
        TriggerClientEvent('QBCore:Client:TriggerCallback', src, name, ...)
    end, ...)
end)

local function spawnCallback(spawner)
    return function(source, cb, model, coords, warp)
        local veh = spawner(source, model, coords, warp)
        CreateThread(function()
            for _ = 1, 100 do
                if DoesEntityExist(veh) then break end
                Wait(10)
            end
            cb(DoesEntityExist(veh) and NetworkGetNetworkIdFromEntity(veh) or nil)
        end)
    end
end

Functions.CreateCallback('QBCore:Server:SpawnVehicle', spawnCallback(Functions.SpawnVehicle))
Functions.CreateCallback('QBCore:Server:CreateVehicle', spawnCallback(Functions.CreateAutomobile))

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------
function Functions.CreateUseableItem(item, data)
    local fn
    if Q.isCallable(data) then
        fn = data
    elseif type(data) == 'table' then
        fn = Q.isCallable(data.cb) and data.cb or Q.isCallable(data.callback) and data.callback or nil
    end
    if not fn then return end

    local resource = GetInvokingResource()
    QBCore.UsableItems[item] = { func = fn, resource = resource }
    -- looked up on use, so a stopped resource's callback is simply skipped
    Core.RegisterUsableItem(item, function(src, qbItem)
        local entry = QBCore.UsableItems[item]
        if entry then entry.func(src, qbItem) end
    end, 'qb', resource)
end

function Functions.CanUseItem(item)
    local entry = QBCore.UsableItems[item]
    if entry then return entry end
    -- registered through the Qbox bridge, which uses the same calling style
    local registered = Core.UsableItems[item]
    if registered and registered.style == 'qb' then
        return { func = registered.cb, resource = registered.resource }
    end
end

function Functions.UseItem(source, item)
    local name = type(item) == 'table' and item.name or item
    if type(name) ~= 'string' then return end
    local slot = type(item) == 'table' and item.slot and ox('GetSlot', source, item.slot)
    slot = slot or ox('GetSlotWithItem', source, name)
    if slot then Core.UseItem(source, name, slot) end
end

function Functions.HasItem(source, items, amount)
    return Q.hasItems(function(name) return itemCount(source, name) end, items, amount)
end

AddEventHandler('onResourceStop', function(resource)
    for name, entry in pairs(QBCore.UsableItems) do
        if entry.resource == resource then QBCore.UsableItems[name] = nil end
    end
    for name, entry in pairs(QBCore.Commands.List) do
        if entry.resource == resource then QBCore.Commands.List[name] = nil end
    end
end)

---------------------------------------------------------------------------
-- Permissions: QB levels map onto rps groups (god -> admin)
---------------------------------------------------------------------------
local function groupFor(permission)
    permission = permission:lower()
    return settings.permissionGroups[permission] or (Core.IsValidGroup(permission) and permission) or nil
end

local function hasPermission(source, permission)
    source = tonumber(source)
    if source == 0 then return true end
    if type(permission) == 'table' then
        for _, perm in pairs(permission) do
            if hasPermission(source, perm) then return true end
        end
        return false
    end
    if type(permission) ~= 'string' then return false end
    if permission:lower() == 'user' then return true end
    local group = groupFor(permission)
    if group then return Core.HasGroup(source, group) end
    return IsPlayerAceAllowed(source, permission)
end

Functions.HasPermission = hasPermission

function Functions.AddPermission(source, permission)
    local player = Core.GetPlayer(source)
    local group = type(permission) == 'string' and groupFor(permission)
    if not player or not group then return end
    if not Core.HasGroup(source, group) then player.setGroup(group) end
    QBCore.Commands.Refresh(source)
end

function Functions.RemovePermission(source, permission)
    local player = Core.GetPlayer(source)
    if not player then return end
    local group = type(permission) == 'string' and groupFor(permission)
    -- only the group being removed: removing 'mod' must not demote an admin
    if not permission or (group and player.getGroup() == group) then
        player.setGroup(Config.DefaultGroup)
        QBCore.Commands.Refresh(source)
    end
end

function Functions.GetPermission(source)
    local perms = {}
    for _, perm in ipairs(QBCore.Config.Server.Permissions) do
        if hasPermission(source, perm) then perms[perm] = true end
    end
    return perms
end

function Functions.IsWhitelisted()
    return true
end

-- Admin report opt-in; kept for the session only
function Functions.IsOptin(source)
    if not hasPermission(source, 'admin') then return false end
    local data = extra[tonumber(source)]
    return data ~= nil and data.optin ~= false
end

function Functions.ToggleOptin(source)
    local qbPlayer = QBCore.Players[tonumber(source)]
    if not qbPlayer or not hasPermission(source, 'admin') then return end
    qbPlayer.Functions.SetPlayerData('optin', not Functions.IsOptin(source))
end

-- Bans and connection checks belong to rps_core / txAdmin
function Functions.IsPlayerBanned() return false end
function Functions.IsLicenseInUse(license)
    for _, id in ipairs(GetPlayers()) do
        if GetPlayerIdentifierByType(id, 'license') == license then return true end
    end
    return false
end

function Functions.GetDatabaseInfo()
    local conn = GetConvar('mysql_connection_string', '')
    local db = conn:match('mysql://[^/]+/([^%?]+)') or conn:match('database=([^;]+)')
    return { exists = db ~= nil, database = db or '' }
end

function Functions.Kick(source, reason, setKickReason, deferrals)
    reason = ('\n%s\n'):format(reason or 'Kicked')
    if setKickReason then setKickReason(reason) end
    CreateThread(function()
        if deferrals then
            deferrals.update(reason)
            Wait(2500)
        end
        if source then DropPlayer(source, reason) end
    end)
end

function Functions.Notify(source, text, notifyType, length)
    TriggerClientEvent('QBCore:Notify', source, text, notifyType, length)
end

-- Random, without upstream's database uniqueness check (that query would yield)
function Functions.CreateAccountNumber()
    return ('US0%dRPS%s'):format(math.random(1, 9), QBCore.Shared.RandomInt(8))
end

function Functions.CreatePhoneNumber()
    return settings.phonePrefix .. QBCore.Shared.RandomInt(7)
end

function Functions.AddPlayerMethod(ids, methodName, handler)
    local function apply(id)
        if id == -1 then
            for _, qbPlayer in pairs(QBCore.Players) do qbPlayer.Functions.AddMethod(methodName, handler) end
        elseif QBCore.Players[id] then
            QBCore.Players[id].Functions.AddMethod(methodName, handler)
        end
    end
    if type(ids) == 'table' then for _, id in ipairs(ids) do apply(id) end else apply(ids) end
end

function Functions.AddPlayerField(ids, fieldName, data)
    local function apply(id)
        if id == -1 then
            for _, qbPlayer in pairs(QBCore.Players) do qbPlayer.Functions.AddField(fieldName, data) end
        elseif QBCore.Players[id] then
            QBCore.Players[id].Functions.AddField(fieldName, data)
        end
    end
    if type(ids) == 'table' then for _, id in ipairs(ids) do apply(id) end else apply(ids) end
end

---------------------------------------------------------------------------
-- Runtime Shared / object edits (upstream server/exports.lua). These only
-- change the QB view: a job added here still can't be set through rps_core.
---------------------------------------------------------------------------
local function sharedSetter(tableName, mustExist)
    return function(key, value)
        if type(key) ~= 'string' then return false, ('invalid_%s_name'):format(tableName:lower():sub(1, -2)) end
        local exists = QBCore.Shared[tableName][key] ~= nil
        if mustExist and not exists then return false, ('%s_not_exists'):format(tableName:lower():sub(1, -2)) end
        if not mustExist and exists then return false, ('%s_exists'):format(tableName:lower():sub(1, -2)) end
        QBCore.Shared[tableName][key] = value
        TriggerClientEvent('QBCore:Client:OnSharedUpdate', -1, tableName, key, value)
        TriggerEvent('QBCore:Server:UpdateObject')
        return true, 'success'
    end
end

local function sharedMultiAdder(tableName)
    return function(values)
        for key, value in pairs(values) do
            if type(key) ~= 'string' then return false, ('invalid_%s_name'):format(tableName:lower():sub(1, -2)), value end
            if QBCore.Shared[tableName][key] then return false, ('%s_exists'):format(tableName:lower():sub(1, -2)), value end
        end
        for key, value in pairs(values) do QBCore.Shared[tableName][key] = value end
        TriggerClientEvent('QBCore:Client:OnSharedUpdateMultiple', -1, tableName, values)
        TriggerEvent('QBCore:Server:UpdateObject')
        return true, 'success', nil
    end
end

local function sharedRemover(tableName)
    return function(key)
        if type(key) ~= 'string' then return false, ('invalid_%s_name'):format(tableName:lower():sub(1, -2)) end
        if not QBCore.Shared[tableName][key] then return false, ('%s_not_exists'):format(tableName:lower():sub(1, -2)) end
        QBCore.Shared[tableName][key] = nil
        TriggerClientEvent('QBCore:Client:OnSharedUpdate', -1, tableName, key, nil)
        TriggerEvent('QBCore:Server:UpdateObject')
        return true, 'success'
    end
end

function Functions.SetMethod(methodName, handler)
    if type(methodName) ~= 'string' then return false, 'invalid_method_name' end
    if Functions[methodName] ~= nil then return false, 'method_exists' end
    Functions[methodName] = handler
    TriggerEvent('QBCore:Server:UpdateObject')
    return true, 'success'
end

function Functions.SetField(fieldName, data)
    if type(fieldName) ~= 'string' then return false, 'invalid_field_name' end
    if QBCore[fieldName] ~= nil then return false, 'field_exists' end
    QBCore[fieldName] = data
    TriggerEvent('QBCore:Server:UpdateObject')
    return true, 'success'
end

Functions.AddJob = sharedSetter('Jobs', false)
Functions.UpdateJob = sharedSetter('Jobs', true)
Functions.AddJobs = sharedMultiAdder('Jobs')
Functions.RemoveJob = sharedRemover('Jobs')
Functions.AddGang = sharedSetter('Gangs', false)
Functions.UpdateGang = sharedSetter('Gangs', true)
Functions.AddGangs = sharedMultiAdder('Gangs')
Functions.RemoveGang = sharedRemover('Gangs')
Functions.AddItem = sharedSetter('Items', false)
Functions.UpdateItem = sharedSetter('Items', true)
Functions.AddItems = sharedMultiAdder('Items')
Functions.RemoveItem = sharedRemover('Items')

function Functions.GetCoreVersion()
    return Q.version
end

---------------------------------------------------------------------------
-- QBCore.Player (login / persistence internals; rps_core owns these)
---------------------------------------------------------------------------
local QBPlayerApi = QBCore.Player

function QBPlayerApi.Login() return false end -- character selection is rps_multicharacter's

function QBPlayerApi.Logout(source)
    if Core.GetPlayer(source) then exports.rps_core:Logout(source) end
end

function QBPlayerApi.Save(source)
    local qbPlayer = QBCore.Players[tonumber(source)]
    if qbPlayer then qbPlayer.Functions.Save() end
end

function QBPlayerApi.SaveOffline() end
function QBPlayerApi.GetOfflinePlayer() return nil end
function QBPlayerApi.GetOfflinePlayerByLicense() return nil end
QBPlayerApi.GetPlayerByLicense = Functions.GetPlayerByLicense
function QBPlayerApi.DeleteCharacter() end
function QBPlayerApi.ForceDeleteCharacter() end

function QBPlayerApi.CreateCitizenId()
    return (QBCore.Shared.RandomStr(3) .. QBCore.Shared.RandomInt(5)):upper()
end

function QBPlayerApi.CreateFingerId()
    return QBCore.Shared.RandomStr(2) .. QBCore.Shared.RandomInt(3) .. QBCore.Shared.RandomStr(1)
        .. QBCore.Shared.RandomInt(2) .. QBCore.Shared.RandomStr(3) .. QBCore.Shared.RandomInt(4)
end

function QBPlayerApi.CreateWalletId()
    return 'QB-' .. math.random(11111111, 99999999)
end

function QBPlayerApi.CreateSerialNumber()
    return math.random(11111111, 99999999)
end

---------------------------------------------------------------------------
-- Commands: RegisterCommand + rps group check ('user' = everyone)
---------------------------------------------------------------------------
local Commands = QBCore.Commands

local function canUseCommand(source, entry)
    return source == 0 or hasPermission(source, entry.permission)
end

local function suggestion(name, entry)
    return { name = '/' .. name, help = entry.help, params = entry.arguments }
end

function Commands.Add(name, help, arguments, argsrequired, callback, permission, ...)
    if type(name) ~= 'string' or not Q.isCallable(callback) then return end
    name = name:lower()
    arguments = type(arguments) == 'table' and arguments or {}

    if select('#', ...) > 0 then
        permission = { permission or 'user', ... }
    else
        permission = type(permission) == 'string' and permission:lower() or 'user'
    end

    local entry = {
        name = name,
        permission = permission,
        help = help,
        arguments = arguments,
        argsrequired = argsrequired,
        callback = callback,
        resource = GetInvokingResource(),
    }
    Commands.List[name] = entry

    RegisterCommand(name, function(source, args, rawCommand)
        -- re-registered or its resource stopped
        if Commands.List[name] ~= entry then return end

        if not canUseCommand(source, entry) then
            return TriggerClientEvent('QBCore:Notify', source, 'No access to this command', 'error')
        end

        if argsrequired and #args < #arguments then
            return TriggerClientEvent('chat:addMessage', source, {
                color = { 255, 0, 0 },
                multiline = true,
                args = { 'System', 'All arguments must be filled out!' },
            })
        end

        TriggerEvent('QBCore:Server:PreCommandExecution', source, name, args, rawCommand)
        if WasEventCanceled() then return end

        callback(source, args, rawCommand)
    end, false)

    for src in pairs(QBCore.Players) do
        if canUseCommand(src, entry) then
            TriggerClientEvent('chat:addSuggestion', src, '/' .. name, help, arguments)
        end
    end
end

function Commands.Refresh(source)
    local src = tonumber(source)
    if not src or not QBCore.Players[src] then return end
    local suggestions = {}
    for name, entry in pairs(Commands.List) do
        if canUseCommand(src, entry) then
            suggestions[#suggestions + 1] = suggestion(name, entry)
        else
            TriggerClientEvent('chat:removeSuggestion', src, '/' .. name)
        end
    end
    TriggerClientEvent('chat:addSuggestions', src, suggestions)
end

-- Non-chat command calls (qb-adminmenu and similar)
RegisterNetEvent('QBCore:CallCommand', function(command, args)
    local src = source
    local entry = type(command) == 'string' and Commands.List[command:lower()]
    if not entry or not QBCore.Players[src] then return end
    if not canUseCommand(src, entry) then
        return TriggerClientEvent('QBCore:Notify', src, 'No access to this command', 'error')
    end
    args = type(args) == 'table' and args or {}
    if entry.argsrequired and #entry.arguments > 0 and args[#entry.arguments] == nil then
        return TriggerClientEvent('QBCore:Notify', src, 'All arguments must be filled out!', 'error')
    end
    entry.callback(src, args)
end)

---------------------------------------------------------------------------
-- Client-triggered events
---------------------------------------------------------------------------
RegisterNetEvent('QBCore:ToggleDuty', function()
    local src = source
    local player = Core.GetPlayer(src)
    if not player then return end
    local onduty = not player.getJob().onduty
    player.setDuty(onduty) -- jobChanged sends QBCore:Client:SetDuty / QBCore:Server:SetDuty
    TriggerClientEvent('QBCore:Notify', src, onduty and 'You are now on duty!' or 'You are now off duty!')
end)

-- Older qb-core let clients set any metadata; only hunger/thirst (clamped) are accepted
RegisterNetEvent('QBCore:Server:SetMetaData', function(meta, value)
    local qbPlayer = QBCore.Players[source]
    if not qbPlayer or (meta ~= 'hunger' and meta ~= 'thirst') or type(value) ~= 'number' then return end
    qbPlayer.Functions.SetMetaData(meta, value)
end)

local function vehicleInfo(eventName)
    return function(veh, seat, modelName)
        TriggerClientEvent('QBCore:Client:VehicleInfo', source, {
            vehicle = veh, seat = seat, name = modelName, event = eventName,
        })
    end
end

RegisterNetEvent('baseevents:enteringVehicle', vehicleInfo('Entering'))
RegisterNetEvent('baseevents:enteredVehicle', vehicleInfo('Entered'))
RegisterNetEvent('baseevents:leftVehicle', vehicleInfo('Left'))
RegisterNetEvent('baseevents:enteringAborted', function()
    TriggerClientEvent('QBCore:Client:AbortVehicleEntering', source)
end)

---------------------------------------------------------------------------
-- Debug helpers
---------------------------------------------------------------------------
local function debugPrint(resource, tbl)
    local ok, text = pcall(json.encode, tbl, { indent = true })
    print(('^4[ %s : DEBUG]^0'):format(resource))
    print(ok and text or tostring(tbl))
    print('^4[ END DEBUG ]^0')
end

function QBCore.Debug(tbl)
    debugPrint(GetInvokingResource() or 'qb-core', tbl)
end

function QBCore.ShowError(resource, msg)
    print(('^1[%s:ERROR]^0 %s'):format(resource, msg))
end

function QBCore.ShowSuccess(resource, msg)
    print(('^2[%s:LOG]^0 %s'):format(resource, msg))
end

RegisterNetEvent('QBCore:DebugSomething', function(tbl, _, resource)
    debugPrint(tostring(resource or 'unknown'), tbl)
end)

---------------------------------------------------------------------------
-- Core object and exports
---------------------------------------------------------------------------
local function getCoreObject(filters)
    sharedItems()
    if type(filters) ~= 'table' then return QBCore end
    local results = {}
    for _, key in ipairs(filters) do
        if QBCore[key] ~= nil then results[key] = QBCore[key] end
    end
    return results
end

export('GetCoreObject', getCoreObject)

export('GetShared', function(namespace, item)
    if namespace == 'Items' then sharedItems() end
    local ns = QBCore.Shared[namespace]
    if not ns then return nil end
    return item and ns[item] or ns
end)

-- Deprecated, still used by old scripts: TriggerEvent('QBCore:GetObject', function(obj) ... end)
AddEventHandler('QBCore:GetObject', function(cb)
    if Q.isCallable(cb) then cb(getCoreObject()) end
end)

export('ExploitBan', function(playerId, origin)
    print(('^1[qb-core] %s dropped for exploiting: %s^0'):format(GetPlayerName(playerId), origin))
    DropPlayer(playerId, 'You were kicked for exploiting')
end)

for name, fn in pairs(Functions) do
    if type(fn) == 'function' then export(name, fn) end
end
