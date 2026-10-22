-- One notification function for rps resources, on top of ox_lib's notify.
--
--   exports.rps_core:Notify('Paycheck received', 'success')
--   exports.rps_core:Notify('Low fuel', 'warning', 8000, 'Vehicle')
--   exports.rps_core:Notify({ title = 'Bank', description = 'Transfer sent', type = 'success', icon = 'building-columns' })
--
-- The table form takes any lib.notify field (icon, iconColor, style, sound...).
-- From the server: exports.rps_core:Notify(source, ...) with the same arguments.

-- Type names other frameworks use, mapped onto ox_lib's four
local TYPES = {
    inform = 'inform', info = 'inform', primary = 'inform', police = 'inform', ambulance = 'inform',
    success = 'success',
    error = 'error',
    warning = 'warning', warn = 'warning',
}

local function notify(data, notifyType, duration, title)
    if type(data) ~= 'table' then
        data = { description = data ~= nil and tostring(data) or nil, type = notifyType, duration = duration, title = title }
    end
    if not data.description and not data.title then return end

    data.type = TYPES[data.type] or 'inform'
    data.duration = tonumber(data.duration) or Config.Notify.duration
    data.position = data.position or Config.Notify.position

    lib.notify(data)
end

exports('Notify', notify)
RegisterNetEvent('rps_core:client:notify', notify)
