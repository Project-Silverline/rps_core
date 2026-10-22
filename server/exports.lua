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
