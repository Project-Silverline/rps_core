-- Include file for Qbox resources (needs '@ox_lib/init.lua' loaded first):
--   shared_scripts { '@qbx_core/modules/lib.lua' }  or  require '@qbx_core.modules.lib'
--   (or '@rps_core/modules/lib.lua'). It sits at the same relative path as in
--   qbx_core so the Qbox path works if rps_core's `provide 'qbx_core'` covers files.
-- Runs inside the including resource and defines the global `qbx` helper table,
-- with the same functions as Qbox's modules/lib.lua.

local isServer = IsDuplicityVersion()

local qbx = {
    string = {},
    math = {},
    table = {},
    array = {},
}

local function set(list)
    local result = {}
    for i = 1, #list do result[list[i]] = true end
    return lib.table.freeze(result)
end

-- arm (component 3) drawables that show bare hands
qbx.armsWithoutGloves = lib.table.freeze({
    male = set({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 18, 26, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 112, 113, 114, 118, 125, 132 }),
    female = set({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 19, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 129, 130, 131, 135, 142, 149, 153, 157, 161, 165 }),
})

-- bag (component 5) drawables that are duffel bags
qbx.duffelbagIndexes = lib.table.freeze({
    male = set({ 40, 41, 44, 45, 81, 82, 85, 86, 130, 131, 132 }),
    female = set({ 40, 41, 44, 45, 81, 82, 85, 86, 131, 132, 133 }),
})

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------
---@param str string
---@return string
function qbx.string.trim(str)
    return (str:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param str string
---@return string
function qbx.string.capitalize(str)
    return (str:gsub('^%l', string.upper))
end

---@param num number
---@param decimalPlaces? integer
---@return number
function qbx.math.round(num, decimalPlaces)
    if not decimalPlaces then return math.floor(num + 0.5) end
    local factor = 10 ^ decimalPlaces
    return math.floor(num * factor + 0.5) / factor
end

---@return boolean true for a number that isn't NaN or infinite
function qbx.math.isFinite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

---@param tbl table
---@return integer
function qbx.table.size(tbl)
    local count = 0
    for _ in pairs(tbl) do count += 1 end
    return count
end

---Groups the subtables of `tble` by the value of their `subfield`.
---@return table<any, table[]>
function qbx.table.mapBySubfield(tble, subfield)
    local map = {}
    for _, entry in pairs(tble) do
        local key = entry[subfield]
        if key then
            map[key] = map[key] or {}
            map[key][#map[key] + 1] = entry
        end
    end
    return map
end

---@return boolean
function qbx.array.contains(arr, val)
    for i = 1, #arr do
        if arr[i] == val then return true end
    end
    return false
end

---@param vehicle integer
---@return string?
function qbx.getVehiclePlate(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)
    return plate and qbx.string.trim(plate) or nil
end

---Random plate from an ox_lib lib.string.random pattern (not checked for uniqueness).
---@param pattern? string
---@return string
function qbx.generateRandomPlate(pattern)
    return lib.string.random(pattern or '........'):upper()
end

---@param entity integer
---@return 'North' | 'South' | 'East' | 'West'
function qbx.getCardinalDirection(entity)
    local heading = GetEntityHeading(entity) % 360
    if heading < 45 or heading >= 315 then return 'North' end
    if heading < 135 then return 'West' end
    if heading < 225 then return 'South' end
    return 'East'
end

if isServer then
    ---------------------------------------------------------------------------
    -- Server
    ---------------------------------------------------------------------------
    local vehicleTypes = {} -- [model hash] = type, found by spawning a hidden vehicle once

    local function waitOrDelete(entity, check, message, timeout)
        local ok, err = pcall(lib.waitFor, function()
            if check() then return true end
        end, message, timeout or 10000)
        if ok then return end
        if DoesEntityExist(entity) then DeleteEntity(entity) end
        error(err, 0)
    end

    local function getVehicleType(model)
        local known = exports.qbx_core:GetVehiclesByHash(model)
        if type(known) == 'table' and known.type then return known.type end
        if vehicleTypes[model] then return vehicleTypes[model] end

        local temp = CreateVehicle(model, 0.0, 0.0, -200.0, 0.0, true, true)
        waitOrDelete(temp, function() return DoesEntityExist(temp) end, 'temp vehicle never existed')
        vehicleTypes[model] = GetVehicleType(temp)
        DeleteEntity(temp)
        return vehicleTypes[model]
    end

    local function toCoords(spawnSource)
        local kind = type(spawnSource)
        if kind == 'vector4' then return spawnSource end
        if kind == 'vector3' then return vec4(spawnSource.x, spawnSource.y, spawnSource.z, 0.0) end
        local coords = GetEntityCoords(spawnSource)
        return vec4(coords.x, coords.y, coords.z, GetEntityHeading(spawnSource))
    end

    ---@class LibSpawnVehicleParams
    ---@field model integer|string
    ---@field spawnSource integer | vector3 | vector4 ped id or coords
    ---@field warp? boolean | integer ped to warp into the driver seat, or true to warp the `spawnSource` ped
    ---@field props? table ox_lib vehicle properties
    ---@field bucket? integer routing bucket

    ---Spawns a vehicle with the server setter native. Waits: call from a thread.
    ---@param params LibSpawnVehicleParams
    ---@return integer netId
    ---@return integer vehicle
    function qbx.spawnVehicle(params)
        local model = type(params.model) == 'string' and joaat(params.model) or params.model
        local source = params.spawnSource
        local warp = params.warp
        local ped = type(warp) == 'number' and warp or (warp and type(source) == 'number' and source) or nil
        local props = type(params.props) == 'table' and params.props or nil
        local bucket = params.bucket or (ped and GetEntityRoutingBucket(ped)) or nil
        local coords = toCoords(source)
        local vehicleType = getVehicleType(model)

        for _ = 1, 3 do
            local veh = CreateVehicleServerSetter(model, vehicleType, coords.x, coords.y, coords.z, coords.w)

            if bucket and bucket > 0 then
                exports.qbx_core:SetEntityBucket(veh, bucket)
            end

            waitOrDelete(veh, function() return DoesEntityExist(veh) end, 'vehicle never existed')
            waitOrDelete(veh, function() return GetVehicleNumberPlateText(veh) ~= '' end, 'vehicle plate never set')

            if ped then SetPedIntoVehicle(ped, veh, -1) end

            -- an owner is needed before properties can be applied (the driver, when warping)
            waitOrDelete(veh, function()
                local owner = NetworkGetEntityOwner(veh)
                if ped then return owner == NetworkGetEntityOwner(ped) end
                return owner ~= -1
            end, 'client never set as owner', 5000)

            local owner = NetworkGetEntityOwner(veh)
            local netId = NetworkGetNetworkIdFromEntity(veh)
            Entity(veh).state:set('initVehicle', true, true)

            local applied = true
            if props and props.plate then
                TriggerClientEvent('qbx_core:client:setVehicleProperties', owner, netId, props)
                local wanted = qbx.string.trim(props.plate)
                -- the plate has to match twice, 100 ms apart, before clients reliably see it
                applied = pcall(function()
                    local seen = false
                    lib.waitFor(function()
                        if qbx.string.trim(GetVehicleNumberPlateText(veh)) ~= wanted then return end
                        assert(NetworkGetEntityOwner(veh) == owner, 'owner changed during vehicle init')
                        if seen then return true end
                        seen = true
                        Wait(100)
                    end, 'failed to set vehicle properties', 1000)
                end)
            end

            if applied then
                SetEntityOrphanMode(veh, 2)
                exports.qbx_core:EnablePersistence(veh)
                return netId, veh
            end

            DeleteEntity(veh)
        end

        error('unable to successfully spawn vehicle after 3 attempts')
    end
else
    ---------------------------------------------------------------------------
    -- Client
    ---------------------------------------------------------------------------
    local function setupText(scaleX, scaleY, font, color, dropShadow, outline)
        color = color or vec4(255, 255, 255, 255)
        SetTextScale(scaleX, scaleY)
        SetTextFont(font or 4)
        SetTextColour(math.floor(color.r), math.floor(color.g), math.floor(color.b), math.floor(color.a))
        if dropShadow then SetTextDropShadow() end
        if outline then SetTextOutline() end
        SetTextCentre(true)
        BeginTextCommandDisplayText('STRING')
    end

    ---Draws 2D text for one frame. params: text, coords (vector2), scale?, font?, color?, width?, height?, enableDropShadow?, enableOutline?
    function qbx.drawText2d(params)
        local scale = params.scale or 0.35
        local width, height = params.width or 1.0, params.height or 1.0
        setupText(scale, scale, params.font, params.color, params.enableDropShadow, params.enableOutline)
        AddTextComponentSubstringPlayerName(params.text)
        EndTextCommandDisplayText(params.coords.x - width / 2, params.coords.y - height / 2 + 0.005)
    end

    ---Draws 3D text for one frame. params: text, coords (vector3), scale? (number|vector2), font?, color?, disableDrawRect?, enableDropShadow?, enableOutline?
    function qbx.drawText3d(params)
        local scale = params.scale or vec2(0.35, 0.35)
        if type(scale) == 'number' then scale = vec2(scale, scale) end
        local coords = params.coords

        setupText(scale.x, scale.y, params.font, params.color, params.enableDropShadow, params.enableOutline)
        AddTextComponentSubstringPlayerName(params.text)
        SetDrawOrigin(coords.x, coords.y, coords.z, 0)
        EndTextCommandDisplayText(0.0, 0.0)
        if not params.disableDrawRect then
            DrawRect(0.0, 0.0125, 0.017 + #params.text / 370, 0.03, 0, 0, 0, 75)
        end
        ClearDrawOrigin()
    end

    ---Waits for the entity behind an 'entity:<netId>' state bag. Waits: call from a thread.
    ---@return integer entity, integer netId
    function qbx.getEntityAndNetIdFromBagName(bagName)
        local netId = tonumber((bagName:gsub('entity:', '')), 10)
        local ok, entity = pcall(lib.waitFor, function()
            if netId and NetworkDoesEntityExistWithNetworkId(netId) then
                return NetworkGetEntityFromNetworkId(netId)
            end
        end, ('statebag timed out while awaiting entity creation! (%s)'):format(bagName), 10000)

        if not ok or not entity then
            lib.print.error(('statebag received invalid entity! (%s)'):format(bagName))
            return 0, 0
        end
        return entity, netId
    end

    ---State bag change handler for entity bags; cb(entity, netId, value, bagName)
    ---@return number cookie
    function qbx.entityStateHandler(keyFilter, cb)
        return AddStateBagChangeHandler(keyFilter, '', function(bagName, _, value)
            local entity, netId = qbx.getEntityAndNetIdFromBagName(bagName)
            if entity and entity ~= 0 then cb(entity, netId, value, bagName) end
        end)
    end

    ---@return boolean deleted
    function qbx.deleteVehicle(vehicle)
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteVehicle(vehicle)
        return not DoesEntityExist(vehicle)
    end

    function qbx.getVehicleDisplayName(vehicle)
        return GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(vehicle)))
    end

    function qbx.getVehicleMakeName(vehicle)
        return GetLabelText(GetMakeNameFromVehicleModel(GetEntityModel(vehicle)))
    end

    function qbx.getVehicleModName(vehicle, modType, modIndex)
        return GetLabelText(GetModTextLabel(vehicle, modType, modIndex))
    end

    function qbx.getVehicleLiveryName(vehicle, liveryIndex)
        return GetLabelText(GetLiveryName(vehicle, liveryIndex))
    end

    ---@return { main: string, cross: string }
    function qbx.getStreetName(coords)
        local main, cross = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
        return { main = GetStreetNameFromHashKey(main), cross = GetStreetNameFromHashKey(cross) }
    end

    function qbx.getZoneName(coords)
        return GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z))
    end

    function qbx.setVehicleExtra(vehicle, extra, enable)
        if DoesExtraExist(vehicle, extra) then
            SetVehicleExtra(vehicle, extra, not enable) -- the native takes "disable"
        end
    end

    function qbx.resetVehicleExtras(vehicle)
        for extra = 1, 20 do qbx.setVehicleExtra(vehicle, extra, true) end
    end

    ---@param extras table<integer, boolean>
    function qbx.setVehicleExtras(vehicle, extras)
        qbx.resetVehicleExtras(vehicle)
        for extra, enable in pairs(extras) do qbx.setVehicleExtra(vehicle, extra, enable) end
    end

    local function genderTable(tables)
        return tables[GetEntityModel(cache.ped) == `mp_m_freemode_01` and 'male' or 'female']
    end

    ---@return boolean
    function qbx.isWearingGloves()
        return not genderTable(qbx.armsWithoutGloves)[GetPedDrawableVariation(cache.ped, 3)]
    end

    ---@return boolean
    function qbx.isWearingDuffelbag()
        return genderTable(qbx.duffelbagIndexes)[GetPedDrawableVariation(cache.ped, 5)] == true
    end

    ---Remember ReleaseScriptAudioBank: only 10 banks can be loaded.
    ---@return boolean loaded
    function qbx.loadAudioBank(audioBank, timeout)
        local ok, loaded = pcall(lib.waitFor, function()
            if RequestScriptAudioBank(audioBank, false) then return true end
        end, ('timed out while requesting audio bank! (%s)'):format(audioBank), timeout or 500)
        return ok and loaded or false
    end

    ---@deprecated
    ---params: audioName, audioRef, returnSoundId?, audioSource? (entity or vector3), range?
    ---@return number? soundId
    function qbx.playAudio(params)
        local soundId = GetSoundId()
        local source = params.audioSource

        if type(source) == 'vector3' then
            PlaySoundFromCoord(soundId, params.audioName, source.x, source.y, source.z, params.audioRef, false, params.range or 5.0, false)
        elseif type(source) == 'number' then
            PlaySoundFromEntity(soundId, params.audioName, source, params.audioRef, false, false)
        else
            PlaySoundFrontend(soundId, params.audioName, params.audioRef, true)
        end

        if params.returnSoundId then return soundId end
        ReleaseSoundId(soundId)
    end
end

_ENV.qbx = qbx
