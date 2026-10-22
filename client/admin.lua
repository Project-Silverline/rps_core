-- Client side of the staff commands (server/admin.lua). The server checks
-- permissions before sending any of these events.

local function notify(msg, notifyType)
    exports.rps_core:Notify(msg, notifyType)
end

-- The vehicle the local player drives, else the ped: what teleports and noclip move
local function movedEntity()
    local vehicle = cache.vehicle
    if vehicle and GetPedInVehicleSeat(vehicle, -1) == cache.ped then return vehicle end
    return cache.ped
end

---------------------------------------------------------------------------
-- Noclip: WASD to move, Q/E down/up, Shift faster, Alt slower
---------------------------------------------------------------------------
local noclip = false

local function setNoclip(state)
    noclip = state
    local entity = movedEntity()

    FreezeEntityPosition(entity, state)
    SetEntityInvincible(entity, state)
    SetEntityCollision(entity, not state, not state)
    SetEntityVisible(entity, not state, false)
    if entity ~= cache.ped then SetEntityVisible(cache.ped, not state, false) end

    notify(state and 'Noclip on' or 'Noclip off', 'inform')
    if not state then return end

    CreateThread(function()
        while noclip do
            entity = movedEntity()
            local speed = IsDisabledControlPressed(0, 21) and 3.0 or IsDisabledControlPressed(0, 19) and 0.15 or 1.0
            local rot = GetGameplayCamRot(2)
            local pitch, yaw = math.rad(rot.x), math.rad(rot.z)
            local forward = vec3(-math.sin(yaw) * math.cos(pitch), math.cos(yaw) * math.cos(pitch), math.sin(pitch))
            local right = vec3(math.cos(yaw), math.sin(yaw), 0.0)
            local move = vec3(0.0, 0.0, 0.0)

            DisableControlAction(0, 30, true) -- move left/right
            DisableControlAction(0, 31, true) -- move forward/back
            DisableControlAction(0, 21, true) -- sprint
            DisableControlAction(0, 19, true) -- character wheel (Alt)
            DisableControlAction(0, 44, true) -- cover (Q)
            DisableControlAction(0, 38, true) -- pick up (E)

            if IsDisabledControlPressed(0, 32) then move = move + forward end  -- W
            if IsDisabledControlPressed(0, 33) then move = move - forward end  -- S
            if IsDisabledControlPressed(0, 34) then move = move - right end    -- A
            if IsDisabledControlPressed(0, 35) then move = move + right end    -- D
            if IsDisabledControlPressed(0, 38) then move = move + vec3(0.0, 0.0, 1.0) end -- E
            if IsDisabledControlPressed(0, 44) then move = move - vec3(0.0, 0.0, 1.0) end -- Q

            local coords = GetEntityCoords(entity) + move * speed
            SetEntityCoordsNoOffset(entity, coords.x, coords.y, coords.z, true, true, true)
            SetEntityHeading(entity, rot.z)
            Wait(0)
        end
    end)
end

RegisterNetEvent('rps_core:client:toggleNoclip', function()
    setNoclip(not noclip)
end)

---------------------------------------------------------------------------
-- Teleport to waypoint
---------------------------------------------------------------------------
RegisterNetEvent('rps_core:client:teleportToWaypoint', function()
    local blip = GetFirstBlipInfoId(8)
    if not DoesBlipExist(blip) then return notify('Set a waypoint first', 'error') end

    local target = GetBlipInfoIdCoord(blip)
    local entity = movedEntity()

    DoScreenFadeOut(250)
    while not IsScreenFadedOut() do Wait(0) end
    FreezeEntityPosition(entity, true)

    -- the ground height isn't known until collision loads, so probe downwards from the sky
    local groundZ
    for z = 800, 0, -50 do
        SetEntityCoordsNoOffset(entity, target.x, target.y, z + 0.0, false, false, false)
        RequestCollisionAtCoord(target.x, target.y, z + 0.0)
        local timeout = GetGameTimer() + 500
        while not HasCollisionLoadedAroundEntity(entity) and GetGameTimer() < timeout do Wait(0) end

        local found, z2 = GetGroundZFor_3dCoord(target.x, target.y, z + 0.0, false)
        if found then
            groundZ = z2
            break
        end
    end

    SetEntityCoordsNoOffset(entity, target.x, target.y, (groundZ or 100.0) + 1.0, false, false, false)
    FreezeEntityPosition(entity, false)
    DoScreenFadeIn(250)

    if not groundZ then notify('Could not find the ground there', 'warning') end
end)

---------------------------------------------------------------------------
-- Vehicles, kill, coords
---------------------------------------------------------------------------
RegisterNetEvent('rps_core:client:spawnVehicle', function(model)
    local hash = type(model) == 'string' and joaat(model) or model
    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
        return notify(('%s is not a vehicle model'):format(model), 'error')
    end

    lib.requestModel(hash)

    -- replace the vehicle you're driving, like most framework /car commands
    local current = cache.vehicle
    if current and GetPedInVehicleSeat(current, -1) == cache.ped then
        SetEntityAsMissionEntity(current, true, true)
        DeleteVehicle(current)
    end

    local coords = GetEntityCoords(cache.ped)
    local vehicle = CreateVehicle(hash, coords.x, coords.y, coords.z, GetEntityHeading(cache.ped), true, false)
    SetModelAsNoLongerNeeded(hash)
    SetVehicleOnGroundProperly(vehicle)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetPedIntoVehicle(cache.ped, vehicle, -1)
    notify(('Spawned %s'):format(model), 'success')
end)

RegisterNetEvent('rps_core:client:kill', function()
    SetEntityHealth(cache.ped, 0)
end)

RegisterNetEvent('rps_core:client:copyCoords', function()
    local c = GetEntityCoords(cache.ped)
    local text = ('vec4(%.2f, %.2f, %.2f, %.2f)'):format(c.x, c.y, c.z, GetEntityHeading(cache.ped))
    lib.setClipboard(text)
    print(text)
    notify(('%s (copied)'):format(text), 'inform')
end)

---------------------------------------------------------------------------
-- Staff menu: every button runs the matching command, which the server
-- permission-checks again
---------------------------------------------------------------------------
local function command(fmt, ...)
    ExecuteCommand(fmt:format(...))
end

local function jobOptions()
    local options = {}
    for name, job in pairs(Config.Jobs) do
        options[#options + 1] = { value = name, label = job.label }
    end
    table.sort(options, function(a, b) return a.label < b.label end)
    return options
end

local function playerMenu(target, isAdmin)
    local options = {
        { title = 'Go to', icon = 'location-arrow', onSelect = function() command('goto %d', target.id) end },
        { title = 'Bring', icon = 'person-walking-arrow-loop-left', onSelect = function() command('bring %d', target.id) end },
    }

    if GetResourceState('rps_ambulance') == 'started' then
        options[#options + 1] = { title = 'Revive / heal', icon = 'heart-pulse', onSelect = function() command('adrevive %d', target.id) end }
    end

    options[#options + 1] = {
        title = 'Kick', icon = 'door-open', iconColor = '#e03131',
        onSelect = function()
            local input = lib.inputDialog(('Kick %s'):format(target.name), {
                { type = 'input', label = 'Reason', required = false },
            })
            if input then command('kick %d %s', target.id, input[1] ~= '' and input[1] or 'Kicked by staff') end
        end,
    }

    if isAdmin and target.character then
        options[#options + 1] = {
            title = 'Set job', icon = 'briefcase',
            onSelect = function()
                local input = lib.inputDialog(('Set job: %s'):format(target.character), {
                    { type = 'select', label = 'Job', options = jobOptions(), required = true },
                    { type = 'number', label = 'Grade', default = 0, min = 0, required = true },
                })
                if input then command('setjob %d %s %d', target.id, input[1], math.floor(input[2])) end
            end,
        }
        options[#options + 1] = {
            title = 'Give money', icon = 'money-bill',
            onSelect = function()
                local input = lib.inputDialog(('Give money: %s'):format(target.character), {
                    { type = 'select', label = 'Account', required = true, default = 'cash', options = {
                        { value = 'cash', label = 'Cash' },
                        { value = 'bank', label = 'Bank' },
                    } },
                    { type = 'number', label = 'Amount', min = 1, required = true },
                })
                if input then command('givemoney %d %s %d', target.id, input[1], math.floor(input[2])) end
            end,
        }
        options[#options + 1] = {
            title = 'Give item', icon = 'box',
            onSelect = function()
                local input = lib.inputDialog(('Give item: %s'):format(target.character), {
                    { type = 'input', label = 'Item name', required = true },
                    { type = 'number', label = 'Amount', default = 1, min = 1, required = true },
                })
                if input then command('giveitem %d %s %d', target.id, input[1], math.floor(input[2])) end
            end,
        }
        options[#options + 1] = { title = 'Kill', icon = 'skull', iconColor = '#e03131', onSelect = function() command('kill %d', target.id) end }
    end

    lib.registerContext({
        id = 'rps_admin_player',
        title = ('%s (%d)'):format(target.name, target.id),
        menu = 'rps_admin_players',
        options = options,
    })
    lib.showContext('rps_admin_player')
end

local function playersMenu(isAdmin)
    local players = lib.callback.await('rps_core:admin:getPlayers', false)
    if not players then return end

    local options = {}
    for _, p in ipairs(players) do
        options[#options + 1] = {
            title = ('[%d] %s'):format(p.id, p.name),
            description = p.character and ('%s · %s'):format(p.character, p.job or '') or 'No character loaded',
            icon = 'user',
            onSelect = function() playerMenu(p, isAdmin) end,
        }
    end

    lib.registerContext({ id = 'rps_admin_players', title = 'Players', menu = 'rps_admin', options = options })
    lib.showContext('rps_admin_players')
end

RegisterNetEvent('rps_core:client:openAdminMenu', function(isAdmin)
    local options = {
        { title = 'Players', icon = 'users', arrow = true, onSelect = function() playersMenu(isAdmin) end },
        { title = noclip and 'Noclip: on' or 'Noclip: off', icon = 'ghost', onSelect = function() command('noclip') end },
        { title = 'Teleport to waypoint', icon = 'map-pin', onSelect = function() command('tpm') end },
        { title = 'Copy coordinates', icon = 'crosshairs', onSelect = function() command('coords') end },
        { title = 'Delete nearest vehicle', icon = 'car-burst', onSelect = function() command('dv') end },
        {
            title = 'Announcement', icon = 'bullhorn',
            onSelect = function()
                local input = lib.inputDialog('Announcement', { { type = 'textarea', label = 'Message', required = true } })
                if input then command('announce %s', (input[1]:gsub('\n', ' '))) end
            end,
        },
    }

    if isAdmin then
        options[#options + 1] = {
            title = 'Spawn vehicle', icon = 'car',
            onSelect = function()
                local input = lib.inputDialog('Spawn vehicle', { { type = 'input', label = 'Model', placeholder = 'adder', required = true } })
                if input then command('car %s', input[1]) end
            end,
        }
    end

    lib.registerContext({ id = 'rps_admin', title = 'Staff menu', options = options })
    lib.showContext('rps_admin')
end)
