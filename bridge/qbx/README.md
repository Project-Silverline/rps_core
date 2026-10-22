# Qbox (qbx_core) bridge

Lets scripts written for [Qbox](https://github.com/Qbox-project/qbx_core) run on RPS.
The bridge runs inside `rps_core`, which `provide`s both `qbx_core` and `qb-core`.
`exports.qbx_core:*` calls are answered by rps_core. The Qbox bridge is built on the
QB bridge (`exports['qb-core']:GetCoreObject()`): Qbox players are the QB Player
objects with Qbox's extra fields. Both bridges must be present.

It translates calls only and stores no data of its own. Characters, money, jobs and
metadata stay in rps_core, and items stay in ox_inventory.

## Including Qbox files

Qbox resources load two files by path. rps_core keeps them at the same relative
path as qbx_core does:

| Qbox path | RPS path |
| --- | --- |
| `@qbx_core/modules/lib.lua` | `@rps_core/modules/lib.lua` |
| `@qbx_core/modules/playerdata.lua` | `@rps_core/modules/playerdata.lua` |

If a resource fails to start with the `@qbx_core/...` path, change its fxmanifest to the
RPS path. The same applies to `require '@qbx_core.modules.lib'`, which becomes
`require '@rps_core.modules.lib'`.

## How Qbox concepts map to RPS

| Qbox | RPS |
| --- | --- |
| `citizenid`, `charinfo`, `money`, `metadata` | whatever the QB bridge maps them to (rps character / accounts / metadata) |
| `money.cash`, `money.bank` | rps `cash` / `bank` accounts (cash = ox_inventory `money` item) |
| `job` | the rps job; `grade.level` = rps grade, `isboss`/`bankAuth` = rps `boss`, `payment` = `salary` |
| `job.type` | the job's `type` field, else `police -> leo`, `ambulance -> ems` (`bridge/qbx/shared.lua`) |
| `jobs` (multi-job) | `{ [job] = grade }` with the single rps job (empty when unemployed) |
| `gang` / `gangs` | always `none` / `{}`. RPS has no gangs |
| usable items | `rps_core` usable items (QB calling style) |
| permissions | ACEs plus rps groups (`user`, `mod`, `admin`) |

## Supported

- **Server exports:** GetPlayer (id or identifier), GetPlayerByCitizenId, GetPlayerByPhone, GetQBPlayers, GetPlayersData, GetPlayers (extra), GetSource, GetCoreVersion, Logout, Save, SetJob, SetJobDuty, AddPlayerToJob / RemovePlayerFromJob / SetPlayerPrimaryJob (single job: adding a job replaces the current one), GetJobs / GetJob / GetGangs / GetGang, GetGroups, HasGroup, HasPrimaryGroup, IsGradeBoss, GetGroupMembers (online only), GetDutyCountJob / GetDutyCountType, SetMetadata / GetMetadata (incl. `'table.key'`), AddMoney / RemoveMoney / SetMoney / GetMoney, registerHook / removeHooks (money hooks), CreateUseableItem, CanUseItem, Notify, HasPermission / GetPermission / AddPermission / RemovePermission, IsOptin / ToggleOptin, SetPlayerData / UpdatePlayerData, routing buckets (SetPlayerBucket, SetEntityBucket, GetPlayersInBucket, GetEntitiesInBucket, GetBucketObjects), CreateSessionId, EnablePersistence / DisablePersistence (flag only), DeleteVehicle, GetVehicleClass (`nil` until a client has sent the class table).
- **Client exports:** GetPlayerData, Notify, HasGroup, HasPrimaryGroup, GetGroups, GetJobs / GetJob / GetGangs / GetGang, GetVehiclesByName / ByHash / ByCategory, GetWeapons, GetLocations.
- **Events:** `qbx_core:server:playerLoggedOut` / `qbx_core:client:playerLoggedOut` (fired on logout, not on disconnect), `qbx_core:server:onGroupUpdate` (source, group, grade?) / `qbx_core:client:onGroupUpdate` (group, grade?), `qbx_core:server:onSetMetaData` (key, old, new, source) / `qbx_core:client:onSetMetaData` (key, old, new). The rps keys `isDead` and `licenses` are reported as `isdead` and `licences`. The QB events come from the QB bridge.
- **State bags:** `isLoggedIn` (set by rps_core). `hunger`, `thirst` and `stress` are kept in sync with rps metadata both ways, clamped to 0-100.
- **`modules/lib.lua`:** the full `qbx` table: string/math/table/array helpers, getVehiclePlate, generateRandomPlate, getCardinalDirection, spawnVehicle (server), drawText2d/3d, getEntityAndNetIdFromBagName, entityStateHandler, deleteVehicle, vehicle name/mod/livery/extras helpers, getStreetName, getZoneName, isWearingGloves, isWearingDuffelbag, loadAudioBank, playAudio.

## Not supported

- **No-ops, nil or false:** gangs (SetGang, AddPlayerToGang and SetPlayerPrimaryGang fail for anything but `none`), offline players (GetOfflinePlayer, SearchPlayers, citizenid-based calls for characters that aren't loaded), user IDs (GetPlayerByUserId, GetUserId = 0), Login, CreatePlayer, DeleteCharacter, SetCharInfo, SaveOffline, bans and whitelist (IsPlayerBanned = false, IsWhitelisted = true, ExploitBan only drops the player), and runtime job/gang editing (CreateJob(s), RemoveJob, Upsert*, Remove*Grade). Edit `rps_core/shared/jobs.lua` instead.
- **Empty data:** RPS has no shared vehicle, weapon or location lists, so GetVehiclesByName, GetVehiclesByHash, GetWeapons and GetLocations return empty tables. Scripts that list vehicles from them, such as vehicle shops, show nothing.
- **Missing systems:** Qbox's own commands, multicharacter, the queue, vehicle persistence and respawn, the `loadInventory` state bag (ox_inventory uses its rps bridge), and Qbox's `modules/utils.lua`, `modules/hooks.lua` and `config/*.lua` include files.
- **Hooks:** money hooks run only for changes made through `exports.qbx_core` Add/Remove/SetMoney. Changes made in rps_core or through qb-core don't run them.
- **GenerateUniqueIdentifier:** returns random values that aren't checked for uniqueness.
