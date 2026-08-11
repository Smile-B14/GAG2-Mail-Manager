# Grow a Garden 2 Mail Manager

Executor-side Luau mail interface for Grow a Garden 2, grounded in the game's actual mailbox, inventory, fruit-value, and Fruit Price Stock structures.

## Executor support

- Delta
- Solara
- Other executors that support standard Roblox `ModuleScript` requiring and Luau buffers

The script avoids requiring the game's `SharedModules.Networking` module because that module uses `require("./Packet")`, which Delta and Solara reject. It reconstructs only the exact mailbox and Fruit Stock packet endpoints from the underlying `Packet` ModuleScript.

## Usage

1. Join Grow a Garden 2 and wait for your inventory to load.
2. Execute `GAG2_Mail_Manager.luau`.
3. Resolve a username, queue grown fruits, seeds, or gear, optionally enter a note, and send.
4. Use the minus button to collapse the interface into a draggable **B** bubble; tap the bubble to restore it.
5. Press Right Shift to hide or show the interface.

Re-executing automatically stops the previous copy and removes orphaned same-name UI left by a cleared executor state or an interrupted initialization.

## Real game limits

- 20 total item units per gift
- 100 UTF-8 characters per note
- Recipient mailbox capacity defaults to 100 gifts

The interface accepts queues of up to 100,000 units and divides them into valid 20-unit gifts. It stops safely on the first server rejection and leaves the unsent remainder queued. If a write response fails, delivery is reported as uncertain and the unconfirmed batch remains queued; verify inventory or mail state before retrying.

## Features

- Race-safe username lookup and avatar preview that stays hidden until a thumbnail resolves, with stale-state clearing, a bounded timeout, and late-response rejection
- Defensive grown-fruit discovery across fruit-named replica containers and wrappers, plus seeds and all non-pet gear categories
- Search and category filters
- Viewport-fitting desktop/mobile scaling that rebinds when Roblox replaces the active camera
- Draggable circular minimized mode for mouse and touch with smooth swirl open/close transitions
- Item icons in inventory, queue, and local mail history, with defensive item-metadata fallback when the native catalog omits a grown fruit
- Fruit mutation, weight, size multiplier, mutation multiplier, stock multiplier, and live Sheckles value
- Live Fruit Price Stock refresh countdown with bounded request timeouts, late-response rejection, and automatic retry
- Automatic selected-fruit value total using K/M/B/T-style abbreviations, refreshed when fruit metadata changes or equal-count inventory swaps occur
- Searchable session/file-backed send history with visible outcome status, malformed-record recovery, and a 250-record cap
- Partial-send accounting and stop control

The game still validates every request server-side. This script does not bypass mailbox availability, inventory ownership, per-gift limits, or recipient capacity.
