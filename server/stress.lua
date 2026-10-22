-- Stress: 0-100, kept in character metadata (`stress`) like hunger and thirst, so
-- HUDs and the framework bridges see it. Settings: Config.Stress.
if not Config.Stress.enabled then return end

local function clamp(value)
    return math.floor(math.max(0, math.min(100, value)) + 0.5)
end

-- amount > 0 adds stress, < 0 relieves it
local function changeStress(player, amount)
    amount = tonumber(amount)
    if not amount or amount == 0 then return end
    local current = tonumber(player.getMeta('stress')) or 0
    local new = clamp(current + amount)
    if new ~= current then player.setMeta('stress', new) end
end
Core.ChangeStress = changeStress

local function ignored(player)
    local job = player.getJob()
    return Config.Stress.ignoreJobs[job.name] and job.onduty
end

---------------------------------------------------------------------------
-- Client reports
-- Shooting and speeding are only visible to the client. Gains are capped per
-- event and rate limited; a client can't remove its own stress this way.
---------------------------------------------------------------------------
local lastGain = {} -- [src] = GetGameTimer() of the last accepted gain

local function clientGain(src, amount)
    local player = Core.GetPlayer(src)
    amount = tonumber(amount)
    if not player or not amount or amount <= 0 or ignored(player) then return end

    local now = GetGameTimer()
    if lastGain[src] and now - lastGain[src] < 900 then return end
    lastGain[src] = now

    changeStress(player, math.min(amount, Config.Stress.maxClientChange))
end

RegisterNetEvent('rps_core:server:gainStress', function(amount)
    clientGain(source, amount)
end)

-- The event names QBCore scripts (and ps-hud / qb-hud) use, so their stress
-- sources and relief items work unchanged. Relief is capped the same way.
RegisterNetEvent('hud:server:GainStress', function(amount)
    clientGain(source, amount)
end)

RegisterNetEvent('hud:server:RelieveStress', function(amount)
    local player = Core.GetPlayer(source)
    amount = tonumber(amount)
    if not player or not amount or amount <= 0 then return end
    changeStress(player, -math.min(amount, Config.Stress.maxClientChange))
end)

AddEventHandler('playerDropped', function()
    lastGain[source] = nil
end)

---------------------------------------------------------------------------
-- Relief over time, and from items
---------------------------------------------------------------------------
CreateThread(function()
    while true do
        Wait(Config.Stress.decayInterval * 1000)
        for _, player in pairs(Core.Players) do
            if (tonumber(player.getMeta('stress')) or 0) > 0 then
                changeStress(player, -Config.Stress.decay)
            end
        end
    end
end)

AddEventHandler('ox_inventory:usedItem', function(src, name)
    local relief = Config.Stress.items[name]
    local player = relief and Core.GetPlayer(src)
    if player then changeStress(player, -relief) end
end)

-- For other resources: exports.rps_core:AddStress(source, 10) / RemoveStress(source, 10)
exports('AddStress', function(src, amount)
    local player = Core.GetPlayer(src)
    if player and tonumber(amount) and amount > 0 then changeStress(player, amount) end
end)

exports('RemoveStress', function(src, amount)
    local player = Core.GetPlayer(src)
    if player and tonumber(amount) and amount > 0 then changeStress(player, -amount) end
end)
