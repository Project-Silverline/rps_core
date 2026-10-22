-- /me and /do text, floating above the player who used it (server/commands.lua)

local COLORS = {
    me = { 200, 140, 255 },
    ['do'] = { 140, 220, 140 },
}

local emotes = {} -- list of { serverId, kind, text, expires }

local function drawText3D(coords, text, color)
    local onScreen, x, y = World3dToScreen2d(coords.x, coords.y, coords.z)
    if not onScreen then return end
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextCentre(true)
    SetTextOutline()
    SetTextColour(color[1], color[2], color[3], 230)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(x, y)
end

local function drawLoop()
    while #emotes > 0 do
        local now = GetGameTimer()
        local stacked = {} -- lines already drawn above each player

        for i = #emotes, 1, -1 do
            local e = emotes[i]
            local player = GetPlayerFromServerId(e.serverId)

            if now > e.expires then
                table.remove(emotes, i)
            elseif player ~= -1 then
                local ped = GetPlayerPed(player)
                local line = stacked[e.serverId] or 0
                stacked[e.serverId] = line + 1
                drawText3D(GetEntityCoords(ped) + vec3(0.0, 0.0, 1.0 + line * 0.15), e.text, COLORS[e.kind])
            end
        end
        Wait(0)
    end
end

RegisterNetEvent('rps_core:client:emote', function(serverId, kind, text)
    if not COLORS[kind] or type(text) ~= 'string' then return end
    local label = kind == 'me' and ('* %s *'):format(text) or ('* %s'):format(text)
    emotes[#emotes + 1] = { serverId = serverId, kind = kind, text = label, expires = GetGameTimer() + Config.Commands.meDuration * 1000 }
    if #emotes == 1 then CreateThread(drawLoop) end
end)
