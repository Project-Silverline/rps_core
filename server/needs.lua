-- Hunger and thirst: 0-100, kept in character metadata (`hunger` / `thirst`) so
-- every HUD and framework bridge sees the same values. Settings: Config.Needs.
if not Config.Needs.enabled then return end

local NEEDS = { hunger = true, thirst = true }

local function clamp(value)
    value = math.max(0, math.min(100, value))
    return math.floor(value * 10 + 0.5) / 10
end

-- amounts = { hunger = n, thirst = n } in points (0-100); negative values drain
local function addNeeds(player, amounts)
    for key in pairs(NEEDS) do
        local amount = tonumber(amounts[key])
        if amount and amount ~= 0 then
            local current = tonumber(player.getMeta(key)) or 100
            player.setMeta(key, clamp(current + amount))
        end
    end
end
Core.AddNeeds = addNeeds

---------------------------------------------------------------------------
-- Decay
---------------------------------------------------------------------------
CreateThread(function()
    local drain = { hunger = -Config.Needs.hungerRate, thirst = -Config.Needs.thirstRate }
    while true do
        Wait(Config.Needs.interval * 1000)
        for src, player in pairs(Core.Players) do
            -- downed players don't get hungrier
            if not Player(src).state.isDead then addNeeds(player, drain) end
        end
    end
end)

---------------------------------------------------------------------------
-- Eating and drinking
-- ox_inventory strips an item's client data on the server, so its `status`
-- (e.g. { hunger = 200000 }) is only known to the client. The client's report is
-- accepted only when the server has also seen that player use an item, within a
-- few seconds and once per use. Items in Config.Needs.items skip the client.
---------------------------------------------------------------------------
local WINDOW = 5 -- seconds between the item use and the client's status report
local pending = {} -- [src] = { used = bool, status = table?, time = os.time() }

local function tryApply(src)
    local entry = pending[src]
    if not (entry and entry.used and entry.status) then return end
    pending[src] = nil
    local player = Core.GetPlayer(src)
    if player then addNeeds(player, entry.status) end
end

AddEventHandler('ox_inventory:usedItem', function(src, name)
    local player = Core.GetPlayer(src)
    if not player then return end

    local fixed = Config.Needs.items[name]
    if fixed then
        pending[src] = nil
        return addNeeds(player, fixed)
    end

    local entry = pending[src]
    if entry and entry.status and not entry.used and os.time() - entry.time <= WINDOW then
        entry.used = true
        return tryApply(src)
    end
    pending[src] = { used = true, time = os.time() }
end)

RegisterNetEvent('rps_core:server:statusItemUsed', function(values)
    local src = source
    if type(values) ~= 'table' then return end

    -- ox / esx_status units: 1000000 = 100 points. Only restoring is accepted.
    local status = {}
    for key in pairs(NEEDS) do
        local value = tonumber(values[key])
        if value and value > 0 then status[key] = math.min(100, value / 10000) end
    end
    if not next(status) then return end

    local entry = pending[src]
    if entry and entry.used and not entry.status and os.time() - entry.time <= WINDOW then
        entry.status = status
        return tryApply(src)
    end
    pending[src] = { used = false, status = status, time = os.time() }
end)

AddEventHandler('rps_core:server:playerUnloaded', function(src)
    pending[src] = nil
end)
