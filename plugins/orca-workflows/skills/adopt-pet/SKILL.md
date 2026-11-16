---
name: adopt-pet
description: >-
  Turn your own character art into an Orca pet: a .codex-pet bundle whose animations follow your agents' state
  (running while they work, waiting when one needs you, review when work is done). Slices grid images, fits frames
  to Orca's 8x9 sheet, fills rows you have no art for, validates the bundle the way Orca's importer does and
  previews it. Use when the user says "adopt-pet", "/adopt-pet", "펫 만들어줘", "Orca 펫으로 만들어", "codex-pet",
  "이 캐릭터로 펫", "make an Orca pet", or wants a custom pet in Orca's status bar. Requires Orca
  (https://github.com/stablyai/orca); the pet is imported from Orca's GUI.
---

# adopt-pet

Orca can show a pet that reacts to your agents. A single uploaded image only bobs up and down. A `.codex-pet`
bundle gets a row of frames per state, so the pet runs while an agent works and waits when one needs you. This
skill builds that bundle from images the user brings.

It does not draw. Code-drawn characters come out as stacks of rectangles, so never offer to draw the character
yourself. The art comes from the user: their own drawing, an image generator, or a sprite sheet they have.

The format was read out of Orca 1.4.256's app bundle; it is not documented by Orca. The full spec is in
[references/spec.md](references/spec.md). If an import fails on a newer Orca, recheck it there first.

```bash
PET="${CLAUDE_PLUGIN_ROOT:-<this skill's folder>}/skills/adopt-pet/scripts/pet.py"   # Codex: path to this skill
pet() { uv run -q "$PET" "$@"; }    # a function, not "$RUN": zsh does not word-split variables
W=<a scratch folder for this pet>
```

`uv` installs Pillow on first run. On a Mac where uv fails with `invalid peer certificate: UnknownIssuer`, add
`--native-tls`.

## 1. Get the art

Ask what they have. Any of these works:

- **Several poses of one character** (separate files or one grid image). Best result.
- **One still image.** The script makes every row from it with motion and small overlays (a speech bubble,
  sparkles, a "!"). It moves, but every row is the same pose.
- **Nothing yet.** Offer an image-generator prompt. Ask for a transparent or plain one-colour background, the whole
  body in frame and the same character in every pose, for example:

  > Full-body chibi sprite of `<character>`, `<pixel art | flat illustration>`, plain white background, one
  > character per cell, a 3x3 grid of poses: standing, walking, waving, jumping, sad, waiting with arms crossed,
  > casting/working, reading a book, sleeping.

If the character belongs to someone else (an anime or game character), say once that a pet made from it is
fine on their own screen but should not be shared or published, then carry on.

Grid images: cut them first.

```bash
pet slice <grid.png> --cols <C> --rows <R> --out "$W/frames"     # writes r<row>c<col>.png per non-empty cell
```

## 2. Write plan.json (your one judgment)

Look at every frame (read the images) and decide which row each one belongs to. Write `$W/plan.json`:

```json
{
  "displayName": "Roxy",
  "id": "roxy",
  "description": "Blue-haired mage with a witch hat.",
  "style": "smooth",
  "background": "auto",
  "base": "frames/r0c0.png",
  "animations": {
    "running": ["frames/r1c0.png", "frames/r1c1.png"],
    "waiting": ["frames/r1c2.png"],
    "review":  ["frames/r2c0.png"],
    "failed":  ["frames/r2c1.png"]
  }
}
```

Rules:

- Paths are relative to `plan.json`.
- `base` is the default standing pose. Every row you leave out is made from it.
- Row names and what Orca shows them for:

  | row | when Orca shows it | good pose |
  |---|---|---|
  | `idle` | nothing is happening | standing, breathing |
  | `running` | an agent is working | working, casting, typing |
  | `waiting` | an agent is blocked or waiting for you | arms crossed, tapping a foot, holding a sign |
  | `review` | an agent finished and the result is unread | reading, holding up a paper |
  | `running-right` / `running-left` | the user drags the pet | walking; give only `running-right`, left is mirrored |
  | `waving`, `jumping`, `failed` | in the sheet; trigger not confirmed in 1.4.256 | wave, jump, sad |

- Give any number of frames per row. The script stretches or repeats them to the row's fixed count.
- `style`: `pixel` for pixel art (nearest-neighbour, whole-number scaling), `smooth` for everything else.
- `background`: `auto` clears a solid corner colour when the image has no transparency; `keep` leaves it.
  Use `keep` if the character touches the image corners.
- Don't put the same image in many rows just to fill them. A missing row is better made by the script.

## 3. Build, check, preview

```bash
pet build --plan "$W/plan.json" --out "$W/<id>.codex-pet"     # also validates; exits non-zero on a bad bundle
pet preview "$W/<id>.codex-pet" --out "$W/preview.png"
```

Read `preview.png` and look at it before showing the user. Check that the character is whole in every cell
(nothing cut off at the top on `jumping`), that the background is gone and that the rows match their labels. If
something is off, fix `plan.json` (or `background`) and build again with `--force`.

`pet validate <bundle>` checks any bundle, including ones the user made by hand, with the rules Orca's importer
applies.

## 4. Hand it over

The import is GUI only; there is no CLI for it and the setting is not in a file you should edit.

1. Copy the bundle somewhere easy to pick, such as `~/Downloads/<id>.codex-pet` (don't overwrite an existing one).
2. In Orca's status bar, open the pet menu → **Import .codex-pet bundle…** and pick the folder.
3. **Quit and reopen Orca.** A reload is not enough for imported pets.
4. Pick the pet in the same menu (**Choose pet**). Size is set there too.

Imported pets are copied into `~/Library/Application Support/orca/sidekicks/custom/`, so the bundle in
Downloads can be deleted afterwards.

Report: the bundle path, which rows came from the user's art and which were made from `base`, and the steps
above.
