lib.addCommand('setjob', {
    help = "Set a player's job",
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'job', type = 'string', help = 'Job name' },
        { name = 'grade', type = 'number', help = 'Grade (default 0)', optional = true },
    },
    restricted = 'group.admin',
}, function(source, args)
    local player = Core.GetPlayer(args.target)
    if not player then return Core.Notify(source, 'That player has no character loaded', 'error') end
    if not player.setJob(args.job, args.grade or 0) then
        return Core.Notify(source, 'Invalid job or grade', 'error')
    end
    Core.Notify(source, ('%s is now %s'):format(player.getName(), player.getJob().gradeLabel), 'success')
end)

lib.addCommand('givemoney', {
    help = 'Give money to a player',
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'account', type = 'string', help = 'cash / bank' },
        { name = 'amount', type = 'number', help = 'Amount' },
    },
    restricted = 'group.admin',
}, function(source, args)
    local player = Core.GetPlayer(args.target)
    if not player then return Core.Notify(source, 'That player has no character loaded', 'error') end
    local amount = math.floor(args.amount)
    if not player.addMoney(args.account, amount, 'admin') then
        return Core.Notify(source, 'Invalid account or amount', 'error')
    end
    Core.Notify(source, ('Gave $%d (%s) to %s'):format(amount, args.account, player.getName()), 'success')
end)

lib.addCommand('setgroup', {
    help = "Set a player's permission group",
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'group', type = 'string', help = table.concat(Config.Groups, ' / ') },
    },
    restricted = 'group.admin',
}, function(source, args)
    local player = Core.GetPlayer(args.target)
    if not player then return Core.Notify(source, 'That player has no character loaded', 'error') end
    if not player.setGroup(args.group) then
        return Core.Notify(source, 'Invalid group', 'error')
    end
    Core.Notify(source, ('%s is now in group %s'):format(player.getName(), args.group), 'success')
end)

lib.addCommand('logout', {
    help = 'Return to character selection',
}, function(source)
    if source == 0 or not Core.GetPlayer(source) then return end
    Core.UnloadPlayer(source)
    TriggerClientEvent('rps_core:client:logout', source)
end)

---------------------------------------------------------------------------
-- Player commands
---------------------------------------------------------------------------
local function self(source)
    if source == 0 then return end
    local player = Core.GetPlayer(source)
    if not player then Core.Notify(source, 'Load a character first', 'error') end
    return player
end

lib.addCommand('id', { help = 'Show your server ID' }, function(source)
    if source == 0 then return end
    Core.Notify(source, ('Your server ID is %d'):format(source), 'inform')
end)

lib.addCommand('job', { help = 'Show your job' }, function(source)
    local player = self(source)
    if not player then return end
    local job = player.getJob()
    Core.Notify(source, ('%s - %s (%s)'):format(job.label, job.gradeLabel, job.onduty and 'on duty' or 'off duty'), 'inform')
end)

lib.addCommand('cash', { help = 'Show your cash' }, function(source)
    local player = self(source)
    if player then Core.Notify(source, ('Cash: $%d'):format(player.getMoney('cash')), 'inform') end
end)

lib.addCommand('bank', { help = 'Show your bank balance' }, function(source)
    local player = self(source)
    if player then Core.Notify(source, ('Bank: $%d'):format(player.getMoney('bank')), 'inform') end
end)

lib.addCommand('duty', { help = 'Go on or off duty' }, function(source)
    local player = self(source)
    if not player then return end
    local job = player.getJob()
    if job.name == 'unemployed' then return Core.Notify(source, "You don't have a job", 'error') end
    player.setDuty(not job.onduty)
    Core.Notify(source, job.onduty and 'You are now off duty' or 'You are now on duty', 'success')
end)

lib.addCommand('givecash', {
    help = 'Hand cash to a nearby player',
    params = {
        { name = 'target', type = 'playerId', help = 'Server ID' },
        { name = 'amount', type = 'number', help = 'Amount' },
    },
}, function(source, args)
    local player = self(source)
    if not player then return end
    local target = Core.GetPlayer(args.target)
    local amount = math.floor(args.amount)

    if args.target == source or not target then
        return Core.Notify(source, 'Invalid player', 'error')
    end
    if amount <= 0 then
        return Core.Notify(source, 'Invalid amount', 'error')
    end
    if #(GetEntityCoords(GetPlayerPed(source)) - GetEntityCoords(GetPlayerPed(args.target))) > Config.Commands.giveCashDistance then
        return Core.Notify(source, 'That player is too far away', 'error')
    end
    if not player.removeMoney('cash', amount, 'givecash') then
        return Core.Notify(source, "You don't have that much cash", 'error')
    end

    target.addMoney('cash', amount, 'givecash')
    Core.Notify(source, ('You gave $%d to %s'):format(amount, target.getName()), 'success')
    Core.Notify(args.target, ('%s gave you $%d'):format(player.getName(), amount), 'success')
end)

-- /me and /do: text floating above the player, shown to everyone nearby
local function emote(kind)
    return function(source, args)
        local player = self(source)
        if not player then return end
        local origin = GetEntityCoords(GetPlayerPed(source))
        for _, id in ipairs(GetPlayers()) do
            id = tonumber(id)
            if #(GetEntityCoords(GetPlayerPed(id)) - origin) <= Config.Commands.meDistance then
                TriggerClientEvent('rps_core:client:emote', id, source, kind, args.text)
            end
        end
    end
end

lib.addCommand('me', {
    help = 'Describe an action your character does',
    params = { { name = 'text', type = 'longString' } },
}, emote('me'))

lib.addCommand('do', {
    help = 'Describe the scene or the result of an action',
    params = { { name = 'text', type = 'longString' } },
}, emote('do'))

lib.addCommand('ooc', {
    help = 'Out-of-character chat to everyone',
    params = { { name = 'message', type = 'longString' } },
}, function(source, args)
    if source == 0 then return end
    TriggerClientEvent('chat:addMessage', -1, {
        color = { 160, 160, 160 },
        multiline = true,
        args = { ('OOC | %s (%d)'):format(GetPlayerName(source), source), args.message },
    })
end)

local lastReport = {}

lib.addCommand('report', {
    help = 'Send a message to online staff',
    params = { { name = 'message', type = 'longString' } },
}, function(source, args)
    if source == 0 then return end
    local now = os.time()
    if lastReport[source] and now - lastReport[source] < Config.Commands.reportCooldown then
        return Core.Notify(source, ('Wait %d seconds before reporting again'):format(Config.Commands.reportCooldown - (now - lastReport[source])), 'error')
    end

    local staff = 0
    for _, id in ipairs(GetPlayers()) do
        id = tonumber(id)
        if Core.HasGroup(id, 'mod') then
            staff = staff + 1
            Core.Notify(id, {
                title = ('Report from %s (%d)'):format(GetPlayerName(source), source),
                description = args.message, type = 'warning', icon = 'flag', duration = 15000,
            })
        end
    end

    if staff == 0 then
        return Core.Notify(source, 'No staff are online right now', 'error')
    end
    lastReport[source] = now
    Core.Notify(source, 'Your report was sent to staff', 'success')
end)

AddEventHandler('playerDropped', function()
    lastReport[source] = nil
end)
