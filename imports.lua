-- ESX compatibility include: shared_script '@es_extended/imports.lua'
-- (or '@rps_core/imports.lua'). Runs inside the including resource and defines
-- the global ESX there, like es_extended's imports.lua. The ESX object comes
-- from rps_core's ESX bridge; this file only keeps the local copy current and
-- replaces the blocking helpers with versions that wait in this resource.

ESX = exports.es_extended:getSharedObject()
ESX.currentResourceName = GetCurrentResourceName()

-- events from the bridge come from rps_core (or es_extended if it is a real resource)
local function fromBridge(resource)
    return resource == 'rps_core' or resource == 'es_extended'
end

local function isCallable(value)
    return type(value) == 'function' or type(value) == 'table'
end

-- Calls fn(done) and waits here for done(...): the bridge never yields across resources
local function awaitCall(fn)
    local p = promise.new()
    fn(function(...) p:resolve(table.pack(...)) end)
    local result = Citizen.Await(p)
    return table.unpack(result, 1, result.n)
end

if not IsDuplicityVersion() then
    OnPlayerData = function(key, val, last) end

    -- ESX.PlayerData.coords is always the live ped position
    local function trackCoords()
        if type(ESX.PlayerData) ~= 'table' then ESX.PlayerData = {} end
        ESX.PlayerData.coords = nil
        setmetatable(ESX.PlayerData, {
            __index = function(_, key)
                if key == 'coords' then return GetEntityCoords(PlayerPedId()) end
            end,
        })
    end

    trackCoords()

    AddEventHandler('esx:setPlayerData', function(key, val, last)
        if not fromBridge(GetInvokingResource()) then return end
        ESX.PlayerData[key] = val
        if OnPlayerData then OnPlayerData(key, val, last) end
    end)

    RegisterNetEvent('esx:playerLoaded', function(xPlayer)
        ESX.PlayerData = xPlayer
        ESX.PlayerLoaded = true
        trackCoords()
    end)

    RegisterNetEvent('esx:onPlayerLogout', function()
        ESX.PlayerLoaded = false
        ESX.PlayerData = {}
        trackCoords()
    end)

    local remote = ESX.TriggerServerCallback

    function ESX.AwaitServerCallback(name, ...)
        local args = table.pack(...)
        return awaitCall(function(done) remote(name, done, table.unpack(args, 1, args.n)) end)
    end

    -- asset loaders: with cb they return at once, without one they wait here
    for _, fnName in ipairs({ 'RequestModel', 'RequestStreamedTextureDict', 'RequestNamedPtfxAsset', 'RequestAnimSet', 'RequestAnimDict', 'RequestWeaponAsset' }) do
        local original = ESX.Streaming and ESX.Streaming[fnName]
        if original then
            ESX.Streaming[fnName] = function(asset, cb)
                if isCallable(cb) then return original(asset, cb) end
                return awaitCall(function(done) original(asset, done) end)
            end
        end
    end

    local Game = ESX.Game or {}

    local spawnVehicle, spawnLocalVehicle = Game.SpawnVehicle, Game.SpawnLocalVehicle
    local spawnObject, spawnLocalObject = Game.SpawnObject, Game.SpawnLocalObject
    local getPedMugshot, teleport = Game.GetPedMugshot, Game.Teleport

    function Game.SpawnVehicle(model, coords, heading, cb, networked)
        if isCallable(cb) then return spawnVehicle(model, coords, heading, cb, networked) end
        return awaitCall(function(done) spawnVehicle(model, coords, heading, done, networked) end)
    end

    function Game.SpawnLocalVehicle(model, coords, heading, cb)
        if isCallable(cb) then return spawnLocalVehicle(model, coords, heading, cb) end
        return awaitCall(function(done) spawnLocalVehicle(model, coords, heading, done) end)
    end

    function Game.SpawnObject(object, coords, cb, networked)
        if isCallable(cb) then return spawnObject(object, coords, cb, networked) end
        return awaitCall(function(done) spawnObject(object, coords, done, networked) end)
    end

    function Game.SpawnLocalObject(object, coords, cb)
        if isCallable(cb) then return spawnLocalObject(object, coords, cb) end
        return awaitCall(function(done) spawnLocalObject(object, coords, done) end)
    end

    function Game.GetPedMugshot(ped, transparent)
        return awaitCall(function(done) getPedMugshot(ped, transparent, done) end)
    end

    function Game.Teleport(entity, coords, cb)
        if isCallable(cb) then return teleport(entity, coords, cb) end
        return awaitCall(function(done) teleport(entity, coords, done) end)
    end
else
    local function createStaticPlayer(src)
        return setmetatable({ src = src }, {
            __index = function(self, method)
                return function(...)
                    return exports.es_extended:RunStaticPlayerMethod(self.src, method, ...)
                end
            end,
        })
    end

    function ESX.Player(src)
        if type(src) ~= 'number' then
            src = ESX.GetPlayerIdFromIdentifier(src)
            if not src then return end
        elseif not ESX.IsPlayerLoaded(src) then
            return
        end
        return createStaticPlayer(src)
    end

    function ESX.ExtendedPlayers(key, val)
        local ids = ESX.GetExtendedPlayers(key, val, true)
        local out = {}
        if key and type(val) == 'table' then
            for group, list in pairs(ids) do
                out[group] = {}
                for i = 1, #list do out[group][i] = createStaticPlayer(list[i]) end
            end
        else
            for i = 1, #ids do out[i] = createStaticPlayer(ids[i]) end
        end
        return out
    end

    local remote = ESX.TriggerClientCallback

    function ESX.AwaitClientCallback(player, name, ...)
        local args = table.pack(...)
        return awaitCall(function(done) remote(player, name, done, table.unpack(args, 1, args.n)) end)
    end

    local OneSync = ESX.OneSync or {}
    local spawnVehicle, spawnObject = OneSync.SpawnVehicle, OneSync.SpawnObject
    local spawnPed, spawnPedInVehicle = OneSync.SpawnPed, OneSync.SpawnPedInVehicle

    function OneSync.SpawnVehicle(model, coords, heading, props, cb, vehicleType)
        if isCallable(cb) then return spawnVehicle(model, coords, heading, props, cb, vehicleType) end
        if type(cb) == 'string' and not vehicleType then vehicleType = cb end
        return awaitCall(function(done) spawnVehicle(model, coords, heading, props, done, vehicleType) end)
    end

    function OneSync.SpawnObject(model, coords, heading, cb)
        if isCallable(cb) then return spawnObject(model, coords, heading, cb) end
        return awaitCall(function(done) spawnObject(model, coords, heading, done) end)
    end

    function OneSync.SpawnPed(model, coords, heading, cb)
        if isCallable(cb) then return spawnPed(model, coords, heading, cb) end
        return awaitCall(function(done) spawnPed(model, coords, heading, done) end)
    end

    function OneSync.SpawnPedInVehicle(model, vehicle, seat, cb)
        if isCallable(cb) then return spawnPedInVehicle(model, vehicle, seat, cb) end
        return awaitCall(function(done) spawnPedInVehicle(model, vehicle, seat, done) end)
    end
end
