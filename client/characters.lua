-- Character selection is done by rps_multicharacter. rps_core only loads the
-- character it picks, and hands control back to it on logout.

local function loadCharacter(id)
    local data = lib.callback.await('rps_core:selectCharacter', false, id)
    if not data then return false end

    SpawnPlayer(data)
    PlayerData = data
    IsLoaded = true
    TriggerEvent('rps_core:client:playerLoaded', PlayerData)
    return true
end

-- Sent by rps_multicharacter. An event rather than an export, because loading
-- waits on the server and an export can't yield across resources.
AddEventHandler('rps_core:client:selectCharacter', function(id)
    if IsLoaded then return end
    if not loadCharacter(id) then
        TriggerEvent('rps_core:client:selectFailed', id)
    end
end)

RegisterNetEvent('rps_core:client:logout', function()
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    PlayerData = {}
    IsLoaded = false
    TriggerEvent('rps_core:client:playerUnloaded')
    TriggerEvent('rps_core:client:openSelection')
end)

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(100) end

    -- rps_multicharacter opens itself on join; just keep spawnmanager out of the way
    if GetResourceState('spawnmanager') == 'started' then
        exports.spawnmanager:setAutoSpawn(false)
    end
end)
