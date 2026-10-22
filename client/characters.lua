-- Minutes this machine's clock is ahead of UTC. The date picker sends local
-- midnight as a timestamp, so the server needs this to get the right day.
local function utcOffsetMinutes()
    local ok, y1, mo1, d1, h1, mi1 = pcall(GetLocalTime)
    local ok2, y2, mo2, d2, h2, mi2 = pcall(GetUtcTime)
    if not (ok and ok2 and y1 and y2) then return 0 end

    local offset = (h1 - h2) * 60 + (mi1 - mi2)
    local localDay, utcDay = y1 * 10000 + mo1 * 100 + d1, y2 * 10000 + mo2 * 100 + d2
    if localDay > utcDay then offset = offset + 1440 elseif localDay < utcDay then offset = offset - 1440 end
    return offset
end

-- dobRange = { min = 'YYYY-MM-DD', max = 'YYYY-MM-DD' } from the server, so the
-- picker only offers dates the server will accept
local function createCharacter(dobRange)
    local input = lib.inputDialog('New character', {
        { type = 'input', label = 'First name', required = true, min = 2, max = 20 },
        { type = 'input', label = 'Last name', required = true, min = 2, max = 20 },
        { type = 'date', label = 'Date of birth', icon = 'calendar', required = true, format = 'DD/MM/YYYY',
            min = dobRange and dobRange.min, max = dobRange and dobRange.max },
        { type = 'select', label = 'Sex', required = true, options = {
            { value = 'm', label = 'Male' },
            { value = 'f', label = 'Female' },
        } },
    }, { allowCancel = true })

    if input then
        local ok, err = lib.callback.await('rps_core:createCharacter', false, {
            firstname = input[1], lastname = input[2], dob = input[3], tz = utcOffsetMinutes(), sex = input[4],
        })
        if not ok then
            lib.notify({ description = type(err) == 'string' and err or 'Could not create character', type = 'error' })
        end
    end

    OpenCharacterMenu()
end

local function loadCharacter(id)
    local data = lib.callback.await('rps_core:selectCharacter', false, id)
    if not data then return false end

    SpawnPlayer(data)
    PlayerData = data
    IsLoaded = true
    TriggerEvent('rps_core:client:playerLoaded', PlayerData)
    return true
end

local function selectCharacter(id)
    if not loadCharacter(id) then
        lib.notify({ description = 'Could not load that character', type = 'error' })
        OpenCharacterMenu()
    end
end

-- A selection resource (rps_multicharacter) replaces the built-in menu when installed.
-- It loads characters through this event rather than an export, because loading
-- waits on the server and an export can't yield across resources.
local function hasSelectionResource()
    return GetResourceState('rps_multicharacter') ~= 'missing'
end

AddEventHandler('rps_core:client:selectCharacter', function(id)
    if IsLoaded then return end
    if not loadCharacter(id) then
        TriggerEvent('rps_core:client:selectFailed', id)
    end
end)

local function deleteCharacter(char)
    local confirm = lib.alertDialog({
        header = 'Delete character',
        content = ('Permanently delete **%s %s**? This cannot be undone.'):format(char.firstname, char.lastname),
        centered = true,
        cancel = true,
    })

    if confirm == 'confirm' and lib.callback.await('rps_core:deleteCharacter', false, char.id) then
        lib.notify({ description = 'Character deleted', type = 'success' })
    end

    OpenCharacterMenu()
end

function OpenCharacterMenu()
    local chars, max, dobRange = lib.callback.await('rps_core:getCharacters', false)
    if not chars then return end

    local options = {}

    for _, char in ipairs(chars) do
        local menuId = ('rps_char_%d'):format(char.id)
        lib.registerContext({
            id = menuId,
            title = ('%s %s'):format(char.firstname, char.lastname),
            menu = 'rps_characters',
            canClose = false,
            options = {
                { title = 'Play', icon = 'play', onSelect = function() selectCharacter(char.id) end },
                { title = 'Delete', icon = 'trash', iconColor = '#e03131', onSelect = function() deleteCharacter(char) end },
            },
        })

        options[#options + 1] = {
            title = ('%s %s'):format(char.firstname, char.lastname),
            description = ('Born %s · %s'):format(char.dob, Config.Jobs[char.job] and Config.Jobs[char.job].label or char.job),
            icon = 'user',
            menu = menuId,
        }
    end

    if #chars < max then
        options[#options + 1] = { title = 'Create character', icon = 'plus', onSelect = function() createCharacter(dobRange) end }
    end

    lib.registerContext({
        id = 'rps_characters',
        title = ('Characters (%d/%d)'):format(#chars, max),
        canClose = false,
        options = options,
    })
    lib.showContext('rps_characters')
end

RegisterNetEvent('rps_core:client:logout', function()
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    PlayerData = {}
    IsLoaded = false
    TriggerEvent('rps_core:client:playerUnloaded')

    if hasSelectionResource() then
        return TriggerEvent('rps_core:client:openSelection')
    end

    StartSelectionScene()
    OpenCharacterMenu()
end)

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(100) end

    if GetResourceState('spawnmanager') == 'started' then
        exports.spawnmanager:setAutoSpawn(false)
    end

    -- the selection resource opens itself on join
    if hasSelectionResource() then return end

    StartSelectionScene()
    OpenCharacterMenu()
end)
