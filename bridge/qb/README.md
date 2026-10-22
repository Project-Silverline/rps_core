# qb-core bridge (inside rps_core)

Lets scripts written for QBCore run on RPS. rps_core declares `provide 'qb-core'`, so
`exports['qb-core']:GetCoreObject()`, `GetResourceState('qb-core')` and
`dependencies { 'qb-core' }` all resolve to rps_core. You don't install a separate
qb-core resource. The bridge only translates. It owns no data and no database tables.

## How QB concepts map to RPS

| QBCore | RPS |
| --- | --- |
| `citizenid` | `tostring(charId)`; `cid` = `charId` |
| `license` | rps license (`license:...`) |
| `money.cash` / `money.bank` | rps `cash` / `bank` accounts. `crypto` always reads 0 and can't be changed |
| `job` | rps job: `payment` = salary, `isboss` = boss, `grade = { name, level }`. `type` comes from the job's `type` field, otherwise `police` = `leo` and `ambulance` = `ems` |
| `QBCore.Shared.Jobs` | rps `Config.Jobs`, with string grade keys (`'0'`, `'1'`...) |
| `gang` | always `none` (RPS has no gangs). `SetGang` returns false |
| `items`, `Shared.Items` | ox_inventory (QB shape: `amount`/`info` alongside `count`/`metadata`). Weapons are listed as both `WEAPON_X` and `weapon_x` |
| `metadata` | rps metadata, filled out with QB's defaults. `isdead` maps to rps `isDead` and `licences` maps to rps `licenses` (both directions). Other keys are stored in rps metadata as-is |
| `charinfo` | name and birthdate come from rps. `gender` is 0 for male, 1 for female. `phone`, `account`, `fingerprint`, `walletid` and `bloodtype` are derived from charId, so they are stable but not editable |
| permissions `god` / `admin` / `mod` / `user` | rps groups: `god` maps to `admin`, and `user` means everyone. Any other string is checked as an ACE |

There is ONE Player object per character. Its PlayerData is refreshed in place from rps_core
events. Values that cross into your resource are copies, so call `GetPlayer` again
when you need current data, the same as on real QBCore.

## Supported
- `GetCoreObject` (with filters), `GetShared`, the `QBCore:GetObject` event, and every `QBCore.Functions.*` as an export.
- Server: GetPlayer and the other lookups (online players only), GetPlayers, GetQBPlayers, GetPlayersByJob, GetPlayersOnDuty, GetDutyCount, callbacks (both directions), usable items, HasItem, permissions, Kick, Notify, buckets, closest entity, vehicle spawning, SetMethod/SetField, and Add/Update/Remove for jobs, gangs and items.
- Player.Functions: every upstream method, plus the older item methods (AddItem, RemoveItem, GetItemByName, GetItemsByName, GetItemBySlot, ClearInventory). `money` is never cleared.
- Events, fired with QB's argument shapes:
  - Server: `QBCore:Server:PlayerLoaded`, `OnPlayerUnload`, `PlayerDropped`, `OnPlayerUpdated`, `OnJobUpdate`, `OnGangUpdate`, `OnMoneyChange`, `SetDuty`, `QBCore:Player:SetPlayerData`.
  - Client: `QBCore:Client:OnPlayerLoaded`, `OnPlayerUnload`, `OnPlayerUpdated`, `OnJobUpdate`, `OnGangUpdate`, `OnMoneyChange`, `SetDuty`, `QBCore:Player:SetPlayerData`, `QBCore:Notify`, `hud:client:OnMoneyChange`.
  - Incoming: `QBCore:ToggleDuty`, `QBCore:CallCommand`, and `QBCore:Server:SetMetaData` (hunger and thirst only).
- `QBCore.Commands.Add` / `Refresh`, with chat suggestions and `QBCore:Server:PreCommandExecution`.
- Client: Notify (ox_lib), Progressbar (`lib.progressBar`; calls onFinish/onCancel), DrawText/ChangeText/HideText/KeyPressed (`lib.showTextUI`), Get/SetVehicleProperties (ox_lib), SpawnVehicle, the closest-entity helpers, and the other upstream helpers.

## Not supported / different
- **Nothing other resources call can wait.** `TriggerCallback` (client) and `TriggerClientCallback` (server) only work in callback form. Without a callback they print a warning and return nil.
  - `LoadModel`, `RequestAnimDict`, `LoadAnimSet` and `LoadParticleDictionary` start loading and return whether the asset is loaded *now*. Load it yourself first (for example with `lib.requestModel`).
  - `PlayAnim` and `SpawnVehicle` run in a thread. Server `SpawnVehicle`/`CreateVehicle` return the handle without waiting for the entity.
- Offline players (`GetOfflinePlayerByCitizenId` / `ByLicense`) return nil. Character create, delete and login belong to rps_core and rps_multicharacter.
- The upstream jobs paycheck, hunger/thirst decay, bans, whitelist, and open/close-server functions aren't included. QB's built-in commands (`/tp`, `/car`, `/setjob`...) aren't either; rps_core has its own.
- Jobs added at runtime (`AddJob`) only exist in the QB view. rps_core can't assign them.
- Player data set by scripts that rps_core doesn't own (such as `optin` or custom fields) lasts for the session only.
- Set ox_inventory's framework convar to RPS's bridge, not `qb`.
