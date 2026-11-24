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
local C = {
    bg     = Color3.fromRGB(16, 17, 21),
    panel  = Color3.fromRGB(24, 26, 32),
    card   = Color3.fromRGB(21, 23, 28),
    row    = Color3.fromRGB(30, 33, 40),
    rowAlt = Color3.fromRGB(26, 28, 34),
    sel    = Color3.fromRGB(38, 58, 92),
    accent = Color3.fromRGB(120, 170, 255),
    good   = Color3.fromRGB(90, 220, 140),
    bad    = Color3.fromRGB(240, 110, 110),
    gold   = Color3.fromRGB(245, 200, 90),
    text   = Color3.fromRGB(228, 232, 240),
    dim    = Color3.fromRGB(140, 148, 162),
    head   = Color3.fromRGB(180, 190, 205),
    line   = Color3.fromRGB(48, 52, 62),
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

local WIN_W, WIN_H = 900, 620

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(WIN_W, WIN_H)
frame.Position = UDim2.new(0.5, -WIN_W / 2, 0.5, -WIN_H / 2)
frame.BackgroundColor3 = C.bg
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = C.line
stroke.Thickness = 1
stroke.Parent = frame

local function mkBtn(text, w, h, x, y, parent, size)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(w, h)
    b.Position = UDim2.fromOffset(x, y)
    b.BackgroundColor3 = C.panel
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = size or 11
    b.TextColor3 = C.text
    b.Text = text
    b.AutoButtonColor = false
    b.Parent = parent or frame
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    return b
end

local function mkLabel(text, x, y, w, h, parent, size, color, bold)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.fromOffset(w, h)
    l.Position = UDim2.fromOffset(x, y)
    l.BackgroundTransparency = 1
    l.Font = bold and Enum.Font.GothamSemibold or Enum.Font.Gotham
    l.TextSize = size or 11
    l.TextColor3 = color or C.dim
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Top
    l.TextWrapped = true
    l.Text = text
    l.Parent = parent
    return l
end

local function mkCard(x, y, w, h, parent)
    local f = Instance.new("Frame")
    f.Size = UDim2.fromOffset(w, h)
    f.Position = UDim2.fromOffset(x, y)
    f.BackgroundColor3 = C.panel
    f.BorderSizePixel = 0
    f.Parent = parent
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 6)
    return f
end

--// header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 46)
header.BackgroundColor3 = C.panel
header.BorderSizePixel = 0
header.Parent = frame
Instance.new("UICorner", header).CornerRadius = UDim.new(0, 8)

local title = mkLabel("SD HUB", 14, 0, 110, 46, header, 15, C.text, true)
title.TextYAlignment = Enum.TextYAlignment.Center
title.TextWrapped = false

local VIEWS = { farm = "DOOR FARM", auction = "AUCTION" }
local tabBtns = {}
local tabX = 130
for _, key in ipairs({ "farm", "auction" }) do
    local b = mkBtn(VIEWS[key], 120, 26, tabX, 10, header, 11)
    tabBtns[key] = b
    tabX = tabX + 126
end

local hubPill = mkLabel("", 392, 0, WIN_W - 440, 46, header, 10, C.dim)
hubPill.TextXAlignment = Enum.TextXAlignment.Right
hubPill.TextYAlignment = Enum.TextYAlignment.Center
hubPill.TextWrapped = false
hubPill.Text = "farm: idle"

local closeBtn = mkBtn("x", 24, 24, WIN_W - 34, 11, header, 12)

local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 1, -46)
content.Position = UDim2.fromOffset(0, 46)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.Parent = frame

local farmView    = Instance.new("Frame")
farmView.Name     = "FarmView"
farmView.Size     = UDim2.new(1, 0, 1, 0)
farmView.BackgroundTransparency = 1
farmView.BorderSizePixel = 0
farmView.Parent   = content

local auctionView = Instance.new("Frame")
auctionView.Name  = "AuctionView"
auctionView.Size  = UDim2.new(1, 0, 1, 0)
auctionView.BackgroundTransparency = 1
auctionView.BorderSizePixel = 0
auctionView.Visible = false
auctionView.Parent = content

--=============================================================
-- FARM VIEW
--=============================================================
local leftCard  = mkCard(12, 8, 300, 556, farmView)
local rightCard = mkCard(324, 8, 564, 556, farmView)

local startBtn = mkBtn("START", 276, 42, 12, 12, leftCard, 13)
startBtn.BackgroundColor3 = Color3.fromRGB(46, 160, 96)
startBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

local fStatus = mkLabel("status: idle", 12, 64, 276, 16, leftCard, 11, C.dim)
local fDoor   = mkLabel("door: -", 12, 84, 276, 16, leftCard, 11, C.dim)
local fDoors  = mkLabel("doors: 0  cooling: 0", 12, 104, 276, 16, leftCard, 11, C.dim)
local fCount  = mkLabel("treats 0  tricks 0", 12, 124, 276, 32, leftCard, 10, C.dim)

local fItemsHead = mkLabel("CONSUMABLES", 12, 160, 276, 14, leftCard, 9, C.head, true)
local fItems     = mkLabel("pumpkinspice 0  basket 0", 12, 176, 276, 32, leftCard, 10, C.gold)

local speedBtn  = mkBtn("speed: instant", 132, 28, 12, 216, leftCard, 11)
local gapBtn    = mkBtn("gap: 1.8s", 132, 28, 156, 216, leftCard, 11)
local pumpkinBtn = mkBtn("use pumpkinspice", 132, 28, 12, 250, leftCard, 11)
local basketBtn  = mkBtn("use basket", 132, 28, 156, 250, leftCard, 11)
pumpkinBtn.BackgroundColor3 = Color3.fromRGB(58, 44, 24)
pumpkinBtn.TextColor3 = Color3.fromRGB(240, 200, 150)
basketBtn.BackgroundColor3 = Color3.fromRGB(58, 44, 24)
basketBtn.TextColor3 = Color3.fromRGB(240, 200, 150)

local resetBtn = mkBtn("reset cooldowns", 276, 26, 12, 286, leftCard, 11)

local fLogHead = mkLabel("LOG", 12, 320, 276, 14, leftCard, 9, C.head, true)
local fLog = mkLabel("", 12, 336, 276, 148, leftCard, 9, C.dim)
fLog.Text = "idle"

local fHint = mkLabel("F5 toggles the window. Items fire only when the inventory actually holds one.",
    12, 492, 276, 52, leftCard, 9, Color3.fromRGB(110, 118, 132))

--// doors table
local doorsHead = mkLabel("DOORS", 12, 10, 200, 14, rightCard, 10, C.head, true)
local doorsSum  = mkLabel("", 200, 10, 352, 14, rightCard, 9, C.dim)
doorsSum.TextXAlignment = Enum.TextXAlignment.Right
doorsSum.TextWrapped = false

local colName = mkLabel("door", 14, 30, 110, 14, rightCard, 9, C.dim, true)
local colRes  = mkLabel("result", 130, 30, 120, 14, rightCard, 9, C.dim, true)
local colCd   = mkLabel("cooldown", 254, 30, 300, 14, rightCard, 9, C.dim, true)
colCd.TextXAlignment = Enum.TextXAlignment.Right

local doorsScroll = Instance.new("ScrollingFrame")
doorsScroll.Size = UDim2.fromOffset(544, 434)
doorsScroll.Position = UDim2.fromOffset(10, 46)
doorsScroll.BackgroundColor3 = C.card
doorsScroll.BorderSizePixel = 0
doorsScroll.ScrollBarThickness = 4
doorsScroll.ScrollBarImageColor3 = C.accent
doorsScroll.CanvasSize = UDim2.new()
doorsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
doorsScroll.Parent = rightCard
Instance.new("UICorner", doorsScroll).CornerRadius = UDim.new(0, 5)

local doorsLayout = Instance.new("UIListLayout")
doorsLayout.Padding = UDim.new(0, 2)
doorsLayout.SortOrder = Enum.SortOrder.LayoutOrder
doorsLayout.Parent = doorsScroll

local fRewards = mkLabel("rewards: -", 12, 488, 544, 56, rightCard, 10, C.good)

local doorRows = {}   -- name -> { frame, res, cd }

uiF.rebuild = function()
    for _, r in pairs(doorRows) do
        if r.frame then r.frame:Destroy() end
    end
    doorRows = {}

    if #FS.Doors == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, -12, 0, 22)
        empty.BackgroundTransparency = 1
        empty.Font = Enum.Font.Gotham
        empty.TextSize = 10
        empty.TextColor3 = C.dim
        empty.TextXAlignment = Enum.TextXAlignment.Left
        empty.Text = "no doors found - this place has no event board"
        empty.Parent = doorsScroll
        doorRows.__empty = { frame = empty }
        return
    end

    for i, d in ipairs(FS.Doors) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -6, 0, 20)
        row.BackgroundColor3 = (i % 2 == 0) and C.rowAlt or C.row
        row.BorderSizePixel = 0
        row.LayoutOrder = i
        row.Parent = doorsScroll
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)

        local nm = Instance.new("TextLabel")
        nm.Size = UDim2.fromOffset(110, 20)
        nm.Position = UDim2.fromOffset(8, 0)
        nm.BackgroundTransparency = 1
        nm.Font = Enum.Font.GothamSemibold
        nm.TextSize = 10
        nm.TextColor3 = C.text
        nm.TextXAlignment = Enum.TextXAlignment.Left
        nm.Text = d.name
        nm.Parent = row

        local res = Instance.new("TextLabel")
        res.Size = UDim2.fromOffset(120, 20)
        res.Position = UDim2.fromOffset(124, 0)
        res.BackgroundTransparency = 1
        res.Font = Enum.Font.Gotham
        res.TextSize = 10
        res.TextColor3 = C.dim
        res.TextXAlignment = Enum.TextXAlignment.Left
        res.Text = "-"
        res.Parent = row

        local cd = Instance.new("TextLabel")
        cd.Size = UDim2.new(1, -252, 0, 20)
        cd.Position = UDim2.fromOffset(248, 0)
        cd.BackgroundTransparency = 1
        cd.Font = Enum.Font.Gotham
        cd.TextSize = 10
        cd.TextColor3 = C.dim
        cd.TextXAlignment = Enum.TextXAlignment.Right
        cd.Text = "ready"
        cd.Parent = row

        doorRows[d.name] = { frame = row, res = res, cd = cd }
    end
end

uiF.log = function()
    fLog.Text = (#FS.Log > 0) and table.concat(FS.Log, "\n") or "idle"
end

uiF.refresh = function()
    local now = os.clock()

    if FS.Running then
        startBtn.Text = "STOP"
        startBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
    else
        startBtn.Text = "START"
        startBtn.BackgroundColor3 = Color3.fromRGB(46, 160, 96)
    end

    fStatus.Text = "status: " .. FS.Status
    fDoor.Text = "door: " .. (FS.Current and FS.Current.name or "-")

    local cooling, ready = 0, 0
    for _, d in ipairs(FS.Doors) do
        if d.cdUntil > now then cooling = cooling + 1 else ready = ready + 1 end
    end
    fDoors.Text = string.format("doors: %d   ready: %d   cooling: %d", #FS.Doors, ready, cooling)
    fCount.Text = string.format("treats %d   tricks %d   cd %d   retry %d",
        FS.Treats, FS.Tricks, FS.Cooldowns, FS.Retries)

    fItems.Text = string.format("pumpkinspice %d   basket %d\nused: %d pumpkin / %d basket",
        itemCount("Pumpkinspice"), itemCount("UpgradedBasket"),
        FS.PumpkinUses or 0, FS.BasketUses or 0)

    local parts = {}
    for item, n in pairs(FS.Rewards) do
        parts[#parts + 1] = item .. " +" .. fmt(n)
    end
    table.sort(parts)
    fRewards.Text = #parts > 0 and ("rewards: " .. table.concat(parts, ", ")) or "rewards: -"

    doorsSum.Text = string.format("%d doors   %d ready", #FS.Doors, ready)

    -- the header pill keeps the farm visible while the auction tab is open
    if FS.Running then
        hubPill.Text = string.format("farm: running   lap %d   %d/%d   %d treats",
            FS.Laps or 1, FS.Cursor or 1, #FS.Doors, FS.Treats)
        hubPill.TextColor3 = C.good
    else
        hubPill.Text = string.format("farm: idle   %d doors   %d treats", #FS.Doors, FS.Treats)
        hubPill.TextColor3 = C.dim
    end

    for _, d in ipairs(FS.Doors) do
        local r = doorRows[d.name]
        if r then
            if d.result == "treat" then
                r.res.Text = "treat"
                r.res.TextColor3 = C.good
            elseif d.result == "trick" then
                r.res.Text = "trick"
                r.res.TextColor3 = C.bad
            elseif d.result == "cooldown" then
                r.res.Text = "cooldown"
                r.res.TextColor3 = C.gold
            else
                r.res.Text = d.inFlight and "fired" or "-"
                r.res.TextColor3 = C.dim
            end

            local left = d.cdUntil - now
            if left > 0 then
                r.cd.Text = "ready in " .. mmss(left)
                r.cd.TextColor3 = C.gold
            else
                r.cd.Text = d.inFlight and "in flight" or "ready"
                r.cd.TextColor3 = C.dim
            end
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
local aStat = mkLabel("loading inventory...", 12, 8, 470, 18, auctionView, 11, C.dim)
aStat.TextWrapped = false

local reloadBtn = mkBtn("reload inventory", 118, 22, 496, 6, auctionView, 10)
local autoBtn   = mkBtn("auto: off", 84, 22, 620, 6, auctionView, 10)
local cancelBtn = mkBtn("cancel all", 90, 22, 710, 6, auctionView, 10)

local invPanel = mkCard(12, 34, 592, 496, auctionView)
local side     = mkCard(616, 34, 272, 496, auctionView)

--// tabs
local tabButtons = {}
for i, name in ipairs(ACATS) do
    local b = mkBtn(name, 92, 24, 6 + (i - 1) * 96, 6, invPanel, 10)
    tabButtons[name] = b
end

local searchBox = Instance.new("TextBox")
searchBox.Name = "Search"
searchBox.Size = UDim2.fromOffset(580, 24)
searchBox.Position = UDim2.fromOffset(6, 34)
searchBox.BackgroundColor3 = C.bg
searchBox.BorderSizePixel = 0
searchBox.Font = Enum.Font.Gotham
searchBox.TextSize = 11
searchBox.TextColor3 = C.text
searchBox.PlaceholderText = "search by name..."
searchBox.PlaceholderColor3 = C.dim
searchBox.ClearTextOnFocus = false
searchBox.TextXAlignment = Enum.TextXAlignment.Left
searchBox.Text = ""
searchBox.Parent = invPanel
Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0, 5)

local invScroll = Instance.new("ScrollingFrame")
invScroll.Name = "ScrollingFrame"
invScroll.Size = UDim2.fromOffset(580, 428)
invScroll.Position = UDim2.fromOffset(6, 62)
invScroll.BackgroundColor3 = C.bg
invScroll.BorderSizePixel = 0
invScroll.ScrollBarThickness = 4
invScroll.ScrollBarImageColor3 = C.accent
invScroll.CanvasSize = UDim2.new()
invScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
invScroll.Parent = invPanel
Instance.new("UICorner", invScroll).CornerRadius = UDim.new(0, 5)

local invLayout = Instance.new("UIListLayout")
invLayout.Padding = UDim.new(0, 2)
invLayout.SortOrder = Enum.SortOrder.LayoutOrder
invLayout.Parent = invScroll

--// side
local selLbl = mkLabel("nothing selected", 10, 8, 252, 34, side, 10, C.dim, true)
mkLabel("START BID (P$)", 10, 44, 252, 14, side, 9, C.dim)
mkLabel("DURATION", 10, 92, 252, 14, side, 9, C.dim)
mkLabel("LISTING SLOTS", 10, 136, 252, 14, side, 9, C.dim)

local priceBox = Instance.new("TextBox")
priceBox.Name = "Price"
priceBox.Size = UDim2.fromOffset(150, 24)
priceBox.Position = UDim2.fromOffset(10, 60)
priceBox.BackgroundColor3 = C.bg
priceBox.BorderSizePixel = 0
priceBox.Font = Enum.Font.Gotham
priceBox.TextSize = 12
priceBox.TextColor3 = C.text
priceBox.PlaceholderText = "price"
priceBox.PlaceholderColor3 = C.dim
priceBox.ClearTextOnFocus = false
priceBox.Text = ""
priceBox.Parent = side
Instance.new("UICorner", priceBox).CornerRadius = UDim.new(0, 5)

local suggestBtn = mkBtn("median", 96, 24, 166, 60, side, 10)

local durButtons = {}
for i, d in ipairs(DURATIONS) do
    local b = mkBtn(d, 48, 22, 10 + (i - 1) * 51, 108, side, 10)
    durButtons[d] = b
end

local slotsLbl = mkLabel("0 / 3 used", 10, 152, 252, 16, side, 10, C.dim)

local listBtn = mkBtn("LIST NOW", 252, 36, 10, 172, side, 12)
listBtn.BackgroundColor3 = Color3.fromRGB(38, 78, 56)
listBtn.TextColor3 = C.good

local fillBtn = mkBtn("FILL FREE SLOTS", 252, 26, 10, 212, side, 11)
fillBtn.BackgroundColor3 = Color3.fromRGB(34, 44, 62)
fillBtn.TextColor3 = C.accent

local autoHint = mkLabel("auto keeps the slots filled and relists as lots expire",
    10, 244, 252, 36, side, 9, C.dim)

local aLog = mkLabel("", 10, 284, 252, 96, side, 9, C.dim)

local sideFoot = mkLabel("", 10, 452, 252, 34, side, 9, Color3.fromRGB(110, 118, 132))
sideFoot.Text = "1 item per listing. Server enforces ~8s between listings."

--// bottom bar
local bar = mkCard(12, 536, 876, 32, auctionView)
local statusLbl = mkLabel("ready", 10, 8, 856, 20, bar, 10, C.dim)
statusLbl.TextWrapped = false
statusLbl.TextYAlignment = Enum.TextYAlignment.Center

--=============================================================
-- AUCTION RENDER
--=============================================================
local aLogLines = {}

uiA.status = function(txt, color)
    statusLbl.Text = txt
    statusLbl.TextColor3 = color or C.dim
end

uiA.log = function(txt)
    aLogLines[#aLogLines + 1] = os.date("%H:%M:%S") .. "  " .. txt
    while #aLogLines > 5 do table.remove(aLogLines, 1) end
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
        b.BackgroundColor3 = on and C.sel or C.bg
        b.TextColor3 = on and C.accent or C.dim
        local n = (name == "All") and #AS.items or (AS.counts[name] or 0)
        b.Text = name .. ((n > 0) and ("  " .. n) or "")
    end
end

uiA.duration = function()
    for d, b in pairs(durButtons) do
        local on = (d == AS.duration)
        b.BackgroundColor3 = on and C.sel or C.bg
        b.TextColor3 = on and C.accent or C.dim
    end
end

local function selectItem(it)
    AS.selected = it
    selLbl.Text = string.format("%s\n%s  -  %s", it.label, it.sub, it.cat)
    selLbl.TextColor3 = C.text
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
            local head = Instance.new("TextLabel")
            head.Size = UDim2.new(1, -6, 0, 18)
            head.BackgroundTransparency = 1
            head.Font = Enum.Font.GothamBold
            head.TextSize = 10
            head.TextColor3 = C.head
            head.TextXAlignment = Enum.TextXAlignment.Left
            head.LayoutOrder = order
            head.Text = string.format("%s   %d", string.upper(it.cat), AS.counts[it.cat] or 0)
            head.Parent = invScroll
            order = order + 1
            aRows[#aRows + 1] = head
        end

        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, -6, 0, 26)
        row.BackgroundColor3 = (AS.selected == it) and C.sel or ((i % 2 == 0) and C.rowAlt or C.row)
        row.BorderSizePixel = 0
        row.Text = ""
        row.AutoButtonColor = false
        row.LayoutOrder = order
        row.Parent = invScroll
        order = order + 1
        aRows[#aRows + 1] = row

        local icon = Instance.new("ImageLabel")
        icon.Size = UDim2.fromOffset(20, 20)
        icon.Position = UDim2.fromOffset(6, 3)
        icon.BackgroundColor3 = C.bg
        icon.BorderSizePixel = 0
        icon.ScaleType = Enum.ScaleType.Fit
        local img = AS.icons[it.label] or AS.icons[it.key]
        if img then
            icon.Image = img
            icon.BackgroundTransparency = 1
        end
        icon.Parent = row
        Instance.new("UICorner", icon).CornerRadius = UDim.new(0, 4)

        local nm = Instance.new("TextLabel")
        nm.Size = UDim2.fromOffset(420, 26)
        nm.Position = UDim2.fromOffset(34, 0)
        nm.BackgroundTransparency = 1
        nm.Font = Enum.Font.GothamSemibold
        nm.TextSize = 11
        nm.TextColor3 = (it.kind == "tower") and C.text or C.gold
        nm.TextXAlignment = Enum.TextXAlignment.Left
        nm.TextTruncate = Enum.TextTruncate.AtEnd
        nm.Text = it.label
        nm.Parent = row

        local sub = Instance.new("TextLabel")
        sub.Size = UDim2.fromOffset(100, 26)
        sub.Position = UDim2.new(1, -106, 0, 0)
        sub.BackgroundTransparency = 1
        sub.Font = Enum.Font.Gotham
        sub.TextSize = 10
        sub.TextColor3 = C.dim
        sub.TextXAlignment = Enum.TextXAlignment.Right
        sub.TextTruncate = Enum.TextTruncate.AtEnd
        sub.Text = it.sub
        sub.Parent = row

        row.MouseButton1Click:Connect(function() selectItem(it) end)
    end

    invScroll.CanvasPosition = Vector2.new(0, 0)
    uiA.tabs()

    slotsLbl.Text = string.format("%d / %d used  -  1 item per listing", AS.myCount, AS.maxListings)
    slotsLbl.TextColor3 = (AS.myCount >= AS.maxListings) and C.bad or C.dim

    aStat.Text = string.format("%s P$   |   listings %d/%d   |   %d items",
        fmt(AS.premium), AS.myCount, AS.maxListings, #AS.items)
    aStat.TextColor3 = (AS.myCount >= AS.maxListings) and C.gold or C.dim

    local q = (AS.search ~= "") and ("  |  search: " .. AS.search) or ""
    uiA.status(string.format("%d items  |  showing %d%s", #AS.items, shown, q))
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
    selLbl.Text = "nothing selected"
    selLbl.TextColor3 = C.dim
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
        uiA.status("median " .. fmt(med) .. " - set to 95%", C.dim)
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
cancelBtn.MouseButton1Click:Connect(cancelAllListings)
reloadBtn.MouseButton1Click:Connect(reloadInventoryUI)
suggestBtn.MouseButton1Click:Connect(suggestPrice)

autoBtn.MouseButton1Click:Connect(function()
    AS.auto = not AS.auto
    autoBtn.Text = "auto: " .. (AS.auto and "on" or "off")
    autoBtn.TextColor3 = AS.auto and C.good or C.dim
    autoBtn.BackgroundColor3 = AS.auto and Color3.fromRGB(38, 78, 56) or C.panel
    autoHint.Text = AS.auto
        and string.format("keeping %d slots filled with %s", AS.maxListings,
            AS.selected and AS.selected.label or "?")
        or "auto keeps the slots filled and relists as lots expire"
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

searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    AS.search = searchBox.Text
    uiA.render()
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
        b.BackgroundColor3 = on and C.sel or C.bg
        b.TextColor3 = on and C.accent or C.dim
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
-- BOOT + TICKER
--=============================================================
showTab("farm")
uiF.rebuild()

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

        -- baskets drop from the doors themselves, so the stock is re-read
        -- periodically instead of only once at load
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
