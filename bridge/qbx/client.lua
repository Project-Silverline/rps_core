-- Qbox (qbx_core) bridge, client side. Answers exports.qbx_core:* from inside rps_core.

local Q = require 'bridge.qbx.shared'
local export = Q.export

local QBCore

-- Fetched lazily: the QB bridge may load after this file.
local function core()
    if not QBCore then QBCore = exports['qb-core']:GetCoreObject() end
    return QBCore
end

---QB PlayerData with Qbox's jobs / gangs fields, read fresh each time
local function getPlayerData()
    if not IsLoaded then return {} end
    local data = core().Functions.GetPlayerData()
    return type(data) == 'table' and Q.decorate(data) or {}
end

export('GetPlayerData', getPlayerData)

export('Notify', function(...)
    lib.notify(Q.notifyData(...))
end)

export('HasPrimaryGroup', function(filter)
    return Q.hasGroup(filter, getPlayerData(), true)
end)

export('HasGroup', function(filter)
    return Q.hasGroup(filter, getPlayerData())
end)

export('GetGroups', function()
    return Q.getPlayerGroups(getPlayerData())
end)

export('GetJobs', Q.getJobs)
export('GetJob', Q.getJob)
export('GetGangs', Q.getGangs)
export('GetGang', Q.getGang)

-- RPS keeps no vehicle / weapon / location lists (see server_vehicles.lua)
local function empty() return {} end

export('GetVehiclesByName', empty)
export('GetVehiclesByHash', empty)
export('GetVehiclesByCategory', empty)
export('GetWeapons', empty)
export('GetLocations', empty)

---------------------------------------------------------------------------
-- Vehicle support for qbx.spawnVehicle (modules/lib.lua) and GetVehicleClass
---------------------------------------------------------------------------
lib.callback.register('qbx_core:client:getVehicleClasses', function()
    local classes = {}
    for _, model in ipairs(GetAllVehicleModels()) do
        classes[joaat(model)] = GetVehicleClassFromName(model)
    end
    return classes
end)

-- the spawning server asks the entity owner to apply the properties
RegisterNetEvent('qbx_core:client:setVehicleProperties', function(netId, props)
    if not props then return end
    local timeout = GetGameTimer() + 10000
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    repeat
        if NetworkGetEntityOwner(vehicle) == cache.playerId and lib.setVehicleProperties(vehicle, props) then
            return
        end
        Wait(50)
    until GetGameTimer() > timeout
end)

-- New server-spawned vehicles: clear ambient peds from the seats and settle on the ground
AddStateBagChangeHandler('initVehicle', '', function(bagName, _, value)
    if not value then return end
    local netId = tonumber((bagName:gsub('entity:', '')), 10)
    if not netId then return end

    CreateThread(function()
        -- out of scope for this client: nothing to do
        local found, vehicle = pcall(lib.waitFor, function()
            if NetworkDoesEntityExistWithNetworkId(netId) then return NetToVeh(netId) end
        end, nil, 5000)
        if not found or not vehicle or vehicle == 0 then return end

        for seat = -1, 6 do
            local ped = GetPedInVehicleSeat(vehicle, seat)
            if ped ~= 0 and ped ~= cache.ped and not IsPedAPlayer(ped) and NetworkGetEntityOwner(ped) == cache.playerId then
                DeleteEntity(ped)
            end
        end

        pcall(lib.waitFor, function()
            if not IsEntityWaitingForWorldCollision(vehicle) then return true end
        end, nil, 5000)

        if NetworkGetEntityOwner(vehicle) ~= cache.playerId then return end
        SetVehicleOnGroundProperly(vehicle)
        Entity(vehicle).state:set('initVehicle', nil, true)
    end)
end)
