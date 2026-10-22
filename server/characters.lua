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

-- Birth years a new character may have: at least MinAge, at most 100
local function dobRange()
    local year = tonumber(os.date('%Y'))
    return {
        min = ('%04d-01-01'):format(year - 100),
        max = ('%04d-12-31'):format(year - Config.MinAge),
    }
end

-- ox_lib's date input sends the player's local midnight as a JS timestamp in ms,
-- and the client sends its UTC offset in minutes. os.date can't handle dates
-- before 1970 on Windows, so days since the epoch are turned into a date by hand
-- (Howard Hinnant's civil_from_days).
local function dateFromTimestamp(ms, tz)
    ms = tonumber(ms)
    if not ms or ms ~= ms or ms == math.huge or ms == -math.huge then return end
    tz = math.floor(tonumber(tz) or 0)
    if tz < -14 * 60 or tz > 14 * 60 then tz = 0 end
    -- +12h absorbs daylight saving differences between the birth date and today
    local days = (math.floor(ms / 1000) + tz * 60 + 43200) // 86400 + 719468
    local era = days // 146097
    local doe = days - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return ('%04d-%02d-%02d'):format(y, m, d)
end

local function validDob(s, tz)
    if type(s) == 'number' then s = dateFromTimestamp(s, tz) end
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

    return chars, Config.MaxCharacters, dobRange()
end)

lib.callback.register('rps_core:createCharacter', guarded(function(src, data)
    if Core.Players[src] or type(data) ~= 'table' then return false end
    local license = getLicense(src)

    local firstname, lastname = cleanName(data.firstname), cleanName(data.lastname)
    local dob = validDob(data.dob, data.tz)
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
