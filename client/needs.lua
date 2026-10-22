-- Client side of hunger and thirst (server/needs.lua)
if not Config.Needs.enabled then return end

-- Fired by the ox_inventory rps bridge when a food or drink item with a `status` is
-- used. The server only accepts it alongside its own record of the item use.
AddEventHandler('rps:client:statusItemUsed', function(values)
    TriggerServerEvent('rps_core:server:statusItemUsed', values)
end)

-- Starving or dehydrated: lose health until you eat or drink
CreateThread(function()
    while true do
        Wait(Config.Needs.damageInterval * 1000)
        local meta = IsLoaded and PlayerData.metadata
        if meta and ((tonumber(meta.hunger) or 100) <= 0 or (tonumber(meta.thirst) or 100) <= 0) then
            local ped = cache.ped
            if not IsEntityDead(ped) and not LocalPlayer.state.isDead then
                ApplyDamageToPed(ped, Config.Needs.damage, false)
            end
        end
    end
end)
