# WoWPaint — Collaborative Pixel Canvas for WoW Classic / Anniversary

**Date:** 2026-08-10
**Status:** Approved by default (autonomous session — greenfield execution mode). Key alternative
(freehand stroke drawing) documented below; raise it if you prefer that direction.

## What it is

An r/place-style shared pixel canvas inside WoW Classic Era / Anniversary. Players open a movable
frame with a 64×64 pixel grid and a 16-color palette, and paint by clicking/dragging. Paint
operations are broadcast to other addon users over addon messages (guild, party, or raid), so
everyone sees the same picture evolve in near-real-time. The canvas persists across sessions via
SavedVariables, and late joiners sync the current picture from whoever has the newest state.

## Why these choices

### Pixel grid vs. freehand strokes
- **Pixel grid (chosen):** matches "collaboratively paint a picture" in the r/place sense — a
  single shared persistent artifact, trivially mergeable (a pixel op is idempotent: set cell to
  color), compact on the wire, and naturally griefing-tolerant (paint over it back).
- **Freehand strokes (alternative):** prettier drawing, but stroke sync/merge is much harder
  (ordering, erasing, unbounded state growth) and the wire format is heavier. Not chosen.

### Transport
WoW addons have no network access; the only peer channel is `C_ChatInfo.SendAddonMessage`.
Custom chat channels no longer carry addon messages (removed in the 8.x engine Classic runs on),
so distribution options are **GUILD / PARTY / RAID / INSTANCE_CHAT / WHISPER** (instance-category
groups such as battlegrounds only deliver on INSTANCE_CHAT). Default scope: **Auto**
(Instance → Raid → Party → Guild); user can pin Guild/Party/Raid. Whisper is used only for sync
streaming, and each message type is accepted only from the channel kind that legitimately
produces it (paints/clears/hellos from group broadcasts, sync negotiation from whispers).

Constraints respected:
- Payload ≤ 255 bytes per message.
- Self-throttled send queue (1 msg / 0.35 s ≈ 730 B/s) — comfortably under the ~800 B/s
  community-established safe rate (ChatThrottleLib's ceiling), so no disconnect risk.

### No external libraries
Self-contained (no Ace3). The comm needs are small enough that embedding Ace3 adds more surface
than it saves, and this keeps the addon a single copy-paste folder.

## Architecture

```
WoWPaint/
  WoWPaint.toc      -- Interface 11507 (Classic Era / Anniversary 1.15.x)
  Util.lua          -- base-64 char codec, small helpers
  Canvas.lua        -- canvas data model + RLE serialize/deserialize
  Comm.lua          -- protocol, throttled send queue, snapshot sync
  UI.lua            -- main frame, pixel grid, palette, input handling
  Core.lua          -- events, SavedVariables, slash commands
```

### Canvas model (Canvas.lua)
- 64×64 cells, flat array `cells[1..4096]`, values 0–15 (0 = white background / eraser).
- 16-color palette (classic r/place 2017 palette).
- `rev` — a coarse revision counter: +1 for every paint **batch** applied (local or remote) and
  every clear. Used only to decide "who is behind" for snapshot sync, not for per-pixel ordering.
- RLE codec for snapshots: runs of ≤64 encoded as 2 chars (run-1, color) from a 64-char alphabet.
  Blank canvas ≈ 128 chars; worst case 8192 chars → ~40 whisper chunks.

### Wire protocol (Comm.lua) — prefix `WoWPaint`
| Msg | Form | Direction | Meaning |
|-----|------|-----------|---------|
| B | `B<xyc xyc …>` (3 chars/op, ≤80 ops) | broadcast | batch of pixel ops |
| C | `C` | broadcast | clear canvas |
| H | `H:<rev>:<version>` | broadcast | hello — announce my revision |
| Q | `Q:<rev>` | whisper | "I'm behind you — offer me a snapshot" |
| O | `O:<rev>` | whisper | snapshot offer |
| G | `G` | whisper | accept offer, start streaming |
| S | `S:<i>:<n>:<rev>:<data>` | whisper | snapshot chunk i of n |
| R | `R` | whisper | snapshot request declined (source-side throttle); requester aborts its wait immediately |

Sync flow: joiner broadcasts `H`. Peers with a higher rev whisper `O` after a random 0.5–2.5 s
delay; peers with a *lower* rev whisper `Q` (which makes the joiner offer back to them, and never
triggers another `Q`, so no loops). The joiner collects offers for 3 s, picks the highest rev,
whispers `G`, and receives `S` chunks. Incoming `B` ops during sync are buffered and replayed
after the snapshot applies (pixel ops are idempotent, so double-apply is harmless). Sync aborts
on a 15 s stall.

Conflict model: live ops are last-arrival-wins per pixel; snapshots replace the whole canvas.
Two groups painting divergently while apart will not merge pixel-perfectly — accepted limitation
for v1 (a per-pixel Lamport clock would fix it at ~2× state size; noted as future work).

Local paints apply immediately (optimistic echo), buffer up to 0.5 s / 80 ops, then flush as one
`B` broadcast. Own broadcasts are ignored on receipt (sender self-check).

### UI (UI.lua)
- Movable frame (~544×640), title bar, close button, Escape closes, position saved.
- 512×512 canvas area: 4096 8×8 textures created once on first open (one-time ~50–100 ms hitch).
- Input: one mouse-capture frame over the canvas — left button paints selected color, right
  button erases (color 0); drag paints continuously with Bresenham interpolation between frames
  so fast strokes don't leave gaps.
- Palette row: 16 swatches with a selection ring.
- Bottom bar: channel cycle button (Auto/Guild/Party/Raid), Clear button (StaticPopup confirm —
  clear is broadcast, it's collaborative), status text (channel · rev · sync state).

### Core (Core.lua)
- SavedVariables `WoWPaintDB`: `{ cells, rev, channel, pos, dbVersion }` (account-wide, one
  global canvas).
- Events: `ADDON_LOADED` (DB init, prefix registration), `PLAYER_ENTERING_WORLD` (delayed hello),
  `CHAT_MSG_ADDON` (dispatch to Comm).
- Slash: `/wowpaint` (toggle), `sync`, `clear`, `channel <auto|guild|party|raid>`, `help`.

## Error handling
- All inbound messages validated (length, alphabet, ranges) and silently dropped if malformed —
  other players are untrusted input.
- Sends are skipped with a status note when no channel is available (unguilded + ungrouped).
- Snapshot buffers keyed to the single accepted source; chunks from anyone else ignored.

## Testing
- `luac -p` syntax pass on all files (Lua 5.4 parser; code written 5.1-compatible for WoW).
- Pure-logic unit checks runnable under desktop Lua: RLE round-trip, batch encode/decode,
  Bresenham coverage (test harness in `tests/`, never loaded by the game client).
- Multi-agent adversarial review pass (API correctness for 1.15.x, protocol logic, UI/perf).
- Manual in-game verification is on the user (two clients or a guildmate).

## Out of scope for v1
Freehand strokes, multiple named canvases, per-pixel author attribution, minimap button,
canvas export, cross-faction/cross-realm sync beyond what addon channels allow, permissions
(anyone in scope can paint or clear — like a real whiteboard).

---

# v0.2 — Portraits and invitations (2026-08-10, user-requested)

**Requirement:** players can create a new *portrait* and invite other addon users to paint it.

## Model

A **portrait** is the document unit: `{ id, name, dist, members?, cells, rev }`.
- `id`: 6 chars from the wire alphabet, randomly generated at creation (64^6 space, no
  coordination needed). The built-in **Shared** portrait has the reserved id `000000` on every
  client — it preserves v0.1 behavior exactly (scope broadcast, implicit membership).
- `dist`: `MEMBERS` for created portraits (whisper fan-out to the roster — members need no
  common guild or group), or a scope (`AUTO`/`GUILD`/`PARTY`/`RAID`) for the Shared portrait.
- `members`: full `Name-Realm` list, **add-only set** (union-merged, so concurrent invites by
  different members converge). Leaving = deleting the portrait locally; remaining members'
  whispers to the departed player are wasted but bounded. Accepted v0.2 limitation.

SavedVariables becomes `{ dbVersion = 2, portraits = { [id] = portrait }, activeId, pos }`;
v1 data migrates into the Shared portrait.

## Protocol changes

Every existing message gains a fixed-width 6-char portrait id right after the kind byte
(`B<id><ops>`, `C<id>`, `H<id>:<rev>:<ver>`, `Q/O/G/S/R` likewise). Scope portraits keep
broadcast delivery for B/C/H; member portraits send everything as whispers to each roster
member. Sync (H/Q/O/G/S/R) is unchanged, just id-scoped; one inbound snapshot transfer at a
time globally, buffered events tagged with the portrait id.

New whisper-only messages:
| Msg | Form | Meaning |
|-----|------|---------|
| I | `I<id>:<name>` | invite to portrait (any member may invite; recipient gets accept/decline popup) |
| J | `J<id>` | invite accepted (honored only if we invited that player for that id within 120 s) |
| M | `M<id>:<name1>,<name2>,…` | roster update, union-merge; chunked if long; trusted only from existing members |

Accept flow: invitee creates a local stub `{members = {self, inviter}}`, whispers `J`; the
inviter adds them, whispers the full roster (`M`) to every member, and streams the canvas
(`S` chunks) straight to the new member (no offer negotiation — the inviter is the source).

Trust rules: B/C/M/paint-affecting messages for a member portrait are accepted only from
players already on the local roster; `J` only from pending invitees; `I` from anyone (that is
its purpose); unknown portrait ids are ignored (ids are unguessable in practice).

## UI

- Title shows the active portrait's name; a second bottom row adds **[Portrait ▸]** (cycle),
  **[New]** (name popup), **[Invite]** (uses friendly player target, else name popup).
  Frame grows ~30 px.
- Scope button applies to the Shared portrait only; member portraits show `Members: N` with a
  roster tooltip.
- Slash additions: `/wowpaint new <name>`, `invite <name>`, `list`, `open <name>`,
  `delete <name>`.

## Accepted trade-offs (v0.2)

- Whisper fan-out costs (N−1) messages per paint batch; with the 0.35 s send throttle a
  ~6-member portrait stays smooth, larger rosters get laggier strokes rather than disconnects.
- No leave protocol, no kick, no ownership enforcement beyond roster trust.
- Offline members simply miss events and re-sync via rev negotiation next time both sides
  are online with the portrait open.

---

# v0.3 — Gallery and locking (2026-08-10, user-requested)

**Requirement:** a gallery to save portraits to, and the ability to lock portraits.

## Gallery (purely local, no protocol)

`db.gallery` is an ordered list of immutable snapshots: `{ name, cells (deep copy), savedAt,
source = portrait name }`. A **Save** control copies the active portrait's canvas at that
moment; saving again later creates a second entry. A **Gallery** panel lists entries
(name + date, paged) with **View** and **Delete**. View renders the entry read-only into the
main canvas grid with painting disabled and a **Back** control; Delete removes the local copy
after a confirm. Gallery entries never sync — each player curates their own collection.

## Locking

- `portrait.locked` / `portrait.lockedBy`, persisted. The **owner** (creator) locks and
  unlocks; the built-in Shared portrait has no owner and cannot be locked.
- Wire: `L<id>` (lock) and `U<id>` (unlock), sent on the portrait's normal distribution.
  Trust: `U` is honored from the owner only. `L` is honored from the owner **or any roster
  member** (lock-relay) — when a locked client receives a paint/clear from a peer that
  evidently missed the lock, it drops the ops and whispers `L<id>` back (throttled 30 s per
  sender), so stale painters converge to locked without owner presence. A malicious member
  can therefore freeze a portrait early, but that is within the existing roster trust class
  (they could equally scribble over it), and the owner can always unlock.
- While locked: local painting and Clear are blocked in the UI (status shows "Locked by X"),
  inbound B/C are dropped, and L/U do not bump `rev`. Snapshot sync stays fully active so
  canvases still converge after stragglers; the `S` chunk header gains a lock-state field so
  late joiners and re-syncers adopt the lock with the pixels.
- Inviting to a locked portrait remains allowed — it is the sharing mechanism for finished
  art (new member receives roster, canvas, and lock state; sees it read-only).

## UI (v0.2 + v0.3 combined)

Second bottom row: **[Portrait ▸] [New] [Invite] [Lock/Unlock] [Save] [Gallery]**
(Lock shown only to the owner of a lockable portrait; Save/Gallery always). Slash additions:
`/wowpaint lock`, `unlock`, `save [name]`, `gallery`.
