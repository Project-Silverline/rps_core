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
