-- Staff commands. `mod` gets movement and moderation tools, `admin` everything
-- that creates money, items or vehicles. Groups inherit upwards (admin has mod).
-- Revive and heal live in rps_ambulance (/adrevive).

local function loaded(source, target)
    local player = Core.GetPlayer(target)
    if not player then Core.Notify(source, 'That player has no character loaded', 'error') end
    return player
end

local function inventoryStarted(source)
    if GetResourceState('ox_inventory') == 'started' then return true end
    Core.Notify(source, 'ox_inventory is not running', 'error')
end

local function teleport(target, coords)
    SetEntityCoords(GetPlayerPed(target), coords.x, coords.y, coords.z, false, false, false, false)
end

---------------------------------------------------------------------------
-- Movement (mod)
---------------------------------------------------------------------------
lib.addCommand('tp', {
    help = 'Teleport to coordinates',
    params = {
        { name = 'x', type = 'number' },
        { name = 'y', type = 'number' },
        { name = 'z', type = 'number' },
    },
    restricted = 'group.mod',
}, function(source, args)
    if source == 0 then return end
    teleport(source, vec3(args.x, args.y, args.z))
end)

lib.addCommand('tpm', {
    help = 'Teleport to your map waypoint',
    restricted = 'group.mod',
}, function(source)
    if source == 0 then return end
    TriggerClientEvent('rps_core:client:teleportToWaypoint', source)
end)

lib.addCommand('goto', {
    help = 'Teleport to a player',
    params = { { name = 'target', type = 'playerId', help = 'Server ID' } },
    restricted = 'group.mod',
}, function(source, args)
    if source == 0 or args.target == source then return end
    teleport(source, GetEntityCoords(GetPlayerPed(args.target)))
end)

lib.addCommand('bring', {
    help = 'Teleport a player to you',
    params = { { name = 'target', type = 'playerId', help = 'Server ID' } },
    restricted = 'group.mod',
}, function(source, args)
    if source == 0 or args.target == source then return end
    teleport(args.target, GetEntityCoords(GetPlayerPed(source)))
    Core.Notify(args.target, 'You were brought by staff', 'inform')
end)

lib.addCommand('noclip', {
    help = 'Toggle noclip',
    restricted = 'group.mod',
}, function(source)
    if source == 0 then return end
    TriggerClientEvent('rps_core:client:toggleNoclip', source)
end)

lib.addCommand('coords', {
    help = 'Show and copy your coordinates',
    restricted = 'group.mod',
}, function(source)
    if source == 0 then return end
    TriggerClientEvent('rps_core:client:copyCoords', source)
end)

---------------------------------------------------------------------------
-- Moderation (mod)
---------------------------------------------------------------------------
lib.addCommand('kick', {
    help = 'Kick a player',
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'reason', type = 'longString', help = 'Reason', optional = true },
    },
    restricted = 'group.mod',
}, function(source, args)
    local reason = args.reason or 'Kicked by staff'
    Core.Notify(source, ('Kicked %s'):format(GetPlayerName(args.target)), 'success')
    DropPlayer(args.target, reason)
end)

lib.addCommand('announce', {
    help = 'Send an announcement to everyone',
    params = { { name = 'message', type = 'longString', help = 'Message' } },
    restricted = 'group.mod',
}, function(source, args)
    Core.Notify(-1, { title = 'Announcement', description = args.message, type = 'inform', icon = 'bullhorn', duration = 10000 })
end)

lib.addCommand('dv', {
    help = 'Delete your vehicle, the nearest one, or all within a radius',
    params = { { name = 'radius', type = 'number', help = 'Radius in metres (max 50)', optional = true } },
    restricted = 'group.mod',
}, function(source, args)
    if source == 0 then return end
    local ped = GetPlayerPed(source)
    local origin = GetEntityCoords(ped)
    local removed = 0

    if args.radius then
        local radius = math.min(args.radius, 50.0)
        for _, vehicle in ipairs(GetAllVehicles()) do
            if #(GetEntityCoords(vehicle) - origin) <= radius then
                DeleteEntity(vehicle)
                removed = removed + 1
            end
        end
    else
        local vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle == 0 then
            local closest = 5.0
            for _, v in ipairs(GetAllVehicles()) do
                local distance = #(GetEntityCoords(v) - origin)
                if distance < closest then vehicle, closest = v, distance end
            end
        end
        if vehicle ~= 0 then
            DeleteEntity(vehicle)
            removed = 1
        end
    end

    Core.Notify(source, removed > 0 and ('Deleted %d vehicle(s)'):format(removed) or 'No vehicle nearby', removed > 0 and 'success' or 'error')
end)

---------------------------------------------------------------------------
-- Admin
---------------------------------------------------------------------------
lib.addCommand('car', {
    help = 'Spawn a vehicle',
    params = { { name = 'model', type = 'string', help = 'Model name, e.g. adder' } },
    restricted = 'group.admin',
}, function(source, args)
    if source == 0 then return end
    TriggerClientEvent('rps_core:client:spawnVehicle', source, args.model)
end)

lib.addCommand('kill', {
    help = 'Kill a player',
    params = { { name = 'target', type = 'playerId', help = 'Server ID' } },
    restricted = 'group.admin',
}, function(source, args)
    TriggerClientEvent('rps_core:client:kill', args.target)
end)

lib.addCommand('setmoney', {
    help = "Set a player's balance",
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'account', type = 'string', help = 'cash / bank' },
        { name = 'amount', type = 'number', help = 'Amount' },
    },
    restricted = 'group.admin',
}, function(source, args)
    local player = loaded(source, args.target)
    if not player then return end
    local amount = math.floor(args.amount)
    if not player.setMoney(args.account, amount, 'admin') then
        return Core.Notify(source, 'Invalid account or amount', 'error')
    end
    Core.Notify(source, ("Set %s's %s to $%d"):format(player.getName(), args.account, amount), 'success')
end)

lib.addCommand('removemoney', {
    help = 'Take money from a player',
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'account', type = 'string', help = 'cash / bank' },
        { name = 'amount', type = 'number', help = 'Amount' },
    },
    restricted = 'group.admin',
}, function(source, args)
    local player = loaded(source, args.target)
    if not player then return end
    local amount = math.floor(args.amount)
    if not player.removeMoney(args.account, amount, 'admin') then
        return Core.Notify(source, 'Invalid account, or not enough money', 'error')
    end
    Core.Notify(source, ('Took $%d (%s) from %s'):format(amount, args.account, player.getName()), 'success')
end)

lib.addCommand('giveitem', {
    help = 'Give an item to a player',
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'item', type = 'string', help = 'Item name' },
        { name = 'count', type = 'number', help = 'Amount (default 1)', optional = true },
    },
    restricted = 'group.admin',
}, function(source, args)
    if not inventoryStarted(source) then return end
    if not exports.ox_inventory:Items(args.item) then
        return Core.Notify(source, ('No item named %s'):format(args.item), 'error')
    end
    local count = math.max(1, math.floor(args.count or 1))
    local ok, response = exports.ox_inventory:AddItem(args.target, args.item, count)
    if not ok then
        return Core.Notify(source, ('Could not give the item (%s)'):format(response or 'unknown'), 'error')
    end
    Core.Notify(source, ('Gave %dx %s to %s'):format(count, args.item, GetPlayerName(args.target)), 'success')
end)

lib.addCommand('clearinv', {
    help = "Clear a player's inventory",
    params = { { name = 'target', type = 'playerId', help = 'Server ID' } },
    restricted = 'group.admin',
}, function(source, args)
    if not inventoryStarted(source) then return end
    exports.ox_inventory:ClearInventory(args.target)
    Core.Notify(source, ("Cleared %s's inventory"):format(GetPlayerName(args.target)), 'success')
end)

---------------------------------------------------------------------------
-- Staff menu (/admin): a UI over the commands above, so every action still
-- goes through the command's own permission check
---------------------------------------------------------------------------
lib.addCommand('admin', {
    help = 'Open the staff menu',
    restricted = 'group.mod',
}, function(source)
    if source == 0 then return end
    TriggerClientEvent('rps_core:client:openAdminMenu', source, Core.HasGroup(source, 'admin'))
end)

lib.callback.register('rps_core:admin:getPlayers', function(source)
    if not (Core.HasGroup(source, 'mod') or IsPlayerAceAllowed(source, 'command.admin')) then return end

    local list = {}
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        local player = Core.GetPlayer(id)
        local job = player and player.getJob()
        list[#list + 1] = {
            id = id,
            name = GetPlayerName(id),
            character = player and player.getName() or nil,
            job = job and ('%s - %s'):format(job.label, job.gradeLabel) or nil,
        }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end)
