-- Qbox bridge, server side: vehicles, shared data and routing buckets.

local export = require 'bridge.qbx.shared'.export

---------------------------------------------------------------------------
-- Shared data. RPS keeps no vehicle / weapon / location lists, so these are
-- empty. Like Qbox, an unknown key returns the (empty) whole table, never nil,
-- so `GetVehiclesByHash(hash).type` is nil and qbx.spawnVehicle detects the type itself.
---------------------------------------------------------------------------
local function lookup()
    return {}
end

export('GetVehiclesByName', lookup)
export('GetVehiclesByHash', lookup)
export('GetVehiclesByCategory', function() return {} end)
export('GetWeapons', lookup)
export('GetLocations', function() return {} end)

---------------------------------------------------------------------------
-- Vehicle classes: Qbox asks a client and waits. An export can't wait, so the
-- table is fetched once in the background (first player load) and nil is
-- returned until then.
---------------------------------------------------------------------------
local vehicleClasses
local fetching = false

local function fetchVehicleClasses()
    if vehicleClasses or fetching then return end
    fetching = true
    CreateThread(function()
        for src in pairs(Core.Players) do
            local ok, classes = pcall(lib.callback.await, 'qbx_core:client:getVehicleClasses', src)
            if ok and type(classes) == 'table' then
                vehicleClasses = classes
                break
            end
        end
        fetching = false
    end)
end

AddEventHandler('rps_core:server:playerLoaded', fetchVehicleClasses)

export('GetVehicleClass', function(model)
    if not vehicleClasses then
        fetchVehicleClasses()
        return nil
    end
    return vehicleClasses[model]
end)

---------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------
local lastSessionId = 0

export('CreateSessionId', function(entity)
    local state = Entity(entity).state
    if state.sessionId then return state.sessionId end
    lastSessionId += 1
    state:set('sessionId', lastSessionId, true)
    return lastSessionId
end)

-- Only the 'persisted' flag: RPS has no vehicle persistence / respawn system.
export('EnablePersistence', function(vehicle)
    Entity(vehicle).state:set('persisted', true, true)
end)

local function disablePersistence(vehicle)
    Entity(vehicle).state:set('persisted', nil, true)
end

export('DisablePersistence', disablePersistence)

export('DeleteVehicle', function(vehicle)
    if not DoesEntityExist(vehicle) then return end
    disablePersistence(vehicle)
    DeleteEntity(vehicle)
end)

---------------------------------------------------------------------------
-- Routing buckets
---------------------------------------------------------------------------
local playerBuckets, entityBuckets = {}, {}

export('GetBucketObjects', function()
    return playerBuckets, entityBuckets
end)

export('SetPlayerBucket', function(source, bucket)
    if not source or not bucket then return false end
    Player(source).state:set('instance', bucket, true)
    SetPlayerRoutingBucket(source, bucket)
    playerBuckets[source] = bucket
    return true
end)

export('SetEntityBucket', function(entity, bucket)
    if not entity or not bucket then return false end
    SetEntityRoutingBucket(entity, bucket)
    entityBuckets[entity] = bucket
    return true
end)

local function inBucket(map, bucket)
    local list = {}
    for key, value in pairs(map) do
        if value == bucket then list[#list + 1] = key end
    end
    return list
end

export('GetPlayersInBucket', function(bucket) return inBucket(playerBuckets, bucket) end)
export('GetEntitiesInBucket', function(bucket) return inBucket(entityBuckets, bucket) end)

AddEventHandler('playerDropped', function()
    playerBuckets[source] = nil
end)

AddEventHandler('entityRemoved', function(entity)
    entityBuckets[entity] = nil
end)
