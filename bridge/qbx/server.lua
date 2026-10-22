-- Qbox (qbx_core) bridge, server side. Answers exports.qbx_core:* from inside
-- rps_core. Players are the QB Player objects of the qb-core bridge (Qbox
-- exposes the same shape) with the Qbox-only fields added; jobs and money
-- are read from and written to rps_core.

local Q = require 'bridge.qbx.shared'
local export = Q.export

local QBCore

-- Fetched lazily: the QB bridge may load after this file.
local function core()
    if not QBCore then QBCore = exports['qb-core']:GetCoreObject() end
    return QBCore
end

---Shallow copy of a QB player with Qbox's PlayerData fields; the Functions stay live.
local function wrap(player)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return end
    local copy = {}
    for k, v in pairs(player) do copy[k] = v end
    copy.PlayerData = Q.decorate(player.PlayerData)
    copy.Offline = false
    return copy
end

---------------------------------------------------------------------------
-- Getters
---------------------------------------------------------------------------
---@param identifier string e.g. 'license:abc'
---@return integer source, 0 if nobody with a loaded character has it
local function getSource(identifier)
    if type(identifier) ~= 'string' then return 0 end
    for src in pairs(Core.Players) do
        for _, id in ipairs(GetPlayerIdentifiers(src)) do
            if id == identifier then return src end
        end
    end
    return 0
end

---@param source integer|string server id, or an identifier such as 'license:abc'
local function getPlayer(source)
    local src = tonumber(source)
    if not src then
        src = getSource(source)
        if src == 0 then return end
    end
    return wrap(core().Functions.GetPlayer(src))
end

local function getPlayerByCitizenId(citizenid)
    if not citizenid then return end
    return wrap(core().Functions.GetPlayerByCitizenId(citizenid))
end

---Qbox convention: a string is a citizenid, a number a server id. RPS citizenids
---are numeric strings ("7"), so never treat a string as a server id.
local function resolvePlayer(identifier)
    if type(identifier) == 'string' then
        return getPlayerByCitizenId(identifier)
    end
    return getPlayer(tonumber(identifier))
end

---@return table? rpsPlayer
local function resolveRpsPlayer(identifier)
    local src
    if type(identifier) == 'string' then
        local player = core().Functions.GetPlayerByCitizenId(identifier)
        src = player and player.PlayerData.source
    else
        src = tonumber(identifier)
    end
    return src and Core.GetPlayer(src)
end

local function getQBPlayers()
    local players = {}
    for src, player in pairs(core().Functions.GetQBPlayers() or {}) do
        players[src] = wrap(player)
    end
    return players
end

export('GetSource', getSource)
export('GetPlayer', getPlayer)
export('GetPlayerByCitizenId', getPlayerByCitizenId)
export('GetQBPlayers', getQBPlayers)

-- Not a Qbox export; for scripts that expect it. Server ids with a loaded character.
export('GetPlayers', function()
    local list = {}
    for src in pairs(Core.Players) do list[#list + 1] = src end
    return list
end)

export('GetPlayersData', function()
    local list = {}
    for _, player in pairs(getQBPlayers()) do
        list[#list + 1] = player.PlayerData
    end
    return list
end)

export('GetPlayerByPhone', function(number)
    if not number then return end
    for _, player in pairs(getQBPlayers()) do
        local charinfo = player.PlayerData.charinfo
        if charinfo and charinfo.phone == number then return player end
    end
end)

-- RPS has no user accounts, and characters only exist while loaded.
export('GetPlayerByUserId', function() return nil end)
export('GetUserId', function() return 0 end)
export('GetOfflinePlayer', function() return nil end)
export('SearchPlayers', function() return {} end)

export('GetCoreVersion', function()
    return Q.version
end)

---------------------------------------------------------------------------
-- Login / logout / persistence
---------------------------------------------------------------------------
-- Characters are chosen through rps_core's own selection screen.
export('Login', function()
    lib.print.warn(('%s called qbx_core Login: characters load through rps_core character selection'):format(GetInvokingResource() or 'unknown'))
    return false
end)

export('Logout', function(source)
    local src = tonumber(source)
    if not src or not Core.GetPlayer(src) then return end
    -- Core.UnloadPlayer saves (waits on MySQL), so it runs in its own thread
    CreateThread(function()
        Core.UnloadPlayer(src)
        TriggerClientEvent('rps_core:client:logout', src)
    end)
end)

export('Save', function(source)
    local player = Core.GetPlayer(source)
    if player then CreateThread(player.save) end
end)

export('SaveOffline', function() end)

export('CreatePlayer', function()
    lib.print.warn('qbx_core CreatePlayer is not supported: characters are created by rps_core')
end)

export('DeleteCharacter', function()
    lib.print.warn('qbx_core DeleteCharacter is not supported: characters are deleted from rps_core character selection')
end)

-- Not checked against a database: RPS keeps no Qbox identifier tables.
export('GenerateUniqueIdentifier', function(idType)
    if idType == 'citizenid' then return lib.string.random('1AA11A11'):upper() end
    if idType == 'PhoneNumber' then return lib.string.random('1111111111') end
    if idType == 'FingerId' or idType == 'SerialNumber' then return lib.string.random('11AAA1AAA11AAAA1') end
    if idType == 'WalletId' then return 'QB-' .. lib.string.random('11111111') end
    return lib.string.random('AA11AAAA1111111111')
end)

export('SetPlayerData', function(identifier, key, value)
    if type(key) ~= 'string' then return end
    local player = resolvePlayer(identifier)
    if player then player.Functions.SetPlayerData(key, value) end
end)

export('UpdatePlayerData', function(identifier)
    local player = resolvePlayer(identifier)
    if player then player.Functions.UpdatePlayerData() end
end)

export('SetCharInfo', function()
    lib.print.warn('qbx_core SetCharInfo is not supported: character info is owned by rps_core')
end)

---------------------------------------------------------------------------
-- Jobs (single job: "adding" a job replaces the current one)
---------------------------------------------------------------------------
local function err(code, message)
    return false, { code = code, message = message }
end

local function validJob(name, grade)
    local def = Config.Jobs[name]
    if not def then return err('job_not_found', ('%s does not exist in core memory'):format(name)) end
    if not def.grades[grade] then return err('job_missing_grade', ('job %s does not have grade %s'):format(name, grade)) end
    return true
end

export('SetJob', function(identifier, jobName, grade)
    if type(jobName) ~= 'string' then return false end
    jobName, grade = jobName:lower(), math.tointeger(tonumber(grade) or 0) or 0
    local ok, result = validJob(jobName, grade)
    if not ok then return false, result end

    local player = resolveRpsPlayer(identifier)
    if not player then return err('player_not_found', ('player not found: %s'):format(identifier)) end
    return player.setJob(jobName, grade)
end)

export('AddPlayerToJob', function(citizenid, jobName, grade)
    if type(jobName) ~= 'string' then return false end
    jobName, grade = jobName:lower(), math.tointeger(tonumber(grade) or 0) or 0
    if jobName == 'unemployed' then return err('unemployed', 'players cannot be added to the unemployed job') end
    local ok, result = validJob(jobName, grade)
    if not ok then return false, result end

    local player = resolveRpsPlayer(citizenid)
    if not player then return err('player_not_found', ('player not found with citizenid %s'):format(citizenid)) end
    local job = player.getJob()
    if job.name == jobName and job.grade == grade then return true end
    return player.setJob(jobName, grade)
end)

export('RemovePlayerFromJob', function(citizenid, jobName)
    if jobName == 'unemployed' then return err('unemployed', 'players cannot be removed from the unemployed job') end
    local player = resolveRpsPlayer(citizenid)
    if not player then return err('player_not_found', ('player not found with citizenid %s'):format(citizenid)) end
    if player.getJob().name ~= jobName then return true end
    return player.setJob('unemployed', 0)
end)

export('SetPlayerPrimaryJob', function(citizenid, jobName)
    local player = resolveRpsPlayer(citizenid)
    if not player then return err('player_not_found', ('player not found with citizenid %s'):format(citizenid)) end
    local current = player.getJob().name
    if current == jobName then return true end
    -- the only other job a player "has" is unemployed, which means leaving the current one
    if jobName == 'unemployed' then return player.setJob('unemployed', 0) end
    return err('player_not_in_job', ('player %s does not have job %s'):format(citizenid, jobName))
end)

export('SetJobDuty', function(identifier, onDuty)
    local player = resolveRpsPlayer(identifier)
    if player then player.setDuty(not not onDuty) end
end)

---------------------------------------------------------------------------
-- Gangs (none in RPS: everyone is in 'none')
---------------------------------------------------------------------------
local function noGangs(gangName)
    return err('gang_not_found', ('%s does not exist in core memory'):format(gangName))
end

export('SetGang', function(_, gangName)
    if gangName == 'none' then return true end
    return noGangs(gangName)
end)

export('SetPlayerPrimaryGang', function(citizenid, gangName)
    if gangName == 'none' then return true end
    return err('player_not_in_gang', ('player %s does not have gang %s'):format(citizenid, gangName))
end)

export('AddPlayerToGang', function(_, gangName)
    if gangName == 'none' then return err('none', 'none is the default gang, so players cannot be added to it') end
    return noGangs(gangName)
end)

export('RemovePlayerFromGang', function(_, gangName)
    if gangName == 'none' then return err('none', 'none is the default gang, so players cannot be removed from it') end
    return true -- nobody is in it
end)

---------------------------------------------------------------------------
-- Group definitions and checks
---------------------------------------------------------------------------
export('GetJobs', Q.getJobs)
export('GetJob', Q.getJob)
export('GetGangs', Q.getGangs)
export('GetGang', Q.getGang)

local function playerData(source)
    local player = getPlayer(source)
    return player and player.PlayerData
end

export('GetGroups', function(source)
    return Q.getPlayerGroups(playerData(source))
end)

export('HasGroup', function(source, filter)
    return Q.hasGroup(filter, playerData(source))
end)

export('HasPrimaryGroup', function(source, filter)
    return Q.hasGroup(filter, playerData(source), true)
end)

export('IsGradeBoss', function(group, grade)
    local data = Q.getJob(group) or Q.getGang(group)
    local gradeData = data and data.grades[math.tointeger(tonumber(grade) or 0)]
    if not gradeData then return end
    return gradeData.isboss or false
end)

---Online members only: RPS keeps no group table to search offline characters.
---@return { citizenid: string, grade: integer }[]
export('GetGroupMembers', function(group, groupType)
    local members = {}
    if groupType == 'gang' then return members end
    for _, player in pairs(getQBPlayers()) do
        local job = player.PlayerData.job
        if job and job.name == group then
            members[#members + 1] = { citizenid = player.PlayerData.citizenid, grade = Q.gradeLevel(job.grade) }
        end
    end
    return members
end)

-- field: 'name' or 'type'
local function getDutyCount(field, value)
    local count, sources = 0, {}
    for src, player in pairs(Core.Players) do
        local job = player.getJob()
        if job.onduty then
            local jobValue = field == 'type' and Q.jobType(job.name) or job.name
            if jobValue == value then
                count += 1
                sources[count] = src
            end
        end
    end
    return count, sources
end

export('GetDutyCountJob', function(job) return getDutyCount('name', job) end)
export('GetDutyCountType', function(jobType) return getDutyCount('type', jobType) end)

-- Job definitions live in rps_core's shared/jobs.lua and can't be changed at runtime.
local function groupsReadOnly()
    lib.print.warn(('%s tried to change job/gang definitions; edit rps_core shared/jobs.lua instead'):format(GetInvokingResource() or 'unknown'))
    return false, 'not supported on RPS'
end

for _, name in ipairs({ 'CreateJob', 'CreateJobs', 'RemoveJob', 'CreateGangs', 'RemoveGang',
    'UpsertJobData', 'UpsertGangData', 'UpsertJobGrade', 'UpsertGangGrade', 'RemoveJobGrade', 'RemoveGangGrade' }) do
    export(name, groupsReadOnly)
end

---------------------------------------------------------------------------
-- Metadata
---------------------------------------------------------------------------
local numericMetadata = { hunger = true, thirst = true, stress = true }

export('SetMetadata', function(identifier, key, value)
    if type(key) ~= 'string' then return end
    local player = resolvePlayer(identifier)
    if not player then return end

    if numericMetadata[key] then
        value = tonumber(value)
        if not value or value ~= value or value == math.huge or value == -math.huge then return end
        value = lib.math.clamp(value, 0, 100)
    end

    local metaTable, metaKey = key:match('^([^%.]+)%.(.+)$')
    if metaTable then
        if metaKey:find('.', 1, true) then
            return lib.print.error('cannot set nested metadata more than 1 level deep')
        end
        local nested = player.PlayerData.metadata[metaTable]
        if type(nested) ~= 'table' then
            return lib.print.error(('cannot set nested metadata, %s is not a table'):format(metaTable))
        end
        nested = lib.table.deepclone(nested)
        nested[metaKey] = value
        key, value = metaTable, nested
    end

    player.Functions.SetMetaData(key, value)
end)

export('GetMetadata', function(identifier, key)
    if type(key) ~= 'string' then return end
    local player = resolvePlayer(identifier)
    if not player then return end

    local metadata = player.PlayerData.metadata or {}
    local metaTable, metaKey = key:match('^([^%.]+)%.(.+)$')
    if metaTable then
        if metaKey:find('.', 1, true) then return end
        local nested = metadata[metaTable]
        return type(nested) == 'table' and nested[metaKey] or nil
    end
    return metadata[key]
end)

---------------------------------------------------------------------------
-- Money hooks (exports.qbx_core:registerHook). Only money changes made through
-- the AddMoney / RemoveMoney / SetMoney exports below run them.
---------------------------------------------------------------------------
local hooks = {} -- [event] = { { cb, resource, id } }
local lastHookId = 0

local function triggerHooks(event, payload)
    local list = hooks[event]
    if not list then return true end

    for i = 1, #list do
        local hook = list[i]
        local ok, response = pcall(hook.cb, payload)
        if not ok then
            lib.print.error(('hook %s from %s errored: %s'):format(event, hook.resource, response))
        elseif response == false then
            return false
        end
    end
    return true
end

local function removeHooks(resource, id)
    for _, list in pairs(hooks) do
        for i = #list, 1, -1 do
            if list[i].resource == resource and (not id or list[i].id == id) then
                table.remove(list, i)
            end
        end
    end
end

export('registerHook', function(event, cb)
    lastHookId += 1
    hooks[event] = hooks[event] or {}
    hooks[event][#hooks[event] + 1] = { cb = cb, resource = GetInvokingResource() or 'rps_core', id = lastHookId }
    return lastHookId
end)

export('removeHooks', function(id)
    removeHooks(GetInvokingResource() or 'rps_core', id)
end)

AddEventHandler('onResourceStop', function(resource)
    removeHooks(resource)
end)

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------
local function validAmount(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then return end
    value = math.floor(value + 0.5)
    return value >= 0 and value or nil
end

local function changeMoney(action, fnName)
    return function(identifier, moneyType, amount, reason)
        local player = resolvePlayer(identifier)
        amount = validAmount(amount)
        if not player or not amount or player.PlayerData.money[moneyType] == nil then return false end

        if not triggerHooks(action, { source = player.PlayerData.source, moneyType = moneyType, amount = amount }) then
            return false
        end

        -- Qbox accepts 0 for add/remove; rps doesn't
        if amount == 0 and action ~= 'setMoney' then return true end
        return player.Functions[fnName](moneyType, amount, reason or 'unknown') and true or false
    end
end

export('AddMoney', changeMoney('addMoney', 'AddMoney'))
export('RemoveMoney', changeMoney('removeMoney', 'RemoveMoney'))
export('SetMoney', changeMoney('setMoney', 'SetMoney'))

export('GetMoney', function(identifier, moneyType)
    if not moneyType then return false end
    local player = resolvePlayer(identifier)
    if not player then return false end
    return player.PlayerData.money[moneyType]
end)

---------------------------------------------------------------------------
-- Usable items (ox_inventory -> rps_core runs the callback in its own thread)
---------------------------------------------------------------------------
-- rps_core owns the registry and drops a resource's items when it stops
export('CreateUseableItem', function(item, cb)
    Core.RegisterUsableItem(item, cb, 'qb')
end)

-- Qbox returns the callback itself; any truthy value works for `if CanUseItem(name)`.
export('CanUseItem', function(item)
    local entry = Core.UsableItems[item]
    if not entry then return nil end
    return entry.style == 'qb' and entry.cb or true
end)

---------------------------------------------------------------------------
-- Permissions (deprecated in Qbox; mapped onto rps groups and ACEs)
---------------------------------------------------------------------------
local function hasPermission(source, permission)
    if type(permission) == 'table' then
        for _, perm in pairs(permission) do
            if hasPermission(source, perm) then return true end
        end
        return false
    end
    if type(permission) ~= 'string' then return false end
    if IsPlayerAceAllowed(source, permission) then return true end
    return Core.IsValidGroup(permission) and Core.HasGroup(source, permission)
end

export('HasPermission', hasPermission)

export('GetPermission', function(source)
    local perms = {}
    for _, group in ipairs(Config.Groups) do
        if Core.HasGroup(source, group) then perms[group] = true end
    end
    return perms
end)

local function permissionUpdated(source)
    TriggerClientEvent('QBCore:Client:OnPermissionUpdate', source)
    TriggerEvent('QBCore:Server:OnPermissionUpdate', source)
end

-- Same rules as the QB bridge, so both frameworks agree on a player's permissions
export('AddPermission', function(source, permission)
    core().Functions.AddPermission(source, permission)
    permissionUpdated(source)
end)

export('RemovePermission', function(source, permission)
    core().Functions.RemovePermission(source, permission)
    permissionUpdated(source)
end)

-- No whitelist or bans in RPS
export('IsWhitelisted', function() return true end)
export('IsPlayerBanned', function() return false end)

export('ExploitBan', function(playerId, origin)
    lib.print.warn(('%s [%s] dropped for exploiting %s (no ban system on RPS)'):format(GetPlayerName(playerId), playerId, origin))
    DropPlayer(playerId, 'You were removed from the server for exploiting.')
end)

-- One opt-in flag, kept by the QB bridge
export('IsOptin', function(source)
    return core().Functions.IsOptin(source)
end)

export('ToggleOptin', function(source)
    core().Functions.ToggleOptin(source)
end)

export('Notify', function(source, ...)
    TriggerClientEvent('ox_lib:notify', source, Q.notifyData(...))
end)

---------------------------------------------------------------------------
-- Qbox events, driven by rps_core
---------------------------------------------------------------------------
-- qbx names for rps metadata keys
local metaAliases = { isDead = 'isdead', licenses = 'licences' }
local metaCache = {} -- [source] = last known metadata, to report old values
local dropped = {}

local function setNeedsState(src, key, value)
    local state = Player(src).state
    if state[key] ~= value then state:set(key, value, true) end
end

AddEventHandler('rps_core:server:playerLoaded', function(src)
    local player = Core.GetPlayer(src)
    if not player then return end
    metaCache[src] = lib.table.deepclone(player.getMeta())
    for key in pairs(numericMetadata) do
        setNeedsState(src, key, tonumber(metaCache[src][key]) or (key == 'stress' and 0 or 100))
    end
end)

AddEventHandler('rps_core:server:metaChanged', function(src, key, value)
    local cache = metaCache[src]
    local old = cache and cache[key]
    if cache then cache[key] = type(value) == 'table' and lib.table.deepclone(value) or value end

    local name = metaAliases[key] or key
    TriggerEvent('qbx_core:server:onSetMetaData', name, old, value, src)
    TriggerClientEvent('qbx_core:client:onSetMetaData', src, name, old, value)

    if numericMetadata[key] and type(value) == 'number' then setNeedsState(src, key, value) end
end)

-- onGroupUpdate(source, groupName, grade): grade is nil when the player left the group
AddEventHandler('rps_core:server:jobChanged', function(src, new, old)
    local function groupUpdate(name, grade)
        if name == 'unemployed' then return end
        TriggerEvent('qbx_core:server:onGroupUpdate', src, name, grade)
        TriggerClientEvent('qbx_core:client:onGroupUpdate', src, name, grade)
    end

    if not old or old.name ~= new.name then
        if old then groupUpdate(old.name) end
        groupUpdate(new.name, new.grade)
    elseif old.grade ~= new.grade then
        groupUpdate(new.name, new.grade)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    dropped[src] = true
    SetTimeout(5000, function() dropped[src] = nil end)
end)

-- rps unloads on logout and on disconnect; Qbox's playerLoggedOut is logout only.
-- playerDropped handlers have all run by the next tick, so check then.
AddEventHandler('rps_core:server:playerUnloaded', function(src)
    metaCache[src] = nil
    SetTimeout(0, function()
        if dropped[src] then return end
        TriggerEvent('qbx_core:server:playerLoggedOut', src)
        TriggerClientEvent('qbx_core:client:playerLoggedOut', src)
    end)
end)

-- Qbox HUDs and consumables use hunger / thirst / stress state bags; changes are
-- clamped and saved to rps metadata. The handler can't tell who made a change, so
-- this is only safe with state bag strict mode on (clients can't write their bags).
if GetConvar('sv_stateBagStrictMode', 'false') ~= 'true' then
    print('^3[rps_core] sv_stateBagStrictMode is off: clients can set their own hunger, thirst and stress. Add "setr sv_stateBagStrictMode true" to server.cfg.^0')
end

for key in pairs(numericMetadata) do
    AddStateBagChangeHandler(key, nil, function(bagName, _, value)
        if type(value) ~= 'number' then return end
        local src = GetPlayerFromStateBagName(bagName)
        local player = src and Core.GetPlayer(src)
        if not player then return end
        local clamped = lib.math.clamp(value, 0, 100)
        if player.getMeta(key) ~= clamped then player.setMeta(key, clamped) end
    end)
end
