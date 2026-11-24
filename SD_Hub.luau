--[[
    SD_HUB
    ======
    Door Farm + Auction House in one window. Two tabs, one script, one ticker.

    FARM TAB
      The door farm from SD_DoorFarm_v2, unchanged in behaviour: it drives the
      door's own ProximityPrompt and keys off the server's own signals
      (anchortrue / anchorfalse) plus the toast, which carries the payout and
      the exact remaining cooldown. Added here: a live door table showing each
      door's last result and how long it still has to cool.

    AUCTION TAB
      The lister from SD_AuctionLister: real inventory thumbnails, the game's
      own buckets (Units / Shards / Items / Traits / Crafted), name search,
      start bid, duration, LIST NOW / FILL FREE SLOTS, auto mode.

    SHARED
      One UpdateInventory hook feeds both tabs, so the farm's consumable counts
      and the auction's item list can never disagree. One loop drives every
      label. The old standalone copies are stood down on load.

    F5 - toggle window      F3 - same, jumps straight to the farm tab
]]

if getgenv().SDHub then
    pcall(function() getgenv().SDHub.Destroy() end)
end

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local WS         = game:GetService("Workspace")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local LP         = Players.LocalPlayer

--=============================================================
-- STAND DOWN THE OLD COPIES
--=============================================================
-- A second door farm would double-count every toast and fight over the
-- character, and a second lister would double-list. Both are torn down here,
-- and the ancient hub's own farm is switched off.
do
    local oldFarm = getgenv().DoorFarmV2
    if oldFarm and type(oldFarm.Destroy) == "function" then pcall(oldFarm.Destroy) end
    local oldList = getgenv().SDAuctionLister
    if oldList and type(oldList.Destroy) == "function" then pcall(oldList.Destroy) end
    getgenv().DoorFarmV2 = nil
    getgenv().SDAuctionLister = nil

    local hub = getgenv().SkibidiDefenseHub
    if hub then
        pcall(function()
            if hub.State then hub.State.DoorFarm = false end
            if hub.Farm and hub.Farm.StopDoor then hub.Farm.StopDoor() end
        end)
    end
end

--=============================================================
-- SHARED BITS
--=============================================================
-- cyberpunk glass: near-black base, cyan + magenta neon, mono type
local C = {
    bg      = Color3.fromRGB(5, 8, 13),
    glass   = Color3.fromRGB(11, 17, 25),
    glass2  = Color3.fromRGB(17, 26, 37),
    card    = Color3.fromRGB(14, 22, 31),
    row     = Color3.fromRGB(17, 26, 36),
    rowAlt  = Color3.fromRGB(13, 20, 29),
    sel     = Color3.fromRGB(19, 56, 66),
    accent  = Color3.fromRGB(64, 224, 240),
    accent2 = Color3.fromRGB(188, 94, 246),
    good    = Color3.fromRGB(94, 232, 158),
    bad     = Color3.fromRGB(255, 92, 118),
    gold    = Color3.fromRGB(246, 196, 84),
    text    = Color3.fromRGB(226, 240, 248),
    dim     = Color3.fromRGB(116, 142, 160),
    head    = Color3.fromRGB(150, 200, 214),
    line    = Color3.fromRGB(28, 58, 72),
    mono    = Enum.Font.Code,
    ui      = Enum.Font.Gotham,
    uiB     = Enum.Font.GothamBold,
}

local CONNS = {}
local function conn(sig, fn)
    local c = sig:Connect(fn)
    CONNS[#CONNS + 1] = c
    return c
end

local function fmt(n)
    n = tonumber(n) or 0
    if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
    if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if n >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return tostring(math.floor(n))
end

local function pretty(k)
    return (tostring(k):gsub("^ITEM/", ""))
end

local function mmss(sec)
    sec = math.max(0, math.floor(sec or 0))
    local m, s = math.floor(sec / 60), sec % 60
    if m >= 60 then
        return string.format("%dh%02dm", math.floor(m / 60), m % 60)
    end
    return string.format("%d:%02d", m, s)
end

--=============================================================
-- INVENTORY (one hook, both tabs)
--=============================================================
local UpdateInv  = RS:WaitForChild("UpdateInventory", 20)
local RequestInv = RS:WaitForChild("RequestInventory", 20)
local UseItem    = RS:FindFirstChild("UseItem")

local INV = { raw = nil, counts = {}, at = 0 }

local function requestInventory()
    if RequestInv and RequestInv:IsA("RemoteEvent") then
        pcall(function() RequestInv:FireServer() end)
    end
end

if UpdateInv then
    conn(UpdateInv.OnClientEvent, function(payload)
        if type(payload) ~= "table" then return end
        INV.raw = payload
        if type(payload[2]) == "table" then INV.counts = payload[2] end
        INV.at = os.clock()
    end)
end

-- waits for a payload newer than the moment we asked, so a stale cached table
-- is never mistaken for a fresh read
local function readInventory(timeout)
    local t0 = os.clock()
    requestInventory()
    while os.clock() - t0 < (timeout or 3) do
        if INV.raw and INV.at >= t0 then return INV.raw end
        task.wait(0.05)
    end
    return INV.raw
end

-- the GUI snapshot is only a fallback: it never refreshes on its own
local function guiCount(name)
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return 0 end
    local want = "ITEM/" .. name
    for _, v in ipairs(pg:GetDescendants()) do
        if v.Name == want then
            local lbl = v:FindFirstChild("TextLabel", true)
            local t = lbl and lbl.Text or ""
            local clean = tostring(t):gsub(",", ""):gsub("%s", "")
            local num, suf = clean:match("^([%d%.]+)([KkMm]?)$")
            if num then
                local n = tonumber(num) or 0
                if suf == "K" or suf == "k" then n = n * 1000
                elseif suf == "M" or suf == "m" then n = n * 1000000 end
                return math.floor(n)
            end
            return 0
        end
    end
    return 0
end

local function itemCount(name)
    local n = INV.counts["ITEM/" .. name]
    if type(n) == "number" then return math.max(0, math.floor(n)) end
    return guiCount(name)
end

local function useItem(name)
    if not UseItem then return false, "no UseItem remote" end
    local ok, err = pcall(function() UseItem:FireServer(name) end)
    if not ok then return false, tostring(err) end
    local key = "ITEM/" .. name
    if type(INV.counts[key]) == "number" then
        INV.counts[key] = math.max(0, INV.counts[key] - 1)
    end
    return true
end

--=============================================================
-- UI PLACEHOLDERS
--=============================================================
-- The cores below report through these; the real widgets are built further
-- down, so both sides stay independent of construction order.
local uiA = {
    status   = function() end,
    log      = function() end,
    render   = function() end,
    duration = function() end,
    tabs     = function() end,
}
local uiF = {
    log        = function() end,
    rebuild    = function() end,
    refresh    = function() end,
}

--=============================================================
-- AUCTION CORE
--=============================================================
local ACATS     = { "All", "Units", "Shards", "Items", "Traits", "Crafted" }
local DURATIONS = { "5m", "1h", "6h", "12h", "24h" }

local ACFG = {
    Poll         = 15,   -- seconds between auto-relist checks
    ListCooldown = 9,    -- measured: server answers "Slow down." under ~8s
    MaxRows      = 400,
}

local AS = {
    items = {},
    icons = {},
    selected = nil,
    cat = "All",
    search = "",
    duration = "5m",
    auto = false,
    premium = 0,
    myId = nil,
    maxListings = 3,
    myCount = 0,
    busy = false,
    lastPoll = 0,
    listed = 0,
    counts = {},
}

local Auction = RS:FindFirstChild("AuctionRemotes")
local Browse, SellRF, CancelRF
if Auction then
    Browse   = Auction:FindFirstChild("Browse")
    SellRF   = Auction:FindFirstChild("Sell")
    CancelRF = Auction:FindFirstChild("Cancel")
end

--// icons: the game's own inventory grid is the primary source because every
--// cell is an ImageButton holding the real thumbnail, ITEM/* stacks included.
local function buildIconMap()
    local map = {}

    local ok, U = pcall(function() return require(RS.Units) end)
    if ok and type(U) == "table" then
        for _, list in pairs(U) do
            if type(list) == "table" then
                for name, data in pairs(list) do
                    if type(data) == "table" and data.DisplayImageID then
                        map[name] = data.DisplayImageID
                    end
                end
            end
        end
    end

    local pg = LP:FindFirstChild("PlayerGui")
    local grid
    if pg then
        local invGui = pg:FindFirstChild("Inventory")
        local main = invGui and invGui:FindFirstChild("Main")
        local layout = main and main:FindFirstChild("Layout")
        local sf = layout and layout:FindFirstChild("ScrollingFrame")
        grid = sf and sf:FindFirstChild("Inventory")
    end
    if grid then
        for _, cell in ipairs(grid:GetChildren()) do
            if cell:IsA("ImageButton") or cell:IsA("ImageLabel") then
                local img = cell.Image
                if img and img ~= "" then
                    map[cell.Name] = img
                    map[pretty(cell.Name)] = img
                end
            end
        end
    end
    return map
end

-- the game's own bucket rule from PS_Trading: ITEM/TRAIT* -> Traits,
-- ITEM* -> Items, anything with a dash -> Crafted, the rest of slot 2 -> Shards
local function categoryOfKey(key)
    local n = tostring(key)
    if n:sub(1, 10):upper() == "ITEM/TRAIT" then return "Traits" end
    if n:sub(1, 4) == "ITEM" then return "Items" end
    if n:find("-", 1, true) then return "Crafted" end
    return "Shards"
end

local function buildItems(inv)
    local items = {}
    if type(inv) ~= "table" then return items end

    local towers = inv[1] or {}
    local flat = inv[2] or {}

    local classSet = {}
    for classID, unitMap in pairs(towers) do
        if type(unitMap) == "table" then
            classSet[classID] = true
            local count, sampleType = 0, nil
            for _, u in pairs(unitMap) do
                count = count + 1
                if not sampleType and type(u) == "table" then sampleType = u.Type end
            end
            if count > 0 then
                items[#items + 1] = {
                    kind = "tower",
                    key = classID,
                    classID = classID,
                    label = classID,
                    sub = string.format("%s x%d", tostring(sampleType or "?"), count),
                    qty = count,
                    cat = "Units",
                }
            end
        end
    end

    for k, v in pairs(flat) do
        if type(k) == "string" and type(v) == "number" and v > 0 and not classSet[k] then
            items[#items + 1] = {
                kind = "stack",
                key = k,
                label = pretty(k),
                sub = "x" .. fmt(v),
                qty = v,
                cat = categoryOfKey(k),
            }
        end
    end

    local order = { All = 1, Units = 2, Shards = 3, Items = 4, Traits = 5, Crafted = 6 }
    table.sort(items, function(a, b)
        local oa, ob = order[a.cat] or 9, order[b.cat] or 9
        if oa ~= ob then return oa < ob end
        if a.qty ~= b.qty then return a.qty > b.qty end
        return a.label < b.label
    end)

    local counts = {}
    for _, it in ipairs(items) do
        counts[it.cat] = (counts[it.cat] or 0) + 1
    end
    AS.counts = counts
    return items
end

local function invoke(rf, arg, timeout)
    local r = { done = false }
    task.spawn(function()
        local ok, a, b = pcall(function() return rf:InvokeServer(arg) end)
        r.ok, r.a, r.b, r.done = ok, a, b, true
    end)
    local t0 = os.clock()
    while not r.done and os.clock() - t0 < (timeout or 8) do task.wait(0.05) end
    return r
end

local function refreshMarket()
    if not Browse then return false end
    local r = invoke(Browse, nil, 8)
    if r.ok and type(r.a) == "table" then
        AS.premium = tonumber(r.a.myPremium) or AS.premium
        AS.myId = r.a.myId
        AS.maxListings = tonumber(r.a.myMaxListings) or AS.maxListings
        AS.myCount = 0
        for _, l in ipairs(r.a.listings or {}) do
            if l.sellerId == AS.myId then AS.myCount = AS.myCount + 1 end
        end
        AS.lastPoll = os.time()
        return true
    end
    return false
end

local function buildCluster(item, qty)
    if item.kind == "tower" then
        local unitMap = INV.raw and INV.raw[1] and INV.raw[1][item.classID]
        if not unitMap then return nil, "unit class gone" end
        local picked = {}
        for _, u in pairs(unitMap) do
            picked[#picked + 1] = u
            if #picked >= qty then break end
        end
        if #picked == 0 then return nil, "no units left" end
        return { Shards = {}, Towers = { [item.classID] = picked } }
    end
    return { Shards = { [item.key] = qty }, Towers = {} }
end

local function readPrice()
    local p = math.floor(tonumber(uiA.priceText()) or 0)
    if p <= 0 then return nil end
    return p
end

local function doList(manual)
    if AS.busy then return false, "busy" end
    local it = AS.selected
    if not it then
        if manual then uiA.status("select an item first", C.bad) end
        return false, "no item"
    end
    local price = readPrice()
    if not price then
        if manual then uiA.status("set a start bid above 0", C.bad) end
        return false, "no price"
    end
    if not SellRF then
        if manual then uiA.status("no auction remotes in this place", C.bad) end
        return false, "no remote"
    end

    AS.busy = true
    local cluster, err = buildCluster(it, 1)
    if not cluster then
        AS.busy = false
        if manual then uiA.status("cluster build failed: " .. tostring(err), C.bad) end
        return false, err
    end

    local r = invoke(SellRF, { cluster = cluster, startBid = price, durationKey = AS.duration }, 10)
    for _ = 1, 2 do
        if r.ok and r.a == false and tostring(r.b):lower():find("slow") then
            task.wait(ACFG.ListCooldown)
            r = invoke(SellRF, { cluster = cluster, startBid = price, durationKey = AS.duration }, 10)
        else
            break
        end
    end
    AS.busy = false

    if r.ok and r.a == true then
        AS.listed = AS.listed + 1
        AS.myCount = AS.myCount + 1
        uiA.log(string.format("listed %s @ %s P$ / %s", it.label, fmt(price), AS.duration))
        uiA.status(string.format("listed %s for %s P$ (%s)", it.label, fmt(price), AS.duration), C.good)
        return true
    end

    local msg = tostring(r.b or r.a or "failed")
    uiA.log("fail: " .. msg)
    uiA.status("list failed: " .. msg, C.bad)
    return false, msg
end

-- re-reads the inventory and keeps the selection pointing at the live entry
local function refreshSelectionAfterReload(inv2)
    if not inv2 then return true end
    AS.items = buildItems(inv2)
    local keep = AS.selected
    if keep then
        for _, it in ipairs(AS.items) do
            if it.kind == keep.kind and it.key == keep.key then
                AS.selected = it
                return true
            end
        end
        AS.selected = nil
        return false
    end
    return true
end

local function autoTick()
    if not AS.auto or AS.busy then return end
    if not refreshMarket() then
        uiA.log("browse failed")
        return
    end
    if AS.myCount >= AS.maxListings then
        uiA.render()
        return
    end
    if not AS.selected then
        uiA.log("nothing selected")
        return
    end

    local free = AS.maxListings - AS.myCount
    for _ = 1, free do
        if not AS.auto or AS.busy then break end
        if not doList(false) then break end
        task.wait(ACFG.ListCooldown)
        refreshSelectionAfterReload(readInventory(2))
    end
    refreshMarket()
    uiA.render()
end

--=============================================================
-- FARM CORE
--=============================================================
local FCFG = {
    Speed        = 0,      -- studs/s along the straight line; 0 = instant
    AcceptWait   = 1.0,    -- how long the server gets to answer a knock
    Gap          = 1.8,    -- fire-to-fire spacing; dropped knocks are refired
    Retries      = 1,      -- extra attempts when a knock is dropped
    RetryBackoff = 1.2,
    RetryCd      = 45,     -- a knock that never landed comes back in this long
    ResolveWait  = 12,
    ApproachY    = 3,
    Settle       = 0.3,
    DefaultCd    = 36 * 60,
    SortBy       = "index",
    AutoPumpkin  = true,
    AutoBasket   = true,
    BasketPerSweep    = 1,
    BasketMinDoors    = 5,
    PumpkinFreshBelow = 3,
}

local FS = {
    Running    = false,
    Doors      = {},
    Cursor     = 1,
    Current    = nil,
    Laps       = 0,
    Treats     = 0,
    Tricks     = 0,
    Cooldowns  = 0,
    Unknown    = 0,
    Retries    = 0,
    Rewards    = {},
    Status     = "idle",
    LastToast  = "",
    AcceptedAt = nil,
    Fired      = {},
    Gen        = 0,
    Log        = {},
}

local EventStuff    = RS:FindFirstChild("EventStuff")
local PromptVisuals = EventStuff and EventStuff:FindFirstChild("PromptVisuals")

local function farmLog(msg)
    FS.Log[#FS.Log + 1] = os.date("%H:%M:%S") .. "  " .. msg
    while #FS.Log > 8 do table.remove(FS.Log, 1) end
    uiF.log()
end

if PromptVisuals then
    conn(PromptVisuals.OnClientEvent, function(kind)
        if kind == "anchortrue" then
            FS.AcceptedAt = os.clock()
        end
    end)
end

-- a reloaded copy cannot reach its predecessor's listeners, but it can find
-- them: every farm listener holds the farm state as an upvalue
local function looksLikeFarmState(v)
    return type(v) == "table"
        and rawget(v, "Treats") ~= nil
        and rawget(v, "Tricks") ~= nil
        and rawget(v, "Doors") ~= nil
end

local function isFarmClosure(fn, depth, seen)
    depth = depth or 0
    seen = seen or {}
    if depth > 2 or type(fn) ~= "function" or seen[fn] then return false end
    seen[fn] = true
    for i = 1, 20 do
        local ok, a, b = pcall(debug.getupvalue, fn, i)
        if not ok or (a == nil and b == nil) then break end
        for _, v in ipairs({ a, b }) do
            if looksLikeFarmState(v) then return true end
            if type(v) == "function" and isFarmClosure(v, depth + 1, seen) then return true end
        end
    end
    return false
end

local function pruneStale(remote, mine)
    if not remote then return end
    local ok, list = pcall(getconnections, remote.OnClientEvent)
    if not ok or type(list) ~= "table" then return end
    local cut = 0
    for _, c in ipairs(list) do
        local fn = c.Function
        if fn and fn ~= mine and isFarmClosure(fn) then
            pcall(function() c:Disconnect() end)
            cut = cut + 1
        end
    end
    if cut > 0 then print("[SD_Hub] pruned " .. cut .. " stale farm listener(s)") end
end

-- toasts carry both the payout and the exact cooldown, so they are parsed
local function parseCooldown(text)
    local total = 0
    local h = tonumber(text:match("(%d+)%s*Hour"))
    local m = tonumber(text:match("(%d+)%s*Minute"))
    local s = tonumber(text:match("(%d+)%s*Second"))
    if h then total = total + h * 3600 end
    if m then total = total + m * 60 end
    if s then total = total + s end
    if total > 0 then return total end
    return nil
end

-- doors are fired faster than they pay out, so the payout is matched to the
-- fire that sits closest to 5.4s ago - the measured fire-to-toast latency
local TOAST_LATENCY = 5.4

local function attributeDoor()
    local want = os.clock() - TOAST_LATENCY
    local best, bi = math.huge, nil
    for i, e in ipairs(FS.Fired) do
        local d = math.abs(e.at - want)
        if d < best then best, bi = d, i end
    end
    if bi then
        local entry = table.remove(FS.Fired, bi)
        entry.door.inFlight = false
        return entry.door
    end
    return FS.Current
end

local function onToast(payload)
    if type(payload) ~= "table" then return end
    local title = tostring(payload.Title or "")
    local text  = tostring(payload.ContentText or "")
    FS.LastToast = title .. " - " .. text
    local door = attributeDoor()

    if title:find("Cooldown") then
        local cd = parseCooldown(text)
        FS.Cooldowns = FS.Cooldowns + 1
        if door and cd then
            door.cdUntil = os.clock() + cd
            door.result = "cooldown"
            door.inFlight = false
            farmLog(string.format("%s cooling %s", door.name, mmss(cd)))
        else
            farmLog("cooldown toast: " .. text)
        end
        return
    end

    if title:find("Treat") then
        FS.Treats = FS.Treats + 1
        if door then
            door.result = "treat"
            door.cdUntil = os.clock() + FCFG.DefaultCd
        end
        local amount, rest = text:match("%+(%d[%d,]*)%s*(.+)$")
        if amount and rest then
            local item = rest:gsub("[%s!%.%,]+$", ""):gsub("^%s+", "")
            local n = tonumber((amount:gsub(",", ""))) or 0
            if item ~= "" then
                FS.Rewards[item] = (FS.Rewards[item] or 0) + n
            end
        end
        farmLog(string.format("TREAT %s: %s", door and door.name or "?", text))
        return
    end

    if title:find("Trick") then
        FS.Tricks = FS.Tricks + 1
        if door then
            door.result = "trick"
            door.cdUntil = os.clock() + FCFG.DefaultCd
        end
        farmLog(string.format("trick %s: %s", door and door.name or "?", text))
        return
    end
end

do
    local toasts = RS:FindFirstChild("Toasts")
    local display = toasts and toasts:FindFirstChild("Assets")
        and toasts.Assets:FindFirstChild("Remotes")
        and toasts.Assets.Remotes:FindFirstChild("Display")
    if display then
        local myToastFn = function(...)
            for i = 1, select("#", ...) do onToast((select(i, ...))) end
        end
        conn(display.OnClientEvent, myToastFn)
        pruneStale(display, myToastFn)
    else
        farmLog("toast remote missing - rewards will not count")
    end
end

local function char()
    local c = LP.Character
    if not c then return nil, nil end
    return c, c:FindFirstChild("HumanoidRootPart")
end

local function release()
    local c, hrp = char()
    if not hrp then return end
    if hrp.Anchored then hrp.Anchored = false end
    local cam = workspace.CurrentCamera
    if cam then
        cam.CameraType = Enum.CameraType.Custom
        local hum = c:FindFirstChildOfClass("Humanoid")
        if hum then cam.CameraSubject = hum end
    end
end

local function collectDoors()
    local list = {}
    for _, v in ipairs(WS:GetChildren()) do
        if v:IsA("Model") and v.Name:match("^Door%d+$") then
            local pt = v:FindFirstChild("PlayerTo")
            local prompt = pt and pt:FindFirstChild("ProximityPrompt")
            if pt and prompt then
                list[#list + 1] = {
                    name    = v.Name,
                    index   = tonumber(v.Name:match("%d+")) or 0,
                    model   = v,
                    pos     = pt.Position,
                    prompt  = prompt,
                    cdUntil = 0,
                    result  = nil,
                    tries   = 0,
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.index < b.index end)
    return list
end

local function orderTour(list)
    if #list < 3 then return list end
    local _, hrp = char()
    local here = hrp and hrp.Position or list[1].pos
    local pool, out = {}, {}
    for i, d in ipairs(list) do pool[i] = d end
    while #pool > 0 do
        local best, bi = math.huge, 1
        for i, d in ipairs(pool) do
            local dist = (d.pos - here).Magnitude
            if dist < best then best, bi = dist, i end
        end
        local picked = table.remove(pool, bi)
        out[#out + 1] = picked
        here = picked.pos
    end
    return out
end

local function rescan()
    local here = FS.Doors[FS.Cursor or 1]
    local hereName = here and here.name or nil
    local fresh = collectDoors()
    local old = {}
    for _, d in ipairs(FS.Doors) do old[d.name] = d end
    for _, d in ipairs(fresh) do
        local prev = old[d.name]
        if prev then
            d.cdUntil = prev.cdUntil
            d.result = prev.result
            d.tries = prev.tries
        end
    end
    FS.Doors = FCFG.SortBy == "tour" and orderTour(fresh) or fresh
    FS.Cursor = 1
    if hereName then
        for i, d in ipairs(FS.Doors) do
            if d.name == hereName then FS.Cursor = i break end
        end
    end
    farmLog(string.format("scan: %d doors", #FS.Doors))
    uiF.rebuild()
    return #FS.Doors
end

local function flyTo(target)
    local _, hrp = char()
    if not hrp then return false end
    local from = hrp.Position
    local delta = target - from
    local dist = delta.Magnitude
    if dist < 0.5 then return true end

    if FCFG.Speed <= 0 then
        hrp.CFrame = CFrame.new(target)
        return true
    end

    local duration = dist / FCFG.Speed
    local elapsed = 0
    local dir = delta.Unit
    while elapsed < duration and FS.Running do
        local dt = RunService.RenderStepped:Wait()
        elapsed = elapsed + dt
        local t = math.min(elapsed / duration, 1)
        hrp.CFrame = CFrame.new(from + dir * (dist * t))
    end
    hrp.CFrame = CFrame.new(target)
    return FS.Running
end

local function pruneFired()
    local cut = os.clock() - 25
    for i = #FS.Fired, 1, -1 do
        if FS.Fired[i].at < cut then table.remove(FS.Fired, i) end
    end
end

-- one knock; true when the server took it
local function knock(door, gen)
    if not FS.Running or gen ~= FS.Gen then return false end
    local _, hrp = char()
    if not hrp then return false end
    if not door.prompt then return false end

    door.tries = door.tries + 1
    FS.Current = door
    FS.Status = "flying to " .. door.name

    if not flyTo(door.pos + Vector3.new(0, FCFG.ApproachY, 0)) then return false end
    task.wait(FCFG.Settle)

    FS.AcceptedAt = nil
    FS.Status = "knocking " .. door.name

    -- measured: 2.5s spacing processes every prompt, 1.8s drops a few, 1.0s
    -- drops most. The animation is not the limit, the server debounce is, so
    -- the walk keeps the fast cadence and refires whatever gets dropped.
    local accepted = false
    for attempt = 1, FCFG.Retries + 1 do
        FS.AcceptedAt = nil
        local ok, err = pcall(fireproximityprompt, door.prompt)
        if not ok then
            farmLog(string.format("%s: prompt threw (%s)", door.name, tostring(err)))
            return false
        end

        local at = os.clock()
        door.inFlight = true
        door.firedAt = at
        pruneFired()
        FS.Fired[#FS.Fired + 1] = { door = door, at = at, attempt = attempt }

        local deadline = at + FCFG.AcceptWait
        while os.clock() < deadline and FS.Running and gen == FS.Gen do
            if FS.AcceptedAt then break end
            if door.result == "cooldown" then break end
            task.wait(0.02)
        end
        release()

        accepted = FS.AcceptedAt ~= nil
        if accepted or door.result == "cooldown" then break end

        for i = #FS.Fired, 1, -1 do
            if FS.Fired[i].at == at then table.remove(FS.Fired, i) end
        end
        door.inFlight = false
        if attempt <= FCFG.Retries then
            FS.Retries = FS.Retries + 1
            farmLog(door.name .. ": knock dropped, refiring")
            task.wait(FCFG.RetryBackoff)
        end
    end

    if accepted then return true end
    door.inFlight = false
    return false
end

local function resolveInFlight()
    local now = os.clock()
    for _, d in ipairs(FS.Doors) do
        if d.inFlight and now - (d.firedAt or 0) > FCFG.ResolveWait then
            d.inFlight = false
            if d.result == nil and d.cdUntil <= now then
                d.cdUntil = now + FCFG.RetryCd
                FS.Unknown = FS.Unknown + 1
                farmLog(string.format("%s: no payout, retry in %ds", d.name, FCFG.RetryCd))
            end
        end
    end
end

local Farm = {}

function Farm.UsePumpkinspice()
    if itemCount("Pumpkinspice") <= 0 then return false end
    if not useItem("Pumpkinspice") then return false end
    FS.PumpkinUses = (FS.PumpkinUses or 0) + 1
    for _, d in ipairs(FS.Doors) do
        d.cdUntil = 0
        d.result = nil
    end
    farmLog("pumpkinspice: every door reset")
    return true
end

function Farm.UseBasket(count)
    local have = itemCount("UpgradedBasket")
    if have <= 0 then return 0 end
    local n = math.min(have, count or FCFG.BasketPerSweep)
    local used = 0
    for _ = 1, n do
        if not useItem("UpgradedBasket") then break end
        used = used + 1
        task.wait(0.2)
    end
    if used > 0 then
        FS.BasketUses = (FS.BasketUses or 0) + used
        farmLog(string.format("basket x%d stacked", used))
    end
    return used
end

local function lapStart()
    local now = os.clock()
    local fresh = 0
    for _, d in ipairs(FS.Doors) do
        if d.cdUntil <= now then fresh = fresh + 1 end
    end
    FS.Laps = (FS.Laps or 0) + 1

    if FCFG.AutoBasket and fresh >= FCFG.BasketMinDoors then
        Farm.UseBasket()
    end
    if FCFG.AutoPumpkin and fresh < FCFG.PumpkinFreshBelow then
        Farm.UsePumpkinspice()
    end
end

local function loop(gen)
    FS.Status = "starting"
    rescan()
    if #FS.Doors == 0 then
        farmLog("no doors in this place")
        FS.Running = false
        return
    end

    while FS.Running and gen == FS.Gen do
        resolveInFlight()
        local n = #FS.Doors
        local idx = FS.Cursor or 1
        if idx < 1 or idx > n then idx = 1 end
        local door = FS.Doors[idx]

        if idx == 1 then lapStart() end

        if door.inFlight then
            FS.Cursor = (idx % n) + 1
            task.wait(0.05)
        else
            knock(door, gen)
            FS.Cursor = (idx % n) + 1
            FS.Status = string.format("lap %d  %d/%d  %s", FS.Laps or 1, idx, n, door.name)

            local paceUntil = (door.firedAt or os.clock()) + FCFG.Gap
            while os.clock() < paceUntil and FS.Running and gen == FS.Gen do
                task.wait(0.02)
            end
        end
    end
    FS.Status = "stopped"
    release()
end

-- the knock locks the camera to the door for the whole sequence; nothing
-- server-side depends on it, so it is handed back to the character
local camGuard = nil
local function startCamGuard()
    if camGuard then return end
    camGuard = task.spawn(function()
        while FS.Running do
            task.wait(0.1)
            local cam = workspace.CurrentCamera
            local c = LP.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            if cam and hum and cam.CameraType == Enum.CameraType.Scriptable then
                cam.CameraType = Enum.CameraType.Custom
                cam.CameraSubject = hum
            end
        end
        camGuard = nil
    end)
end

function Farm.Start()
    if FS.Running then return end
    if not PromptVisuals then
        farmLog("not in the event map - no doors to farm")
        return
    end
    FS.Running = true
    FS.Gen = FS.Gen + 1
    farmLog(string.format("start (gen %d, %d doors)", FS.Gen, #FS.Doors))
    startCamGuard()
    task.spawn(loop, FS.Gen)
end

function Farm.Stop()
    if not FS.Running then return end
    FS.Running = false
    FS.Gen = FS.Gen + 1
    FS.Status = "stopped"
    release()
    farmLog("stop")
end

function Farm.Toggle()
    if FS.Running then Farm.Stop() else Farm.Start() end
end

Farm.Rescan = rescan

--=============================================================
-- WINDOW
--=============================================================
local function parentGui()
    local ok, hui = pcall(function() return gethui() end)
    if ok and hui then return hui end
    return LP:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "SD_Hub"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 9999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parentGui()

local WIN_W, WIN_H = 940, 660

--// ---------- primitives ----------
local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = inst
    return c
end

local function stroke(inst, color, alpha, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color
    s.Transparency = alpha or 0.45
    s.Thickness = thickness or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = inst
    return s
end

-- eight short lines, two per corner: the bracket look from the reference
local function brackets(parent, color, len, thick)
    len, thick = len or 12, thick or 1
    for _, p in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
        local sx, sy = p[1], p[2]
        local ox = (sx == 0) and 0 or -len
        local oy = (sy == 0) and 0 or -thick
        local h = Instance.new("Frame")
        h.BackgroundColor3 = color
        h.BackgroundTransparency = 0.1
        h.BorderSizePixel = 0
        h.Size = UDim2.fromOffset(len, thick)
        h.Position = UDim2.new(sx, ox, sy, oy)
        h.Parent = parent

        local v = Instance.new("Frame")
        v.BackgroundColor3 = color
        v.BackgroundTransparency = 0.1
        v.BorderSizePixel = 0
        v.Size = UDim2.fromOffset(thick, len)
        v.Position = UDim2.new(sx, (sx == 0) and 0 or -thick, sy, (sy == 0) and 0 or -len)
        v.Parent = parent
    end
end

-- one scale rule for the whole UI: small type grows most, mid type a little,
-- big type stays in proportion. keeps every label in the same rhythm
local function bump(n)
    if n <= 8 then return n + 2 end
    if n <= 12 then return n + 1 end
    return n + 2
end

-- a translucent panel with a vertical glass gradient, a hairline edge and
-- corner brackets. this is the whole look: nothing here is opaque
local function glass(x, y, w, h, parent, opt)
    opt = opt or {}
    local f = Instance.new("Frame")
    f.Name = opt.name or "Glass"
    f.Size = UDim2.fromOffset(w, h)
    f.Position = UDim2.fromOffset(x, y)
    f.BackgroundColor3 = Color3.new(1, 1, 1)
    f.BackgroundTransparency = opt.t or 0.36
    f.BorderSizePixel = 0
    f.Parent = parent
    corner(f, opt.r or 12)

    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new(Color3.fromRGB(26, 44, 58), Color3.fromRGB(6, 10, 16))
    g.Rotation = 90
    g.Parent = f

    local edge = opt.stroke or C.accent
    stroke(f, edge, opt.sa or 0.72, 1)
    if opt.brackets ~= false then brackets(f, edge, 11, 1) end
    return f
end

local function mono(text, x, y, w, h, parent, size, color, font)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(w, h)
    l.Position = UDim2.fromOffset(x, y)
    l.BackgroundTransparency = 1
    l.Font = font or C.uiB
    l.TextSize = bump(size or 10)
    l.TextColor3 = color or C.dim
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Top
    l.Text = text
    l.Parent = parent
    return l
end

local function chip(parent, text, color, x, y, w, h, size)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(w, h)
    l.Position = UDim2.fromOffset(x, y)
    l.BackgroundColor3 = color
    l.BackgroundTransparency = 0.84
    l.BorderSizePixel = 0
    l.Font = C.uiB
    l.TextSize = bump(size or 9)
    l.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.55)
    l.Text = text
    l.TextXAlignment = Enum.TextXAlignment.Center
    l.Parent = parent
    corner(l, 5)
    stroke(l, color, 0.5, 1)
    return l
end

-- A UIGradient tints the text of the control it sits on, not just the fill, so
-- the gradient lives on a frame behind the button and the button itself is
-- transparent. That keeps the label white while the plate stays neon.
local function neon(text, x, y, w, h, parent, c1, c2, size, glow)
    if glow then
        local g = Instance.new("Frame")
        g.Size = UDim2.fromOffset(w + 12, h + 12)
        g.Position = UDim2.fromOffset(x - 6, y - 6)
        g.BackgroundColor3 = c1
        g.BackgroundTransparency = 0.88
        g.BorderSizePixel = 0
        g.Parent = parent
        corner(g, 16)
    end

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromOffset(w, h)
    bg.Position = UDim2.fromOffset(x, y)
    bg.BackgroundColor3 = Color3.new(1, 1, 1)
    bg.BorderSizePixel = 0
    bg.Parent = parent
    corner(bg, 8)
    local gr = Instance.new("UIGradient")
    gr.Color = ColorSequence.new(c1, c2 or c1)
    gr.Rotation = 90
    gr.Parent = bg
    stroke(bg, c1:Lerp(Color3.new(1, 1, 1), 0.4), 0.32, 1)

    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w, h)
    b.Position = UDim2.fromOffset(x, y)
    b.BackgroundTransparency = 1
    b.BorderSizePixel = 0
    b.Font = C.uiB
    b.TextSize = bump(size or 11)
    b.TextColor3 = Color3.fromRGB(242, 253, 255)
    b.Text = text
    b.AutoButtonColor = false
    b.Parent = parent
    return b, bg
end

-- flat chip button, used for tabs, durations and settings
local function tagBtn(text, x, y, w, h, parent, size)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w, h)
    b.Position = UDim2.fromOffset(x, y)
    b.BackgroundColor3 = C.glass2
    b.BackgroundTransparency = 0.62
    b.BorderSizePixel = 0
    b.Font = C.uiB
    b.TextSize = bump(size or 10)
    b.TextColor3 = C.dim
    b.Text = text
    b.AutoButtonColor = false
    b.Parent = parent
    corner(b, 7)
    stroke(b, C.line, 0.35, 1)
    return b
end

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--// ---------- window ----------
local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(WIN_W, WIN_H)
frame.Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2)
frame.BackgroundColor3 = C.bg
frame.BackgroundTransparency = 0.05
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
corner(frame, 14)
stroke(frame, C.accent, 0.6, 1)
brackets(frame, C.accent, 16, 1)

local sheen = Instance.new("Frame")
sheen.Size = UDim2.new(1, -30, 0, 1)
sheen.Position = UDim2.fromOffset(15, 0)
sheen.BackgroundColor3 = Color3.fromRGB(130, 240, 255)
sheen.BorderSizePixel = 0
sheen.Parent = frame
local sg = Instance.new("UIGradient")
sg.Color = ColorSequence.new(Color3.fromRGB(130, 240, 255), Color3.fromRGB(130, 240, 255))
sg.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.35),
    NumberSequenceKeypoint.new(0.55, 0.92),
    NumberSequenceKeypoint.new(1, 1),
})
sg.Parent = sheen

--// ---------- header ----------
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 58)
header.BackgroundTransparency = 1
header.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.fromOffset(200, 26)
title.Position = UDim2.fromOffset(20, 10)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.TextSize = 22
title.TextColor3 = Color3.fromRGB(240, 252, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "SD_HUB"
title.Parent = header
local tg = Instance.new("UIGradient")
tg.Color = ColorSequence.new(Color3.fromRGB(126, 248, 255), Color3.fromRGB(188, 96, 246))
tg.Parent = title

local subtitle = mono("// SKIBIDI DEFENSE  ·  DOOR_FARM + AUCTION", 20, 34, 320, 12, header, 8, C.dim)

local VIEWS = { farm = "DOOR FARM", auction = "AUCTION" }
local tabBtns, tabBars = {}, {}
local tabX = 246
for _, key in ipairs({ "farm", "auction" }) do
    local w = 128
    local b = tagBtn("[ " .. VIEWS[key] .. " ]", tabX, 14, w, 30, header, 11)
    tabBtns[key] = b
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, -16, 0, 2)
    bar.Position = UDim2.new(0, 8, 1, -4)
    bar.BackgroundColor3 = C.accent
    bar.BorderSizePixel = 0
    bar.Visible = false
    bar.Parent = b
    tabBars[key] = bar
    tabX = tabX + w + 8
end

local hubPill = mono("farm: idle", 530, 0, WIN_W - 600, 58, header, 10, C.dim)
hubPill.TextXAlignment = Enum.TextXAlignment.Right
hubPill.TextYAlignment = Enum.TextYAlignment.Center
hubPill.TextWrapped = false

local closeBtn = tagBtn("×", WIN_W - 46, 14, 30, 30, header, 16)
closeBtn.TextColor3 = C.dim

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -32, 0, 1)
divider.Position = UDim2.fromOffset(16, 56)
divider.BackgroundColor3 = C.accent
divider.BorderSizePixel = 0
divider.Parent = frame
local dg = Instance.new("UIGradient")
dg.Color = ColorSequence.new(C.accent, C.accent2)
dg.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.15),
    NumberSequenceKeypoint.new(0.6, 0.85),
    NumberSequenceKeypoint.new(1, 1),
})
dg.Parent = divider

local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 1, -58)
content.Position = UDim2.fromOffset(0, 58)
content.BackgroundTransparency = 1
content.Parent = frame

local farmView = Instance.new("Frame")
farmView.Name = "FarmView"
farmView.Size = UDim2.new(1, 0, 1, 0)
farmView.BackgroundTransparency = 1
farmView.Parent = content

local auctionView = Instance.new("Frame")
auctionView.Name = "AuctionView"
auctionView.Size = UDim2.new(1, 0, 1, 0)
auctionView.BackgroundTransparency = 1
auctionView.Visible = false
auctionView.Parent = content

--=============================================================
-- FARM VIEW
--=============================================================
local startBtn, startBg = neon("START", 14, 6, 352, 44, farmView, Color3.fromRGB(28, 168, 122),
    Color3.fromRGB(22, 118, 158), 13, true)

local statsCard = glass(14, 58, 352, 108, farmView, { name = "Stats" })
local statsLbl = Instance.new("TextLabel")
statsLbl.Size = UDim2.fromOffset(330, 94)
statsLbl.Position = UDim2.fromOffset(12, 8)
statsLbl.BackgroundTransparency = 1
statsLbl.Font = C.mono
statsLbl.TextSize = 12
statsLbl.TextColor3 = C.text
statsLbl.TextXAlignment = Enum.TextXAlignment.Left
statsLbl.TextYAlignment = Enum.TextYAlignment.Top
statsLbl.RichText = true
statsLbl.Text = ""
statsLbl.Parent = statsCard

-- consumables: two little readouts, same shape as the reference's stat rows
local function readout(x, title)
    local p = glass(x, 172, 170, 54, farmView, { name = title, brackets = false })
    mono(title, 10, 7, 150, 10, p, 8, C.head)
    local v = mono("0", 10, 20, 150, 26, p, 20, C.gold)
    return v
end
local pumpkinVal = readout(14, "PUMPKINSPICE")
local basketVal = readout(196, "BASKET")

local speedBtn = tagBtn("speed: instant", 14, 232, 170, 30, farmView, 10)
local gapBtn   = tagBtn("gap: 1.8s", 196, 232, 170, 30, farmView, 10)
local pumpkinBtn = tagBtn("use pumpkinspice", 14, 268, 170, 30, farmView, 10)
local basketBtn  = tagBtn("use basket", 196, 268, 170, 30, farmView, 10)
pumpkinBtn.TextColor3 = Color3.fromRGB(240, 200, 150)
basketBtn.TextColor3 = Color3.fromRGB(240, 200, 150)
local resetBtn = tagBtn("reset cooldowns", 14, 304, 352, 28, farmView, 10)

--// terminal
local term = glass(14, 338, 352, 256, farmView, { name = "Terminal", t = 0.3 })
mono("TERMINAL", 12, 8, 120, 12, term, 9, C.head)
mono("/ DOOR_SYS", 84, 8, 120, 12, term, 9, C.accent)
local termRule = Instance.new("Frame")
termRule.Size = UDim2.new(1, -24, 0, 1)
termRule.Position = UDim2.fromOffset(12, 24)
termRule.BackgroundColor3 = C.line
termRule.BorderSizePixel = 0
termRule.Parent = term

local termLbl = Instance.new("TextLabel")
termLbl.Size = UDim2.fromOffset(330, 180)
termLbl.Position = UDim2.fromOffset(12, 30)
termLbl.BackgroundTransparency = 1
termLbl.Font = C.mono
termLbl.TextSize = 10
termLbl.TextColor3 = C.text
termLbl.TextXAlignment = Enum.TextXAlignment.Left
termLbl.TextYAlignment = Enum.TextYAlignment.Top
termLbl.RichText = true
termLbl.TextWrapped = true
termLbl.Text = ""
termLbl.Parent = term

local promptLbl = mono("root@sd_hub:~$", 12, 222, 330, 16, term, 10, C.accent, C.mono)
local promptCur = Instance.new("Frame")
promptCur.Size = UDim2.fromOffset(7, 13)
promptCur.Position = UDim2.fromOffset(112, 224)
promptCur.BackgroundColor3 = C.accent
promptCur.BorderSizePixel = 0
promptCur.Parent = term

--// doors grid
local doorsTitle = mono("DOORS", 380, 6, 120, 14, farmView, 10, C.head)
local doorsSum = mono("", 500, 6, 426, 14, farmView, 9, C.dim)
doorsSum.TextXAlignment = Enum.TextXAlignment.Right

local grid = Instance.new("ScrollingFrame")
grid.Size = UDim2.fromOffset(546, 498)
grid.Position = UDim2.fromOffset(380, 28)
grid.BackgroundTransparency = 1
grid.BorderSizePixel = 0
grid.ScrollBarThickness = 3
grid.ScrollBarImageColor3 = C.accent
grid.CanvasSize = UDim2.new()
grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
grid.Parent = farmView

local gridLayout = Instance.new("UIGridLayout")
gridLayout.CellSize = UDim2.fromOffset(127, 80)
gridLayout.CellPadding = UDim2.fromOffset(8, 8)
gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
gridLayout.Parent = grid

local rewardsCard = glass(380, 534, 546, 60, farmView, { name = "Rewards", brackets = false })
mono("PAYOUT", 12, 7, 120, 10, rewardsCard, 8, C.head)
local rewardsLbl = mono("-", 12, 20, 520, 32, rewardsCard, 10, C.good)
rewardsLbl.TextWrapped = true

local doorCards = {}

uiF.log = function()
    local out = {}
    for _, line in ipairs(FS.Log) do
        local t, m = line:match("^(%d%d:%d%d:%d%d)%s+(.*)$")
        if t then
            out[#out + 1] = string.format('<font color="#3d7f8f">%s</font>  %s', t, esc(m))
        else
            out[#out + 1] = esc(line)
        end
    end
    if #out == 0 then
        out[1] = '<font color="#3d7f8f">// awaiting uplink</font>'
    end
    termLbl.Text = table.concat(out, "\n")
end

uiF.rebuild = function()
    for _, r in pairs(doorCards) do
        if r.frame then r.frame:Destroy() end
    end
    doorCards = {}

    if #FS.Doors == 0 then
        local empty = mono("no doors in this place", 4, 4, 300, 14, grid, 10, C.dim)
        doorCards.__empty = { frame = empty }
        return
    end

    for i, d in ipairs(FS.Doors) do
        local card = Instance.new("Frame")
        card.Size = UDim2.fromOffset(127, 80)
        card.BackgroundColor3 = C.card
        card.BackgroundTransparency = 0.32
        card.BorderSizePixel = 0
        card.LayoutOrder = i
        card.Parent = grid
        corner(card, 5)
        local cs = stroke(card, C.line, 0.35, 1)

        local nm = mono(d.name:upper(), 8, 7, 64, 14, card, 10, C.text, C.mono)
        local ch = chip(card, "READY", C.dim, 73, 6, 48, 16, 8)
        local val = mono("-", 8, 28, 111, 30, card, 17, C.dim, C.mono)
        local sub = mono("", 8, 58, 111, 12, card, 8, C.dim, C.mono)

        local bar = Instance.new("Frame")
        bar.Size = UDim2.new(1, -20, 0, 2)
        bar.Position = UDim2.new(0, 10, 1, -8)
        bar.BackgroundColor3 = C.line
        bar.BorderSizePixel = 0
        bar.Parent = card

        doorCards[d.name] = { frame = card, chip = ch, val = val, sub = sub, bar = bar, stroke = cs }
    end
end

uiF.refresh = function()
    local now = os.clock()

    local sg2 = startBg:FindFirstChildOfClass("UIGradient")
    if FS.Running then
        startBtn.Text = "STOP"
        if sg2 then
            sg2.Color = ColorSequence.new(Color3.fromRGB(198, 52, 92), Color3.fromRGB(120, 40, 130))
        end
    else
        startBtn.Text = "START"
        if sg2 then
            sg2.Color = ColorSequence.new(Color3.fromRGB(28, 168, 122), Color3.fromRGB(22, 118, 158))
        end
    end

    local cooling, ready = 0, 0
    for _, d in ipairs(FS.Doors) do
        if d.cdUntil > now then cooling = cooling + 1 else ready = ready + 1 end
    end

    statsLbl.Text = string.format(
        '<font color="#3d7f8f">SYS  </font> %s\n' ..
        '<font color="#3d7f8f">DOOR </font> %s\n' ..
        '<font color="#3d7f8f">QUEUE</font> %d ready / %d cooling\n' ..
        '<font color="#3d7f8f">RUN  </font> lap %d  ·  treats %d  ·  tricks %d\n' ..
        '<font color="#3d7f8f">MISC </font> cd %d  ·  retry %d',
        FS.Running and '<font color="#5ee89e">RUNNING</font>' or '<font color="#748ea0">IDLE</font>',
        esc(FS.Current and FS.Current.name or "-"),
        ready, cooling,
        FS.Laps or 1, FS.Treats, FS.Tricks,
        FS.Cooldowns, FS.Retries)

    pumpkinVal.Text = tostring(itemCount("Pumpkinspice"))
    basketVal.Text = tostring(itemCount("UpgradedBasket"))

    doorsSum.Text = string.format("%d total  ·  %d ready  ·  %d cooling", #FS.Doors, ready, cooling)

    local parts = {}
    for item, n in pairs(FS.Rewards) do
        parts[#parts + 1] = item .. " +" .. fmt(n)
    end
    table.sort(parts)
    rewardsLbl.Text = #parts > 0 and table.concat(parts, "   ·   ") or "-"

    -- blink, roughly twice a second at this tick rate
    promptCur.Visible = (math.floor(os.clock() * 2) % 2 == 0)

    if FS.Running then
        hubPill.Text = string.format("farm: running  ·  lap %d  ·  %d/%d  ·  %d treats",
            FS.Laps or 1, FS.Cursor or 1, #FS.Doors, FS.Treats)
        hubPill.TextColor3 = C.good
    else
        hubPill.Text = string.format("farm: idle  ·  %d doors  ·  %d treats", #FS.Doors, FS.Treats)
        hubPill.TextColor3 = C.dim
    end

    for _, d in ipairs(FS.Doors) do
        local c = doorCards[d.name]
        if c then
            local left = d.cdUntil - now
            local col, label, value, sub

            if d.result == "treat" then
                col, label = C.good, "TREAT"
            elseif d.result == "trick" then
                col, label = C.bad, "TRICK"
            elseif d.result == "cooldown" then
                col, label = C.gold, "COOL"
            elseif d.inFlight then
                col, label = C.accent, "FIRE"
            else
                col, label = C.dim, "READY"
            end

            if left > 0 then
                value = mmss(left)
                sub = "cooldown"
            elseif d.inFlight then
                value = "···"
                sub = "in flight"
            else
                value = "READY"
                sub = "open"
            end

            c.chip.Text = label
            c.chip.TextColor3 = col:Lerp(Color3.new(1, 1, 1), 0.55)
            c.chip.BackgroundColor3 = col
            c.val.Text = value
            c.val.TextColor3 = (left > 0) and col or (d.inFlight and C.accent or C.good)
            c.sub.Text = string.format("%s  ·  tries %d", sub, d.tries or 0)
            c.bar.BackgroundColor3 = col
            c.bar.BackgroundTransparency = (left > 0 or d.inFlight) and 0.15 or 0.75
        end
    end
end

local SPEEDS = { 0, 150, 400, 800 }
local speedIdx = 1
local function refreshSpeed()
    local s = SPEEDS[speedIdx]
    FCFG.Speed = s
    speedBtn.Text = (s == 0) and "speed: instant" or ("speed: " .. s .. "/s")
end
refreshSpeed()

local GAPS = { 2.5, 2.0, 1.8, 1.5, 1.2 }
local gapIdx = 3
local function refreshGap()
    FCFG.Gap = GAPS[gapIdx]
    gapBtn.Text = string.format("gap: %.1fs", FCFG.Gap)
end
refreshGap()

speedBtn.MouseButton1Click:Connect(function()
    speedIdx = speedIdx % #SPEEDS + 1
    refreshSpeed()
end)

gapBtn.MouseButton1Click:Connect(function()
    gapIdx = gapIdx % #GAPS + 1
    refreshGap()
end)

resetBtn.MouseButton1Click:Connect(function()
    for _, d in ipairs(FS.Doors) do
        d.cdUntil = 0
        d.result = nil
    end
    farmLog("cooldowns reset")
end)

pumpkinBtn.MouseButton1Click:Connect(function()
    if not Farm.UsePumpkinspice() then farmLog("no pumpkinspice in the inventory") end
end)

basketBtn.MouseButton1Click:Connect(function()
    if Farm.UseBasket(FCFG.BasketPerSweep) == 0 then farmLog("no basket in the inventory") end
end)

startBtn.MouseButton1Click:Connect(function() Farm.Toggle() end)

--=============================================================
-- AUCTION VIEW
--=============================================================
local invPanel = glass(14, 6, 600, 556, auctionView, { name = "Inventory" })
local side     = glass(626, 6, 300, 556, auctionView, { name = "Side" })

--// category chips
local tabButtons = {}
for i, name in ipairs(ACATS) do
    local b = tagBtn(name, 9 + (i - 1) * 98, 8, 92, 26, invPanel, 10)
    tabButtons[name] = b
end

local searchBox = Instance.new("TextBox")
searchBox.Name = "Search"
searchBox.Size = UDim2.fromOffset(582, 28)
searchBox.Position = UDim2.fromOffset(9, 40)
searchBox.BackgroundColor3 = C.glass2
searchBox.BackgroundTransparency = 0.55
searchBox.BorderSizePixel = 0
searchBox.Font = C.mono
searchBox.TextSize = 12
searchBox.TextColor3 = C.text
searchBox.PlaceholderText = "> search_name"
searchBox.PlaceholderColor3 = C.dim
searchBox.ClearTextOnFocus = false
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.Text = ""
searchBox.Parent = invPanel
corner(searchBox, 4)
stroke(searchBox, C.line, 0.4, 1)

local invScroll = Instance.new("ScrollingFrame")
invScroll.Name = "ScrollingFrame"
invScroll.Size = UDim2.fromOffset(582, 468)
invScroll.Position = UDim2.fromOffset(9, 76)
invScroll.BackgroundTransparency = 1
invScroll.BorderSizePixel = 0
invScroll.ScrollBarThickness = 3
invScroll.ScrollBarImageColor3 = C.accent
invScroll.CanvasSize = UDim2.new()
invScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
invScroll.Parent = invPanel

local invLayout = Instance.new("UIListLayout")
invLayout.Padding = UDim.new(0, 2)
invLayout.SortOrder = Enum.SortOrder.LayoutOrder
invLayout.Parent = invScroll

--// detail card
local detail = glass(10, 8, 280, 108, side, { name = "Detail", brackets = false, t = 0.42 })
local dIcon = Instance.new("ImageLabel")
dIcon.Size = UDim2.fromOffset(52, 52)
dIcon.Position = UDim2.fromOffset(14, 26)
dIcon.BackgroundColor3 = C.bg
dIcon.BackgroundTransparency = 0.4
dIcon.BorderSizePixel = 0
dIcon.ScaleType = Enum.ScaleType.Fit
dIcon.Parent = detail
corner(dIcon, 4)

local dName = mono("nothing selected", 76, 20, 196, 16, detail, 11, C.text)
local dChip = chip(detail, "-", C.dim, 76, 40, 70, 14, 8)
local dQty = mono("", 76, 60, 196, 14, detail, 9, C.dim)
mono("// click a row", 14, 86, 250, 12, detail, 8, C.dim)

mono("START BID (P$)", 10, 124, 200, 12, side, 8, C.head)

local priceBox = Instance.new("TextBox")
priceBox.Name = "Price"
priceBox.Size = UDim2.fromOffset(160, 30)
priceBox.Position = UDim2.fromOffset(10, 140)
priceBox.BackgroundColor3 = C.glass2
priceBox.BackgroundTransparency = 0.5
priceBox.BorderSizePixel = 0
priceBox.Font = C.mono
priceBox.TextSize = 14
priceBox.TextColor3 = C.text
priceBox.PlaceholderText = "0"
priceBox.PlaceholderColor3 = C.dim
priceBox.ClearTextOnFocus = false
priceBox.Text = ""
priceBox.Parent = side
corner(priceBox, 4)
stroke(priceBox, C.line, 0.4, 1)

local suggestBtn = tagBtn("median", 178, 140, 112, 30, side, 10)

mono("DURATION", 10, 178, 200, 12, side, 8, C.head)
local durButtons = {}
for i, d in ipairs(DURATIONS) do
    local b = tagBtn(d, 10 + (i - 1) * 55, 194, 52, 24, side, 10)
    durButtons[d] = b
end

mono("LISTING SLOTS", 10, 226, 200, 12, side, 8, C.head)
local slotsLbl = mono("0 / 3 used", 10, 242, 280, 16, side, 10, C.dim)

local listBtn = neon("LIST NOW", 10, 264, 280, 38, side, Color3.fromRGB(112, 56, 202),
    Color3.fromRGB(30, 132, 188), 13, true)

local fillBtn = tagBtn("FILL FREE SLOTS", 10, 310, 280, 28, side, 10)
fillBtn.TextColor3 = C.accent

local autoBtn = tagBtn("auto: off", 10, 344, 280, 28, side, 10)

local aLog = mono("// no activity", 10, 380, 280, 126, side, 9, C.dim, C.mono)
aLog.TextWrapped = true
aLog.RichText = true

local reloadBtn = tagBtn("RELOAD INV", 10, 512, 136, 28, side, 9)
local cancelBtn = tagBtn("CANCEL ALL", 154, 512, 136, 28, side, 9)
cancelBtn.TextColor3 = Color3.fromRGB(230, 120, 140)

--// footer
local footer = glass(14, 570, 912, 26, auctionView, { name = "Status", brackets = false, t = 0.4 })
local statusLbl = mono("ready", 12, 7, 640, 14, footer, 10, C.dim)
local footHint = mono("1 item / lot  ·  ~8s between lots  ·  no fee", 660, 7, 240, 14, footer, 8, C.dim)
footHint.TextXAlignment = Enum.TextXAlignment.Right

--=============================================================
-- AUCTION RENDER
--=============================================================
local aLogLines = {}

uiA.status = function(txt, color)
    statusLbl.Text = txt
    statusLbl.TextColor3 = color or C.dim
end

uiA.log = function(txt)
    aLogLines[#aLogLines + 1] = string.format('<font color="#3d7f8f">%s</font>  %s',
        os.date("%H:%M:%S"), esc(txt))
    while #aLogLines > 6 do table.remove(aLogLines, 1) end
    aLog.Text = table.concat(aLogLines, "\n")
end

uiA.priceText = function() return priceBox.Text end

local aRows = {}

local function visibleItems()
    local out = {}
    local q = string.lower(AS.search or "")
    for _, it in ipairs(AS.items) do
        local passCat = (AS.cat == "All") or (it.cat == AS.cat)
        if passCat then
            if q == "" or string.find(string.lower(it.label), q, 1, true) then
                out[#out + 1] = it
            end
        end
    end
    return out
end

uiA.tabs = function()
    for name, b in pairs(tabButtons) do
        local on = (name == AS.cat)
        b.BackgroundColor3 = on and C.sel or C.glass2
        b.BackgroundTransparency = on and 0.15 or 0.62
        b.TextColor3 = on and C.accent or C.dim
        local n = (name == "All") and #AS.items or (AS.counts[name] or 0)
        b.Text = name .. ((n > 0) and ("  " .. n) or "")
    end
end

uiA.duration = function()
    for d, b in pairs(durButtons) do
        local on = (d == AS.duration)
        b.BackgroundColor3 = on and C.sel or C.glass2
        b.BackgroundTransparency = on and 0.15 or 0.62
        b.TextColor3 = on and C.accent or C.dim
    end
end

local function selectItem(it)
    AS.selected = it
    dName.Text = it.label
    dName.TextColor3 = (it.kind == "tower") and C.text or C.gold
    dChip.Text = it.cat:upper()
    dChip.TextColor3 = C.accent:Lerp(Color3.new(1, 1, 1), 0.55)
    dChip.BackgroundColor3 = C.accent
    dQty.Text = it.sub
    local img = AS.icons[it.label] or AS.icons[it.key]
    if img then
        dIcon.Image = img
        dIcon.BackgroundTransparency = 1
    else
        dIcon.Image = ""
        dIcon.BackgroundTransparency = 0.4
    end
    uiA.render()
end

uiA.render = function()
    for _, r in ipairs(aRows) do
        if r.Parent then r:Destroy() end
    end
    aRows = {}

    local list = visibleItems()
    local shown = math.min(#list, ACFG.MaxRows)
    local order = 0
    local lastCat = nil

    for i = 1, shown do
        local it = list[i]

        if AS.cat == "All" and it.cat ~= lastCat then
            lastCat = it.cat
            local head = mono(string.format("%s // %d", string.upper(it.cat), AS.counts[it.cat] or 0),
                6, 0, 300, 18, invScroll, 9, C.head)
            head.LayoutOrder = order
            head.TextYAlignment = Enum.TextYAlignment.Center
            order = order + 1
            aRows[#aRows + 1] = head
        end

        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -6, 0, 36)
        row.BackgroundColor3 = (AS.selected == it) and C.sel or C.row
        row.BackgroundTransparency = (AS.selected == it) and 0.25 or 0.55
        row.BorderSizePixel = 0
        row.Text = ""
        row.AutoButtonColor = false
        row.LayoutOrder = order
        row.Parent = invScroll
        corner(row, 4)
        order = order + 1
        aRows[#aRows + 1] = row

        if AS.selected == it then
            local bar = Instance.new("Frame")
            bar.Size = UDim2.fromOffset(2, 20)
            bar.Position = UDim2.fromOffset(0, 6)
            bar.BackgroundColor3 = C.accent
            bar.BorderSizePixel = 0
            bar.Parent = row
        end

        local icon = Instance.new("ImageLabel")
        icon.Size = UDim2.fromOffset(26, 26)
        icon.Position = UDim2.fromOffset(10, 5)
        icon.BackgroundColor3 = C.bg
        icon.BackgroundTransparency = 0.55
        icon.BorderSizePixel = 0
        icon.ScaleType = Enum.ScaleType.Fit
        local img = AS.icons[it.label] or AS.icons[it.key]
        if img then
            icon.Image = img
            icon.BackgroundTransparency = 1
        end
        icon.Parent = row
        corner(icon, 3)

        local nm = mono(it.label, 44, 11, 400, 18, row, 11,
            (it.kind == "tower") and C.text or C.gold)
        nm.TextTruncate = Enum.TextTruncate.AtEnd
        nm.TextWrapped = false

        local sub = mono(it.sub, 0, 11, 96, 18, row, 10, C.dim)
        sub.Position = UDim2.new(1, -106, 0, 11)
        sub.TextXAlignment = Enum.TextXAlignment.Right
        sub.TextWrapped = false

        row.MouseButton1Click:Connect(function() selectItem(it) end)
    end

    invScroll.CanvasPosition = Vector2.new(0, 0)
    uiA.tabs()

    slotsLbl.Text = string.format("%d / %d used", AS.myCount, AS.maxListings)
    slotsLbl.TextColor3 = (AS.myCount >= AS.maxListings) and C.bad or C.dim

    if AS.myCount >= AS.maxListings then
        uiA.status(string.format("all %d slots used  ·  %s P$  ·  cancel or wait", AS.maxListings, fmt(AS.premium)), C.gold)
    else
        local q = (AS.search ~= "") and ("  ·  filter: " .. AS.search) or ""
        uiA.status(string.format("%d items  ·  showing %d%s", #AS.items, shown, q))
    end
end

--=============================================================
-- AUCTION ACTIONS
--=============================================================
local function reloadInventoryUI()
    uiA.status("reading inventory...", C.accent)
    local inv = readInventory(4)
    if not inv then
        uiA.status("inventory read failed", C.bad)
        return
    end
    AS.items = buildItems(inv)
    AS.icons = buildIconMap()
    AS.selected = nil
    dName.Text = "nothing selected"
    dName.TextColor3 = C.dim
    dChip.Text = "-"
    dChip.TextColor3 = C.dim
    dChip.BackgroundColor3 = C.dim
    dQty.Text = ""
    dIcon.Image = ""
    refreshMarket()
    uiA.render()
    uiA.duration()
end

local function fillSlots()
    if AS.busy then return end
    if not AS.selected then
        uiA.status("select an item first", C.bad)
        return
    end
    if not readPrice() then
        uiA.status("set a start bid above 0", C.bad)
        return
    end
    task.spawn(function()
        refreshMarket()
        -- the number of lots is decided up front: trusting myCount mid-loop
        -- races with the browse cache and over-lists
        local free = AS.maxListings - AS.myCount
        if free <= 0 then
            uiA.status("all slots already used", C.bad)
            return
        end
        local placed = 0
        for _ = 1, free do
            if not doList(false) then break end
            placed = placed + 1
            task.wait(ACFG.ListCooldown)
            refreshSelectionAfterReload(readInventory(2))
        end
        refreshMarket()
        uiA.render()
        uiA.status(placed > 0 and ("filled " .. placed .. " slot(s)") or "nothing filled",
            placed > 0 and C.good or C.bad)
    end)
end

local function cancelAllListings()
    if not Browse or not CancelRF then
        uiA.status("no auction remotes in this place", C.bad)
        return
    end
    uiA.status("cancelling...", C.accent)
    task.spawn(function()
        local r = invoke(Browse, nil, 8)
        if not (r.ok and type(r.a) == "table") then
            uiA.status("browse failed", C.bad)
            return
        end
        local n = 0
        for _, l in ipairs(r.a.listings or {}) do
            if l.sellerId == r.a.myId then
                pcall(function() CancelRF:InvokeServer({ id = l.id }) end)
                n = n + 1
                task.wait(0.6)
            end
        end
        uiA.log("cancelled " .. n)
        refreshMarket()
        uiA.render()
        uiA.status("cancelled " .. n, C.good)
    end)
end

local function suggestPrice()
    local it = AS.selected
    if not it then
        uiA.status("select an item first", C.bad)
        return
    end
    local sn = getgenv().SDAuctionSniper
    local med
    if sn and sn.S and sn.S.Median then
        med = sn.S.Median[it.label] or sn.S.Median[it.key]
    end
    if med then
        priceBox.Text = tostring(math.floor(med * 0.95))
        uiA.status("median " .. fmt(med) .. "  ·  set to 95%", C.dim)
    else
        uiA.status("no median data - load the sniper first", C.bad)
    end
end

listBtn.MouseButton1Click:Connect(function()
    doList(true)
    refreshMarket()
    uiA.render()
end)

fillBtn.MouseButton1Click:Connect(fillSlots)
reloadBtn.MouseButton1Click:Connect(reloadInventoryUI)
cancelBtn.MouseButton1Click:Connect(cancelAllListings)
suggestBtn.MouseButton1Click:Connect(suggestPrice)

autoBtn.MouseButton1Click:Connect(function()
    AS.auto = not AS.auto
    autoBtn.Text = "auto: " .. (AS.auto and "on" or "off")
    autoBtn.TextColor3 = AS.auto and C.good or C.dim
    autoBtn.BackgroundColor3 = AS.auto and Color3.fromRGB(20, 62, 52) or C.glass2
    if AS.auto then autoTick() end
end)

for name, b in pairs(tabButtons) do
    b.MouseButton1Click:Connect(function()
        AS.cat = name
        uiA.render()
    end)
end

for d, b in pairs(durButtons) do
    b.MouseButton1Click:Connect(function()
        AS.duration = d
        uiA.duration()
    end)
end

local searchPending = false
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    AS.search = searchBox.Text
    -- rebuilding a few hundred rows on every keystroke is wasteful; one
    -- deferred pass per burst is enough
    if searchPending then return end
    searchPending = true
    task.defer(function()
        task.wait(0.12)
        searchPending = false
        uiA.render()
    end)
end)

--=============================================================
-- TABS
--=============================================================
local currentTab = "farm"
local function showTab(which)
    currentTab = which
    farmView.Visible = (which == "farm")
    auctionView.Visible = (which == "auction")
    for key, b in pairs(tabBtns) do
        local on = (key == which)
        b.BackgroundColor3 = on and C.sel or C.glass2
        b.BackgroundTransparency = on and 0.2 or 0.62
        b.TextColor3 = on and C.accent or C.dim
        tabBars[key].Visible = on
    end
end

for key, b in pairs(tabBtns) do
    b.MouseButton1Click:Connect(function() showTab(key) end)
end

closeBtn.MouseButton1Click:Connect(function() gui.Enabled = not gui.Enabled end)

conn(UIS.InputBegan, function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F5 then
        gui.Enabled = not gui.Enabled
    elseif input.KeyCode == Enum.KeyCode.F3 then
        if gui.Enabled and currentTab == "farm" then
            gui.Enabled = false
        else
            gui.Enabled = true
            showTab("farm")
        end
    end
end)

--=============================================================
-- BOOT + TICKERS
--=============================================================
showTab("farm")
uiF.rebuild()
uiF.log()

task.spawn(function()
    local inv = readInventory(4)
    AS.items = buildItems(inv)
    AS.icons = buildIconMap()
    refreshMarket()
    uiA.duration()
    uiA.render()

    local invReqAt = os.clock()

    while gui.Parent do
        task.wait(0.25)
        if gui.Enabled then
            uiF.refresh()
        end
        if os.clock() - invReqAt > 30 then
            invReqAt = os.clock()
            requestInventory()
        end
    end
end)

task.spawn(function()
    while gui.Parent do
        task.wait(1)
        if AS.auto and os.time() - AS.lastPoll >= ACFG.Poll then
            autoTick()
        end
    end
end)

--=============================================================
-- PUBLIC API
--=============================================================
local api = {}
api.Gui = gui
api.Farm = Farm
api.FarmState = FS
api.FarmConfig = FCFG
api.Auction = {
    S = AS,
    Config = ACFG,
    List = function() return doList(true) end,
    Fill = fillSlots,
    CancelAll = cancelAllListings,
    Reload = reloadInventoryUI,
    SetCategory = function(cat) AS.cat = cat; uiA.render() end,
    SetPrice = function(n) priceBox.Text = tostring(math.max(0, math.floor(tonumber(n) or 0))) end,
    Search = function(q) searchBox.Text = q or "" end,
    SetItem = function(key)
        for _, it in ipairs(AS.items) do
            if it.key == key or it.label == key then
                selectItem(it)
                return true
            end
        end
        return false
    end,
}
api.Show = function(which)
    gui.Enabled = true
    showTab(which == "auction" and "auction" or "farm")
end
api.Toggle = function() gui.Enabled = not gui.Enabled end
api.Destroy = function()
    pcall(function() Farm.Stop() end)
    for _, c in ipairs(CONNS) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
    if getgenv().SDHub == api then getgenv().SDHub = nil end
    print("[SD_Hub] destroyed")
end

getgenv().SDHub = api

print("[SD_Hub] loaded - F5 window, F3 farm tab")
