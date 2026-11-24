# SD_Hub — UI parameters and layout (read this before touching the GUI)

Everything below is measured from the working build, not planned. If you change a
number here, change it in `SD_Hub.luau` too, and re-check at 1920x1009.

## Palette (`local C`)

| key | rgb | used for |
| --- | --- | --- |
| `bg` | 5, 8, 13 | window plate, image placeholders |
| `glass` | 11, 17, 25 | panel base (overridden by the gradient) |
| `glass2` | 17, 26, 37 | inactive chips / tags / inputs |
| `card` | 14, 22, 31 | door cards |
| `row` | 17, 26, 36 | inventory rows |
| `sel` | 19, 56, 66 | selected row / active tab |
| `accent` | 64, 224, 240 | cyan: borders, brackets, active text |
| `accent2` | 188, 94, 246 | magenta: title gradient end, divider end |
| `good` | 94, 232, 158 | TREAT, READY, running |
| `bad` | 255, 92, 118 | TRICK, failures |
| `gold` | 246, 196, 84 | COOL, stack items, consumable counts |
| `text` | 226, 240, 248 | primary text |
| `dim` | 116, 142, 160 | labels, secondary |
| `head` | 150, 200, 214 | section headers |
| `line` | 28, 58, 72 | idle strokes |

Fonts: `C.mono = Enum.Font.Code`, `C.ui = Gotham`, `C.uiB = GothamBold`.
Mono is kept only where it is the point — terminal, stats block, door timers,
prompt, activity log. Everything else is `C.uiB`.

## Type scale

`bump(n)` is the single rule: `n <= 8 -> n+2`, `n <= 12 -> n+1`, else `n+2`.
`mono()`, `chip()`, `tagBtn()`, `neon()` all run their size through it, so a call
site keeps its original design number and the rule lifts it. Do not hand-edit
sizes at call sites; change `bump()` if the whole UI needs to move.

Actual rendered sizes: title 22, stats 12, terminal 10, terminal prompt 11,
door name 12, door value 19, door sub 10, card chip 10, item name 12,
item qty 11, section head 10, tab 12, duration chip 12, buttons 12-15,
footer 12/10.

## Geometry (window 940 x 660, content starts at y=58)

Header 58 tall: title at (20,10), subtitle (20,34), tabs at x=246 w=128 h=30,
gap 8, status pill x=530 w=340 right-aligned, close 30x30 at x=894, divider at
y=56 (1px, cyan->magenta, fades right).

Farm tab:
- left column x=14 w=352: START (6, 44h) · stats (58, 108h) · consumables
  (172, 170x54 each at x=14 and x=196) · speed/gap (232, 170x30) ·
  pumpkin/basket (268) · reset (304, 352x28) · terminal (338, 352x256)
- right column x=380 w=546: DOORS header y=6 · grid y=28 h=498 ·
  rewards strip y=534 h=60
- grid: `UIGridLayout` 127x80, padding 8x8, 4 per row

Auction tab:
- inventory panel (14, 6, 600x556): 6 category chips 92x26 at x=9+98i,
  search 582x28 at y=40, list 582x468 at y=76
- side panel (626, 6, 300x556): detail 280x108 at y=8 · START BID label 124 ·
  price 160x30 + median 112x30 at 140 · DURATION label 178 · 5 chips 52x24 at
  194 (step 55) · LISTING SLOTS 226 · slots 242 · LIST NOW 280x38 at 264 ·
  FILL 310 · auto 344 · log 380 h=126 · RELOAD/CANCEL 136x28 at 512
- footer (14, 570, 912x26)

Radii: window 14, panels 12, door cards 8, buttons 8, chips/tags 5-7,
inventory rows 6, icons 4.

## Gotchas that cost time

1. **`UIGradient` multiplies with `BackgroundColor3`.** A plate authored as
   `Color3.fromRGB(28,168,122)` with a gradient of the same colour renders almost
   black. Every gradient-bearing frame now has `BackgroundColor3 = Color3.new(1,1,1)`
   so the sequence is what you see. Same rule for the glass panels.
2. **`UIGradient` on a `TextButton` tints the text too.** That is why `neon()`
   builds a `Frame` with the gradient and puts a transparent `TextButton` on top;
   the label stays white.
3. **Diagonal gradients band.** `neon()` uses `Rotation = 90` (vertical) only.
4. **A full-width 2px strip at the bottom of a rounded card leaves a stepped edge
   at both corners.** The door card underline is inset: `(1,-20)` at `x=10`,
   `y = bottom-8`.
5. **PrintWindow screenshots of Roblox return stale frames.** A capture that
   shows half a panel or a missing window is usually the compositor, not the UI.
   Verify with a geometry dump before "fixing" anything.
6. `gethui()` returns `CoreGui.RobloxGui`; counting children of `CoreGui` for
   `SD_Hub` returns 0 and is meaningless.

## Live values worth remembering

- Farm: 29 doors, gap 1.8s, ~8.4s server sequence per door, `DefaultCd` 36 min,
  cooldown parsed from the toast.
- Auction: 1 item per listing, ~8s server cooldown between listings (client uses
  9s), `myMaxListings` 3, no fee.
- Inventory payload: `[1]` = classID -> {guid -> unit}, `[2]` = flat counts,
  shard keys included.
