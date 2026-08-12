# Pixel Party

Collaborative pixel painting for **WoW Classic Era / Anniversary** (1.15.x). Paint a shared
64×64 canvas with your guild or group, create invite-only **portraits** (up to 128×128) with
friends on any realm you can whisper, **lock** finished pieces, and keep copies in your
personal **gallery**.

## Install

1. Copy this folder into `World of Warcraft\_classic_era_\Interface\AddOns\` so you have
   `...\AddOns\PixelParty\PixelParty.toc`.
2. Fully exit and restart the client; `/reload` does not discover a newly named addon package.
3. Everyone who wants to paint (or watch) needs the addon installed.

Pixel Party intentionally starts with a fresh SavedVariables identity. Canvases, portraits,
gallery entries, and UI settings stored by an earlier package are not imported.

## Paint

- The **minimap button** is the front door: **left-click** opens the canvas, **right-click**
  opens the Portraits panel — pick a canvas to paint, browse the **Gallery**, or start a
  **New portrait**. Drag it around the minimap ring; `/pixelparty minimap` hides or shows it.
- `/pixelparty` (or `/pparty`) — toggle the canvas window.
- **Left-click / drag** paints with the selected color; **right-click / drag** erases — with
  every tool, so right-dragging a box erases a box.
- The palette row selects one of 16 colors (classic r/place palette). The **wheel button** at
  its end opens the **color wheel** — 48 more colors on 12 hue spokes × 4 shade rings, for 64
  total. Everyone painting needs Pixel Party 0.7+ to see wheel colors: older versions never
  receive those strokes (each cell keeps showing whatever was painted there before) and can't
  sync a canvas that uses them. Pixel Party warns in chat when it knows that combination is
  happening — best effort, since an out-of-date client that never announces itself can't be
  detected — and prefers up-to-date painters when pulling a canvas, so a stale copy from an
  old client doesn't quietly overwrite wheel-colored art.
- **Clear** wipes the active canvas for everyone painting it (confirmation first).

### Tools

| Tool | What it does |
|------|--------------|
| **Pencil** | Freehand. Gaps between mouse samples are filled in, so fast strokes stay solid. |
| **Line** | Drag for a straight line. |
| **Box** | Drag for a rectangle. Hold **Shift** to fill it. |
| **Circle** | Drag for an ellipse. Hold **Shift** to fill it. |
| **Fill** | Flood-fills the matching area under the cursor. |
| **Pick** | Picks up the color under the cursor, then switches back to Pencil. |
| **Nib** | Freehand width, 1–3 cells. |
| **Undo** | Steps back through your last 20 actions. |
| **Grid** | Cell guides — yours only, nobody else sees them. |
| **Zoom** | 4/8/16/32 px per cell. Mouse wheel over the canvas also works. |

**Zoom and pan.** The wheel zooms and keeps what's under the cursor in view; **middle-drag**
pans when the canvas is bigger than the window. There's deliberately no zooming out past the
point where the whole canvas fits — that would only shrink the picture inside a fixed frame.

Shapes preview live while you drag and are only sent when you release, so sketching a box
costs no traffic. Dragging past the edge clamps to it instead of cancelling. Undo repaints
what your action covered, so other painters see a repaint rather than a rewind — the only
thing that can work without a server.

## The Shared canvas

The built-in **Shared** portrait works with zero setup: everyone in your scope who runs the
addon paints the same picture. The **Scope** button (or `/pixelparty channel`) cycles
Auto → Guild → Party → Raid; *Auto* prefers your battleground/instance group, then Raid,
Party, Guild.

## Portraits and invitations

- **New** (or `/pixelparty new Sunset Over Orgrimmar`) creates a named portrait with you as its
  creator and sole member. The Portraits panel has a **New size** toggle: **64×64** or
  **128×128**, four times the area. The Shared canvas is always 64×64.
- Everyone painting a 128×128 portrait needs the same addon version — older clients can't read
  the wider coordinates. If someone's out of date you'll get a warning in chat rather than
  silently mismatched art. The Shared canvas works across every version as long as it sticks
  to the classic 16 colors; wheel colors need 0.7+ everywhere, like everything else.
- **Invite** (or `/pixelparty invite Thrall`) whispers an invitation — it prefills your current
  friendly target. The invitee gets an accept/decline popup; on accept they join the roster
  and receive the canvas automatically. Any member can invite others (up to 24 members).
- Members paint together over whispers, so they **don't need to share a guild or group** —
  anyone you can whisper works. Around 6 simultaneous painters stays smooth; bigger rosters
  get laggier strokes, never disconnects.
- **Portrait:** opens the picker — every canvas you have, with member counts and lock state;
  **Paint** switches to one, **Remove** drops your copy (`/pixelparty portraits`, the minimap
  button's right-click, or `open <name>` / `list` / `delete <name>` from chat). The panel
  floats free of the canvas window, so it works as a launcher with the canvas closed.
- **Members: N** opens the roster (hover it for a quick list). The creator gets an
  **Uninvite** button beside every other member; `/pixelparty uninvite Thrall` does the same.
  Uninviting deletes that player's copy and they can no longer paint it — only the creator
  can do it, and only the creator can invite them back afterwards.

## Locking and the gallery

- **Lock** (creator only, `/pixelparty lock` / `unlock`) freezes a portrait for everyone — no
  more painting or clearing until the creator unlocks. Inviting people to a locked portrait
  is how you share finished art.
- **Save** (`/pixelparty save [name]`) snapshots the active canvas into your local gallery;
  **Gallery** (`/pixelparty gallery`) browses saved pieces read-only (View/Delete, paged) with
  **Back to painting** to leave the read-only view. Gallery copies are yours alone and never
  change, even if the live portrait is painted over.

## How it works (and its limits)

- WoW addons have no internet access; peers talk over **addon messages** (guild/party/raid/
  instance chat for the Shared canvas, whispers for portraits and sync). There is no server —
  every canvas lives in each player's SavedVariables and merges opportunistically.
- Strokes batch every 0.5 s; all traffic is self-throttled well below the chat server's
  tolerance, so it will not disconnect you.
- **Battle.net friends sync much faster.** Addon data sent to a BNet friend carries 4078 bytes
  per message against chat's 255, so a full canvas takes ~3 messages instead of ~41. Only
  snapshots use it — Battle.net delivery isn't ordered, so live strokes stay on the ordered
  chat path where their sequence matters. Everyone else falls back to whispers automatically.
- On login or opening a canvas, revision counters are compared and whoever is behind pulls a
  snapshot from whoever is ahead. Own broadcasts are reconciled against the chat channel's
  serialization order, so racing a clear against in-flight strokes converges.
- **Known limits:** groups that paint the same portrait while apart diverge and the
  higher-revision canvas wins wholesale on reunion; whisper-mesh portraits can transiently
  diverge if a clear races strokes within the same second (repaired by the next snapshot
  sync); there is no *leave* protocol — deleting a portrait just removes your copy, and
  members who are offline when someone is uninvited keep whispering at them (harmlessly)
  until they hear about it; locks and uninvites rely on every member running an unmodified
  addon (they are whiteboard conventions, not DRM).

## Development

Desktop tests cover the codecs, RLE, geometry, viewport maths, rosters, the inbound protocol
trust rules, and the SavedVariables migration path:

```bash
lua tests/run_tests.lua
```

Design notes: [docs/superpowers/specs/2026-08-10-pixel-party-design.md](docs/superpowers/specs/2026-08-10-pixel-party-design.md).

If Blizzard bumps the Classic Era client past 1.15.9, update `## Interface:` in
[PixelParty.toc](PixelParty.toc) (or enable "Load out of date AddOns").
