-- Include file for Qbox resources:
--   client_scripts { '@qbx_core/modules/playerdata.lua' }
--   (or '@rps_core/modules/playerdata.lua')
-- Runs inside the including resource and keeps the global QBX.PlayerData current.
if IsDuplicityVersion() then return end

QBX = QBX or {} -- luacheck: ignore

-- QB PlayerData + Qbox's jobs / gangs (RPS: one job, no gangs)
local function withGroups(data)
    if type(data) ~= 'table' or type(data.job) ~= 'table' then return data or {} end

    local function level(grade)
        return type(grade) == 'table' and tonumber(grade.level) or tonumber(grade) or 0
    end

    data.jobs = {}
    if data.job.name and data.job.name ~= 'unemployed' then data.jobs[data.job.name] = level(data.job.grade) end
    data.gang = type(data.gang) == 'table' and data.gang
        or { name = 'none', label = 'No Gang Affiliation', isboss = false, bankAuth = false, grade = { name = 'none', level = 0 } }
    data.gangs = {}
    if data.gang.name ~= 'none' then data.gangs[data.gang.name] = level(data.gang.grade) end
    return data
end

local function reload()
    QBX.PlayerData = exports.qbx_core:GetPlayerData() or {}
end

reload()

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    QBX.PlayerData = {}
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(value)
    if type(value) == 'table' then
        QBX.PlayerData = withGroups(value)
    else
        reload()
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', reload)

RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job)
    if type(QBX.PlayerData) == 'table' and type(job) == 'table' then
        QBX.PlayerData.job = job
        withGroups(QBX.PlayerData)
    end
end)
