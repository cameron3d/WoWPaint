# WoWPaint

An r/place-style collaborative pixel canvas for **WoW Classic Era / Anniversary** (1.15.x).
Open a shared 64×64 canvas, pick a color, and paint with your guild, party, or raid — everyone
running the addon sees the picture evolve live, and it persists between sessions.

## Install

1. Copy this folder into `World of Warcraft\_classic_era_\Interface\AddOns\` so you have
   `...\AddOns\WoWPaint\WoWPaint.toc`.
2. Restart the client if it was running (a `/reload` is enough if you were already logged in).
3. Everyone who wants to paint (or watch) needs the addon installed.

## Use

- `/wowpaint` (or `/wpaint`) — toggle the canvas window.
- **Left-click / drag** paints with the selected color; **right-click / drag** erases.
- The palette row selects one of 16 colors (classic r/place palette).
- **Scope** button cycles Auto → Guild → Party → Raid. *Auto* prefers Raid, then Party, then
  Guild. Paint ops broadcast to that scope only.
- **Clear** wipes the canvas for everyone in scope (confirmation dialog first).
- `/wowpaint sync` — re-request the latest canvas from peers.
- `/wowpaint channel guild` — pin the broadcast scope.

## How it works (and its limits)

- WoW addons have no internet access; peers talk over **addon messages** (guild/party/raid chat
  channels, whispers for sync). There is no server — the canvas lives on every player's machine
  (SavedVariables) and merges opportunistically.
- Paint strokes batch every 0.5 s and broadcast at a self-throttled rate that stays well below
  the chat server's tolerance, so it will not disconnect you.
- When you log in or open the canvas, the addon announces its canvas revision; whoever has the
  newest picture streams it to whoever is behind (a full canvas is at most ~40 whispers,
  ~10–15 s).
- **Known limitation:** two groups painting separately while apart (e.g. offline) diverge; when
  they meet again, the higher-revision canvas wins wholesale rather than merging pixel-by-pixel.
- Anyone in scope can paint over anything or clear the canvas — it is a whiteboard, not a vault.

## Development

Pure-logic tests (codec, RLE, line drawing) run on desktop Lua:

```bash
lua tests/run_tests.lua
```

Design notes live in [docs/superpowers/specs/2026-08-10-wowpaint-design.md](docs/superpowers/specs/2026-08-10-wowpaint-design.md).

If Blizzard bumps the Classic Era client past 1.15.7, update `## Interface:` in
[WoWPaint.toc](WoWPaint.toc) (or enable "Load out of date AddOns").
