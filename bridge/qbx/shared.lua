-- Qbox bridge: shared helpers, loaded with require 'bridge.qbx.shared' by the
-- qbx server and client files (it defines no globals and runs nothing itself).
-- RPS is single-job and has no gangs, so a player's `jobs` holds at most their
-- one job and `gangs` is always empty (gang = 'none').

local M = {}

-- reported by GetCoreVersion; rps_core's own manifest version is what lib.checkDependency sees
M.version = '1.23.0'

M.notifyPosition = 'top-right'

-- Qbox job "types" (GetDutyCountType, PlayerData.job.type). rps jobs have no
-- type, so a job's own `type` field wins, then this map.
M.jobTypes = {
    police = 'leo',
    ambulance = 'ems',
}

local NONE_GANG = {
    label = 'No Gang Affiliation',
    grades = { [0] = { name = 'none' } },
}

local function gradeLevel(grade)
    if type(grade) == 'table' then return tonumber(grade.level) or 0 end
    return tonumber(grade) or 0
end

M.gradeLevel = gradeLevel

function M.jobType(name, def)
    def = def or Config.Jobs[name]
    return def and def.type or M.jobTypes[name]
end

---rps job definition -> Qbox Job { label, type, defaultDuty, offDutyPay, grades = { [n] = { name, payment, isboss, bankAuth } } }
local function convertJob(name, def)
    local grades = {}
    for level, grade in pairs(def.grades or {}) do
        grades[level] = {
            name = grade.label,
            payment = grade.salary or 0,
            isboss = grade.boss or nil,
            bankAuth = grade.boss or nil,
        }
    end

    return {
        label = def.label,
        type = M.jobType(name, def),
        defaultDuty = def.defaultDuty ~= false,
        offDutyPay = false,
        grades = grades,
    }
end

function M.getJobs()
    local jobs = {}
    for name, def in pairs(Config.Jobs) do
        jobs[name] = convertJob(name, def)
    end
    return jobs
end

function M.getJob(name)
    local def = name and Config.Jobs[name]
    return def and convertJob(name, def) or nil
end

function M.getGangs()
    return { none = lib.table.deepclone(NONE_GANG) }
end

function M.getGang(name)
    return name == 'none' and lib.table.deepclone(NONE_GANG) or nil
end

local function noneGang()
    return {
        name = 'none',
        label = NONE_GANG.label,
        isboss = false,
        bankAuth = false,
        grade = { name = NONE_GANG.grades[0].name, level = 0 },
    }
end

---Returns a copy of a QB PlayerData with the Qbox-only fields added
---(jobs, gangs, job.type, gang). The original table is left untouched.
function M.decorate(data)
    if type(data) ~= 'table' or type(data.job) ~= 'table' then return data end

    local copy = {}
    for k, v in pairs(data) do copy[k] = v end

    local job = {}
    for k, v in pairs(data.job) do job[k] = v end
    if job.type == nil then job.type = M.jobType(job.name) end
    copy.job = job

    copy.jobs = {}
    if job.name and job.name ~= 'unemployed' then
        copy.jobs[job.name] = gradeLevel(job.grade)
    end

    if type(copy.gang) ~= 'table' or not copy.gang.name then copy.gang = noneGang() end
    copy.gangs = {}
    if copy.gang.name ~= 'none' then
        copy.gangs[copy.gang.name] = gradeLevel(copy.gang.grade)
    end

    return copy
end

---@return table<string, integer>
function M.getPlayerGroups(playerData)
    local groups = {}
    if type(playerData) ~= 'table' then return groups end
    for name, grade in pairs(playerData.jobs or {}) do groups[name] = grade end
    for name, grade in pairs(playerData.gangs or {}) do
        if groups[name] == nil then groups[name] = grade end
    end
    return groups
end

-- Does `name` match the player, at least at `minGrade` when given?
local function matches(playerData, groups, name, minGrade)
    if playerData.citizenid and playerData.citizenid == name then return true end

    local job, gang = playerData.job, playerData.gang
    local level
    if job and job.name == name then
        level = gradeLevel(job.grade)
    elseif gang and gang.name == name then
        level = gradeLevel(gang.grade)
    elseif groups and groups[name] then
        level = groups[name]
    else
        return false
    end

    return minGrade == nil or level >= minGrade
end

---Same rules as Qbox: filter is a name, an array of names, or { [name] = minGrade }.
---@param primary? boolean only the primary job / gang
function M.hasGroup(filter, playerData, primary)
    if not filter or type(playerData) ~= 'table' or not playerData.job then return false end
    local groups = not primary and M.getPlayerGroups(playerData) or nil

    if type(filter) == 'string' then
        return matches(playerData, groups, filter)
    elseif type(filter) == 'table' then
        if table.type(filter) == 'array' then
            for i = 1, #filter do
                if matches(playerData, groups, filter[i]) then return true end
            end
        else
            for name, minGrade in pairs(filter) do
                if matches(playerData, groups, name, tonumber(minGrade) or 0) then return true end
            end
        end
    end

    return false
end

---Qbox Notify arguments -> ox_lib notify data
function M.notifyData(text, notifyType, duration, subTitle, notifyPosition, notifyStyle, notifyIcon, notifyIconColor)
    local title, description
    if type(text) == 'table' then
        title, description = text.text or 'Placeholder', text.caption
    elseif subTitle then
        title, description = text, subTitle
    else
        description = text
    end

    return {
        id = title,
        title = title,
        description = description,
        duration = duration,
        type = notifyType,
        position = notifyPosition or M.notifyPosition,
        style = notifyStyle,
        icon = notifyIcon,
        iconColor = notifyIconColor,
    }
end

---Answers exports.qbx_core:<name>(...) from inside rps_core
function M.export(name, fn)
    AddEventHandler(('__cfx_export_qbx_core_%s'):format(name), function(setCB)
        setCB(fn)
    end)
end

return M
