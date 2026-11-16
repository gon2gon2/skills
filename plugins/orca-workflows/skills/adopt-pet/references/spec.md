# Orca `.codex-pet` bundle spec

Read out of Orca 1.4.256's app bundle (`/Applications/Orca.app/Contents/Resources/app.asar` and
`app.asar.unpacked/out/renderer/assets/PetOverlay-*.js`). Orca does not document it, so treat it as a snapshot.
`scripts/pet.py validate` encodes these rules.

## Layout

A folder holding a manifest and one sprite sheet. The import dialog picks the folder.

```
<name>.codex-pet/
├── pet.json
└── spritesheet.webp
```

- Neither file may be a symlink.
- The sheet may be PNG, APNG, JPG, GIF or WebP, at most 64 MB.
- `spritesheetPath` is relative to the bundle. It may not start with `/` or `\`, contain `..` or a NUL, or be a
  drive path.

## pet.json

Every field is optional; unknown fields are allowed.

| field | type | limits |
|---|---|---|
| `id` | string | 1–128 chars |
| `displayName` | string | 1–120 chars; the name in the pet menu |
| `description` | string | ≤ 2000 chars |
| `spritesheetPath` | string | 1–255 chars; default `spritesheet.webp` |
| `frame` | `{width, height}` | integers 1–1024 |
| `fps` | number | > 0, ≤ 60 |
| `defaultAnimation` | string | must name an entry in `animations` |
| `animations` | `{name: {row, frames, frameDurationsMs?}}` | row 0–256, frames 1–512, durations ≤ 60000 ms each and as many as `frames` |

## The default layout

When `spritesheetPath` is absent or ends in `spritesheet.webp`, and `frame` and `animations` are both absent,
Orca fills in:

- `frame` 192×208, 8 columns, `fps` 8, `defaultAnimation` `idle`
- the animation table below, so the sheet is **1536×1872** (8 columns × 9 rows)

| row | name | frames | frame durations (ms) |
|---|---|---|---|
| 0 | `idle` | 6 | 1680, 660, 660, 840, 840, 1920 |
| 1 | `running-right` | 8 | 120 each, last 220 |
| 2 | `running-left` | 8 | 120 each, last 220 |
| 3 | `waving` | 4 | 140 each, last 280 |
| 4 | `jumping` | 5 | 140 each, last 280 |
| 5 | `failed` | 8 | 140 each, last 240 |
| 6 | `waiting` | 6 | 150 each, last 260 |
| 7 | `running` | 6 | 120 each, last 220 |
| 8 | `review` | 6 | 150 each, last 280 |

Unused cells to the right of a row stay transparent. If `fps` is given without `animations`, the rows keep their
frame counts and every frame lasts `1000 / fps` ms.

## A custom layout

Set `frame` (and usually `animations`). On import Orca checks:

- the sheet's width and height are whole multiples of `frame`
- every `row` is below the sheet's row count and every `frames` is at most its column count
- `frameDurationsMs`, when present, has one entry per frame
- `defaultAnimation`, when present, is a key of `animations`

Keep the animation names from the table; they are what the overlay looks up.

## Which state plays which row

The overlay looks at the agents it tracks and picks, in order:

1. `waiting` if any agent is `blocked` or `waiting` (permission prompt, question)
2. `running` if any agent is `working`, except in `monitoring` mode
3. `review` if any agent is `done`, or finished work is still unread
4. `idle` otherwise

Dragging plays `running-right` or `running-left` by direction. `waving`, `jumping` and `failed` are in the sheet;
what triggers them was not readable in the minified code.

## Import and storage

- Status bar → pet menu → **Import .codex-pet bundle…**, then quit and reopen Orca (a window reload is not enough).
- A single image (**Upload your own…**) also works: PNG, APNG, JPG, GIF, WebP or SVG up to 64 MB. It gets no
  per-state rows, only a bobbing motion.
- Imported pets are copied to `~/Library/Application Support/orca/sidekicks/custom/` under a UUID name.
- Built-in pets in 1.4.256: Gremlin, OpenCode, Claudino.
