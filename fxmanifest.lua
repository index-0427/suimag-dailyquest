fx_version 'cerulean'
game 'gta5'

name 'suimag-dailyquest'
author 'index_0427'
description 'Server-authoritative daily and weekly quests for Qbox'
version '1.4.0'

shared_scripts { '@ox_lib/init.lua', 'config.lua' }
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/domain.lua',
    'server/selection.lua',
    'server/store.lua',
    'server/boards.lua',
    'server/bonuses.lua',
    'server/settlement.lua',
    'server/autoclaim.lua',
    'server/tracking.lua',
    'server/debug.lua',
    'server/main.lua',
    'server/adapters.lua',
}
client_script 'client/main.lua'
ui_page 'ui/countdown.html'
files { 'sql/schema.sql', 'ui/countdown.html', 'ui/countdown.css', 'ui/countdown.js', 'ui/quests.css', 'ui/quests.js' }
dependencies { 'qbx_core', 'ox_lib', 'oxmysql', 'ox_inventory', '/onesync' }
