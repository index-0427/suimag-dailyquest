fx_version 'cerulean'
game 'gta5'

name 'suimag-dailyquest'
author 'index_0427'
description 'Server-authoritative daily and weekly quests for Qbox'
version '1.2.0'

shared_scripts { '@ox_lib/init.lua', 'config.lua' }
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/domain.lua',
    'server/selection.lua',
    'server/store.lua',
    'server/boards.lua',
    'server/tracking.lua',
    'server/main.lua',
    'server/adapters.lua',
}
client_script 'client/main.lua'
files { 'sql/schema.sql' }
dependencies { 'qbx_core', 'ox_lib', 'oxmysql', 'ox_inventory', '/onesync' }
