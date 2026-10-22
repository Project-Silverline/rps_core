-- QBCore (qb-core) bridge, client side. QB PlayerData is built on the server
-- and pushed with QBCore:Client:OnPlayerUpdated; items are read from
-- ox_inventory whenever a script asks for PlayerData. Notifications, progress
-- bars, text UI and vehicle properties go through ox_lib.
-- Nothing other resources call yields: upstream helpers that wait (LoadModel,
-- RequestAnimDict, awaiting TriggerCallback...) start the work and return.

local Q = require 'bridge.qb.shared'
local export = Q.export

local QBCore = {
    Config = Q.buildConfig(),
    Shared = Q.buildShared(),
    Functions = {},
    PlayerData = {},
    ServerCallbacks = {},
    ClientCallbacks = {},
}
QBCore.Shared.Jobs = Q.buildJobs()

local Functions = QBCore.Functions

---------------------------------------------------------------------------
-- ox_inventory (starts after rps_core, so read lazily)
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

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'ox_inventory' then return end
    QBCore.Shared.Items = {}
    sharedItems()
end)

local function refreshItems()
    if not QBCore.PlayerData.citizenid or not oxStarted() then return end
    local ok, slots = pcall(function() return exports.ox_inventory:GetPlayerItems() end)
    if ok then QBCore.PlayerData.items = Q.convertInventory(slots, sharedItems()) end
end

local function itemCount(name)
    if not oxStarted() then return 0 end
    local ok, count = pcall(function() return exports.ox_inventory:GetItemCount(name) end)
    return ok and count or 0
end

---------------------------------------------------------------------------
-- Player data
---------------------------------------------------------------------------
local announced = false

-- QBCore:Client:OnPlayerLoaded is sent by the server once the character is
-- both spawned (rps_core's client event) and has its QB data here.
local function announceLoaded()
    if announced or not IsLoaded or not QBCore.PlayerData.citizenid then return end
    announced = true
    TriggerServerEvent('QBCore:Server:OnPlayerLoaded')
end

AddEventHandler('rps_core:client:playerLoaded', announceLoaded)

AddEventHandler('rps_core:client:playerUnloaded', function()
    if not announced and not QBCore.PlayerData.citizenid then return end
    announced = false
    QBCore.PlayerData = {}
    TriggerEvent('QBCore:Client:OnPlayerUnload')
end)

RegisterNetEvent('QBCore:Client:OnPlayerUpdated', function(key, value)
    if key == 'all' then
        QBCore.PlayerData = value
        refreshItems()
        TriggerEvent('QBCore:Player:SetPlayerData', QBCore.PlayerData)
        TriggerEvent('QBCore:Client:OnJobUpdate', value.job)
        TriggerEvent('QBCore:Client:OnGangUpdate', value.gang)
        announceLoaded()
    elseif key and QBCore.PlayerData.citizenid then
        QBCore.PlayerData[key] = value
        if key == 'job' then TriggerEvent('QBCore:Client:OnJobUpdate', value) end
        if key == 'gang' then TriggerEvent('QBCore:Client:OnGangUpdate', value) end
        -- older QB sent the whole PlayerData on every change; scripts still listen for it
        refreshItems()
        TriggerEvent('QBCore:Player:SetPlayerData', QBCore.PlayerData)
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    if not QBCore.Config.Server.PVP then return end
    SetCanAttackFriendly(cache.ped, true, false)
    NetworkSetFriendlyFireOption(true)
end)

RegisterNetEvent('QBCore:Client:PvpHasToggled', function(pvp)
    SetCanAttackFriendly(cache.ped, pvp, false)
    NetworkSetFriendlyFireOption(pvp)
end)

function Functions.GetPlayerData(cb)
    refreshItems()
    if not cb then return QBCore.PlayerData end
    cb(QBCore.PlayerData)
end

function Functions.GetName()
    local ci = QBCore.PlayerData.charinfo or {}
    return ('%s %s'):format(ci.firstname, ci.lastname)
end

function Functions.GetCoords(entity)
    local coords = GetEntityCoords(entity)
    return vector4(coords.x, coords.y, coords.z, GetEntityHeading(entity))
end

function Functions.HasItem(items, amount)
    return Q.hasItems(itemCount, items, amount)
end

---------------------------------------------------------------------------
-- Callbacks (QB's own event protocol, so either side can be stock QB code)
---------------------------------------------------------------------------
local pendingServerCallbacks = {} -- [name] = { cb, cb, ... } answered in order

function Functions.CreateClientCallback(name, cb)
    QBCore.ClientCallbacks[name] = cb
end

-- Upstream awaits the result when no cb is given; a yield can't cross back
-- into the calling resource, so only the callback form returns data.
function Functions.TriggerCallback(name, ...)
    local args = table.pack(...)
    local cb
    if Q.isCallable(args[1]) then
        cb = args[1]
        table.remove(args, 1)
        args.n -= 1
    else
        print(('^3[qb-core] TriggerCallback(%s) without a callback function is not supported on RPS^0'):format(name))
    end

    local queue = pendingServerCallbacks[name]
    if not queue then
        queue = {}
        pendingServerCallbacks[name] = queue
    end
    queue[#queue + 1] = cb or false

    TriggerServerEvent('QBCore:Server:TriggerCallback', name, table.unpack(args, 1, args.n))
end

RegisterNetEvent('QBCore:Client:TriggerCallback', function(name, ...)
    local queue = pendingServerCallbacks[name]
    if not queue or #queue == 0 then return end
    local cb = table.remove(queue, 1)
    if cb then cb(...) end
end)

RegisterNetEvent('QBCore:Client:TriggerClientCallback', function(name, ...)
    local cb = QBCore.ClientCallbacks[name]
    if not cb then return end
    cb(function(...)
        TriggerServerEvent('QBCore:Server:TriggerClientCallback', name, ...)
    end, ...)
end)

function QBCore.Debug(resource, obj, depth)
    TriggerServerEvent('QBCore:DebugSomething', resource, obj, depth)
end

---------------------------------------------------------------------------
-- UI: notify, progress bar, text UI (ox_lib)
---------------------------------------------------------------------------
local NOTIFY_TYPES = {
    primary = 'inform', info = 'inform', police = 'inform', ambulance = 'inform',
    success = 'success', error = 'error', warning = 'warning',
}

function Functions.Notify(text, texttype, length)
    local data = { type = NOTIFY_TYPES[texttype] or 'inform', duration = tonumber(length) or 5000 }
    if type(text) == 'table' then
        data.title = text.text
        data.description = text.caption
    else
        data.description = tostring(text)
    end
    lib.notify(data)
end

RegisterNetEvent('QBCore:Notify', function(text, texttype, length, icon)
    Functions.Notify(text, texttype, length, icon)
end)

local function toVector3(v)
    if not v then return nil end
    return vec3(v.x or 0.0, v.y or 0.0, v.z or 0.0)
end

local function convertProp(prop)
    if type(prop) ~= 'table' or not prop.model then return end
    return { model = prop.model, bone = prop.bone, pos = toVector3(prop.coords), rot = toVector3(prop.rotation) }
end

---QB Progressbar -> lib.progressBar, run in a thread; calls onFinish or onCancel
function Functions.Progressbar(name, label, duration, useWhileDead, canCancel, disableControls, animation, prop, propTwo, onFinish, onCancel)
    local controls = disableControls or {}
    local options = {
        duration = tonumber(duration) or 0,
        label = label,
        useWhileDead = useWhileDead or false,
        canCancel = canCancel or false,
        disable = {
            move = controls.disableMovement or false,
            car = controls.disableCarMovement or false,
            combat = controls.disableCombat or false,
            mouse = controls.disableMouse or false,
        },
    }

    if type(animation) == 'table' then
        if animation.task then
            options.anim = { scenario = animation.task }
        elseif animation.animDict then
            options.anim = { dict = animation.animDict, clip = animation.anim, flag = animation.flags or 1 }
        end
    end

    local props = {}
    props[#props + 1] = convertProp(prop)
    props[#props + 1] = convertProp(propTwo)
    if #props > 0 then options.prop = props end

    CreateThread(function()
        if lib.progressBar(options) then
            if onFinish then onFinish() end
        elseif onCancel then
            onCancel()
        end
    end)
end

local TEXT_POSITIONS = { left = 'left-center', right = 'right-center', top = 'top-center', bottom = 'bottom-center' }

local function drawTextUI(text, position)
    lib.showTextUI(text, { position = TEXT_POSITIONS[position] or 'left-center' })
end

local function hideTextUI()
    lib.hideTextUI()
end

local function keyPressed()
    SetTimeout(500, hideTextUI)
end

RegisterNetEvent('qb-core:client:DrawText', drawTextUI)
RegisterNetEvent('qb-core:client:ChangeText', drawTextUI)
RegisterNetEvent('qb-core:client:HideText', hideTextUI)
RegisterNetEvent('qb-core:client:KeyPressed', keyPressed)

function Functions.DrawText(x, y, width, height, scale, r, g, b, a, text)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x - width / 2, y - height / 2 + 0.005)
end

function Functions.DrawText3D(x, y, z, text)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    BeginTextCommandDisplayText('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(x, y, z, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    DrawRect(0.0, 0.0125, 0.017 + #text / 370, 0.03, 0, 0, 0, 75)
    ClearDrawOrigin()
end

---------------------------------------------------------------------------
-- World getters
---------------------------------------------------------------------------
local function coordsOrPed(coords)
    if coords then return vec3(coords.x, coords.y, coords.z) end
    return GetEntityCoords(cache.ped)
end

local function closest(list, coords, skip)
    local best, bestDist = -1, -1
    for i = 1, #list do
        local entity = list[i]
        if not skip or not skip[entity] then
            local dist = #(GetEntityCoords(entity) - coords)
            if bestDist == -1 or dist < bestDist then best, bestDist = entity, dist end
        end
    end
    return best, bestDist
end

function Functions.GetVehicles() return GetGamePool('CVehicle') end
function Functions.GetObjects() return GetGamePool('CObject') end
function Functions.GetPlayers() return GetActivePlayers() end

function Functions.GetPlayersFromCoords(coords, distance)
    coords = coordsOrPed(coords)
    distance = distance or 5
    local players = {}
    for _, player in ipairs(GetActivePlayers()) do
        if #(GetEntityCoords(GetPlayerPed(player)) - coords) <= distance then
            players[#players + 1] = player
        end
    end
    return players
end

function Functions.GetClosestPlayer(coords)
    coords = coordsOrPed(coords)
    local me = PlayerId()
    local best, bestDist = -1, -1
    for _, player in ipairs(Functions.GetPlayersFromCoords(coords)) do
        if player ~= me then
            local dist = #(GetEntityCoords(GetPlayerPed(player)) - coords)
            if bestDist == -1 or dist < bestDist then best, bestDist = player, dist end
        end
    end
    return best, bestDist
end

function Functions.GetPeds(ignoreList)
    local ignore = {}
    for _, ped in ipairs(ignoreList or {}) do ignore[ped] = true end
    local peds = {}
    for _, ped in ipairs(GetGamePool('CPed')) do
        if not ignore[ped] then peds[#peds + 1] = ped end
    end
    return peds
end

function Functions.GetClosestPed(coords, ignoreList)
    return closest(Functions.GetPeds(ignoreList), coordsOrPed(coords))
end

function Functions.GetClosestVehicle(coords)
    return closest(GetGamePool('CVehicle'), coordsOrPed(coords))
end

function Functions.GetClosestObject(coords)
    return closest(GetGamePool('CObject'), coordsOrPed(coords))
end

function Functions.GetClosestBone(entity, list)
    local playerCoords = GetEntityCoords(cache.ped)
    local bone, coords, distance
    for _, element in pairs(list) do
        local boneCoords = GetWorldPositionOfEntityBone(entity, element.id or element)
        local boneDistance = #(playerCoords - boneCoords)
        if not distance or boneDistance < distance then
            bone, coords, distance = element, boneCoords, boneDistance
        end
    end
    if not bone then
        bone = { id = GetEntityBoneIndexByName(entity, 'bodyshell'), type = 'remains', name = 'bodyshell' }
        coords = GetWorldPositionOfEntityBone(entity, bone.id)
        distance = #(coords - playerCoords)
    end
    return bone, coords, distance
end

function Functions.GetBoneDistance(entity, boneType, boneIndex)
    local bone = boneType == 1 and GetPedBoneIndex(entity, boneIndex) or GetEntityBoneIndexByName(entity, boneIndex)
    return #(GetWorldPositionOfEntityBone(entity, bone) - GetEntityCoords(cache.ped))
end

function Functions.SpawnClear(coords, radius)
    coords = coordsOrPed(coords)
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if #(GetEntityCoords(veh) - coords) <= radius then return false end
    end
    return true
end

function Functions.GetStreetNametAtCoords(coords)
    local street1, street2 = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    return { main = GetStreetNameFromHashKey(street1), cross = GetStreetNameFromHashKey(street2) }
end

function Functions.GetZoneAtCoords(coords)
    return GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z))
end

function Functions.GetCardinalDirection(entity)
    entity = DoesEntityExist(entity) and entity or cache.ped
    local heading = GetEntityHeading(entity)
    if heading >= 45 and heading < 135 then return 'West' end
    if heading >= 135 and heading < 225 then return 'South' end
    if heading >= 225 and heading < 315 then return 'East' end
    return 'North'
end

function Functions.GetCurrentTime()
    local obj = { min = GetClockMinutes(), hour = GetClockHours() }
    if obj.hour <= 12 then
        obj.ampm = 'AM'
    else
        obj.ampm = 'PM'
        obj.formattedHour = obj.hour - 12
    end
    if obj.min <= 9 then obj.formattedMin = '0' .. obj.min end
    return obj
end

function Functions.GetGroundZCoord(coords)
    if not coords then return end
    local found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z, false)
    return found and vector3(coords.x, coords.y, groundZ) or coords
end

function Functions.GetGroundHash(entity)
    local coords = GetEntityCoords(entity)
    local handle = StartShapeTestCapsule(coords.x, coords.y, coords.z + 4, coords.x, coords.y, coords.z - 2.0, 1, 1, entity, 7)
    local retval, success, endCoords, surfaceNormal, materialHash, entityHit = GetShapeTestResultEx(handle)
    return materialHash, entityHit, surfaceNormal, endCoords, success, retval
end

function Functions.IsWearingGloves()
    local ped = cache.ped
    local arms = GetPedDrawableVariation(ped, 3)
    local noGloves = GetEntityModel(ped) == `mp_m_freemode_01` and QBCore.Shared.MaleNoGloves or QBCore.Shared.FemaleNoGloves
    return not noGloves[arms]
end

---------------------------------------------------------------------------
-- Asset loading. These request the asset and report whether it is loaded
-- right now; upstream waits for it, which would yield into the caller.
---------------------------------------------------------------------------
function Functions.LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if HasModelLoaded(hash) then return true, model end
    if not IsModelValid(hash) and not IsModelInCdimage(hash) then
        print(('[qb-core] Model does not exist: %s'):format(model))
        return false, hash
    end
    RequestModel(hash)
    return HasModelLoaded(hash), hash
end

function Functions.RequestAnimDict(animDict)
    if HasAnimDictLoaded(animDict) then return true, animDict end
    if not DoesAnimDictExist(animDict) then
        print(('[qb-core] Animation dictionary does not exist: %s'):format(animDict))
        return false, animDict
    end
    RequestAnimDict(animDict)
    return HasAnimDictLoaded(animDict), animDict
end

Functions.LoadAnimDict = Functions.RequestAnimDict

function Functions.LoadAnimSet(animSet)
    if not HasAnimSetLoaded(animSet) then RequestAnimSet(animSet) end
    return HasAnimSetLoaded(animSet), animSet
end

function Functions.LoadParticleDictionary(dictionary)
    if not HasNamedPtfxAssetLoaded(dictionary) then RequestNamedPtfxAsset(dictionary) end
    return HasNamedPtfxAssetLoaded(dictionary), dictionary
end

-- Plays from a thread (loading the dictionary first); returns immediately
function Functions.PlayAnim(animDict, animName, upperbodyOnly, duration)
    if type(animDict) ~= 'string' or type(animName) ~= 'string' or not DoesAnimDictExist(animDict) then return end
    CreateThread(function()
        lib.requestAnimDict(animDict)
        local flags = upperbodyOnly and 16 or 0
        local runTime = duration or -1
        if runTime == -1 then flags = 49 end
        TaskPlayAnim(cache.ped, animDict, animName, 8.0, 8.0, runTime, flags, 0, true, true, true)
        RemoveAnimDict(animDict)
    end)
end

function Functions.LookAtEntity(entity, timeout)
    if type(entity) ~= 'number' or not DoesEntityExist(entity) then return end
    TaskTurnPedToFaceEntity(cache.ped, entity, math.min(tonumber(timeout) or 1000, 5000))
end

function Functions.AttachProp(ped, model, boneId, x, y, z, xR, yR, zR, vertex)
    local hash = type(model) == 'string' and joaat(model) or model
    if not HasModelLoaded(hash) then RequestModel(hash) end
    local prop = CreateObject(hash, 1.0, 1.0, 1.0, true, true, false)
    AttachEntityToEntity(prop, ped, GetPedBoneIndex(ped, boneId), x, y, z, xR, yR, zR, true, true, false, true, not vertex and 2 or 0, true)
    SetModelAsNoLongerNeeded(hash)
    return prop
end

local function stopAfter(handle, duration)
    if not duration then return end
    SetTimeout(duration, function() StopParticleFxLooped(handle, false) end)
end

function Functions.StartParticleAtCoord(dict, ptName, looped, coords, rot, scale, alpha, color, duration)
    coords = coordsOrPed(coords)
    Functions.LoadParticleDictionary(dict)
    UseParticleFxAssetNextCall(dict)
    SetPtfxAssetNextCall(dict)
    if looped then
        local handle = StartParticleFxLoopedAtCoord(ptName, coords.x, coords.y, coords.z, rot.x, rot.y, rot.z, scale or 1.0, false, false, false, false)
        if color then SetParticleFxLoopedColour(handle, color.r, color.g, color.b, false) end
        SetParticleFxLoopedAlpha(handle, alpha or 10.0)
        stopAfter(handle, duration)
        return handle
    end
    SetParticleFxNonLoopedAlpha(alpha or 10.0)
    if color then SetParticleFxNonLoopedColour(color.r, color.g, color.b) end
    StartParticleFxNonLoopedAtCoord(ptName, coords.x, coords.y, coords.z, rot.x, rot.y, rot.z, scale or 1.0, false, false, false)
end

function Functions.StartParticleOnEntity(dict, ptName, looped, entity, bone, offset, rot, scale, alpha, color, evolution, duration)
    Functions.LoadParticleDictionary(dict)
    UseParticleFxAssetNextCall(dict)
    local boneId
    if bone then
        boneId = GetEntityType(entity) == 1 and GetPedBoneIndex(entity, bone) or GetEntityBoneIndexByName(entity, bone)
    end
    if looped then
        local handle
        if boneId then
            handle = StartParticleFxLoopedOnEntityBone(ptName, entity, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z, boneId, scale, false, false, false)
        else
            handle = StartParticleFxLoopedOnEntity(ptName, entity, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z, scale, false, false, false)
        end
        if evolution then SetParticleFxLoopedEvolution(handle, evolution.name, evolution.amount, false) end
        if color then SetParticleFxLoopedColour(handle, color.r, color.g, color.b, false) end
        SetParticleFxLoopedAlpha(handle, alpha)
        stopAfter(handle, duration)
        return handle
    end
    SetParticleFxNonLoopedAlpha(alpha or 10.0)
    if color then SetParticleFxNonLoopedColour(color.r, color.g, color.b) end
    if boneId then
        StartParticleFxNonLoopedOnPedBone(ptName, entity, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z, boneId, scale, false, false, false)
    else
        StartParticleFxNonLoopedOnEntity(ptName, entity, offset.x, offset.y, offset.z, rot.x, rot.y, rot.z, scale, false, false, false)
    end
end

---------------------------------------------------------------------------
-- Vehicles
---------------------------------------------------------------------------
function Functions.SpawnVehicle(model, cb, coords, isnetworked, teleportInto)
    local hash = type(model) == 'string' and joaat(model) or model
    if not IsModelInCdimage(hash) then return end
    coords = coords or GetEntityCoords(cache.ped)
    local heading = (coords.w or GetEntityHeading(cache.ped)) + 0.0
    isnetworked = isnetworked == nil or isnetworked

    -- loading the model waits, so spawning happens in a thread and cb gets the vehicle
    CreateThread(function()
        lib.requestModel(hash)
        local veh = CreateVehicle(hash, coords.x, coords.y, coords.z, heading, isnetworked, false)
        if isnetworked then SetNetworkIdCanMigrate(NetworkGetNetworkIdFromEntity(veh), true) end
        SetVehicleHasBeenOwnedByPlayer(veh, true)
        SetVehicleNeedsToBeHotwired(veh, false)
        SetVehRadioStation(veh, 'OFF')
        SetVehicleFuelLevel(veh, 100.0)
        SetModelAsNoLongerNeeded(hash)
        if teleportInto then TaskWarpPedIntoVehicle(cache.ped, veh, -1) end
        if cb then cb(veh) end
    end)
end

function Functions.DeleteVehicle(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    DeleteVehicle(vehicle)
end

function Functions.GetPlate(vehicle)
    if not vehicle or vehicle == 0 then return end
    return QBCore.Shared.Trim(GetVehicleNumberPlateText(vehicle))
end

function Functions.GetVehicleLabel(vehicle)
    if not vehicle or vehicle == 0 then return end
    return GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)))
end

function Functions.GetVehicleProperties(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    local props = lib.getVehicleProperties(vehicle)
    if props and props.plate then props.plate = QBCore.Shared.Trim(props.plate) end
    return props
end

function Functions.SetVehicleProperties(vehicle, props)
    if not vehicle or not DoesEntityExist(vehicle) or type(props) ~= 'table' then return end
    lib.setVehicleProperties(vehicle, props)
end

---------------------------------------------------------------------------
-- Shared updates and vehicle info from the server
---------------------------------------------------------------------------
RegisterNetEvent('QBCore:Client:OnSharedUpdate', function(tableName, key, value)
    if type(QBCore.Shared[tableName]) ~= 'table' then return end
    QBCore.Shared[tableName][key] = value
    TriggerEvent('QBCore:Client:UpdateObject')
end)

RegisterNetEvent('QBCore:Client:OnSharedUpdateMultiple', function(tableName, values)
    if type(QBCore.Shared[tableName]) ~= 'table' then return end
    for key, value in pairs(values) do QBCore.Shared[tableName][key] = value end
    TriggerEvent('QBCore:Client:UpdateObject')
end)

RegisterNetEvent('QBCore:Client:VehicleInfo', function(info)
    -- baseevents sends this client's own entity handle back to it
    local vehicle = info.vehicle
    local plate = Functions.GetPlate(vehicle)
    local hasKeys = true
    if GetResourceState('qb-vehiclekeys') == 'started' then
        hasKeys = exports['qb-vehiclekeys']:HasKeys(plate)
    end
    TriggerEvent(('QBCore:Client:%sVehicle'):format(info.event), {
        vehicle = vehicle,
        seat = info.seat,
        name = info.name,
        plate = plate,
        driver = GetPedInVehicleSeat(vehicle, -1),
        inseat = GetPedInVehicleSeat(vehicle, info.seat),
        haskeys = hasKeys,
    })
end)

---------------------------------------------------------------------------
-- Core object and exports
---------------------------------------------------------------------------
local function getCoreObject(filters)
    sharedItems()
    refreshItems()
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

-- Deprecated: TriggerEvent('QBCore:GetObject', function(obj) ... end)
AddEventHandler('QBCore:GetObject', function(cb)
    if Q.isCallable(cb) then cb(getCoreObject()) end
end)

for name, fn in pairs(Functions) do
    if type(fn) == 'function' and name ~= 'DrawText' then export(name, fn) end
end

-- the text UI exports (DrawText also names the screen-text function, as upstream)
export('DrawText', drawTextUI)
export('ChangeText', drawTextUI)
export('HideText', hideTextUI)
export('KeyPressed', keyPressed)
