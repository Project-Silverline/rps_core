local function cleanName(s)
    if type(s) ~= 'string' then return end
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if #s < 2 or #s > 20 or not s:match("^%a[%a%-' ]*$") then return end
    return s:sub(1, 1):upper() .. s:sub(2)
end

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function daysInMonth(y, m)
    if m == 2 and (y % 4 == 0 and y % 100 ~= 0 or y % 400 == 0) then return 29 end
    return DAYS_IN_MONTH[m]
end

local function validDob(s)
    if type(s) ~= 'string' then return end
    local y, m, d = s:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m) then return end
    local year = tonumber(os.date('%Y'))
    if y > year - Config.MinAge or y < year - 100 then return end
    return s
end

local function getLicense(src)
    return GetPlayerIdentifierByType(src, 'license')
end

-- One character action per player at a time. Without this, requests sent
-- together all pass the checks made before the database calls.
local busy = {}

local function guarded(fn)
    return function(src, ...)
        if busy[src] then return false end
        busy[src] = true
        local ok, a, b = pcall(fn, src, ...)
        busy[src] = nil
        if not ok then
            print(('[rps_core] ^1%s^0'):format(a))
            return false
        end
        return a, b
    end
end

lib.callback.register('rps_core:getCharacters', function(src)
    if Core.Players[src] then return end
    local license = getLicense(src)
    if not license then return end

    local chars = MySQL.query.await(
        'SELECT id, firstname, lastname, dob, sex, job FROM characters WHERE license = ? ORDER BY id',
        { license })

    return chars, Config.MaxCharacters
end)

lib.callback.register('rps_core:createCharacter', guarded(function(src, data)
    if Core.Players[src] or type(data) ~= 'table' then return false end
    local license = getLicense(src)

    local firstname, lastname = cleanName(data.firstname), cleanName(data.lastname)
    local dob = validDob(data.dob)
    local sex = (data.sex == 'm' or data.sex == 'f') and data.sex or nil
    if not (license and firstname and lastname and dob and sex) then
        return false, 'Invalid character details'
    end

    local count = MySQL.scalar.await('SELECT COUNT(*) FROM characters WHERE license = ?', { license })
    if count >= Config.MaxCharacters then
        return false, 'Character limit reached'
    end

    local id = MySQL.insert.await(
        'INSERT INTO characters (license, firstname, lastname, dob, sex, accounts, metadata) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { license, firstname, lastname, dob, sex, json.encode(Config.StartingAccounts), json.encode(Config.DefaultMetadata) })

    return id ~= nil, id
end))

lib.callback.register('rps_core:deleteCharacter', guarded(function(src, charId)
    if Core.Players[src] then return false end
    charId = tonumber(charId)
    local license = getLicense(src)
    if not charId or not license then return false end

    local affected = MySQL.update.await('DELETE FROM characters WHERE id = ? AND license = ?', { charId, license })
    if affected > 0 then
        TriggerEvent('rps_core:server:characterDeleted', charId, license)
    end
    return affected > 0
end))

lib.callback.register('rps_core:selectCharacter', guarded(function(src, charId)
    if Core.Players[src] then return false end
    charId = tonumber(charId)
    local license = getLicense(src)
    if not charId or not license or Core.ByCharId[charId] then return false end

    local row = MySQL.single.await('SELECT * FROM characters WHERE id = ? AND license = ?', { charId, license })
    if not row then return false end

    local group = MySQL.scalar.await('SELECT `group` FROM users WHERE license = ?', { license })

    -- the player may have dropped, or the character been loaded, while we were waiting on the database
    if not GetPlayerName(src) or Core.Players[src] or Core.ByCharId[charId] then return false end

    local player = Core.CreatePlayer(src, license, group or Config.DefaultGroup, row)

    Core.Players[src] = player
    Core.ByCharId[player.charId] = src

    TriggerEvent('rps_core:server:playerLoaded', src, player)
    return player.getData()
end))
