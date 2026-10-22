fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rps_core'
description 'Custom roleplay framework core'
version '0.4.0'

-- Framework bridges (bridge/qb, bridge/esx, bridge/qbx) let QBCore, ESX and Qbox
-- scripts run on rps_core. Declaring these names makes scripts that check for or
-- depend on those frameworks find rps_core; their exports are answered from the
-- bridge files. Don't run the real frameworks alongside rps_core.
provide 'qb-core'
provide 'es_extended'
provide 'qbx_core'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/jobs.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/player.lua',
    'server/characters.lua',
    'server/commands.lua',
    'server/admin.lua',
    'server/needs.lua',
    'server/stress.lua',
    'server/exports.lua',

    -- framework bridges (qbx builds on qb, so qb first)
    'bridge/qb/server.lua',
    'bridge/qbx/server.lua',
    'bridge/qbx/server_vehicles.lua',
    'bridge/esx/server.lua',
}

client_scripts {
    'client/main.lua',
    'client/notify.lua',
    'client/spawn.lua',
    'client/characters.lua',
    'client/commands.lua',
    'client/admin.lua',
    'client/needs.lua',
    'client/stress.lua',

    'bridge/qb/client.lua',
    'bridge/qbx/client.lua',
    'bridge/esx/client.lua',
}

files {
    -- bridge modules loaded with require
    'bridge/qb/shared.lua',
    'bridge/qbx/shared.lua',
    'bridge/esx/shared.lua',
    'bridge/esx/menu.lua',

    -- files other scripts include by path (@qbx_core/modules/..., @es_extended/...)
    'modules/lib.lua',
    'modules/playerdata.lua',
    'imports.lua',
    'locale.lua',
}

dependencies {
    'oxmysql',
    'ox_lib',
}
