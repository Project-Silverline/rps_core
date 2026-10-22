-- ESX Legacy (es_extended) bridge, client side. Answers exports.es_extended:*
-- and fires the client 'esx:*' events from rps_core's own client events, so the
-- events reach scripts locally (no server round trip). ESX.PlayerData is built
-- from rps PlayerData + ox_inventory and kept current here; imports.lua mirrors
-- it into each including resource through 'esx:setPlayerData'.

local S = require 'bridge.esx.shared'
local UI = require 'bridge.esx.menu'
local export = S.export
local clean = S.clean
local round = S.round

local RESOURCE = GetCurrentResourceName()

local ESX = {
    Config = S.buildConfig(),
    PlayerData = {},
    PlayerLoaded = false,
    playerId = PlayerId(),
    serverId = GetPlayerServerId(PlayerId()),
    UI = { Menu = UI.Menu },
    Game = { Utils = {} },
    Streaming = {},
}
S.addHelpers(ESX)

---------------------------------------------------------------------------
-- Player data
---------------------------------------------------------------------------
local function setPlayerData(key, value)
    local last = ESX.PlayerData[key]
    ESX.PlayerData[key] = value
    if key ~= 'loadout' and (type(value) == 'table' or value ~= last) then
        TriggerEvent('esx:setPlayerData', key, value, last)
    end
end

local function oxStarted()
    return GetResourceState('ox_inventory') == 'started'
end

-- ox_inventory fires the esx item events itself when its framework is 'esx'
local function oxFiresEsxEvents()
    return GetConvar('inventory:framework', 'esx') == 'esx'
end

local ACCOUNT_ITEMS = { money = true, black_money = true }

local function buildInventory()
    local list, byName, weight = {}, {}, 0
    if not oxStarted() then return list, 0, 0 end

    local black = 0
    for _, slot in pairs(exports.ox_inventory:GetPlayerItems() or {}) do
        if type(slot) == 'table' and slot.name then
            weight = weight + (slot.weight or 0)
            if slot.name == 'black_money' then
                black = black + (slot.count or 0)
            elseif not ACCOUNT_ITEMS[slot.name] then
                local entry = byName[slot.name]
                if entry then
                    entry.count = entry.count + (slot.count or 0)
                else
                    local count = slot.count or 0
                    entry = {
                        name = slot.name,
                        count = count,
                        label = slot.label or slot.name,
                        weight = count > 0 and (slot.weight or 0) / count or 0,
                        usable = false,
                        rare = false,
                        canRemove = true,
                    }
                    byName[slot.name] = entry
                    list[#list + 1] = entry
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.label < b.label end)
    return list, weight, black
end

local function buildAccounts(accounts, black)
    local values = { bank = accounts.bank or 0, money = accounts.cash or 0, black_money = black or 0 }
    local list = {}
    for i, a in ipairs(S.accounts) do
        list[i] = { name = a.name, money = values[a.name], label = a.label, round = true, index = i }
    end
    return list
end

local function pedCoords(ped)
    local c = GetEntityCoords(ped)
    return { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) }
end

local function buildPlayerData(data)
    local charinfo = data.charinfo or {}
    local inventory, weight, black = buildInventory()
    local ped = PlayerPedId()
    local name = ('%s %s'):format(charinfo.firstname or '', charinfo.lastname or '')

    return {
        identifier = S.identifier(data.charId),
        ssn = S.ssn(data.charId),
        accounts = buildAccounts(data.accounts or {}, black),
        money = (data.accounts or {}).cash or 0,
        inventory = inventory,
        weight = weight,
        maxWeight = oxStarted() and exports.ox_inventory:GetPlayerMaxWeight() or GetConvarInt('inventory:weight', 30000),
        loadout = {}, -- weapons are ox_inventory items
        job = S.toEsxJob(data.job),
        group = data.group,
        name = name,
        firstName = charinfo.firstname,
        lastName = charinfo.lastname,
        dateofbirth = charinfo.dob,
        sex = charinfo.sex,
        height = 180,
        metadata = S.deepCopy(data.metadata or {}),
        variables = {
            firstName = charinfo.firstname,
            lastName = charinfo.lastname,
            dateofbirth = charinfo.dob,
            sex = charinfo.sex,
            height = 180,
        },
        coords = pedCoords(ped),
        ped = ped,
        dead = false,
    }
end

AddEventHandler('rps_core:client:playerLoaded', function(data)
    ESX.PlayerData = buildPlayerData(data)
    ESX.PlayerLoaded = true

    -- a character that has never been saved has no position yet
    local isNew = data.position == nil
    local skin = { sex = (data.charinfo or {}).sex == 'f' and 1 or 0 }

    TriggerEvent('esx:playerLoaded', ESX.PlayerData, isNew, skin)
    TriggerEvent('esx:onPlayerSpawn')
    TriggerServerEvent('esx:onPlayerSpawn')
end)

AddEventHandler('rps_core:client:playerUnloaded', function()
    ESX.PlayerLoaded = false
    ESX.PlayerData = {}
    TriggerEvent('esx:onPlayerLogout')
end)

AddEventHandler('rps_core:client:jobChanged', function(job)
    if not ESX.PlayerLoaded then return end
    local last = ESX.PlayerData.job
    local new = S.toEsxJob(job)
    setPlayerData('job', new)
    TriggerEvent('esx:setJob', new, last)
end)

local function updateAccount(name, money)
    for _, account in ipairs(ESX.PlayerData.accounts or {}) do
        if account.name == name and account.money ~= money then
            account.money = money
            TriggerEvent('esx:setAccountMoney', account)
            return true
        end
    end
end

AddEventHandler('rps_core:client:accountsChanged', function(accounts)
    if not ESX.PlayerLoaded then return end
    local changed = updateAccount('bank', accounts.bank or 0)
    changed = updateAccount('money', accounts.cash or 0) or changed
    if changed then
        ESX.PlayerData.money = accounts.cash or 0
        setPlayerData('accounts', ESX.PlayerData.accounts)
    end
end)

-- rps_core registers this net event; a second handler just mirrors the group
AddEventHandler('rps_core:client:setGroup', function(group)
    if not ESX.PlayerLoaded then return end
    local last = ESX.PlayerData.group
    setPlayerData('group', group)
    TriggerEvent('esx:setGroup', group, last)
end)

AddEventHandler('rps_core:client:metaChanged', function(key, value)
    if not ESX.PlayerLoaded then return end
    ESX.PlayerData.metadata = ESX.PlayerData.metadata or {}
    ESX.PlayerData.metadata[key] = value
    setPlayerData('metadata', ESX.PlayerData.metadata)
end)

-- ox_inventory changed: rebuild the ESX inventory, black money and weight
AddEventHandler('ox_inventory:updateInventory', function()
    if not ESX.PlayerLoaded then return end

    local inventory, weight, black = buildInventory()
    local before = {}
    for _, item in ipairs(ESX.PlayerData.inventory or {}) do before[item.name] = item.count end

    setPlayerData('inventory', inventory)
    setPlayerData('weight', weight)

    if updateAccount('black_money', black) then
        setPlayerData('accounts', ESX.PlayerData.accounts)
    end

    if oxFiresEsxEvents() then return end

    local now = {}
    for _, item in ipairs(inventory) do
        now[item.name] = item.count
        local old = before[item.name] or 0
        if item.count > old then
            TriggerEvent('esx:addInventoryItem', item.name, item.count, false, item)
        elseif item.count < old then
            TriggerEvent('esx:removeInventoryItem', item.name, item.count, false)
        end
    end
    for name in pairs(before) do
        if not now[name] then TriggerEvent('esx:removeInventoryItem', name, 0, false) end
    end
end)

-- keep ped and coords current (ESX.PlayerData.ped is read by many scripts)
CreateThread(function()
    while true do
        if ESX.PlayerLoaded then
            local ped = PlayerPedId()
            if ped ~= ESX.PlayerData.ped then setPlayerData('ped', ped) end
            ESX.PlayerData.coords = pedCoords(ped)
        end
        Wait(500)
    end
end)

---------------------------------------------------------------------------
-- Death / revive from rps_ambulance's isDead state
---------------------------------------------------------------------------
local function deathData()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local killer = GetPedSourceOfDeath(ped)
    local killerId = NetworkGetPlayerIndexFromPed(killer)

    local data = {
        victimCoords = { x = round(coords.x, 1), y = round(coords.y, 1), z = round(coords.z, 1) },
        killedByPlayer = false,
        deathCause = GetPedCauseOfDeath(ped),
    }

    if killer ~= ped and killerId and killerId ~= -1 and NetworkIsPlayerActive(killerId) then
        local kc = GetEntityCoords(killer)
        data.killedByPlayer = true
        data.killerCoords = { x = round(kc.x, 1), y = round(kc.y, 1), z = round(kc.z, 1) }
        data.distance = round(#(coords - kc), 1)
        data.killerServerId = GetPlayerServerId(killerId)
        data.killerClientId = killerId
    end

    return data
end

AddStateBagChangeHandler('isDead', ('player:%s'):format(cache.serverId), function(_, _, value)
    if not ESX.PlayerLoaded then return end

    if value and not ESX.PlayerData.dead then
        setPlayerData('dead', true)
        local data = deathData()
        TriggerEvent('esx:onPlayerDeath', data)
        TriggerServerEvent('esx:onPlayerDeath', data)
    elseif not value and ESX.PlayerData.dead then
        setPlayerData('dead', false)
        setPlayerData('ped', PlayerPedId())
        TriggerEvent('esx:onPlayerSpawn')
        TriggerServerEvent('esx:onPlayerSpawn')
    end
end)

---------------------------------------------------------------------------
-- Player data API
---------------------------------------------------------------------------
function ESX.IsPlayerLoaded()
    return ESX.PlayerLoaded
end

function ESX.GetPlayerData()
    return ESX.PlayerData
end

function ESX.SetPlayerData(key, value)
    setPlayerData(key, value)
end

function ESX.GetAccount(name)
    for _, account in ipairs(ESX.PlayerData.accounts or {}) do
        if account.name == name then return account end
    end
end

function ESX.SearchInventory(list, count)
    local single
    if type(list) == 'string' then single, list = list, { list } end

    local found = {}
    for _, name in ipairs(list) do
        local entry
        for _, item in ipairs(ESX.PlayerData.inventory or {}) do
            if item.name == name then entry = item break end
        end
        if count then
            found[name] = entry and entry.count or 0
        else
            found[name] = entry
        end
    end

    if single then return found[single] end
    return found
end

-- ox_inventory opens with its own keybind
function ESX.ShowInventory() end

---------------------------------------------------------------------------
-- Notifications and UI
---------------------------------------------------------------------------
local NOTIFY_TYPES = { info = 'inform', inform = 'inform', success = 'success', error = 'error', warning = 'warning' }

function ESX.ShowNotification(message, notifyType, length, title, position)
    lib.notify({
        title = clean(title),
        description = clean(message),
        type = NOTIFY_TYPES[notifyType] or 'inform',
        duration = tonumber(length) or 5000,
        position = position,
    })
end

function ESX.ShowAdvancedNotification(sender, subject, msg, textureDict, iconType, flash, saveToBrief, hudColorIndex)
    AddTextEntry('rpsEsxAdvancedNotification', msg)
    BeginTextCommandThefeedPost('rpsEsxAdvancedNotification')
    if hudColorIndex then ThefeedSetNextPostBackgroundColor(hudColorIndex) end
    EndTextCommandThefeedPostMessagetext(textureDict, textureDict, false, iconType, sender, subject)
    EndTextCommandThefeedPostTicker(flash or false, saveToBrief == nil or saveToBrief)
end

function ESX.ShowHelpNotification(msg, thisFrame, beep, duration)
    AddTextEntry('rpsEsxHelpNotification', msg)
    if thisFrame then
        DisplayHelpTextThisFrame('rpsEsxHelpNotification', false)
    else
        BeginTextCommandDisplayHelp('rpsEsxHelpNotification')
        EndTextCommandDisplayHelp(0, false, beep == nil or beep, duration or -1)
    end
end

function ESX.ShowFloatingHelpNotification(msg, coords)
    AddTextEntry('rpsEsxFloatingHelpNotification', msg)
    SetFloatingHelpTextWorldPosition(1, coords.x, coords.y, coords.z)
    SetFloatingHelpTextStyle(1, 1, 2, -1, 3, 0)
    BeginTextCommandDisplayHelp('rpsEsxFloatingHelpNotification')
    EndTextCommandDisplayHelp(2, false, false, -1)
end

function ESX.DrawMissionText(msg, time)
    ClearPrints()
    BeginTextCommandPrint('STRING')
    AddTextComponentSubstringPlayerName(msg)
    EndTextCommandPrint(time or 5000, true)
end

function ESX.TextUI(message)
    lib.showTextUI(clean(message) or '')
end

function ESX.HideUI()
    lib.hideTextUI()
end

-- Runs lib.progressBar in its own thread; options.onFinish / onCancel as in esx_progressbar
function ESX.Progressbar(message, length, options)
    options = options or {}
    local anim
    local a = options.animation
    if type(a) == 'table' then
        if a.type == 'anim' then
            anim = { dict = a.dict, clip = a.lib }
        elseif a.Scenario or a.type == 'Scenario' then
            anim = { scenario = a.Scenario }
        end
    end

    CreateThread(function()
        local ok = lib.progressBar({
            duration = tonumber(length) or 3000,
            label = clean(message) or '',
            canCancel = true,
            disable = { move = options.FreezePlayer, car = options.FreezePlayer, combat = true },
            anim = anim,
        })
        if ok then
            if options.onFinish then options.onFinish() end
        elseif options.onCancel then
            options.onCancel()
        end
    end)

    return true
end

function ESX.CancelProgressbar()
    lib.cancelProgress()
end

ESX.UI.ShowInventoryItemNotification = function(add, item, count)
    ESX.ShowNotification(('%s%s %s'):format(add and '+' or '-', count, item), add and 'success' or 'inform')
end

ESX.OpenContext = UI.Context.Open
ESX.PreviewContext = UI.Context.Preview
ESX.CloseContext = UI.Context.Close
ESX.RefreshContext = UI.Context.Refresh

function ESX.RegisterInput(name, label, group, key, onPress, onRelease)
    local command = onRelease and ('+' .. name) or name
    RegisterCommand(command, function() if onPress then onPress() end end, false)
    if onRelease then
        RegisterCommand('-' .. name, function() onRelease() end, false)
    end
    RegisterKeyMapping(command, label, group, key)
end

function ESX.HashString(str)
    return ('~INPUT_%s~'):format(('%x'):format(joaat(str) & 0x7fffffff + 2 ^ 31):upper())
end

---------------------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------------------
local serverRequests, lastRequest = {}, 0
local clientCallbacks = {} -- [name] = { cb, owner }

function ESX.TriggerServerCallback(name, cb, ...)
    lastRequest = lastRequest + 1
    serverRequests[lastRequest] = cb
    TriggerServerEvent('rps_core:esx:triggerServerCallback', name, lastRequest, ...)
end

-- Blocks: from other resources use it through imports.lua, which awaits locally
function ESX.AwaitServerCallback(name, ...)
    local p = promise.new()
    ESX.TriggerServerCallback(name, function(...) p:resolve(table.pack(...)) end, ...)
    local result = Citizen.Await(p)
    return table.unpack(result, 1, result.n)
end

RegisterNetEvent('rps_core:esx:serverCallback', function(requestId, ...)
    local cb = serverRequests[requestId]
    serverRequests[requestId] = nil
    if cb then cb(...) end
end)

function ESX.RegisterClientCallback(name, cb)
    clientCallbacks[name] = { cb = cb, owner = GetInvokingResource() or RESOURCE }
end

function ESX.DoesClientCallbackExist(name)
    return clientCallbacks[name] ~= nil
end

RegisterNetEvent('rps_core:esx:triggerClientCallback', function(name, requestId, ...)
    local entry = clientCallbacks[name]
    if not entry then
        return print(('[rps_core] ESX client callback "%s" does not exist'):format(tostring(name)))
    end
    entry.cb(function(...)
        TriggerServerEvent('rps_core:esx:clientCallback', requestId, ...)
    end, ...)
end)

-- Net event that ignores client-side triggers, except the ones this bridge fires locally
local secureEvents = {}

function ESX.SecureNetEvent(name, func)
    local owner = GetInvokingResource() or RESOURCE
    local handler = RegisterNetEvent(name, function(...)
        if source == '' and GetInvokingResource() ~= RESOURCE then return end
        func(...)
    end)
    secureEvents[owner] = secureEvents[owner] or {}
    table.insert(secureEvents[owner], handler)
end

AddEventHandler('onResourceStop', function(resource)
    for name, entry in pairs(clientCallbacks) do
        if entry.owner == resource then clientCallbacks[name] = nil end
    end
    for _, handler in ipairs(secureEvents[resource] or {}) do
        RemoveEventHandler(handler)
    end
    secureEvents[resource] = nil
end)

---------------------------------------------------------------------------
-- Streaming. With a callback: loads in a thread, then cb(asset).
-- Without one it blocks (imports.lua gives other resources a local awaiting version).
---------------------------------------------------------------------------
local function withCb(cb, fn, ...)
    if cb then
        local args = table.pack(...)
        CreateThread(function() cb(fn(table.unpack(args, 1, args.n))) end)
        return
    end
    return fn(...)
end

local function loadAsset(request, loaded, asset, ...)
    if asset == nil then return end
    if loaded(asset) then return asset end
    request(asset, ...)
    local deadline = GetGameTimer() + 10000
    while not loaded(asset) do
        if GetGameTimer() > deadline then return end
        Wait(0)
    end
    return asset
end

local function loadModel(model)
    model = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(model) then return end
    return loadAsset(RequestModel, HasModelLoaded, model)
end

local St = ESX.Streaming

function St.RequestModel(model, cb) return withCb(cb, loadModel, model) end
function St.RequestStreamedTextureDict(dict, cb) return withCb(cb, loadAsset, function(d) RequestStreamedTextureDict(d, false) end, HasStreamedTextureDictLoaded, dict) end
function St.RequestNamedPtfxAsset(asset, cb) return withCb(cb, loadAsset, RequestNamedPtfxAsset, HasNamedPtfxAssetLoaded, asset) end
function St.RequestAnimSet(set, cb) return withCb(cb, loadAsset, RequestAnimSet, HasAnimSetLoaded, set) end
function St.RequestAnimDict(dict, cb) return withCb(cb, loadAsset, RequestAnimDict, HasAnimDictLoaded, dict) end

function St.RequestWeaponAsset(weapon, cb)
    weapon = type(weapon) == 'number' and weapon or joaat(weapon)
    return withCb(cb, loadAsset, function(w) RequestWeaponAsset(w, 31, 0) end, HasWeaponAssetLoaded, weapon)
end

---------------------------------------------------------------------------
-- Game
---------------------------------------------------------------------------
local G = ESX.Game

local function mugshot(ped, transparent)
    if not DoesEntityExist(ped) then return end
    local handle = transparent and RegisterPedheadshotTransparent(ped) or RegisterPedheadshot(ped)
    local deadline = GetGameTimer() + 5000
    while not IsPedheadshotReady(handle) and GetGameTimer() < deadline do Wait(0) end
    return handle, GetPedheadshotTxdString(handle)
end

-- cb is an rps addition (upstream has none) so imports.lua can await it without a cross-resource yield
function G.GetPedMugshot(ped, transparent, cb)
    return withCb(cb, mugshot, ped, transparent)
end

local function teleport(entity, coords)
    if not DoesEntityExist(entity) then return end
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local deadline = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(entity) and GetGameTimer() < deadline do Wait(0) end
    SetEntityCoords(entity, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(entity, coords.w or coords.heading or 0.0)
end

function G.Teleport(entity, coords, cb)
    if cb then
        CreateThread(function()
            teleport(entity, coords)
            cb()
        end)
        return
    end
    teleport(entity, coords)
end

local function spawnObject(object, coords, networked)
    local model = loadModel(object)
    if not model then return end
    local obj = CreateObject(model, coords.x, coords.y, coords.z, networked == nil or networked, false, true)
    SetModelAsNoLongerNeeded(model)
    return obj
end

function G.SpawnObject(object, coords, cb, networked)
    return withCb(cb, spawnObject, object, coords, networked)
end

function G.SpawnLocalObject(object, coords, cb)
    return withCb(cb, spawnObject, object, coords, false)
end

local function spawnVehicle(model, coords, heading, networked)
    model = loadModel(model)
    if not model then return end
    networked = networked == nil or networked

    local vehicle = CreateVehicle(model, coords.x, coords.y, coords.z, heading or 0.0, networked, true)
    if networked then
        SetNetworkIdCanMigrate(NetworkGetNetworkIdFromEntity(vehicle), true)
        SetEntityAsMissionEntity(vehicle, true, true)
    end
    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    SetVehRadioStation(vehicle, 'OFF')
    SetModelAsNoLongerNeeded(model)

    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local deadline = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(vehicle) and GetGameTimer() < deadline do Wait(0) end
    return vehicle
end

function G.SpawnVehicle(model, coords, heading, cb, networked)
    return withCb(cb, spawnVehicle, model, coords, heading, networked)
end

function G.SpawnLocalVehicle(model, coords, heading, cb)
    return withCb(cb, spawnVehicle, model, coords, heading, false)
end

function G.DeleteVehicle(vehicle)
    SetEntityAsMissionEntity(vehicle, true, true)
    DeleteVehicle(vehicle)
end

function G.DeleteObject(object)
    SetEntityAsMissionEntity(object, false, true)
    DeleteObject(object)
end

function G.IsVehicleEmpty(vehicle)
    return GetVehicleNumberOfPassengers(vehicle) == 0 and IsVehicleSeatFree(vehicle, -1)
end

function G.GetObjects()
    return GetGamePool('CObject')
end

function G.GetVehicles()
    return GetGamePool('CVehicle')
end

function G.GetPeds(onlyOtherPeds)
    local pool = GetGamePool('CPed')
    if not onlyOtherPeds then return pool end
    local mine, out = PlayerPedId(), {}
    for _, ped in ipairs(pool) do
        if ped ~= mine then out[#out + 1] = ped end
    end
    return out
end

function G.GetPlayers(onlyOtherPlayers, returnKeyValue, returnPeds)
    local players, me = {}, PlayerId()
    for _, player in ipairs(GetActivePlayers()) do
        local ped = GetPlayerPed(player)
        if DoesEntityExist(ped) and not (onlyOtherPlayers and player == me) then
            if returnKeyValue then
                players[player] = ped
            else
                players[#players + 1] = returnPeds and ped or player
            end
        end
    end
    return players
end

local function origin(coords)
    if coords then return vector3(coords.x, coords.y, coords.z) end
    return GetEntityCoords(PlayerPedId())
end

-- isPlayerEntities: entities is { [playerId] = ped } and the player id is returned
function G.GetClosestEntity(entities, isPlayerEntities, coords, modelFilter)
    local from = origin(coords)
    local closest, closestDist = -1, -1
    for k, entity in pairs(entities) do
        if not modelFilter or modelFilter[GetEntityModel(entity)] then
            local dist = #(from - GetEntityCoords(entity))
            if closestDist == -1 or dist < closestDist then
                closest, closestDist = isPlayerEntities and k or entity, dist
            end
        end
    end
    return closest, closestDist
end

local function withinDistance(entities, isPlayerEntities, coords, maxDistance)
    local from, out = origin(coords), {}
    for k, entity in pairs(entities) do
        if #(from - GetEntityCoords(entity)) <= maxDistance then
            out[#out + 1] = isPlayerEntities and k or entity
        end
    end
    return out
end

function G.GetClosestObject(coords, modelFilter) return G.GetClosestEntity(G.GetObjects(), false, coords, modelFilter) end
function G.GetClosestPed(coords, modelFilter) return G.GetClosestEntity(G.GetPeds(true), false, coords, modelFilter) end
function G.GetClosestPlayer(coords) return G.GetClosestEntity(G.GetPlayers(true, true), true, coords) end
function G.GetClosestVehicle(coords, modelFilter) return G.GetClosestEntity(G.GetVehicles(), false, coords, modelFilter) end
function G.GetPlayersInArea(coords, maxDistance) return withinDistance(G.GetPlayers(true, true), true, coords, maxDistance) end
function G.GetVehiclesInArea(coords, maxDistance) return withinDistance(G.GetVehicles(), false, coords, maxDistance) end
function G.IsSpawnPointClear(coords, maxDistance) return #G.GetVehiclesInArea(coords, maxDistance) == 0 end

function G.GetVehicleInDirection()
    local ped = PlayerPedId()
    local from = GetEntityCoords(ped)
    local to = GetOffsetFromEntityInWorldCoords(ped, 0.0, 5.0, 0.0)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, 10, ped, 0)
    local _, hit, endCoords, _, entity = GetShapeTestResult(ray)
    if hit and hit ~= 0 and entity ~= 0 and IsEntityAVehicle(entity) then
        return entity, endCoords
    end
end

function G.GetVehicleProperties(vehicle)
    if not DoesEntityExist(vehicle) then return end
    return lib.getVehicleProperties(vehicle)
end

function G.SetVehicleProperties(vehicle, props)
    if not DoesEntityExist(vehicle) or type(props) ~= 'table' then return end
    lib.setVehicleProperties(vehicle, props)
end

function G.Utils.DrawText3D(coords, text, size, font)
    local pos = vector3(coords.x, coords.y, coords.z)
    local distance = #(pos - GetFinalRenderedCamCoord())
    local scale = ((size or 1) / distance) * 2 * (1 / GetGameplayCamFov()) * 100

    SetTextScale(0.0, 0.55 * scale)
    SetTextFont(font or 0)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    BeginTextCommandDisplayText('STRING')
    SetTextCentre(true)
    AddTextComponentSubstringPlayerName(text)
    SetDrawOrigin(pos.x, pos.y, pos.z, 0)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

-- ESX.OneSync.SpawnVehicle (server) leaves its properties in this state bag key
AddStateBagChangeHandler('VehicleProperties', '', function(bagName, _, value)
    if type(value) ~= 'table' then return end
    CreateThread(function()
        local deadline = GetGameTimer() + 3000
        local entity = GetEntityFromStateBagName(bagName)
        while entity == 0 and GetGameTimer() < deadline do
            Wait(100)
            entity = GetEntityFromStateBagName(bagName)
        end
        if entity == 0 or NetworkGetEntityOwner(entity) ~= PlayerId() then return end
        lib.setVehicleProperties(entity, value)
        Entity(entity).state:set('VehicleProperties', nil, true)
    end)
end)

---------------------------------------------------------------------------
-- Items / weapons (ox_inventory definitions)
---------------------------------------------------------------------------
function ESX.GetWeapon(name)
    if not oxStarted() then return end
    local def = exports.ox_inventory:Items(tostring(name):upper())
    return def and def.weapon and def or nil
end

function ESX.GetWeaponLabel(name)
    local def = ESX.GetWeapon(name)
    return def and def.label or nil
end

---------------------------------------------------------------------------
-- Server -> client ESX events
---------------------------------------------------------------------------
RegisterNetEvent('esx:showNotification', function(...) ESX.ShowNotification(...) end)
RegisterNetEvent('esx:showAdvancedNotification', function(...) ESX.ShowAdvancedNotification(...) end)
RegisterNetEvent('esx:showHelpNotification', function(...) ESX.ShowHelpNotification(...) end)

RegisterNetEvent('esx:executeCommand', function(command)
    if source == '' then return end
    ExecuteCommand(command)
end)

RegisterNetEvent('esx:updatePlayerData', function(key, value)
    if source == '' or not ESX.PlayerLoaded then return end
    setPlayerData(key, value)
end)

RegisterNetEvent('esx:setMaxWeight', function(maxWeight)
    if source == '' or not ESX.PlayerLoaded then return end
    setPlayerData('maxWeight', maxWeight)
end)

---------------------------------------------------------------------------
-- Shared object
---------------------------------------------------------------------------
export('getSharedObject', function()
    return ESX
end)

AddEventHandler('esx:getSharedObject', function(cb)
    if ESX.IsFunctionReference(cb) then cb(ESX) end
end)
