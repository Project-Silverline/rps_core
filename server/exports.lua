exports('GetPlayer', Core.GetPlayer)
exports('GetPlayerByCharId', Core.GetPlayerByCharId)

exports('GetPlayers', function()
    local list = {}
    for src in pairs(Core.Players) do list[#list + 1] = src end
    return list
end)

exports('GetJobs', function()
    return Config.Jobs
end)

exports('GetGroups', function()
    return Config.Groups
end)

exports('HasGroup', Core.HasGroup)

-- Usable items (see server/main.lua). style: 'rps' (default), 'qb' or 'esx'
exports('RegisterUsableItem', Core.RegisterUsableItem)
exports('CanUseItem', Core.CanUseItem)
exports('UseItem', Core.UseItem)

-- Saves and unloads the character, then sends the player back to character selection
exports('Logout', function(src)
    src = tonumber(src)
    if not Core.GetPlayer(src) then return false end
    -- saving waits on the database, and an export can't yield back into its caller
    CreateThread(function()
        Core.UnloadPlayer(src)
        TriggerClientEvent('rps_core:client:logout', src)
    end)
    return true
end)
