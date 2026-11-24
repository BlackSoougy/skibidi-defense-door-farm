# Skibidi Defense — Door Farm + Auction Hub

One file. A door farm and an auction-house lister in a single window, for
`[UTTV REWORK] Skibidi Defense`.

Also in this repo: **[STD_Mini.luau](#std_mini)** — a separate mini hub for the
JJK-style tower defence (`STD`), not part of the door farm.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/BlackSoougy/skibidi-defense-door-farm/main/SD_Hub.luau"))()
```

## Hotkeys

| Key | Does |
| --- | --- |
| `F5` | show / hide the window |
| `F3` | show it on the door-farm tab |

Both tabs live in one `ScreenGui`, so nothing is duplicated and the old
standalone copies are shut down automatically if they are still loaded.

## Door farm

It does not forge a remote. It drives the door's own `ProximityPrompt` — the
same call your mouse makes when you walk up and press `E` — and it reads the
server's own signals instead of guessing:

| time | signal | meaning |
| --- | --- | --- |
| 0.25s | prompt fired | — |
| 0.5s | `PromptVisuals "anchortrue"` | the knock was accepted |
| 2.7s | viewport | the room pops up |
| 5.5s | toast `Treat!` / `Trick!` | the payout, and the exact cooldown |
| 8.4s | `PromptVisuals "anchorfalse"` | the sequence is over |

- **One knock in flight.** Firing a second door mid-sequence is silently
  dropped by the server, so a dropped knock is re-fired instead of the walk
  being slowed down for everything.
- **Cooldowns are parsed, not assumed.** The toast carries the remaining time
  (`"The door will be available in 27 Minutes 32 Seconds"`) and it is stored
  against that door.
- **Per-door table.** Every door shows its last result (`treat` / `trick` /
  `cooldown` / `fired`) and how long it still has to cool.
- **Consumables only fire when the bag has one.** Counts come from the
  `UpdateInventory` payload, never from the inventory GUI, which is a stale
  snapshot. `Pumpkinspice` wipes every cooldown, `UpgradedBasket` doubles the
  next 15 doors and stacks.

Speed is `instant` / `150` / `400` / `800` studs per second, and the fire gap
cycles `2.5s → 2.0s → 1.8s → 1.5s → 1.2s`. At 1.8s a full 29-door sweep takes
about four minutes; the run is bound by the server sequence, not by travel.

## Auction house

- Real thumbnails, scraped from the game's own inventory grid, so `ITEM/*`
  stacks have icons too.
- The same buckets the trading menu uses: `Units`, `Shards`, `Items`, `Traits`,
  `Crafted`, plus `All` with section headers and a name search.
- Start bid, duration (`5m` / `1h` / `6h` / `12h` / `24h`), `LIST NOW`,
  `FILL FREE SLOTS`, `cancel all`, and an auto mode that keeps the slots filled
  and re-lists as lots expire.
- `median` fills the price from the auction sniper's price table, if it is
  loaded (`getgenv().SDAuctionSniper`).

Measured against the server, not assumed:

- `Max 1 items per listing.` — the quantity field was removed rather than left
  lying.
- `Slow down.` under about 8s between listings, so the cooldown is 9s with one
  retry.
- No listing fee.
- The number of free slots is decided **before** the fill loop starts. Trusting
  the cached count mid-loop over-lists (it placed 6 lots into 3 slots).

## Notes

- Nothing here writes to the account. Listing and cancelling are reversible and
  free; the farm only uses items you actually own.
- Reloading the script is safe: it tears down its predecessor and prunes stale
  listeners left on the toast and prompt remotes.
- Public API, if you want to drive it from another script:

```lua
local hub = getgenv().SDHub
hub.Show("auction")
hub.Farm.Start()  hub.Farm.Stop()  hub.Farm.Toggle()
hub.Auction.SetItem("CursedSpeakerman")
hub.Auction.SetPrice(500)
hub.Auction.List()
hub.Auction.Fill()
hub.Auction.CancelAll()
hub.Destroy()
```

---

<a name="std_mini"></a>
# STD_Mini — event joiner / auto exit / anti-AFK

A different game, a different file. Three modules and a 480×600 window:
auto-join the piñata portals, leave the match when it ends, and stay awake.

## Load

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/BlackSoougy/skibidi-defense-door-farm/main/STD_Mini.luau"))()
```

This one line is the whole thing: the hub, its own anti-AFK, and the companion
`unrexl/Scripts` AntiAfk listed in `CFG.ExtraScripts`. Nothing else to paste.

Safe to put in **autoexec**: it waits for `game:IsLoaded()`, `LocalPlayer`,
`PlayerGui`, `ReplicatedStorage.Configs.Towers` and the character before it
touches anything, and the switch `INJECT // BOOT` in the panel turns that wait
off (stored in `STD_Mini_settings.txt`).

## Which portal it joins

A candidate is a portal that is open, holds at least `min players` (default 7),
and is not full. Below the minimum it is not a candidate at all — the hub waits
for a portal to fill rather than hopping into a 3/10 nobody else will join. If
everything is empty or 10/10 it simply waits. Among the portals that qualify:

| # | key |
| --- | --- |
| 1 | somebody inside holds **Meguna** (`KingOfCursesEvo`) or **Gojo Awakened** (`StrongestSorcererEvo`) |
| 2 | the strongest deck — sum of the best 6 owned units by base damage |
| 3 | headcount, then portal index |

`JOIN NOW` is the one way past the gate: it forces a pass with a floor of 1, and
the status says `joining below min` so it is clear the gate was skipped.

Player slots are read through `Remotes.GetOtherPlayerData` (the trade menu's own
call), cached per user for 20s. A portal that just opened reads `0/10` for a
moment, so the hub waits for the counts to replicate before deciding.

## Also in it

- **Auto exit** — end screen up, or `Info.GameRunning == false` →
  `Events.ExitGame:FireServer()`, with the game's own Exit button as a fallback.
  Both remotes only exist inside a match place, so they are looked up per place.
- **Anti-AFK** — four camera-relative directions held and blended, the root
  carried along the same vector, on `Stepped` (a background client stops
  rendering, so `RenderStepped` never fires). Stands still while the mouse is in
  use. If the server drops you in the AFK plaza anyway, it teleports back to the
  exact server it came from.
- **Survives its own teleports** — the script queues itself for the next
  teleport and reloads from the workspace copy or, failing that, from this file's
  raw URL. A plain loadstring is enough; nothing has to be saved locally.
- **Companion scripts** — `CFG.ExtraScripts` is a list of URLs loaded alongside
  the hub, once per place, each in its own thread with its own `pcall`, so a
  companion that loops or throws cannot take the hub down. It currently carries
  `unrexl/Scripts` AntiAfk; the same single loadstring brings both, and the
  INJECT line reports `extra 1/1`.

## API

```lua
local hub = getgenv().STD_Mini
hub.Show(false)         hub.Toggle()
hub.SetMin(7)           hub.JoinNow()      hub.ExitNow()
hub.SetBoot(true)       hub.Boot.took      hub.Build
hub.LoadExtra()         hub.Extra.done
hub.Log()
```
