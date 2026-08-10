# WoWPaint

Collaborative pixel painting for **WoW Classic Era / Anniversary** (1.15.x). Paint a shared
64×64 canvas with your guild or group, create invite-only **portraits** with friends on any
realm you can whisper, **lock** finished pieces, and keep copies in your personal **gallery**.

## Install

1. Copy this folder into `World of Warcraft\_classic_era_\Interface\AddOns\` so you have
   `...\AddOns\WoWPaint\WoWPaint.toc`.
2. Restart the client if it was running (a `/reload` is enough if you were already logged in).
3. Everyone who wants to paint (or watch) needs the addon installed.

## Paint

- `/wowpaint` (or `/wpaint`) — toggle the canvas window.
- **Left-click / drag** paints with the selected color; **right-click / drag** erases.
- The palette row selects one of 16 colors (classic r/place palette).
- **Clear** wipes the active canvas for everyone painting it (confirmation first).

## The Shared canvas

The built-in **Shared** portrait works with zero setup: everyone in your scope who runs the
addon paints the same picture. The **Scope** button (or `/wowpaint channel`) cycles
Auto → Guild → Party → Raid; *Auto* prefers your battleground/instance group, then Raid,
Party, Guild.

## Portraits and invitations

- **New** (or `/wowpaint new Sunset Over Orgrimmar`) creates a named portrait with you as its
  creator and sole member.
- **Invite** (or `/wowpaint invite Thrall`) whispers an invitation — it prefills your current
  friendly target. The invitee gets an accept/decline popup; on accept they join the roster
  and receive the canvas automatically. Any member can invite others (up to 24 members).
- Members paint together over whispers, so they **don't need to share a guild or group** —
  anyone you can whisper works. Around 6 simultaneous painters stays smooth; bigger rosters
  get laggier strokes, never disconnects.
- **Portrait ▸** cycles between your portraits (`/wowpaint open <name>`, `list`,
  `delete <name>`).

## Locking and the gallery

- **Lock** (creator only, `/wowpaint lock`) freezes a portrait for everyone — no more
  painting or clearing until the creator unlocks. Inviting people to a locked portrait is
  how you share finished art.
- **Save** (`/wowpaint save [name]`) snapshots the active canvas into your local gallery;
  **Gallery** (`/wowpaint gallery`) browses saved pieces read-only (View/Delete, paged).
  Gallery copies are yours alone and never change, even if the live portrait is painted over.

## How it works (and its limits)

- WoW addons have no internet access; peers talk over **addon messages** (guild/party/raid/
  instance chat for the Shared canvas, whispers for portraits and sync). There is no server —
  every canvas lives in each player's SavedVariables and merges opportunistically.
- Strokes batch every 0.5 s; all traffic is self-throttled well below the chat server's
  tolerance, so it will not disconnect you. A full canvas syncs in at most ~40 whispers.
- On login or opening a canvas, revision counters are compared and whoever is behind pulls a
  snapshot from whoever is ahead. Own broadcasts are reconciled against the chat channel's
  serialization order, so racing a clear against in-flight strokes converges.
- **Known limits:** groups that paint the same portrait while apart diverge and the
  higher-revision canvas wins wholesale on reunion; whisper-mesh portraits can transiently
  diverge if a clear races strokes within the same second (repaired by the next snapshot
  sync); there is no kick/leave protocol — deleting a portrait just removes your copy; locks
  rely on every member running an unmodified addon (it is a whiteboard convention, not DRM).

## Development

Pure-logic tests (codec, RLE, line drawing, ids, rosters, gallery) run on desktop Lua:

```bash
lua tests/run_tests.lua
```

Design notes: [docs/superpowers/specs/2026-08-10-wowpaint-design.md](docs/superpowers/specs/2026-08-10-wowpaint-design.md).

If Blizzard bumps the Classic Era client past 1.15.7, update `## Interface:` in
[WoWPaint.toc](WoWPaint.toc) (or enable "Load out of date AddOns").
