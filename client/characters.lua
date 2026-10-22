local function createCharacter()
    local input = lib.inputDialog('New character', {
        { type = 'input', label = 'First name', required = true, min = 2, max = 20 },
        { type = 'input', label = 'Last name', required = true, min = 2, max = 20 },
        { type = 'input', label = 'Date of birth', placeholder = 'YYYY-MM-DD', required = true, min = 10, max = 10 },
        { type = 'select', label = 'Sex', required = true, options = {
            { value = 'm', label = 'Male' },
            { value = 'f', label = 'Female' },
        } },
    }, { allowCancel = true })

    if input then
        local ok, err = lib.callback.await('rps_core:createCharacter', false, {
            firstname = input[1], lastname = input[2], dob = input[3], sex = input[4],
        })
        if not ok then
            lib.notify({ description = type(err) == 'string' and err or 'Could not create character', type = 'error' })
        end
    end

    OpenCharacterMenu()
end

local function selectCharacter(id)
    local data = lib.callback.await('rps_core:selectCharacter', false, id)
    if not data then
        lib.notify({ description = 'Could not load that character', type = 'error' })
        return OpenCharacterMenu()
    end

    SpawnPlayer(data)
    PlayerData = data
    IsLoaded = true
    TriggerEvent('rps_core:client:playerLoaded', PlayerData)
end

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
    local chars, max = lib.callback.await('rps_core:getCharacters', false)
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
        options[#options + 1] = { title = 'Create character', icon = 'plus', onSelect = createCharacter }
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

    StartSelectionScene()
    OpenCharacterMenu()
end)

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(100) end

    if GetResourceState('spawnmanager') == 'started' then
        exports.spawnmanager:setAutoSpawn(false)
    end

    StartSelectionScene()
    OpenCharacterMenu()
end)
