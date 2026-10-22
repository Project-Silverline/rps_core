fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'rps_core'
description 'Custom roleplay framework core'
version '0.3.1'

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
    'server/exports.lua',
}

client_scripts {
    'client/main.lua',
    'client/spawn.lua',
    'client/characters.lua',
}

dependencies {
    'oxmysql',
    'ox_lib',
}
