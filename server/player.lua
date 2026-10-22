-- All state lives in upvalues and is reached through functions, so the
-- object works correctly when passed to other resources through exports
-- (exports copy plain fields, but functions stay live references).

local function decode(str, fallback)
    if not str then return fallback end
    local ok, value = pcall(json.decode, str)
    return (ok and value) or fallback
end

function Core.CreatePlayer(src, license, group, row)
    local self = {
        source = src,
        license = license,
        charId = row.id,
    }

    local principal = ('player.%s'):format(src)
    local charinfo = { firstname = row.firstname, lastname = row.lastname, dob = row.dob, sex = row.sex }
    local accounts = decode(row.accounts, {})
    local metadata = decode(row.metadata, {})
    local position = decode(row.position, nil)
    local job = { name = row.job, grade = row.job_grade }

    for name, start in pairs(Config.StartingAccounts) do
        if accounts[name] == nil then accounts[name] = start end
    end
    for key, value in pairs(Config.DefaultMetadata) do
        if metadata[key] == nil then metadata[key] = value end
    end
    if not (Config.Jobs[job.name] and Config.Jobs[job.name].grades[job.grade]) then
        job = { name = 'unemployed', grade = 0 }
    end
    -- duty isn't saved: every session starts on the job's default (on duty unless defaultDuty = false)
    job.onduty = Config.Jobs[job.name].defaultDuty ~= false
    if not Core.IsValidGroup(group) then group = Config.DefaultGroup end

    -----------------------------------------------------------------------
    -- Identity
    -----------------------------------------------------------------------
    function self.getName()
        return ('%s %s'):format(charinfo.firstname, charinfo.lastname)
    end

    function self.getCharInfo()
        return charinfo
    end

    -----------------------------------------------------------------------
    -- Money
    -----------------------------------------------------------------------
    local function syncAccounts()
        TriggerClientEvent('rps_core:client:setAccounts', src, accounts)
    end

    local function toAmount(value)
        value = math.floor(tonumber(value) or 0)
        return value > 0 and value or nil
    end

    function self.getAccounts()
        return accounts
    end

    function self.getMoney(account)
        return accounts[account] or 0
    end

    function self.addMoney(account, amount, reason)
        amount = toAmount(amount)
        if not amount or accounts[account] == nil then return false end
        accounts[account] = accounts[account] + amount
        syncAccounts()
        TriggerEvent('rps_core:server:moneyChanged', src, account, accounts[account], amount, reason)
        return true
    end

    function self.removeMoney(account, amount, reason)
        amount = toAmount(amount)
        if not amount or accounts[account] == nil or accounts[account] < amount then return false end
        accounts[account] = accounts[account] - amount
        syncAccounts()
        TriggerEvent('rps_core:server:moneyChanged', src, account, accounts[account], -amount, reason)
        return true
    end

    function self.setMoney(account, amount, reason)
        amount = math.floor(tonumber(amount) or -1)
        if amount < 0 or accounts[account] == nil then return false end
        local diff = amount - accounts[account]
        accounts[account] = amount
        syncAccounts()
        TriggerEvent('rps_core:server:moneyChanged', src, account, amount, diff, reason)
        return true
    end

    -----------------------------------------------------------------------
    -- Job
    -----------------------------------------------------------------------
    function self.getJob()
        local def = Config.Jobs[job.name]
        local grade = def.grades[job.grade]
        return {
            name = job.name,
            label = def.label,
            grade = job.grade,
            gradeLabel = grade.label,
            salary = grade.salary or 0,
            boss = grade.boss or false,
            onduty = job.onduty,
        }
    end

    local function jobUpdated(old)
        local new = self.getJob()
        Player(src).state:set('job', new, true)
        TriggerClientEvent('rps_core:client:setJob', src, new)
        TriggerEvent('rps_core:server:jobChanged', src, new, old)
    end

    function self.setJob(name, grade)
        grade = math.floor(tonumber(grade) or 0)
        local def = Config.Jobs[name]
        if not def or not def.grades[grade] then return false end

        local old = self.getJob()
        job = { name = name, grade = grade, onduty = def.defaultDuty ~= false }
        jobUpdated(old)
        return true
    end

    function self.setDuty(onduty)
        onduty = onduty and true or false
        if job.onduty == onduty then return end
        local old = self.getJob()
        job.onduty = onduty
        jobUpdated(old)
    end

    -----------------------------------------------------------------------
    -- Group / permissions
    -----------------------------------------------------------------------
    function self.getGroup()
        return group
    end

    function self.setGroup(name)
        if not Core.IsValidGroup(name) then return false end
        lib.removePrincipal(principal, ('group.%s'):format(group))
        group = name
        lib.addPrincipal(principal, ('group.%s'):format(group))

        MySQL.update('UPDATE users SET `group` = ? WHERE license = ?', { group, license })
        Player(src).state:set('group', group, true)
        TriggerClientEvent('rps_core:client:setGroup', src, group)
        return true
    end

    function self.hasPermission(ace)
        return IsPlayerAceAllowed(src, ace)
    end

    -----------------------------------------------------------------------
    -- Metadata (hunger, thirst, licenses, anything persistent)
    -----------------------------------------------------------------------
    function self.getMeta(key)
        if key then return metadata[key] end
        return metadata
    end

    function self.setMeta(key, value)
        metadata[key] = value
        TriggerClientEvent('rps_core:client:setMeta', src, key, value)
        TriggerEvent('rps_core:server:metaChanged', src, key, value)
    end

    -----------------------------------------------------------------------
    -- Persistence
    -----------------------------------------------------------------------
    local function updatePosition()
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            local c = GetEntityCoords(ped)
            position = { x = c.x, y = c.y, z = c.z, w = GetEntityHeading(ped) }
        end
    end

    function self.getPosition()
        updatePosition()
        return position
    end

    function self.save()
        updatePosition()
        MySQL.update.await(
            'UPDATE characters SET accounts = ?, job = ?, job_grade = ?, position = ?, metadata = ?, last_played = NOW() WHERE id = ?',
            { json.encode(accounts), job.name, job.grade, position and json.encode(position), json.encode(metadata), self.charId }
        )
    end

    -----------------------------------------------------------------------
    -- Snapshot sent to the client on load
    -----------------------------------------------------------------------
    function self.getData()
        return {
            source = src,
            charId = self.charId,
            charinfo = charinfo,
            accounts = accounts,
            job = self.getJob(),
            group = group,
            metadata = metadata,
            position = position,
        }
    end

    -- Initial state
    lib.addPrincipal(principal, ('group.%s'):format(group))
    local state = Player(src).state
    state:set('job', self.getJob(), true)
    state:set('group', group, true)
    state:set('isLoggedIn', true, true) -- read by QB/Qbox scripts through the bridges

    return self
end
