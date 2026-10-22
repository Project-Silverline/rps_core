local cam

function StartSelectionScene()
    local scene = Config.SelectionScene
    local ped = PlayerPedId()

    SetEntityCoordsNoOffset(ped, scene.coords.x, scene.coords.y, scene.coords.z, false, false, false)
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    SetEntityInvincible(ped, true)

    if not cam then
        cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            scene.coords.x, scene.coords.y, scene.coords.z,
            scene.rot.x, scene.rot.y, scene.rot.z, scene.fov, false, 0)
    end
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    DisplayRadar(false)

    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
    DoScreenFadeIn(500)
end

local function stopSelectionScene()
    if cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        cam = nil
    end
    DisplayRadar(true)
end

function SpawnPlayer(data)
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    local model = joaat(Config.DefaultModel[data.charinfo.sex] or Config.DefaultModel.m)
    lib.requestModel(model)
    SetPlayerModel(cache.playerId, model)
    SetModelAsNoLongerNeeded(model)

    local pos = data.position or Config.DefaultSpawn
    local ped = PlayerPedId()
    SetPedDefaultComponentVariation(ped)

    RequestCollisionAtCoord(pos.x, pos.y, pos.z)
    NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, pos.w, true, false)
    ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, pos.x, pos.y, pos.z, false, false, false)
    SetEntityHeading(ped, pos.w)

    local timeout = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < timeout do Wait(0) end

    stopSelectionScene()
    SetEntityVisible(ped, true, false)
    SetEntityInvincible(ped, false)
    FreezeEntityPosition(ped, false)
    ClearPedTasksImmediately(ped)

    -- An appearance resource fades the screen in once the saved look is applied,
    -- so the default ped is never seen. The timeout is a safety net.
    if GetResourceState('illenium-appearance') == 'started' then
        SetTimeout(10000, function()
            if IsScreenFadedOut() then DoScreenFadeIn(500) end
        end)
    else
        DoScreenFadeIn(500)
    end
end
