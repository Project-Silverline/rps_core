-- ESX (es_extended) bridge: shared helpers, loaded with require 'bridge.esx.shared'
-- by the esx server and client files. Defines no globals and runs nothing itself.

local M = {}

M.version = '1.13.4'

-- Answer exports.es_extended:<name>() from inside rps_core
function M.export(name, fn)
    AddEventHandler(('__cfx_export_es_extended_%s'):format(name), function(setCB)
        setCB(fn)
    end)
end

-- ESX account list, in a fixed order so account.index is stable
M.accounts = {
    { name = 'bank', label = 'Bank' },
    { name = 'black_money', label = 'Dirty Money' },
    { name = 'money', label = 'Cash' },
}

-- ESX group names that don't exist in rps
M.groupAlias = { superadmin = 'admin', owner = 'admin', moderator = 'mod' }

function M.identifier(charId)
    return ('char%d'):format(charId)
end

-- Not a real SSN: a stable, unique-per-character stand-in in ESX's format
function M.ssn(charId)
    return ('%03d-%02d-%04d'):format(charId // 1000000 % 1000, charId // 10000 % 100, charId % 10000)
end

function M.round(value, places)
    value = tonumber(value) or 0
    if places then
        local power = 10 ^ places
        return math.floor(value * power + 0.5) / power
    end
    return math.floor(value + 0.5)
end

local function deepCopy(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = deepCopy(v) end
    return copy
end

M.deepCopy = deepCopy

-- Strip the HTML and GTA colour codes ESX menus are full of; ox_lib shows plain text
function M.clean(text)
    if text == nil then return nil end
    text = tostring(text):gsub('<br%s*/?>', ' '):gsub('<.->', ''):gsub('&nbsp;', ' '):gsub('~n~', '\n'):gsub('~%a~', '')
    return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function gradeName(label, boss)
    if boss then return 'boss' end
    return (tostring(label):lower():gsub('[^%w]+', '_'))
end

-- rps job definitions -> ESX.Jobs (grades keyed by tostring(grade), like upstream)
function M.buildJobs()
    local jobs = {}
    for name, def in pairs(Config.Jobs) do
        local grades = {}
        for grade, g in pairs(def.grades) do
            grades[tostring(grade)] = {
                job_name = name,
                grade = grade,
                name = gradeName(g.label, g.boss),
                label = g.label,
                salary = g.salary or 0,
                skin_male = {},
                skin_female = {},
            }
        end
        jobs[name] = {
            name = name,
            label = def.label,
            type = def.type or 'civ',
            whitelisted = name ~= 'unemployed',
            grades = grades,
        }
    end
    return jobs
end

-- rps getJob() table -> ESX xPlayer.job
function M.toEsxJob(job)
    if not job then return nil end
    local def = Config.Jobs[job.name]
    return {
        name = job.name,
        label = job.label,
        type = def and def.type or 'civ',
        onDuty = job.onduty,
        grade = job.grade,
        grade_name = gradeName(job.gradeLabel, job.boss),
        grade_label = job.gradeLabel,
        grade_salary = job.salary or 0,
        skin_male = {},
        skin_female = {},
    }
end

-- Subset of es_extended's Config that scripts read through ESX.GetConfig()
function M.buildConfig()
    local accounts = {}
    for _, a in ipairs(M.accounts) do accounts[a.name] = { label = a.label, round = true } end

    local spawn = Config.DefaultSpawn
    return {
        Locale = GetConvar('esx:locale', 'en'),
        Accounts = accounts,
        StartingAccountMoney = { bank = Config.StartingAccounts.bank, money = Config.StartingAccounts.cash },
        DefaultSpawns = { { x = spawn.x, y = spawn.y, z = spawn.z, heading = spawn.w } },
        AdminGroups = { admin = true },
        EnablePaycheck = true,
        PaycheckInterval = Config.PaycheckInterval,
        MaxWeight = GetConvarInt('inventory:weight', 30000) / 1000,
        Multichar = true,
        Identifier = 'license',
        CustomInventory = 'ox',
        OxInventory = true,
        DefaultJobDuty = true,
        EnableDebug = false,
    }
end

-- Generic ESX helpers (ESX.Math, ESX.Table, timeouts, ...) added to an ESX table
function M.addHelpers(ESX)
    ESX.Round = M.round

    ESX.Math = {
        Round = M.round,
        GroupDigits = function(value)
            local left, num, right = tostring(value):match('^([^%d]*%d)(%d*)(.-)$')
            if not left then return tostring(value) end
            return left .. num:reverse():gsub('(%d%d%d)', '%1,'):reverse() .. right
        end,
        Trim = function(value)
            return value and (tostring(value):gsub('^%s*(.-)%s*$', '%1'))
        end,
        Random = function(...) return math.random(...) end,
        GetHeadingFromCoords = function(a, b)
            return (math.deg(math.atan(b.y - a.y, b.x - a.x)) - 90.0) % 360.0
        end,
    }

    local T = {}
    ESX.Table = T

    function T.SizeOf(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end

    function T.Set(t)
        local set = {}
        for _, v in ipairs(t) do set[v] = true end
        return set
    end

    function T.IndexOf(t, value)
        for i = 1, #t do if t[i] == value then return i end end
        return -1
    end

    function T.LastIndexOf(t, value)
        for i = #t, 1, -1 do if t[i] == value then return i end end
        return -1
    end

    function T.Find(t, cb)
        for i = 1, #t do if cb(t[i]) then return t[i] end end
    end

    function T.FindIndex(t, cb)
        for i = 1, #t do if cb(t[i]) then return i end end
    end

    function T.Filter(t, cb)
        local out = {}
        for i = 1, #t do if cb(t[i]) then out[#out + 1] = t[i] end end
        return out
    end

    function T.Map(t, cb)
        local out = {}
        for i = 1, #t do out[i] = cb(t[i], i) end
        return out
    end

    function T.Reverse(t)
        local out = {}
        for i = #t, 1, -1 do out[#out + 1] = t[i] end
        return out
    end

    T.Clone = deepCopy

    function T.Concat(a, b)
        local out = deepCopy(a)
        for i = 1, #b do out[#out + 1] = b[i] end
        return out
    end

    function T.Join(t, sep)
        local parts = {}
        for i = 1, #t do parts[i] = tostring(t[i]) end
        return table.concat(parts, sep or ',')
    end

    function T.TableContains(t, value)
        for _, v in pairs(t) do if v == value then return true end end
        return false
    end

    function T.ToArray(t)
        local out = {}
        for _, v in pairs(t) do out[#out + 1] = v end
        return out
    end

    function T.Wipe(t)
        for k in pairs(t) do t[k] = nil end
        return t
    end

    local timeouts, lastTimeout = {}, 0

    function ESX.SetTimeout(msec, cb)
        lastTimeout = lastTimeout + 1
        local id = lastTimeout
        timeouts[id] = true
        SetTimeout(msec, function()
            if timeouts[id] then
                timeouts[id] = nil
                cb()
            end
        end)
        return id
    end

    function ESX.ClearTimeout(id)
        timeouts[id] = nil
    end

    function ESX.DumpTable(tbl, depth)
        depth = depth or 0
        if type(tbl) ~= 'table' then return tostring(tbl) end
        local indent = ('    '):rep(depth)
        local out = '{\n'
        for k, v in pairs(tbl) do
            out = out .. indent .. '    [' .. tostring(k) .. '] = ' .. ESX.DumpTable(v, depth + 1) .. ',\n'
        end
        return out .. indent .. '}'
    end

    local charset = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

    function ESX.GetRandomString(length)
        local out = {}
        for i = 1, length or 8 do
            local n = math.random(1, #charset)
            out[i] = charset:sub(n, n)
        end
        return table.concat(out)
    end

    function ESX.IsFunctionReference(value)
        local t = type(value)
        if t == 'function' then return true end
        if t ~= 'table' then return false end
        local mt = getmetatable(value)
        return (mt and mt.__call ~= nil) or rawget(value, '__cfx_functionReference') ~= nil
    end

    function ESX.ValidateType(value, ...)
        local t = type(value)
        for i = 1, select('#', ...) do
            if t == select(i, ...) then return true end
        end
        return false
    end

    function ESX.AssertType(value, ...)
        assert(ESX.ValidateType(value, ...), ('invalid type: %s'):format(type(value)))
    end

    function ESX.GetConfig(key)
        if key then return ESX.Config[key] end
        return ESX.Config
    end

    function ESX.Trace(msg)
        print(('[^2TRACE^7] %s^7'):format(msg))
    end
end

return M
