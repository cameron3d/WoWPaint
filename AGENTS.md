# AGENTS.md — working agreements for WoWPaint

## Always port the latest build to the live WoW install

**After any change to addon code (`*.lua` or `WoWPaint.toc`), copy the build into the game's
AddOns folder.** Do it as the closing step of the change, next to running the tests — not only
when asked. The desktop suite cannot exercise the UI or the comm layer, so the only real
verification is in the client, and that cannot start until the build is in place.

### Destination

Classic Era and Anniversary realms both run the `_classic_era_` client:

```
F:\World of Warcraft\_classic_era_\Interface\AddOns\WoWPaint\
```

The folder name must be exactly `WoWPaint`, matching `WoWPaint.toc`, or the client ignores it.

### What to copy

Only what the client loads: `WoWPaint.toc` and the six `.lua` files it lists. Keep `docs/`,
`tests/`, `.git/` and `.claude/` out of the AddOns folder — the client never reads them.

```bash
WOW_ADDONS="/f/World of Warcraft/_classic_era_/Interface/AddOns"
mkdir -p "$WOW_ADDONS/WoWPaint" && cp WoWPaint.toc *.lua "$WOW_ADDONS/WoWPaint/"
```

### Before porting

Both must pass. Porting a build that does not parse costs a client restart to discover.

```bash
for f in *.lua; do luac -p "$f" || echo "SYNTAX FAIL $f"; done && lua tests/run_tests.lua
```

### After porting

Tell the user what to do to pick it up, and be specific — the two cases differ:

- **`.lua` changes only** → `/reload` is enough.
- **`WoWPaint.toc` changed** (new file listed, version bump) → full client restart. A
  `/reload` will not pick up a file the client did not know about at load.

Then say what to look for in game, since that is the part no test covers.

## Project conventions

- **No libraries.** No Ace3, no LibDBIcon. The addon ships as one copy-paste folder, and
  everything — frames, minimap button, comm — is hand-rolled against the stock API.
- **Lua 5.1.** The client runs 5.1; `luac -p` here is 5.4 and will happily accept syntax the
  game rejects. Avoid goto, integer division, and 5.4-only stdlib.
- **Untrusted input.** Every inbound addon message comes from another player. Validate length,
  alphabet and ranges, and drop malformed messages silently.
- **Design decisions live in** [`docs/superpowers/specs/2026-08-10-wowpaint-design.md`](docs/superpowers/specs/2026-08-10-wowpaint-design.md).
  Add a section there when behaviour changes; do not let the spec drift from the code.
