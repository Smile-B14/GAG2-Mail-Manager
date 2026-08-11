# Grow a Garden 2 Mail Manager

Executor-side Luau mail interface for Grow a Garden 2, grounded in the game's mailbox, inventory, fruit-value, and Fruit Price Stock structures.

## Executor support

- Delta
- Other executors that support standard Roblox `ModuleScript` requiring, Luau buffers, `loadstring`, and `game:HttpGet`

## Usage

1. Join Grow a Garden 2 and wait for your inventory to load.
2. Execute `GAG2_Mail_Manager.luau`.
3. The script builds its plant/fruit catalog only from `ReplicatedStorage.Assets.Fruits`, `.Plants`, and `.Seeds`, yielding between small batches so startup does not freeze the game.
4. Resolve a username, select grown fruits, pets, seeds, or gear, optionally enter a note, and send.
5. In **Auto Collect**, select produce, choose a weight (kg) or height (studs) threshold and whether to collect at/above or at/below it, then enable Auto Collect. Bamboo defaults to height.
6. Optionally enable Auto Sell to sell newly collected, unfavorited fruit through the game's normal Sell All endpoint.
7. Use the minus button to collapse the interface into a draggable **SB** bubble; tap the bubble to restore it.
8. Press Right Shift to hide or show the interface.

Re-executing automatically stops the previous copy and removes orphaned same-name UI left by an interrupted run.

## Features

- Runtime catalog discovery only from the game's exact `Assets.Fruits`, `Assets.Plants`, and `Assets.Seeds` folders
- Batched/yielding asset scans to reduce frame stalls
- Replica-safe startup that reuses the game's already-loaded `PlayerStateClient` before attempting an executor-local module require
- Live inventory refresh every second, reacquiring the current player replica and recovering automatically if one refresh fails
- Exact live Tool-marker reconciliation for newly added seed, gear, and pet inventory entries and stack counts
- Grown-fruit discovery from authoritative `Inventory.HarvestedFruits` entries plus exact game-marked `FruitProxyUtil` instances, using stable mailbox IDs
- Pets come from authoritative `Inventory.Pets`; equipped and favorited pets are excluded
- Favorited harvested fruit is excluded and removed from stale queues
- Fruit mutation, weight, size multiplier, mutation multiplier, Fruit Price Stock multiplier, and live Sheckles value
- Automatic selected-fruit total using K/M/B/T/Qa/Qi-style abbreviations
- Large queued sends have no fixed client-side queue cap and are submitted in one mailbox request rather than the old artificial 20-unit client batching
- Non-blocking mailbox response timeout so the UI cannot remain stuck on STOP forever
- Inventory reconciliation after a missing/hung response to detect sends that the server accepted even when no response returned
- STOP immediately cancels the local send state and ignores late responses
- Search and Fruits / Pets / Seeds / Gears filters
- Responsive five-tab inventory filter row that stays inside the panel at every UI scale
- Draggable minimized bubble with swirl animation to and from the bubble's actual position
- Responsive desktop/mobile scaling
- Smooth milestone-based loading animation with a 0–100% progress line and Smile B credit
- Smile B branding in the main header and `SB` minimized bubble
- Default mail note: `Smile B Messenger`
- Per-produce Auto Collect rules with persisted selection, weight/height metric, threshold, and above/below condition
- Authoritative own-garden scanning using the game's `UserId`, `PlantId`, `FruitId`, `Age`, and `MaxAge` attributes
- Exact game weight calculations in kilograms (the game value is already kg) plus rendered-height measurement for Bamboo and other whole plants
- Persistent `Grab Mutated` toggle; mutated plants and fruit are skipped by default and collected only when explicitly enabled
- Rate-limited harvest batches using the game's `Garden.CollectFruit` packet
- Optional timeout-safe Auto Sell checks live inventory every five seconds using the game's `NPCS.SellAll` response; server-protected favorited fruit is not sold
- Item icons and local mail history
- Live Fruit Price Stock refresh countdown

The game server still validates ownership and mailbox requests. The script does not invent items or recipient inventory.
