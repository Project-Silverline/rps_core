PlayerData = {}
IsLoaded = false

RegisterNetEvent('rps_core:client:setAccounts', function(accounts)
    PlayerData.accounts = accounts
    TriggerEvent('rps_core:client:accountsChanged', accounts)
end)

RegisterNetEvent('rps_core:client:setJob', function(job)
    PlayerData.job = job
    TriggerEvent('rps_core:client:jobChanged', job)
end)

RegisterNetEvent('rps_core:client:setGroup', function(group)
    PlayerData.group = group
end)

RegisterNetEvent('rps_core:client:setMeta', function(key, value)
    if PlayerData.metadata then PlayerData.metadata[key] = value end
    TriggerEvent('rps_core:client:metaChanged', key, value)
end)

exports('GetPlayerData', function() return PlayerData end)
exports('IsLoaded', function() return IsLoaded end)
exports('GetJobs', function() return Config.Jobs end)
