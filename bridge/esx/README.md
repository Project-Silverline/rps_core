# ESX Legacy bridge (es_extended)

Lets scripts written for ESX Legacy run on RPS. It lives inside `rps_core`, which
`provide`s `es_extended`, so `exports.es_extended:getSharedObject()`,
`GetResourceState('es_extended')` and `dependencies { 'es_extended' }` keep working.
It reports version `1.13.4`. The bridge only translates. It owns no data and no
database tables.

## Including ESX files

| Script uses | Provided by |
| --- | --- |
| `shared_script '@es_extended/imports.lua'` | `rps_core/imports.lua` |
| `shared_script '@es_extended/locale.lua'` | `rps_core/locale.lua` |

If a server build doesn't resolve `@es_extended/...` through `provide`, change
the include to `@rps_core/imports.lua` or `@rps_core/locale.lua`. Both files
work from either path.

- `imports.lua` defines the global `ESX` in the including resource. On the
  client it keeps `ESX.PlayerData` and `ESX.PlayerLoaded` current, and
  `OnPlayerData(key, val, last)` works. On the server it adds `ESX.Player()`
  and `ESX.ExtendedPlayers()`.
- `locale.lua` provides `Locales`, `_`/`Translate` and `_U`/`TranslateCap`. It
  reads the resource's own `Locales['xx'] = {}` files or `locales/xx.lua`
  files. A missing key returns the key itself.
- The legacy `TriggerEvent('esx:getSharedObject', cb)` also works.

## How ESX maps to RPS

| ESX | RPS |
| --- | --- |
| `identifier` | `'char' .. charId`, one per character. `license` is the Rockstar license. `ESX.GetIdentifier(src)` returns the character identifier, or the bare license if no character is loaded. |
| `money` account, `xPlayer.getMoney()` | rps `cash`, which is kept equal to the ox `money` item |
| `bank` account | rps `bank` |
| `black_money` account | ox_inventory item `black_money` |
| Inventory | ox_inventory: one entry per item name, `{ name, count, label, weight, usable, rare, canRemove }`. The `money` and `black_money` items are left out. `addInventoryItem('money', n)` changes cash. |
| Loadout and weapons | ox_inventory `WEAPON_*` items. The `xPlayer.loadout` field is `{}`, while `getLoadout()` reads ox. |
| Jobs | `rps_core/shared/jobs.lua`. `ESX.Jobs[job].grades` are keyed by `tostring(grade)`, as in ESX. A grade with `boss = true` gets `grade_name = 'boss'`. `onDuty` is rps duty. Job `type` is `'civ'` unless the rps job sets `type`. |
| Groups | rps `user`, `mod` and `admin`. ESX `superadmin`/`owner` map to `admin`, and `moderator` maps to `mod`. |
| Metadata | rps metadata (`getMeta`/`setMeta`/`clearMeta`) |
| Death | rps_ambulance's `isDead` state fires `esx:onPlayerDeath` and, on revive, `esx:onPlayerSpawn` |

The server keeps one xPlayer per character and refreshes its fields from rps
and ox_inventory each time it is handed out. Values crossing resources are
copies, so call `ESX.GetPlayerFromId` again when you need fresh data, as with
real ESX.

## Supported

- **Server functions:** `GetPlayerFromId`, `GetPlayerFromIdentifier`,
  `GetPlayerIdFromIdentifier`, `IsPlayerLoaded`, `GetExtendedPlayers(key, val, minimal)`,
  `GetNumPlayers`, `GetPlayers`, `GetIdentifier`, `TriggerClientEvent`,
  `RegisterServerCallback`, `TriggerClientCallback`, `AwaitClientCallback`,
  `RegisterUsableItem`, `UseItem`, `GetUsableItems`, `GetItems`, `GetItemLabel`,
  `GetWeapon`, `GetWeaponLabel`, `GetWeaponList`, `GetJobs`, `DoesJobExist`,
  `RefreshJobs`, `RefreshJob`, `SavePlayer`, `SavePlayers`, `Trace`, `GetConfig`,
  `OneSync.*` (Spawn* and the area/closest helpers), and `Math`, `Table` and
  `SetTimeout`.
- **Commands:** `RegisterCommand(name, group, cb, allowConsole, suggestion)`
  supports the argument types `number`, `player`, `playerId`, `string`, `item`,
  `weapon`, `any`, `merge` and `coordinate`, plus `validate`, `Validator` and
  `showError`. Permission works through the ACE `group.<name>`.
- **xPlayer:** every upstream method. Component, tint and paycheck methods are
  harmless no-ops (see below).
- **Server events:** `esx:playerLoaded (src, xPlayer, isNew)`,
  `esx:playerDropped (src, reason)`, `esx:setJob (src, job, lastJob)`,
  `esx:setGroup`, `esx:setAccountMoney`/`addAccountMoney`/`removeAccountMoney`
  `(src, account, money, reason)`, and `esx:onPlayerDeath`/`esx:onPlayerSpawn`
  from clients. The incoming `esx:playerLogout (src, cb)` logs the player out.
- **Client functions:** `PlayerData`, `PlayerLoaded`, `IsPlayerLoaded`,
  `GetPlayerData`, `SetPlayerData`, `SearchInventory`, `GetAccount`,
  `TriggerServerCallback`, `AwaitServerCallback`, `RegisterClientCallback`,
  `SecureNetEvent`, `ShowNotification` (ox_lib), `ShowAdvancedNotification`,
  `ShowHelpNotification`, `ShowFloatingHelpNotification`, `DrawMissionText`,
  `TextUI`/`HideUI`, `Progressbar` (ox_lib, with `onFinish`/`onCancel`),
  `RegisterInput`, `Streaming.Request*`, `Game.*`, and `Game.Utils.DrawText3D`.
  Vehicle properties use ox_lib.
- **Client events:** `esx:playerLoaded (data, isNew, skin)`,
  `esx:onPlayerLogout`, `esx:setJob (job, lastJob)`, `esx:setAccountMoney (account)`,
  `esx:setGroup`, `esx:setPlayerData`, `esx:addInventoryItem`/`esx:removeInventoryItem`,
  `esx:onPlayerDeath`, `esx:onPlayerSpawn`, and `esx:showNotification`,
  `esx:showAdvancedNotification` and `esx:showHelpNotification`.
- **Menus:** `ESX.UI.Menu.Open('default' | 'dialog', ...)` with ESX's
  `(data, menu)` handlers. `data.current` holds the selected element and
  `data.value` holds the dialog input. Menus support `menu.close`, `update`,
  `refresh`, `setElement(s)`, `setTitle` and `removeElement`, as well as
  `Close`, `CloseAll`, `IsOpen`, `GetOpened`, `GetOpenedMenus` and `RegisterType`.
  Default menus use ox_lib `registerMenu` and dialogs use `lib.inputDialog`.
  Menus stack like ESX, so closing a submenu shows its parent again. Sliders
  (min/max or `options`) call `change`. `ESX.OpenContext`/`CloseContext` use
  ox_lib context menus.

## Not supported, or different

- **Menus:** only the `default` and `dialog` types are built in. `list` and other
  types work only if a resource registers them with `RegisterType`. HTML in
  labels is stripped. Menu elements can't be disabled. A dialog that is
  cancelled is always closed. A dialog that is submitted stays open until the
  script closes it, as in ESX. Context `input` elements show as read-only.
- **Blocking helpers:** `AwaitServerCallback`, `AwaitClientCallback`, and
  `Streaming`, `Game.Spawn*`, `Teleport`, `GetPedMugshot` and `OneSync.Spawn*`
  without a callback wait in the calling resource when it includes
  `imports.lua`. Scripts that only use `getSharedObject()` must pass a callback
  or call these from a thread.
- **Not available:** `ESX.Players` is an empty table (use `GetExtendedPlayers`).
  `ESX.CreatePickup`, `CreateJob`, `DiscordLog`, `ESX.ShowInventory` and player
  function overrides are stubs. Weapon components and tints are no-ops, because
  ox_inventory uses its own component items. Paychecks are paid by rps_core, so
  `togglePaycheck` only records the flag. `setName` lasts for the session only.
  There is no skinchanger: the `skin` argument of `esx:playerLoaded` is
  `{ sex = 0|1 }`. Scaleform, points and interactions helpers are not provided.
- **`isNew`:** it is true for a character that has never been saved, meaning one
  with no stored position.
- **Vehicle type:** `ESX.OneSync.SpawnVehicle` defaults the vehicle type to
  `automobile`. Pass the type yourself for boats, bikes, helicopters and planes.
- **ox_inventory framework:** keep ox_inventory on its rps framework
  (`setr inventory:framework "rps"`). When it is set to `esx`, ox_inventory
  fires the ESX item events itself, and the bridge then skips its own.
