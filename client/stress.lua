-- Client side of stress (server/stress.lua): detects shooting and speeding, and
-- shakes or blurs the screen when stress is high.
if not Config.Stress.enabled then return end

local ignoreWeapons = {}
for _, hash in ipairs(Config.Stress.ignoreWeapons) do ignoreWeapons[hash] = true end

local function stress()
    local meta = IsLoaded and PlayerData.metadata
    return meta and tonumber(meta.stress) or 0
end

-- Shooting: one report per second of firing at most (the server also rate limits)
CreateThread(function()
    local firing = false
    local lastReport = 0
    while true do
        local ped = cache.ped
        if IsLoaded and IsPedArmed(ped, 6) then
            if IsPedShooting(ped) and not ignoreWeapons[GetSelectedPedWeapon(ped)] then firing = true end
            local now = GetGameTimer()
            if firing and now - lastReport >= 1000 then
                TriggerServerEvent('rps_core:server:gainStress', Config.Stress.shootingGain)
                firing = false
                lastReport = now
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- Speeding: drivers above the threshold, checked every 10 seconds
CreateThread(function()
    local mph = 2.236936
    while true do
        Wait(10000)
        local vehicle = IsLoaded and cache.vehicle
        if vehicle and GetPedInVehicleSeat(vehicle, -1) == cache.ped then
            local class = GetVehicleClass(vehicle)
            -- boats, helicopters and planes don't count
            if class ~= 14 and class ~= 15 and class ~= 16
                and GetEntitySpeed(vehicle) * mph > Config.Stress.speedingThreshold then
                TriggerServerEvent('rps_core:server:gainStress', Config.Stress.speedingGain)
            end
        end
    end
end)

-- Effects: shake more often (and harder) as stress rises; blur near the top
CreateThread(function()
    while true do
        local level = stress()
        if level >= Config.Stress.effectsAt and not LocalPlayer.state.isDead then
            local strength = (level - Config.Stress.effectsAt) / (100 - Config.Stress.effectsAt) -- 0..1
            ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', 0.04 + strength * 0.12)

            if level >= Config.Stress.blurAt then
                TriggerScreenblurFadeIn(500)
                Wait(800)
                TriggerScreenblurFadeOut(500)
            end

            -- every 30 s at the threshold, down to every 8 s at full stress
            Wait(math.floor(30000 - strength * 22000))
        else
            Wait(5000)
        end
    end
end)
