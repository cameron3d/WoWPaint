# Pixel Party — Collaborative Pixel Canvas for WoW Classic / Anniversary

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
PixelParty/
  PixelParty.toc    -- Interface 11509 (Classic Era / Anniversary 1.15.x)
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

### Wire protocol (Comm.lua) — prefix `PixelParty`
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
- SavedVariables `PixelPartyDB`: `{ cells, rev, channel, pos, dbVersion }` (account-wide, one
  global canvas).
- Events: `ADDON_LOADED` (DB init, prefix registration), `PLAYER_ENTERING_WORLD` (delayed hello),
  `CHAT_MSG_ADDON` (dispatch to Comm).
- Slash: `/pixelparty` (toggle), `sync`, `clear`, `channel <auto|guild|party|raid>`, `help`.

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

Accept flow: invitee creates a local stub `{members = {self, inviter, owner}}`, whispers `J`;
the inviter adds them, whispers the full roster (`M`) to every member, and offers the canvas
(`O`, then the standard `G`/`S` exchange). Implementation note: the offer path was chosen over
streaming blind so the joiner keeps its usual guards, timeouts and one-transfer-at-a-time rule.

Trust rules: B/C/M/paint-affecting messages for a member portrait are accepted only from
players already on the local roster; `J` only from pending invitees; `I` from anyone (that is
its purpose); unknown portrait ids are ignored (ids are unguessable in practice).

## UI

- Title shows the active portrait's name; a second bottom row adds **[Portrait ▸]** (cycle),
  **[New]** (name popup), **[Invite]** (uses friendly player target, else name popup).
  Frame grows ~30 px.
- Scope button applies to the Shared portrait only; member portraits show `Members: N` with a
  roster tooltip.
- Slash additions: `/pixelparty new <name>`, `invite <name>`, `list`, `open <name>`,
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
`/pixelparty lock`, `unlock`, `save [name]`, `gallery`.

---

# v0.4 — Tools, panels, and owner authority (2026-08-10, user-requested)

**Requirements:** a GUI for choosing which portrait to paint; owner-only locking *and*
uninviting; a real drawing toolset.

## Drawing tools

A tool row above the palette: **Pencil, Line, Box, Circle, Fill, Pick**, plus **Nib** (1–3
cell freehand width), **Undo**, and **Grid**. The right mouse button still means "erase", so
every tool has a subtractive twin without doubling the buttons; Shift fills Box and Circle.

- Shapes are previewed by writing straight to the cell textures during the drag and are only
  committed on release, so an in-progress box costs no wire traffic. Dragging off the canvas
  clamps to the edge rather than cancelling.
- Fill is a 4-connected flood over the colour under the cursor. The region is collected before
  anything is painted, because the walk reads the cells the paint would be mutating. A
  whole-canvas fill is ~4096 ops ≈ 54 batched messages ≈ 19 s of throttled queue: slow, never
  a disconnect risk.
- Undo keeps the last 20 actions per session as `(cell, previous colour)` lists and replays
  them newest-first through the normal paint path — peers see a repaint, not a rewind, which
  is the only thing that can work without a server. Undo is not itself undoable.
- Geometry (`ForRect`, `ForEllipse`) and `Canvas.FloodFill` live in the pure-logic modules so
  the desktop suite covers them. The ellipse uses a cell-centre membership test with a
  4-neighbour edge rule: midpoint variants leak at shallow slopes, and a leaky outline is
  visible on a 64-cell grid.

## Panels

Three side panels share the frame: **Portraits** and **Members** on the left (mutually
exclusive), **Gallery** on the right. All are `UISpecialFrames` (Escape closes).

- **Portraits** — the picker. One row per portrait: name, lock marker, member count or shared
  scope, "yours" for portraits you created, with **Paint** and **Remove**, paged, plus **New
  portrait**. The bottom-bar Portrait button opens it (it used to blind-cycle).
- **Members** — the roster. Owner sees **Uninvite** on every row but their own; everyone gets
  **Invite**. Opened from the `Members: N` button, which also carries a roster tooltip.
- **Gallery** — unchanged, plus the **Back to painting** control v0.3 specified and never got.

## Owner authority

- **Locking is owner-only in both directions.** v0.3 let any roster member relay a lock so
  stale painters converged without the owner online. That also let a straggler who missed an
  unlock drag the owner back into it, and handed every member a freeze button. Locked clients
  now just drop inbound paints, so a straggler diverges from nobody, and only the owner sends
  the "it's locked" nag.
- **Uninvite (`K<id>`, whispered, owner only).** The removed player deletes their local copy;
  anything still whispered at them for that id is ignored as an unknown portrait.
- Rosters union-merge, so a bare removal would be undone by the next gossip from a member who
  had not heard about it. Every removal leaves an **add-only tombstone**, and the `M` payload
  grew a token grammar: `name` adds, `-name` tombstones, `+name` lifts a tombstone. Removals
  and revocations are honoured **from the owner only**. `ValidMemberName` rejects names
  starting with `-`/`+` so a member cannot be laundered into a kick for someone else, and
  rejects `|`, `,`, `:` and control characters (chat escapes and both delimiters).
- The owner may re-invite someone they removed (the invite lifts the tombstone and gossips
  `+name`); anyone else's re-invite is refused locally, since every peer's tombstone would
  filter it out anyway.

## Review fixes folded in (v0.2/v0.3 code)

- `/pixelparty lock` on a locked portrait unlocked it — both verbs routed to a toggle.
- Queued-paint drops after a remote clear deduplicated by message *content*, so two batches
  with identical ops (paint a cell, erase it, paint it again) un-counted one `rev` instead of
  two and left the client permanently ahead of its peers. Batches now carry a send tag.
- The invitee's roster stub was built as a table literal, so a `nil` in the middle would
  truncate the `ipairs` walk and leave a roster that trusts nobody.
- Status read "Whispering N members" while whispering to N−1 (the roster counts you).
- `pendingInvites` never dropped expired entries; Lock stayed live while viewing the gallery.

## Still out of scope

Redo, per-pixel author attribution, freehand strokes, a leave protocol (deleting a portrait
is still a local act), and any lock stronger than a convention between unmodified clients.

## v0.4.1 — Minimap launcher (user-requested)

A minimap button, hand-rolled (no LibDBIcon — the addon still ships as one folder):

- **Left-click** opens the canvas, **right-click** opens the Portraits panel, **drag** moves it
  around the ring. Angle and hidden state persist in `db.minimap`; `/pixelparty minimap` toggles
  visibility. The tooltip names the active portrait, its member count or scope, and its lock.
- The initial v0.4.1 icon was four quads of the addon's own palette rather than an
  `Interface\ICONS\…` path. v0.5.1 replaces those quads with the Pixelbrush runtime asset.
- Creating the button costs nothing at load — it does not build the canvas frame, so the
  one-time 4096-texture hitch still waits for an actual click.

To be the launcher the request asked for, the **Portraits panel became a floating sibling** of
the canvas window instead of its child: it anchors beside the canvas when that is open and
centre-screen when it is not, and it gained **Open the canvas** and **Gallery** buttons. Picking
a portrait raises the canvas window. It sits at HIGH strata — above the canvas, below the
StaticPopups it opens.

---

# v0.5 — Larger canvases, zoom, and Battle.net bulk sync (2026-08-11, user-requested)

**Requirement:** bigger canvases, and/or zooming in and out.

Both, as it turned out: bigger canvases need zoom anyway, because a 128-cell grid does not
fit a 512px widget at a usable cell size. Shipped in two stages so the risk was staged too —
stage 1 changed no wire format at all.

## Why 64 was the old ceiling

The wire alphabet is 64 characters, so a paint op packed x, y and colour into one character
each. 64x64 is the largest grid where a coordinate fits in a single character. Two other
things scaled with area: snapshot sync (2 chars per cell worst case, 200 chars per whisper)
and the texture grid (one texture per cell, forever).

## Stage 1 — virtualized viewport (no protocol change)

Textures are allocated per **visible slot**, not per canvas cell, and the window they show is
moved by panning. Rendering cost therefore tracks the viewport rather than the canvas; a
fixed per-cell grid would have needed 16384 textures at 128x128. The pool grows lazily and
never shrinks, so a 64x64 canvas at 8px still allocates exactly the 4096 textures it always
did.

Zoom levels are 4/8/16/32 px per cell, offered from the level where the whole canvas fits and
inwards — there is deliberately no zoom-out past that, since it would only shrink the picture
inside a fixed widget. The wheel zooms and keeps what is under the cursor in view;
middle-drag pans; pan is disabled when the whole canvas is on screen.

All of the arithmetic (`VisibleCells`, `FitZoom`, `ZoomList`, `ClampPan`, and both directions
of the viewport/canvas mapping) is pure and unit-tested. It is the one part of the new UI that
can be wrong arithmetically rather than visibly.

## Stage 2 — per-portrait size

Sizes are **64 and 128**. A third size was considered and dropped: it would have been another
code path through every codec, test and migration for a marginal middle. The built-in Shared
canvas is pinned at 64 on every client forever, which is what keeps it readable across addon
versions.

- `Canvas` takes size as a **required first argument** everywhere. A call site that forgets it
  raises instead of quietly treating a 128 canvas as a 64 one — a silent coordinate scramble
  is far worse than a visible error.
- Ops stay **3 chars at size 64, byte-identical to v0.1**, and widen to 5 (two chars per axis,
  12 bits, up to 4096) above it. Batch limits recompute per width: 76 ops at 3 chars, 48 at 5.
- Size rides in `I` (invite), `S` (snapshot header) and `H` (hello). The invite parse is
  strict, so an invite from an older addon fails to match rather than creating a canvas of the
  wrong size and scrambling every op after it. A peer announcing a different size for the same
  portrait gets a throttled warning — silent divergence is the thing worth avoiding.
- A snapshot whose declared size differs from ours is rejected outright rather than
  reinterpreted.

## Stage 2 — Battle.net bulk transport

`C_BattleNet.SendGameData` (formerly `BNSendGameData`) delivers addon data to a Battle.net
friend's game account and carries **4078 bytes per message against the chat transport's 255**.
A worst-case full canvas costs ~41 whispers over chat and 3 messages here; at 128x128 it is
164 versus 9.

The catch, documented by both Blizzard and ChatThrottleLib, is that Battle.net delivery is
**explicitly not ordered**. So only snapshot chunks take this path: they are numbered `i of n`
and reassembled by index, which makes ordering irrelevant to them. Everything whose meaning
depends on sequence — paints, clears, locks, the echo linearization — stays on the ordered
chat transport. Inbound Battle.net messages that are not snapshot chunks are dropped rather
than trusted, so the unordered pipe cannot be used to smuggle a clear past the ordering rules.

The whole path is feature-detected and falls back to chat: the API is resolved at call time,
and the receive event is registered under `pcall` because registering an unknown event raises.

## Testing

`Core.lua` joined the desktop suite for the first time — it owns the upgrade path for canvases
people have already painted, and nothing was exercising it. Stubbing `CreateFrame` to capture
the event handler is enough to drive `ADDON_LOADED` and assert on real migrations: v1 to v2,
sizeless portraits adopting 64, corrupt data being repaired, and cells past the canvas area
being trimmed. It caught a load-breaking bug on its first run (`SanitizeCells` called without
the new size argument, which would have raised on every login).

## Accepted limits

- Members of a >64 portrait all need v0.5+. Portrait ids are random, so older clients never
  see new portraits uninvited, but an invitee on an old version cannot join one.
- A non-Battle.net late joiner to a busy 128x128 still waits through a chat-rate snapshot;
  that is the transport's floor, not something the addon can optimise away.
- Canvases cannot be resized after creation.

---

## v0.5.1 — Pixelbrush visual identity (2026-08-11)

The generic four-colour minimap quadrants are replaced by an original **Pixelbrush Crest**:
a diagonal pixel brush followed by cyan, yellow, and magenta paint cells. The storefront and
runtime exports deliberately share a silhouette but not a single raster treatment:

- `art/PixelParty-CurseForge-1024.png` is the richer square project-logo master, with a dark
  stone medallion and restrained gold rim. It is publication art and is not shipped to WoW.
- `Media/PixelPartyMinimap.tga` is a flat 64x64 RGBA runtime texture authored for reduction to
  the 18px launcher interior. The existing Blizzard tracking border and hover remain intact.
- Runtime distribution now includes the single `Media/` texture alongside the TOC and Lua
  files. Generated sources, alternate versions, and small-size proofs stay under `art/` and
  are excluded from the live AddOns copy.

The minimap glyph is kept text-free, high-contrast, and deliberately simple. Storefront detail
must never be automatically downscaled into the launcher; future revisions validate a 16px
proof separately before replacing the runtime texture.

---

## v0.6 — Full Pixel Party identity (2026-08-11)

The addon is fully renamed from its former identity to **Pixel Party**, including its package
folder and TOC (`PixelParty/PixelParty.toc`), SavedVariables table (`PixelPartyDB`), addon-message
prefix (`PixelParty`), public slash command (`/pixelparty`), frames, assets, documentation, and
release metadata. This is intentionally a fresh technical identity: existing data stored under
the former SavedVariables name is not migrated, and clients using the former wire prefix do not
interoperate with Pixel Party. Install the addon only as `Interface/AddOns/PixelParty/`; remove
the former addon folder to avoid loading both identities at once.
