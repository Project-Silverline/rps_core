Core = {
    Players = {},  -- [source] = player object
    ByCharId = {}, -- [charId] = source
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function Core.Notify(src, msg, notifyType)
    if src == 0 then return print(('[rps_core] %s'):format(msg)) end
    TriggerClientEvent('ox_lib:notify', src, { description = msg, type = notifyType or 'inform' })
end

function Core.GetPlayer(src)
    return Core.Players[tonumber(src)]
end

function Core.GetPlayerByCharId(charId)
    local src = Core.ByCharId[tonumber(charId)]
    return src and Core.Players[src]
end

function Core.IsValidGroup(name)
    for _, g in ipairs(Config.Groups) do
        if g == name then return true end
    end
    return false
end

-- 1 = lowest group; nil for unknown names
function Core.GroupRank(name)
    for i, g in ipairs(Config.Groups) do
        if g == name then return i end
    end
end

-- true if the player's group is `group` or higher (groups inherit downwards)
function Core.HasGroup(src, group)
    local player = Core.GetPlayer(src)
    local have, need = player and Core.GroupRank(player.getGroup()), Core.GroupRank(group)
    return have ~= nil and need ~= nil and have >= need
end

---------------------------------------------------------------------------
-- Usable items
-- ox_inventory hands items with no client/server export of their own to its
-- bridge's server.UseItem, which calls Core.UseItem. Callbacks are registered
-- here by rps resources and by the QB / ESX / Qbox bridges, each in their own
-- calling style.
---------------------------------------------------------------------------
Core.UsableItems = {} -- [name] = { cb = function, style = 'rps' | 'qb' | 'esx', resource = string }

-- resource: who owns the callback. Defaults to the resource calling in, which is
-- also right when a bridge forwards a script's registration.
function Core.RegisterUsableItem(name, cb, style, resource)
    Core.UsableItems[name] = {
        cb = cb,
        style = style or 'rps',
        resource = resource or GetInvokingResource() or GetCurrentResourceName(),
    }
end

-- A stopped resource's callbacks are dead references: drop them, whichever
-- bridge registered them
AddEventHandler('onResourceStop', function(resource)
    for name, entry in pairs(Core.UsableItems) do
        if entry.resource == resource then Core.UsableItems[name] = nil end
    end
end)

function Core.CanUseItem(name)
    return Core.UsableItems[name] ~= nil
end

-- data is ox_inventory's slot: { name, label, count, slot, metadata, weight }.
-- Callbacks run in their own thread: they often wait (progress bars, database),
-- and this is reached through an export, which can't yield back to its caller.
function Core.UseItem(src, name, data)
    local entry = Core.UsableItems[name]
    if not entry then return false end

    CreateThread(function()
        if entry.style == 'qb' then
            entry.cb(src, {
                name = data.name, label = data.label, amount = data.count, count = data.count,
                info = data.metadata or {}, metadata = data.metadata or {}, slot = data.slot, weight = data.weight,
            })
        elseif entry.style == 'esx' then
            entry.cb(src, name, data)
        else
            entry.cb(src, data)
        end
    end)

    return true
end

-- Group inheritance: admin -> mod -> user
for i = #Config.Groups, 2, -1 do
    lib.addPrincipal(('group.%s'):format(Config.Groups[i]), ('group.%s'):format(Config.Groups[i - 1]))
end

---------------------------------------------------------------------------
-- Connection
---------------------------------------------------------------------------
AddEventHandler('playerConnecting', function(name, _, deferrals)
    local src = source
    deferrals.defer()
    Wait(0)
    deferrals.update('Checking your Rockstar license...')

    local license = GetPlayerIdentifierByType(src, 'license')
    if not license then
        return deferrals.done('No Rockstar license found. Restart FiveM and try again.')
    end

    for _, id in ipairs(GetPlayers()) do
        if GetPlayerIdentifierByType(id, 'license') == license then
            return deferrals.done('This license is already connected to the server.')
        end
    end

    local ok = pcall(MySQL.insert.await,
        'INSERT INTO users (license, name) VALUES (?, ?) ON DUPLICATE KEY UPDATE name = VALUES(name)',
        { license, name })

    if not ok then
        return deferrals.done('Database unavailable, please try again shortly.')
    end

    deferrals.done()
end)

---------------------------------------------------------------------------
-- Load / unload
---------------------------------------------------------------------------
function Core.UnloadPlayer(src)
    local player = Core.Players[src]
    if not player then return end

    player.save()
    lib.removePrincipal(('player.%s'):format(src), ('group.%s'):format(player.getGroup()))

    Core.ByCharId[player.charId] = nil
    Core.Players[src] = nil

    local state = Player(src).state
    state:set('job', nil, true)
    state:set('group', nil, true)
    state:set('isLoggedIn', false, true)

    TriggerEvent('rps_core:server:playerUnloaded', src, player.charId)
end

AddEventHandler('playerDropped', function()
    Core.UnloadPlayer(source)
end)

function Core.SaveAll()
    -- Saving waits on the database, and players can load or drop meanwhile,
    -- so work from a copy and skip anyone unloaded since it was taken.
    local players = {}
    for _, player in pairs(Core.Players) do players[#players + 1] = player end

    for _, player in ipairs(players) do
        if Core.Players[player.source] == player then player.save() end
    end
end

AddEventHandler('txAdmin:events:serverShuttingDown', Core.SaveAll)

---------------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(Config.SaveInterval)
        Core.SaveAll()
    end
end)

CreateThread(function()
    while true do
        Wait(Config.PaycheckInterval)
        for src, player in pairs(Core.Players) do
            local job = player.getJob()
            if job.salary > 0 then
                player.addMoney('bank', job.salary, 'paycheck')
                Core.Notify(src, ('Paycheck received: $%d'):format(job.salary), 'success')
            end
        end
    end
end)
