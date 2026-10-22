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
    if not player.addMoney(args.account, args.amount, 'admin') then
        return Core.Notify(source, 'Invalid account or amount', 'error')
    end
    Core.Notify(source, ('Gave $%d (%s) to %s'):format(args.amount, args.account, player.getName()), 'success')
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
