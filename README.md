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
3. Resolve a username, queue items, optionally enter a note, and send.
4. Press Right Shift to hide or show the interface.

Re-executing automatically stops the previous copy and removes orphaned same-name UI left by a cleared executor state or an interrupted initialization.

## Real game limits

- 20 total item units per gift
- 100 UTF-8 characters per note
- Recipient mailbox capacity defaults to 100 gifts

The interface accepts queues of up to 100,000 units and divides them into valid 20-unit gifts. It stops safely on the first server rejection and leaves the unsent remainder queued.

## Features

- Race-safe username lookup and avatar preview with stale-state clearing, a bounded timeout, and late-response rejection
- Mailable fruits, seeds, and all non-pet gear categories
- Search and category filters
- Responsive desktop/mobile scaling that rebinds when Roblox replaces the active camera
- Item icons in inventory, queue, and local mail history
- Fruit mutation, weight, size multiplier, mutation multiplier, stock multiplier, and live Sheckles value
- Live Fruit Price Stock refresh countdown with bounded request timeouts, late-response rejection, and automatic retry
- Automatic queued-fruit value total, refreshed when fruit metadata changes or equal-count inventory swaps occur
- Searchable session/file-backed send history with malformed-record recovery and a 250-record cap
- Partial-send accounting and stop control

The game still validates every request server-side. This script does not bypass mailbox availability, inventory ownership, per-gift limits, or recipient capacity.
