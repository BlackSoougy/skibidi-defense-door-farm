--[[
    STD MINI  -  the three things that keep a session alive, and nothing else.

    Extracted from STD_Hub_v7.luau, not rewritten from memory. What came over:

      EVENT    auto join the pinata portals, 7+ players by default. Portals are
               workspace.PinataTeleporters.<n>.Part (ProximityPrompt) with the
               live count in Billboard.BillboardGui.PlayerCount ("7/10") and the
               cap in Config.MaxPlayers. Entry is TpIn + fireproximityprompt,
               retried, and success is judged by actually leaving the spot.

      MATCH    auto exit when a round ends. The end screen is the signal, the
               remote is the action: ReplicatedStorage.Events.ExitGame has no
               arguments, so firing it is byte for byte what the Exit button
               does. workspace.Info.GameRunning going false covers the modes
               that end without a screen. One exit per place visit, and a screen
               that is already up when you land has to age 25s first, or a
               leftover end screen would throw you straight back out.

      ANTI-AFK the walk loop plus the afk-plaza escape. This executor cannot
               press a key (VirtualInputManager has no SendKeyDownEvent and
               keypress does nothing), so the walk is the shape of the input:
               four camera-relative directions, w a s d, each held and blending
               into the next, with the root carried along the same vector. It
               runs on Stepped, because a background client stops rendering and
               RenderStepped never fires there. It stands still while the mouse
               is in use. If the server moves you to the afk plaza anyway, the
               escape teleports back to the exact server you came from - job id
               and all, remembered on disk so a reload does not lose it - then
               the same place, then the lobby, backing off on failure.

    Not here on purpose: the squad gate / king-follow / macros / tower tools.
    Those need the roster files and the whole hub around them.
]]

local CFG = {
    Key            = Enum.KeyCode.RightShift,

    -- event
    MinPlayers     = 7,     -- join only a portal this full. 10 is always full,
                            -- so the cap on the joinable side is max-1
    WaitPopulate   = 8,     -- a portal that just opened reads 0/10 for a moment
    JoinGap        = 2,     -- seconds between passes
    JoinRetryGap   = 5,     -- and after a join, so the client can land first

    -- who is worth joining. the portal count says how many are queued, the
    -- towers say who. ids straight out of Configs.Towers:
    --   KingOfCursesEvo      "King Of Curses (Shadow)"        AscendedGrade
    --   StrongestSorcererEvo "Strongest Sorcerer (Awakened)"  AscendedGrade
    VipUnits       = { "KingOfCursesEvo", "StrongestSorcererEvo" },
    -- the pad is 10.5 x 10.5 and neighbouring pads are 18 studs apart, so a
    -- radius of 9 covers a pad without reaching into the next one
    PortalRadius   = 9,
    RosterTTL      = 20,    -- seconds a player's tower list is reused. short on
                            -- purpose: a trade or an equip changes the answer,
                            -- and only occupants of open portals are ever asked,
                            -- so this is a handful of round trips per cycle
    PowerSlots     = 6,     -- best N owned units are what a deck is worth

    -- match
    ExitDelay      = 1.2,   -- end screen up -> fire, seconds
    ExitStateDelay = 6,     -- GameRunning false -> fire, seconds (no screen)
    ExitMinAge     = 25,    -- a screen younger than this is not an ending

    -- walk
    WalkSpeed      = 6,     -- studs/s carried on top of the humanoid
    WalkHold       = 0.45,  -- one direction, seconds
    WalkOverlap    = 0.12,  -- blend into the next direction, seconds
    WalkQuiet      = 10,    -- hands off the mouse this long before walking

    -- plaza escape
    PlazaPlace     = 17720234441,
    PlazaHome      = 17720162456,
    PlazaDelay     = 2,

    -- where this file is published. the teleport reload reads the workspace
    -- copy first and falls back to this, so a plain loadstring is enough and
    -- the hub still comes back after every join. bump nothing here by hand:
    -- it is the exact URL the loadstring uses
    ReloadURL      = "https://raw.githubusercontent.com/BlackSoougy/skibidi-defense-door-farm/main/STD_Mini.luau",
    Build          = "2026-11-24.3",

    -- loaded alongside the hub, once per place, after the boot gate. anything
    -- that belongs next to this but is not part of it goes here - the hub's own
    -- anti-afk walk is already built in, so these are extras, not requirements
    ExtraScripts   = {
        -- anti-afk, unrexl/Scripts
        "https://raw.githubusercontent.com/unrexl/Scripts/refs/heads/main/AntiAfk9b7m",
    },
}

local Players      = game:GetService("Players")
local RS           = game:GetService("ReplicatedStorage")
local UIS          = game:GetService("UserInputService")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Teleport     = game:GetService("TeleportService")

--=============================================================
-- BOOT GATE
--=============================================================
-- this file is meant to sit in the executor's autoexec, and autoexec fires while
-- the client can still be on the loading screen: no LocalPlayer, no PlayerGui,
-- and - the one that actually bites - no ReplicatedStorage.Configs. damageTable()
-- caches whatever it finds the first time it is asked, so running one second too
-- early leaves every deck at 0 for the rest of the session. so nothing below runs
-- until there is a world to run in.
--
-- the switch in the panel is this same flag, written to disk: leave it on for
-- autoexec, turn it off only if you always inject by hand after the place is up
local SETTINGS_FILE = "STD_Mini_settings.txt"

local function readSettings()
    local t = {}
    if type(readfile) ~= "function" then return t end
    local ok, s = pcall(readfile, SETTINGS_FILE)
    if ok and type(s) == "string" then
        for k, v in s:gmatch("([%w_]+)%s*=%s*([^%s]+)") do t[k] = v end
    end
    return t
end

local function saveSettings(t)
    if type(writefile) ~= "function" then return end
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    pcall(writefile, SETTINGS_FILE, table.concat(parts, "\n"))
end

local SAVED = readSettings()

-- write the file once on a fresh install, so the switch has a file to write to
-- and the setting is findable in the workspace before anybody flips anything
if type(writefile) == "function"
    and (type(isfile) ~= "function" or not isfile(SETTINGS_FILE)) then
    SAVED.boot = SAVED.boot or "1"
    saveSettings(SAVED)
end

local Boot = {
    -- on unless it was turned off once. no settings file means a fresh install,
    -- and a fresh install is exactly the one that must not run early
    wait    = SAVED.boot ~= "0",
    ready   = false,
    skipped = false,
    took    = 0,
    why     = "starting",
    missing = {},
}

local function bootGate()
    local t0 = os.clock()
    if not Boot.wait then
        Boot.skipped, Boot.ready, Boot.took, Boot.why = true, true, 0, "skipped"
        return
    end
    -- every step polls instead of waiting: a Wait on something that never shows
    -- up hangs the load forever, and each of these can legitimately be slow
    local function until_(why, fn, limit)
        Boot.why = why
        local stop = os.clock() + (limit or 60)
        while os.clock() < stop do
            local ok, v = pcall(fn)
            if ok and v then return true end
            task.wait(0.2)
        end
        return false
    end
    local function req(why, fn, limit)
        if not until_(why, fn, limit) then table.insert(Boot.missing, why) end
    end

    req("place", function() return game:IsLoaded() end, 120)
    req("player", function() return Players.LocalPlayer end, 60)
    req("gui", function() return Players.LocalPlayer:FindFirstChild("PlayerGui") end, 30)
    -- the one that matters: the tower config has to be replicated before the
    -- first damageTable() call, or that call has nothing to read. `Configs`
    -- alone is not enough - `Configs.Towers` is a separate module child
    req("configs", function()
        local c = RS:FindFirstChild("Configs")
        return c and c:FindFirstChild("Towers")
    end, 25)
    -- not fatal if this one is late: the walk and the plaza escape look the
    -- character up again on every step, so it only costs the first pass
    req("character", function()
        local c = Players.LocalPlayer and Players.LocalPlayer.Character
        return c and c:FindFirstChild("HumanoidRootPart")
    end, 20)

    Boot.took = os.clock() - t0
    Boot.ready = true
    Boot.why = (#Boot.missing > 0) and Boot.missing[1] or "ready"
end

bootGate()

local LP = Players.LocalPlayer
if not LP then
    warn("[STD_MINI] the client never finished loading, hub not started")
    return
end
local PG = LP:WaitForChild("PlayerGui", 30)

--=============================================================
-- CLEANUP + HUB TABLE
--=============================================================
if getgenv().STD_Mini then
    pcall(function() getgenv().STD_Mini.destroy() end)
end

local Hub = { conns = {}, threads = {}, log = {}, alive = true, gui = nil }
getgenv().STD_Mini = Hub

local function addConn(c)
    table.insert(Hub.conns, c)
    return c
end

-- the UI is built before the modules, and its switch callbacks run later, so
-- the names have to exist as locals now or those closures would read globals
local Anniv, AutoExit, Move, Plaza, AnnivStart, AnnivStop, Extra

local LOG_FILE = "STD_Mini_log_" .. LP.Name .. ".txt"
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local line = ("%s  %s"):format(os.date("%H:%M:%S"), table.concat(parts, " "))
    table.insert(Hub.log, line)
    while #Hub.log > 60 do table.remove(Hub.log, 1) end
    if writefile then pcall(writefile, LOG_FILE, table.concat(Hub.log, "\n")) end
end

--=============================================================
-- PALETTE + PRIMITIVES
--=============================================================
-- same look as the SD hub: near-black base, translucent glass, cyan edges,
-- mono only where it is the point
local C = {
    bg      = Color3.fromRGB(5, 8, 13),
    glass   = Color3.fromRGB(11, 17, 25),
    glass2  = Color3.fromRGB(17, 26, 37),
    card    = Color3.fromRGB(14, 22, 31),
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
    mono    = Enum.Font.GothamBold,
    ui      = Enum.Font.GothamMedium,
    uiB     = Enum.Font.GothamBold,
    display = Enum.Font.GothamBlack,
}

local function parentGui()
    local ok, hui = pcall(function() return gethui() end)
    if ok and hui then return hui end
    return PG
end

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
    -- a mitred join on a rounded rect draws the arc as a row of steps. round
    -- joins are what actually follow the curve
    pcall(function() s.LineJoinMode = Enum.LineJoinMode.Round end)
    s.Parent = inst
    return s
end

local function bump(n)
    if n <= 8 then return n + 2 end
    if n <= 12 then return n + 1 end
    return n + 2
end

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

-- a UIGradient tints the text of the control it sits on, so the gradient lives
-- on a frame behind and the button on top stays transparent
local function neon(text, x, y, w, h, parent, c1, c2, size)
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
    return b
end

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

--=============================================================
-- WINDOW
--=============================================================
local gui = Instance.new("ScreenGui")
gui.Name = "STD_Mini"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 9999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parentGui()
Hub.gui = gui

local WIN_W, WIN_H = 480, 600

-- whole pixels only. a window at x.5/y.5 puts every 1px line on a half pixel,
-- which is exactly the blur and the stair-stepping on the corners
local function screenSize()
    local cam = workspace.CurrentCamera
    local v = cam and cam.ViewportSize
    if v and v.X > 0 and v.Y > 0 then return v end
    return Vector2.new(1920, 1009)
end

local vp0 = screenSize()

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(WIN_W, WIN_H)
frame.Position = UDim2.fromOffset(math.floor((vp0.X - WIN_W) / 2), math.floor((vp0.Y - WIN_H) / 2))
frame.BackgroundColor3 = C.bg
frame.BackgroundTransparency = 0.05
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui

-- where the window was last put. the hub reloads itself after every teleport,
-- and re-centring on each load would drag it back to the middle of the screen
-- every time the player had moved it somewhere useful
local UI_FILE = "STD_Mini_ui.txt"

local function savedPos()
    if type(readfile) ~= "function" then return nil end
    local ok, data = pcall(readfile, UI_FILE)
    if not ok or type(data) ~= "string" then return nil end
    local sx, sy = data:match("^%s*(-?%d+)|(-?%d+)%s*$")
    local x, y = tonumber(sx), tonumber(sy)
    if not x or not y then return nil end
    -- a saved spot from a bigger screen must not land off this one
    if x < -(WIN_W - 80) or x > vp0.X - 80 or y < -40 or y > vp0.Y - 40 then return nil end
    return x, y
end

local function savePos()
    if type(writefile) ~= "function" then return end
    pcall(writefile, UI_FILE, ("%d|%d"):format(
        math.floor(frame.Position.X.Offset), math.floor(frame.Position.Y.Offset)))
end

-- Position and AbsolutePosition are 58px apart with IgnoreGuiInset, so the
-- centring is measured instead of assumed. one pass, whole pixels
task.defer(function()
    if not frame.Parent then return end
    local sx, sy = savedPos()
    if sx then
        frame.Position = UDim2.fromOffset(sx, sy)
        return
    end
    local want = Vector2.new(math.floor((vp0.X - WIN_W) / 2), math.floor((vp0.Y - WIN_H) / 2))
    local got = frame.AbsolutePosition
    local dx = math.floor(want.X - got.X)
    local dy = math.floor(want.Y - got.Y)
    if dx ~= 0 or dy ~= 0 then
        frame.Position = UDim2.fromOffset(
            frame.Position.X.Offset + dx,
            frame.Position.Y.Offset + dy)
    end
end)

corner(frame, 14)
stroke(frame, C.accent, 0.55, 1)

--// ---------- header ----------
-- a TextButton, not a Frame: it is the drag handle, and a label on top of a
-- button does not swallow the press (a label over a frame does)
local header = Instance.new("TextButton")
header.Size = UDim2.new(1, 0, 0, 58)
header.BackgroundTransparency = 1
header.Text = ""
header.AutoButtonColor = false
header.Active = true
header.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.fromOffset(240, 26)
title.Position = UDim2.fromOffset(18, 8)
title.BackgroundTransparency = 1
title.Font = C.display
title.TextSize = 20
title.TextColor3 = Color3.new(1, 1, 1)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "STD // MINI"
title.Parent = header
local tg = Instance.new("UIGradient")
tg.Color = ColorSequence.new(C.accent, C.accent2)
tg.Parent = title

local subtitle = mono("event  ·  match  ·  anti-afk", 20, 34, 300, 16, header, 9, C.dim, C.uiB)

local placeChip = chip(header, "LOBBY", C.accent, WIN_W - 190, 16, 118, 22, 9)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(28, 28)
closeBtn.Position = UDim2.fromOffset(WIN_W - 38, 12)
closeBtn.BackgroundColor3 = C.glass2
closeBtn.BackgroundTransparency = 0.5
closeBtn.BorderSizePixel = 0
closeBtn.Font = C.uiB
closeBtn.TextSize = 14
closeBtn.TextColor3 = C.dim
closeBtn.Text = "x"
closeBtn.AutoButtonColor = false
closeBtn.Parent = header
corner(closeBtn, 7)
stroke(closeBtn, C.line, 0.4, 1)

local hdrLine = Instance.new("Frame")
hdrLine.Size = UDim2.new(1, -30, 0, 1)
hdrLine.Position = UDim2.fromOffset(15, 56)
hdrLine.BackgroundColor3 = C.accent
hdrLine.BackgroundTransparency = 0.45
hdrLine.BorderSizePixel = 0
hdrLine.Parent = header

--// ---------- switch ----------
-- a label and a track with a knob. the knob is the only thing that moves, so
-- the row never shifts when the state flips
local function switchRow(parent, x, y, w, labelText, default, cb)
    mono(labelText, x, y + 3, w - 60, 18, parent, 10, C.text)

    local track = Instance.new("Frame")
    track.Size = UDim2.fromOffset(46, 22)
    track.Position = UDim2.fromOffset(x + w - 46, y)
    track.BackgroundColor3 = C.glass2
    track.BackgroundTransparency = 0.3
    track.BorderSizePixel = 0
    track.Parent = parent
    corner(track, 11)
    local st = stroke(track, C.line, 0.3, 1)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.fromOffset(16, 16)
    knob.Position = UDim2.fromOffset(3, 3)
    knob.BackgroundColor3 = C.dim
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 8)

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(46, 22)
    btn.Position = UDim2.fromOffset(x + w - 46, y)
    btn.BackgroundTransparency = 1
    btn.Text = ""
    btn.Parent = parent

    local state = default == true
    local function paint(animate)
        track.BackgroundColor3 = state and C.sel or C.glass2
        st.Color = state and C.accent or C.line
        st.Transparency = state and 0.35 or 0.3
        knob.BackgroundColor3 = state and C.accent or C.dim
        local goal = UDim2.fromOffset(state and 27 or 3, 3)
        if animate then
            TweenService:Create(knob, TweenInfo.new(0.12), { Position = goal }):Play()
        else
            knob.Position = goal
        end
    end
    paint(false)

    btn.MouseButton1Click:Connect(function()
        state = not state
        paint(true)
        if cb then cb(state) end
    end)

    return {
        get = function() return state end,
        set = function(v)
            v = v == true
            if v == state then return end
            state = v
            paint(true)
            if cb then cb(state) end
        end,
    }
end

--// ---------- event panel ----------
local evPanel = glass(12, 66, 456, 178, frame, { name = "Event" })
mono("EVENT // PINATA", 12, 8, 240, 16, evPanel, 9, C.accent, C.display)

local joinSw
joinSw = switchRow(evPanel, 12, 30, 432, "auto join", true, function(v)
    if v then AnnivStart() else AnnivStop() end
end)

mono("min players", 12, 62, 110, 18, evPanel, 10, C.dim)
local minusBtn = tagBtn("-", 120, 58, 26, 24, evPanel, 11)
local minChip = chip(evPanel, "7", C.accent, 150, 58, 42, 24, 11)
local plusBtn = tagBtn("+", 196, 58, 26, 24, evPanel, 11)

local evPortals = mono("portals: -", 12, 91, 432, 18, evPanel, 10, C.head, C.uiB)
local evStatus = mono("idle", 12, 110, 432, 18, evPanel, 10, C.dim, C.uiB)

local joinNow = neon("JOIN NOW", 12, 136, 432, 32, evPanel,
    Color3.fromRGB(24, 150, 180), Color3.fromRGB(30, 110, 200), 12)

--// ---------- match panel ----------
local mtPanel = glass(12, 250, 456, 116, frame, { name = "Match" })
mono("MATCH // EXIT", 12, 8, 240, 16, mtPanel, 9, C.accent, C.display)

local exitSw
exitSw = switchRow(mtPanel, 12, 30, 432, "auto exit on end", true, function(v)
    AutoExit.on = v
    if v then AutoExit.done = false end
    log(v and "exit: watching" or "exit: off")
end)

local mtStatus = mono("watching", 12, 58, 432, 18, mtPanel, 10, C.dim, C.uiB)

local exitNow = neon("EXIT NOW", 12, 78, 432, 30, mtPanel,
    Color3.fromRGB(150, 50, 160), Color3.fromRGB(90, 40, 190), 12)

--// ---------- anti-afk panel ----------
local afkPanel = glass(12, 374, 456, 136, frame, { name = "Afk" })
mono("ANTI-AFK", 12, 8, 240, 16, afkPanel, 9, C.accent, C.display)

local walkSw
walkSw = switchRow(afkPanel, 12, 30, 432, "walk loop", true, function(v) Move.set(v) end)
local walkLbl = mono("walking: wasd   steps: 0", 12, 54, 432, 18, afkPanel, 10, C.dim, C.uiB)

local plazaSw
plazaSw = switchRow(afkPanel, 12, 78, 432, "leave afk plaza", true, function(v)
    Plaza.on = v
    if v then Plaza.cool = 0 Plaza.fails = 0 end
    log(v and "plaza: leaving on sight" or "plaza: staying put")
end)
local plazaLbl = mono("plaza: away   escapes: 0", 12, 102, 432, 18, afkPanel, 10, C.dim, C.uiB)

--// ---------- boot panel ----------
-- the switch only changes what the NEXT inject does: this run already got past
-- the gate, so flipping it here is a note to the next load, not a live action
local bootPanel = glass(12, 518, 456, 68, frame, { name = "Boot" })
mono("INJECT // BOOT", 12, 8, 240, 16, bootPanel, 9, C.accent, C.display)

local bootSw
bootSw = switchRow(bootPanel, 12, 26, 432, "wait for game load", Boot.wait, function(v)
    Boot.wait = v
    SAVED.boot = v and "1" or "0"
    saveSettings(SAVED)
    log(v and "boot: next inject waits for the place"
           or "boot: next inject runs immediately")
end)
local bootLbl = mono("boot: -", 12, 48, 432, 16, bootPanel, 10, C.dim, C.uiB)

--// ---------- log ----------

--=============================================================
-- ROSTER  (whose slots are worth joining)
--=============================================================
-- ReplicatedStorage.Remotes.GetOtherPlayerData is the function the trade menu
-- uses: invoke it with a Player and it answers with that account's profile,
-- Towers included (guid -> { Name, UUID, Equipped }). That is the only way a
-- client can see somebody else's slots - the portal's own Config carries just
-- Map and MaxPlayers, and player objects only expose Coins/Gems.
--
-- The call is a server round trip, so nothing here blocks a join pass: a player
-- is asked once, the answer is cached, and the first pass that sees them simply
-- scores zero until the reply lands.
local Roster = {}
Hub.Roster = Roster

Roster.cache = {}
Roster.pending = {}
Roster.TTL = CFG.RosterTTL

local VIP = {}
for _, id in ipairs(CFG.VipUnits) do VIP[id] = true end

-- Configs.Towers.Config[id].Damage is the real strength number and it ships as
-- a string with a suffix ("360k", "61.5M", "20"). parsed once, then it is just
-- a table lookup per tower
local DMG = nil

local function parseNum(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return 0 end
    local s = v:lower():gsub(",", "")
    local n, suf = s:match("^([%d%.]+)%s*([kmb]?)$")
    n = tonumber(n)
    if not n then return 0 end
    if suf == "k" then return n * 1e3 end
    if suf == "m" then return n * 1e6 end
    if suf == "b" then return n * 1e9 end
    return n
end

local function damageTable()
    if DMG then return DMG end
    -- only a real answer gets cached. Configs arrives with replication, so a
    -- require can fail on a client that was injected a second too early - and
    -- caching that failure as "this game has no towers" would leave every deck
    -- reading 0 for the rest of the session. an empty result is handed back for
    -- this pass only, and the next call asks again
    local ok, mod = pcall(function() return require(RS.Configs.Towers) end)
    if not ok or type(mod) ~= "table" or type(mod.Config) ~= "table" then return {} end
    local t = {}
    for id, e in pairs(mod.Config) do
        if type(e) == "table" then
            local d = parseNum(e.Damage)
            if d > 0 then t[tostring(id)] = d end
        end
    end
    if next(t) == nil then return {} end
    DMG = t
    return DMG
end

local function fmtPower(n)
    if n >= 1e9 then return ("%.1fB"):format(n / 1e9) end
    if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
    if n >= 1e3 then return ("%.0fk"):format(n / 1e3) end
    return tostring(math.floor(n))
end

-- the deck a player could field: their best N units by base damage. levels are
-- not in the profile, so base damage is the honest number - it separates an
-- account holding an Ascended unit from one holding six legendaries without
-- pretending to know how far they upgraded anything
local function deckPower(units)
    local dmg = damageTable()
    local list = {}
    for id in pairs(units) do
        local d = dmg[id]
        if d then list[#list + 1] = d end
    end
    table.sort(list, function(a, b) return a > b end)
    local total, taken = 0, 0
    for _, d in ipairs(list) do
        total = total + d
        taken = taken + 1
        if taken >= CFG.PowerSlots then break end
    end
    return total
end

local function otherDataFn()
    local rem = RS:FindFirstChild("Remotes")
    return rem and rem:FindFirstChild("GetOtherPlayerData")
end

function Roster.entry(player)
    if not player or player == LP then return nil end
    local c = Roster.cache[player.UserId]
    if not c then
        Roster.request(player)
        return nil
    end
    if (os.clock() - c.at) > Roster.TTL then Roster.request(player) end
    return c
end

-- profile -> owned unit ids, and which of the wanted ones are in there
function Roster.parse(data)
    local units, names, vip = {}, {}, 0
    for _, t in pairs((type(data) == "table" and data.Towers) or {}) do
        local nm = type(t) == "table" and (t.Name or t.Class) or nil
        if nm then
            nm = tostring(nm)
            units[nm] = true
            if VIP[nm] and not names[nm] then
                names[nm] = true
                vip = vip + 1
            end
        end
    end
    return units, names, vip, deckPower(units)
end

function Roster.request(player)
    if Roster.pending[player.UserId] then return end
    local fn = otherDataFn()
    if not fn then return end
    Roster.pending[player.UserId] = true
    task.spawn(function()
        local ok, data = pcall(function() return fn:InvokeServer(player) end)
        Roster.pending[player.UserId] = nil
        if not ok or type(data) ~= "table" then
            -- a refusal is cached too, or one bad profile gets asked every pass
            Roster.cache[player.UserId] = { at = os.clock(), units = {}, vip = 0,
                                            names = {}, power = 0, name = player.Name,
                                            bad = true }
            return
        end
        local units, names, vip, power = Roster.parse(data)
        Roster.cache[player.UserId] = {
            at = os.clock(), units = units, vip = vip, names = names,
            power = power, name = player.Name,
        }
    end)
end

-- the n nearest players to a pad are the n the portal is counting. the count is
-- the server's own number, so this lines the people up with it instead of
-- guessing at a radius alone
function Roster.occupants(part, n)
    local out = {}
    if not part or (n or 0) <= 0 then return out end
    local p0 = part.Position
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local c = p.Character
            local hrp = c and c:FindFirstChild("HumanoidRootPart")
            if hrp then
                local d = (hrp.Position - p0).Magnitude
                if d <= CFG.PortalRadius then
                    out[#out + 1] = { player = p, d = d }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.d < b.d end)
    while #out > n do table.remove(out) end
    return out
end

-- vip count + who, for one portal entry
function Roster.score(portal)
    local occ = Roster.occupants(portal.part, portal.n)
    local vip, names, power, best = 0, {}, 0, 0
    for _, o in ipairs(occ) do
        local e = Roster.entry(o.player)
        if e then
            power = power + (e.power or 0)
            if (e.power or 0) > best then best = e.power end
        end
        if e and e.vip > 0 then
            vip = vip + 1
            local label = e.name
            if e.names.KingOfCursesEvo and e.names.StrongestSorcererEvo then
                label = label .. " (meguna+gojo)"
            elseif e.names.KingOfCursesEvo then
                label = label .. " (meguna)"
            else
                label = label .. " (gojo)"
            end
            names[#names + 1] = label
        end
    end
    return vip, names, #occ, power, best
end

--=============================================================
-- EVENT  (auto join)
--=============================================================
Anniv = { on = true, min = CFG.MinPlayers, status = "idle", state = "idle",
          list = {}, joins = 0, bestNow = nil }
Hub.Anniv = Anniv

local function pinataRoot()
    return workspace:FindFirstChild("PinataTeleporters")
end

function Anniv.scan()
    local root = pinataRoot()
    local out = {}
    if not root then return out end
    for i, p in ipairs(root:GetChildren()) do
        local part = p:FindFirstChild("Part")
        local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
        local bb = p:FindFirstChild("Billboard")
        local gui = bb and bb:FindFirstChildOfClass("BillboardGui")
        local pc = gui and gui:FindFirstChild("PlayerCount")
        local titleLbl = gui and gui:FindFirstChild("Title")
        local cfg = p:FindFirstChild("Config")
        local maxV = cfg and cfg:FindFirstChild("MaxPlayers")
        local txt = pc and tostring(pc.Text) or "0/10"
        table.insert(out, {
            model = p,
            idx = i,
            part = part,
            prompt = prompt,
            n = tonumber(txt:match("^(%d+)")) or 0,
            max = (maxV and maxV.Value) or (tonumber(txt:match("/(%d+)")) or 10),
            title = titleLbl and tostring(titleLbl.Text) or "",
            open = prompt ~= nil and prompt.Enabled == true,
        })
    end
    return out
end

function Anniv.openList(list)
    local out = {}
    for _, e in ipairs(list or Anniv.list) do
        if e.open then table.insert(out, e) end
    end
    table.sort(out, function(a, b)
        if a.n == b.n then return a.idx < b.idx end
        return a.n > b.n
    end)
    return out
end

-- candidates, best first:
--   1. a portal with somebody holding Meguna or Gojo Awakened always wins,
--   2. then the strongest deck,
--   3. then the headcount, then the index.
--
-- the `min players` setting is a hard gate again: a portal below it is not a
-- candidate at all, so the hub sits and waits for one of them to fill instead of
-- hopping into a 3/10 nobody else is going to join. a full portal is never a
-- candidate either - there is no slot in it. `force` is the manual pass, which
-- ignores the gate on purpose: pressing JOIN NOW is you saying "this one, now"
function Anniv.ranked(list, force)
    local out = {}
    local floor = force and 1 or Anniv.min
    for _, e in ipairs(Anniv.openList(list)) do
        local vip, names, seen, power, best = Roster.score(e)
        e.vip = vip
        e.vipNames = names
        e.seen = seen
        e.power = power
        e.best = best
        if e.n < e.max and e.n >= floor then table.insert(out, e) end
    end
    table.sort(out, function(a, b)
        local av, bv = a.vip or 0, b.vip or 0
        if av ~= bv then return av > bv end
        local ap, bp = a.power or 0, b.power or 0
        if ap ~= bp then return ap > bp end
        if a.n == b.n then return a.idx < b.idx end
        return a.n > b.n
    end)
    return out
end

function Anniv.summary(list)
    list = list or Anniv.list
    if #list == 0 then return "portals: -" end
    local parts = {}
    for _, e in ipairs(list) do
        local mark = ""
        if (e.vip or 0) > 0 then
            mark = "*"
        elseif e.open and e.n >= Anniv.min and e.n < e.max then
            mark = "+"
        end
        table.insert(parts, ("%d/%d%s"):format(e.n, e.max, mark))
    end
    return "portals: " .. table.concat(parts, "  ·  ")
end

-- TpIn is where the portal drops you, Part is what the prompt is attached to.
-- the first teleport is not always enough - the prompt can be on cooldown or the
-- character can be mid-fall - so it re-seats and re-fires at 1.6s and 3.2s, and
-- "did it work" is judged by the root actually leaving the spot, not by a reply
function Anniv.enter(model)
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local tp = model and model:FindFirstChild("TpIn")
    local part = model and model:FindFirstChild("Part")
    local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
    if not (hrp and tp and part and prompt) then return false end
    if type(fireproximityprompt) ~= "function" then return false end

    pcall(function() prompt.HoldDuration = 0 end)
    pcall(function() prompt.ClickablePrompt = true end)

    local place0 = game.PlaceId

    local function left()
        if game.PlaceId ~= place0 then return true end
        local c = LP.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        if r and (r.Position - tp.Position).Magnitude > 80 then return true end
        return false
    end

    pcall(function() hrp.CFrame = CFrame.new(tp.Position + Vector3.new(0, 3, 0)) end)
    task.wait(0.4)
    pcall(function() fireproximityprompt(prompt) end)

    for i = 1, 30 do
        task.wait(0.2)
        if left() then return true end
        if i == 8 or i == 16 then
            local c = LP.Character
            local r = c and c:FindFirstChild("HumanoidRootPart")
            if r then
                pcall(function() r.CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0)) end)
            end
            pcall(function() fireproximityprompt(prompt) end)
        end
    end
    return false
end

function Anniv.step(force)
    local list = Anniv.scan()
    Anniv.list = list
    if #list == 0 then
        Anniv.status = "no portals - not in the lobby"
        Anniv.state = "no portals"
        Anniv.bestNow = nil
        return
    end

    local open = Anniv.openList(list)
    if #open == 0 then
        Anniv.status = "portals closed"
        Anniv.state = "closed"
        Anniv.bestNow = nil
        return
    end

    -- a portal that just opened reads 0/10 while the count replicates. waiting
    -- a few seconds here is what stops a pass from deciding "nobody is in it"
    -- on a portal that is actually full
    if open[1].n == 0 then
        Anniv.status = "open, reading counts"
        local t0 = os.clock()
        while os.clock() - t0 < CFG.WaitPopulate and Hub.alive do
            task.wait(0.6)
            local l2 = Anniv.scan()
            Anniv.list = l2
            local o2 = Anniv.openList(l2)
            if #o2 > 0 then
                open = o2
                if o2[1].n > 0 then break end
            end
        end
    end

    local q = Anniv.ranked(open, force)
    -- what the panel shows: the strongest candidate, whether or not it is being
    -- entered right now. when nothing qualifies it is the best of what is open,
    -- so the count and the deck still tell you what the server looks like
    Anniv.bestNow = q[1] or open[1]
    if #q == 0 then
        -- nothing to join. three different reasons, and the wait is different in
        -- each, so say which one it is instead of a single vague "waiting"
        local e = open[1]
        if e.n >= e.max then
            Anniv.state = "full"
            Anniv.status = ("all open portals are full - waiting for a slot (%d/%d)"):format(
                e.n, e.max)
        elseif e.n < Anniv.min then
            Anniv.state = "waiting"
            Anniv.status = ("waiting for %d+  ·  best %d/%d  ·  deck %s"):format(
                Anniv.min, e.n, e.max, fmtPower(e.power or 0))
        else
            Anniv.state = "waiting"
            Anniv.status = ("waiting for a joinable portal (best %d/%d)"):format(e.n, e.max)
        end
        return
    end

    if q[1].n < Anniv.min then
        Anniv.state = "joining below min"      -- only reachable from a manual pass
    elseif (q[1].vip or 0) > 0 then
        Anniv.state = "joining"
    else
        Anniv.state = "joining strongest"
    end
    for _, e in ipairs(q) do
        local tag = ""
        if (e.vip or 0) > 0 then
            tag = "  " .. table.concat(e.vipNames or {}, ", ")
        end
        Anniv.status = ("joining %d/%d  ·  deck %s%s"):format(
            e.n, e.max, fmtPower(e.power or 0), tag)
        if Anniv.enter(e.model) then
            Anniv.joins = Anniv.joins + 1
            Anniv.state = "joined"
            local who = (#(e.vipNames or {}) > 0) and ("  " .. table.concat(e.vipNames, ", ")) or ""
            Anniv.status = ("joined %d/%d"):format(e.n, e.max)
            log(("event: joined %s at %d/%d, deck %s%s"):format(
                e.title ~= "" and e.title or "portal", e.n, e.max,
                fmtPower(e.power or 0), who))
            return
        end
    end
    Anniv.status = "join failed - retrying"
end

function Anniv.start()
    if Anniv.thread then return end
    Anniv.thread = task.spawn(function()
        while Hub.alive and Anniv.on do
            pcall(Anniv.step)
            task.wait(Anniv.status:find("joined") and CFG.JoinRetryGap or CFG.JoinGap)
        end
        Anniv.thread = nil
    end)
end

function Anniv.stop()
    Anniv.on = false
    Anniv.thread = nil
end

-- the switch callbacks are wired before the module functions exist, so they go
-- through these two shims
function AnnivStart()
    Anniv.on = true
    Anniv.start()
    log("event: auto join on")
end

function AnnivStop()
    Anniv.on = false
    log("event: auto join off")
end

--=============================================================
-- AUTO EXIT
--=============================================================
AutoExit = { on = true, done = false, fired = 0, lastPlace = 0, t0 = os.clock(), sawRun = false }
Hub.AutoExit = AutoExit

function AutoExit.screen()
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local direct = pg:FindFirstChild("EndScreen")
    if direct then return direct end
    for _, d in ipairs(pg:GetDescendants()) do
        if d.Name == "EndScreen" then return d end
    end
    return nil
end

-- true only when the screen and every ancestor of it are shown
function AutoExit.up()
    local es = AutoExit.screen()
    if not es then return false end
    local n = es
    while n and n ~= game do
        local okv, v = pcall(function() return n.Visible end)
        if okv and v == false then return false end
        local oke, e = pcall(function() return n.Enabled end)
        if oke and e == false then return false end
        n = n.Parent
    end
    return true
end

-- the remote does not exist in the lobby - it ships with the match place - so
-- the lookup is cached per place and falls back to a descendant scan instead of
-- trusting one hardcoded path
function AutoExit.remote()
    if AutoExit._rem and AutoExit._rem.Parent then return AutoExit._rem end
    local pid = game.PlaceId
    if AutoExit._remPlace == pid then return nil end
    AutoExit._remPlace = pid
    AutoExit._rem = nil
    local ev = RS:FindFirstChild("Events")
    local r = ev and ev:FindFirstChild("ExitGame")
    if not r then
        for _, d in ipairs(RS:GetDescendants()) do
            if d.Name == "ExitGame" and d:IsA("RemoteEvent") then
                r = d
                break
            end
        end
    end
    AutoExit._rem = r
    return r
end

-- ExitGame takes no arguments, so this is the same call the button makes. the
-- button itself is the fallback, through its own connection
function AutoExit.fire()
    local rem = AutoExit.remote()
    if rem then
        local ok = pcall(function() rem:FireServer() end)
        if ok then return "ExitGame" end
    end
    local es = AutoExit.screen()
    local btn = es and es:FindFirstChild("Exit", true)
    if btn then
        local ok = pcall(function()
            local c = getconnections(btn.Activated)
            if c and #c > 0 then c[1].Function() end
        end)
        if ok then return "the game's own button" end
    end
    return nil
end

-- workspace.Info carries Timer / GameID / AfkID in the lobby, and GameRunning
-- only exists once a mode is live. if the value is not under Info it is looked
-- for once per place and the answer is cached
function AutoExit.running()
    local info = workspace:FindFirstChild("Info")
    local v = info and info:FindFirstChild("GameRunning")
    if not v then
        if AutoExit._grPlace ~= game.PlaceId then
            AutoExit._grPlace = game.PlaceId
            AutoExit._gr = workspace:FindFirstChild("GameRunning", true)
                or RS:FindFirstChild("GameRunning", true)
        end
        v = AutoExit._gr
        if v and not v.Parent then
            AutoExit._gr = nil
            return nil
        end
    end
    if not v then return nil end
    local ok, val = pcall(function() return v.Value end)
    if not ok then return nil end
    return val == true
end

function AutoExit.stateEnd()
    if not AutoExit.sawRun then return false end
    return AutoExit.running() == false
end

function AutoExit.start()
    if AutoExit._watch then return end
    AutoExit._watch = task.spawn(function()
        while Hub.alive do
            local pid = game.PlaceId
            if pid ~= AutoExit.lastPlace then
                AutoExit.lastPlace = pid
                AutoExit.done = false
                AutoExit.sawRun = false
                AutoExit.t0 = os.clock()
            end
            if AutoExit.running() == true then AutoExit.sawRun = true end

            -- a screen that is already up the instant you arrive is a leftover
            -- or part of the loading sequence, not an ending. it has to age
            local old = (os.clock() - AutoExit.t0) > CFG.ExitMinAge
            local screen = AutoExit.up()
            local state = (not screen) and AutoExit.stateEnd()
            if AutoExit.on and old and not AutoExit.done and (screen or state) then
                task.wait(screen and CFG.ExitDelay or CFG.ExitStateDelay)
                if AutoExit.up() or AutoExit.stateEnd() then
                    local how = AutoExit.fire()
                    if how then
                        AutoExit.done = true
                        AutoExit.fired = AutoExit.fired + 1
                        log("exit: left via " .. how)
                    end
                end
            end
            task.wait(0.4)
        end
        AutoExit._watch = nil
    end)
end

--=============================================================
-- ANTI-AFK  (walk)
--=============================================================
Move = {
    on = true,
    speed = CFG.WalkSpeed,
    hold = CFG.WalkHold,
    overlap = CFG.WalkOverlap,
    quiet = CFG.WalkQuiet,
    lastUser = 0,
    steps = 0,
    t0 = os.clock(),
}
Hub.Move = Move

-- camera relative, exactly like wasd: w is where you look, a is your left. the
-- phase is read off the clock, not counted per frame, so a lag spike cannot make
-- the loop skip or crawl
function Move.dir()
    local cam = workspace.CurrentCamera
    if not cam then return Vector3.zero end
    local l = cam.CFrame.LookVector
    local r = cam.CFrame.RightVector
    l = Vector3.new(l.X, 0, l.Z)
    r = Vector3.new(r.X, 0, r.Z)
    if l.Magnitude < 0.01 or r.Magnitude < 0.01 then return Vector3.zero end
    l, r = l.Unit, r.Unit

    local t = os.clock() - Move.t0
    local seg = math.floor(t / Move.hold)
    local i = seg % 4 + 1
    local j = i % 4 + 1
    local frac = (t - seg * Move.hold) / Move.hold
    local edge = 1 - math.min(0.9, Move.overlap / Move.hold)
    local blend = 0
    if frac > edge then blend = (frac - edge) / (1 - edge) end

    local a, b
    if i == 1 then a = l elseif i == 2 then a = -r elseif i == 3 then a = -l else a = r end
    if j == 1 then b = l elseif j == 2 then b = -r elseif j == 3 then b = -l else b = r end

    local v = a + b * blend
    if v.Magnitude < 0.001 then return Vector3.zero end
    return v.Unit
end

function Move.drive(dt)
    if not Move.on then return end
    if (os.clock() - Move.lastUser) < Move.quiet then return end
    local okBox, box = pcall(function() return UIS:GetFocusedTextBox() end)
    if okBox and box then return end
    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not (hum and hrp) then return end
    if hum.Health <= 0 or hum.Sit then return end
    -- in the air the humanoid is not listening and a root write would fight
    -- gravity. wait for the floor instead of flying
    if hum.FloorMaterial == Enum.Material.Air then return end
    local d = Move.dir()
    if d.Magnitude < 0.5 then return end
    hum:Move(d, false)
    hrp.CFrame = hrp.CFrame + d * Move.speed * dt
    Move.steps = Move.steps + 1
end

-- a mouse in your hand means you are at the machine, so the walk steps aside
-- instead of dragging you around while you play. only mouse, never keys:
-- injected keys would loop it forever
function Move.arm()
    if Move._conn then return end
    Move._conn = addConn(UIS.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            Move.lastUser = os.clock()
        end
    end))
    Move._btn = addConn(UIS.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.MouseButton2 then
            Move.lastUser = os.clock()
        end
    end))
end

function Move.start()
    if Move._drive then return end
    Move.t0 = os.clock()
    Move.arm()
    -- Stepped, not RenderStepped: a background client stops rendering and
    -- RenderStepped never fires there
    Move._drive = addConn(RunService.Stepped:Connect(function(_, dt)
        local ok, err = pcall(Move.drive, dt)
        if not ok and not Move._err then
            Move._err = true
            log("anti-afk: walk error " .. tostring(err))
        end
    end))
end

function Move.set(v)
    Move.on = v == true
    if Move.on then Move.t0 = os.clock() end
    log(Move.on and "anti-afk: walking" or "anti-afk: stopped")
end

--=============================================================
-- PLAZA ESCAPE
--=============================================================
Plaza = {
    PLACE = CFG.PlazaPlace,
    HOME  = CFG.PlazaHome,
    file  = "STD_Mini_last_server.txt",
    on    = true,
    delay = CFG.PlazaDelay,
    left  = 0,
    fails = 0,
    cool  = 0,
    dead  = false,
}
Hub.Plaza = Plaza

function Plaza.pid()
    local info = workspace:FindFirstChild("Info")
    local v = info and info:FindFirstChild("AfkID")
    if v then
        local ok, val = pcall(function() return v.Value end)
        if ok and tonumber(val) then return tonumber(val) end
    end
    return Plaza.PLACE
end

function Plaza.here()
    return game.PlaceId == Plaza.PLACE or game.PlaceId == Plaza.pid()
end

-- a method fetched off the instance and called as a plain function: the
-- __namecall hook that refuses teleports is a metamethod, and this path never
-- touches it
local function rawCall(inst, name, ...)
    local fn = inst[name]
    if type(fn) ~= "function" then return false, "no " .. tostring(name) end
    local ok, err = pcall(fn, inst, ...)
    return ok, err
end

function Plaza.leave()
    local place, job = Plaza.lastPlace, Plaza.lastJob
    if place and place ~= Plaza.PLACE and place ~= Plaza.pid() then
        if job and job ~= "" then
            local ok = rawCall(Teleport, "TeleportToPlaceInstance", place, job, LP)
            if ok then return "same server" end
        end
        local ok = rawCall(Teleport, "Teleport", place, LP)
        if ok then return "same place" end
    end
    local ok = rawCall(Teleport, "Teleport", Plaza.HOME, LP)
    if ok then return "lobby" end
    return nil
end

-- the server you came from goes to disk, not just into the table: a teleport
-- reloads the client, autoexec runs again, and the hub that wakes up in the
-- plaza has an empty table. without this it always fell back to the lobby
function Plaza.remember(place, job)
    Plaza.lastPlace = place
    Plaza.lastJob = job
    if not writefile then return end
    local stamp = tostring(place) .. "|" .. tostring(job)
    if Plaza._saved == stamp then return end
    Plaza._saved = stamp
    pcall(writefile, Plaza.file, stamp)
end

function Plaza.recall()
    if Plaza.lastPlace then return end
    if not readfile then return end
    local ok, data = pcall(readfile, Plaza.file)
    if not ok or type(data) ~= "string" then return end
    local p, j = data:match("^(%d+)|([%w%-]+)")
    if p and j then
        Plaza.lastPlace = tonumber(p)
        Plaza.lastJob = j
    end
end

function Plaza.start()
    if Plaza._thread then return end
    Plaza.dead = false
    Plaza.recall()
    Plaza._thread = task.spawn(function()
        while not Plaza.dead and Hub.alive do
            if not Plaza.here() then
                if game.PlaceId ~= Plaza.PLACE then
                    Plaza.remember(game.PlaceId, game.JobId)
                end
                if Plaza.fails > 0 and os.clock() > Plaza.cool then Plaza.fails = 0 end
            elseif Plaza.on and os.clock() >= Plaza.cool then
                if Plaza.delay > 0 then task.wait(Plaza.delay) end
                if Plaza.here() and not Plaza.dead then
                    local how = Plaza.leave()
                    if how then
                        Plaza.left = Plaza.left + 1
                        log(("plaza: leaving (%s), %d total"):format(how, Plaza.left))
                    end
                    local t0 = os.clock()
                    while Plaza.here() and not Plaza.dead and (os.clock() - t0) < 10 do
                        task.wait(0.5)
                    end
                    if Plaza.here() then
                        Plaza.fails = Plaza.fails + 1
                        Plaza.cool = os.clock() + math.min(60, 10 * Plaza.fails)
                        log(("plaza: still here, backing off %ds"):format(math.min(60, 10 * Plaza.fails)))
                        pcall(function() rawCall(Teleport, "Teleport", Plaza.HOME, LP) end)
                        task.wait(8)
                    else
                        Plaza.fails = 0
                    end
                end
            end
            task.wait(1)
        end
        Plaza._thread = nil
    end)
end

--=============================================================
-- WIRING
--=============================================================
local function setMin(n)
    -- 9, not 10: a portal at its cap has no slot left, so a minimum of 10 could
    -- never be satisfied and the hub would sit there forever
    n = math.clamp(math.floor(tonumber(n) or 7), 1, 9)
    Anniv.min = n
    CFG.MinPlayers = n
    minChip.Text = tostring(n)
    log("event: min players " .. n)
end

minusBtn.MouseButton1Click:Connect(function() setMin(Anniv.min - 1) end)
plusBtn.MouseButton1Click:Connect(function() setMin(Anniv.min + 1) end)

joinNow.MouseButton1Click:Connect(function()
    if not Anniv.on then joinSw.set(true) end
    task.spawn(function()
        pcall(Anniv.step, true)   -- manual: ignore the min gate, take the best
        log("event: manual pass - " .. Anniv.status)
    end)
end)

exitNow.MouseButton1Click:Connect(function()
    local how = AutoExit.fire()
    log(how and ("exit: manual, via " .. how) or "exit: nothing to fire")
end)

closeBtn.MouseButton1Click:Connect(function()
    frame.Visible = false
end)

-- dragging, but on a whole-pixel grid: the default Draggable leaves the frame
-- on fractional offsets and the whole window goes soft
do
    local dragging, dragFrom, startPos
    addConn(header.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        dragFrom = input.Position
        startPos = frame.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
                savePos()
            end
        end)
    end))
    addConn(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local d = input.Position - dragFrom
        frame.Position = UDim2.fromOffset(
            math.floor(startPos.X.Offset + d.X),
            math.floor(startPos.Y.Offset + d.Y))
    end))
end

addConn(UIS.InputBegan:Connect(function(input, typing)
    if typing then return end
    if input.KeyCode == CFG.Key then
        frame.Visible = not frame.Visible
    end
end))

--=============================================================
-- COMPANION SCRIPTS
--=============================================================
-- things that belong alongside the hub instead of inside it. they load once per
-- place, after the boot gate, each in its own thread with its own pcall - a
-- companion that loops forever or throws cannot take the hub down with it, and
-- the url is remembered in genv so re-injecting by hand does not stack a second
-- copy of something that was only ever meant to run once
Extra = { list = CFG.ExtraScripts or {}, ok = 0, bad = 0, done = {} }
Hub.Extra = Extra

function Extra.load()
    local seen = getgenv().STD_Mini_Extra
    if type(seen) ~= "table" then
        seen = {}
        getgenv().STD_Mini_Extra = seen
    end
    for _, url in ipairs(Extra.list) do
        if not seen[url] then
            seen[url] = true
            Extra.done[url] = "loading"
            task.spawn(function()
                local host = tostring(url):match("^https?://([^/]+)") or tostring(url)
                local src
                for attempt = 1, 3 do
                    local ok, body = pcall(function() return game:HttpGet(url) end)
                    if ok and type(body) == "string" and #body > 200 then
                        src = body
                        break
                    end
                    if attempt < 3 then task.wait(2) end
                end
                if not src then
                    seen[url] = nil          -- let a later LoadExtra try again
                    Extra.bad = Extra.bad + 1
                    Extra.done[url] = "download failed"
                    log("extra: " .. host .. " failed to download")
                    return
                end
                local fn, err = loadstring(src)
                if not fn then
                    seen[url] = nil
                    Extra.bad = Extra.bad + 1
                    Extra.done[url] = "compile error"
                    log("extra: " .. host .. " does not compile - " .. tostring(err))
                    return
                end
                Extra.ok = Extra.ok + 1
                Extra.done[url] = "running"
                log(("extra: %s started (%d KB)"):format(host, math.floor(#src / 1024)))
                local ok2, err2 = pcall(fn)
                if not ok2 then
                    Extra.done[url] = "errored"
                    log("extra: " .. host .. " errored - " .. tostring(err2))
                end
            end)
        end
    end
end

--=============================================================
-- TICKER
--=============================================================
local function placeLabel()
    if Plaza.here() then return "AFK PLAZA", C.bad end
    if game.PlaceId == Plaza.HOME then return "LOBBY", C.accent end
    return "IN MATCH", C.good
end

local function refresh()
    local name, col = placeLabel()
    placeChip.Text = name
    placeChip.TextColor3 = col:Lerp(Color3.new(1, 1, 1), 0.55)
    local cs = placeChip:FindFirstChildOfClass("UIStroke")
    if cs then cs.Color = col end

    evPortals.Text = Anniv.summary()
    if not Anniv.on then
        evStatus.Text = "auto join off"
    elseif Anniv.bestNow then
        local b = Anniv.bestNow
        -- the min belongs on this line now that it is a gate: without it the
        -- panel says "best 4/10" and nothing about what it is waiting for
        evStatus.Text = ("min %d  ·  best %d/%d  ·  deck %s  ·  %s"):format(
            Anniv.min, b.n or 0, b.max or 0, fmtPower(b.power or 0), Anniv.state or "-")
    else
        evStatus.Text = Anniv.status
    end

    local exitState
    if not AutoExit.on then
        exitState = "off"
    elseif AutoExit.done then
        exitState = "left this match"
    elseif AutoExit.up() then
        exitState = "end screen up - firing"
    elseif AutoExit.stateEnd() then
        exitState = "round stopped - firing"
    else
        exitState = "watching"
    end
    mtStatus.Text = ("%s  ·  fired %d"):format(exitState, AutoExit.fired)

    local walkState = "off"
    if Move.on then
        walkState = ((os.clock() - Move.lastUser) < Move.quiet) and "waiting for mouse" or "wasd"
    end
    walkLbl.Text = ("walking: %s  ·  steps %d"):format(walkState, Move.steps)

    local plazaState
    if not Plaza.here() then
        plazaState = "away"
    elseif Plaza.on and os.clock() < Plaza.cool then
        plazaState = ("in plaza, retry in %ds"):format(math.ceil(Plaza.cool - os.clock()))
    elseif Plaza.on then
        plazaState = "in plaza - leaving"
    else
        plazaState = "in plaza - staying"
    end
    plazaLbl.Text = ("plaza: %s  ·  escapes %d"):format(plazaState, Plaza.left)

    local bootState, bootCol
    if not Boot.wait then
        bootState, bootCol = "off - next inject runs immediately", C.dim
    elseif #Boot.missing > 0 then
        bootState, bootCol = "gave up on " .. table.concat(Boot.missing, ", "), C.bad
    elseif Boot.took < 0.4 then
        bootState, bootCol = "already loaded - no wait", C.good
    else
        bootState, bootCol = ("waited %.1fs for the place"):format(Boot.took), C.good
    end
    local n = #Extra.list
    if n > 0 then
        bootState = bootState .. ("  ·  extra %d/%d"):format(Extra.ok, n)
        if Extra.bad > 0 then bootCol = C.gold end
    end
    bootLbl.Text = "boot: " .. bootState
    bootLbl.TextColor3 = bootCol

end

Anniv.start()
AutoExit.start()
Move.start()
Plaza.start()
Extra.load()

local tick = task.spawn(function()
    while Hub.alive do
        pcall(refresh)
        task.wait(0.5)
    end
end)

if Boot.skipped then
    log("boot: skipped - wait for game load is off")
elseif #Boot.missing > 0 then
    log("boot: gave up waiting for " .. table.concat(Boot.missing, ", "))
else
    log(("boot: ready in %.1fs"):format(Boot.took))
end
log(("started: %s  place %d"):format(LP.Name, game.PlaceId))
pcall(refresh)

--=============================================================
-- API + DESTROY
--=============================================================
local api = {}
api.Hub       = Hub
api.Gui       = gui
api.Anniv     = Anniv
api.Roster    = Roster   -- exposed so the sort can be tested with stubbed scores
api.AutoExit  = AutoExit
api.Move      = Move
api.Plaza     = Plaza
api.Show      = function(v) frame.Visible = (v ~= false) end
api.Toggle    = function() frame.Visible = not frame.Visible end
api.SetMin    = setMin
api.JoinNow   = function() pcall(Anniv.step, true) end
api.ExitNow   = function() return AutoExit.fire() end
api.Log       = function() return table.concat(Hub.log, "\n") end
api.Boot      = Boot
api.SetBoot   = function(v) bootSw.set(v) end
api.Build     = CFG.Build
api.URL       = CFG.ReloadURL
api.Extra     = Extra
api.LoadExtra = function() Extra.load() end

function api.destroy()
    Hub.alive = false
    for _, c in ipairs(Hub.conns) do pcall(function() c:Disconnect() end) end
    Hub.conns = {}
    for _, t in ipairs(Hub.threads) do pcall(function() task.cancel(t) end) end
    Hub.threads = {}
    pcall(function() task.cancel(tick) end)
    pcall(function() if Plaza._thread then task.cancel(Plaza._thread) end end)
    pcall(function() if Anniv.thread then task.cancel(Anniv.thread) end end)
    pcall(function() if AutoExit._watch then task.cancel(AutoExit._watch) end end)
    pcall(function() if gui then gui:Destroy() end end)
    if getgenv().STD_Mini == api then getgenv().STD_Mini = nil end
end

Hub.destroy = api.destroy
getgenv().STD_Mini = api

--=============================================================
-- SURVIVE THE TELEPORT
--=============================================================
-- both things this hub does end in a place change: the join teleports into the
-- event and the exit teleports back out. a script that dies there leaves the
-- next round unattended, which is the whole point of the hub. so it queues
-- itself for the next teleport - every load re-arms, so the chain holds for the
-- whole session.
--
-- two sources, in order: the copy in the executor workspace (instant, works
-- offline, and it is the build you just edited), then the published file on
-- GitHub. the second one is what makes a plain loadstring enough: nothing has
-- to be saved locally for the hub to come back after a join
local SELF_FILE = "STD_Mini.luau"

local function armReload()
    if type(queue_on_teleport) ~= "function" then return false end
    local hasFile = type(isfile) ~= "function" or isfile(SELF_FILE)
    local url = CFG.ReloadURL or ""
    if not hasFile and url == "" then return false end
    local body = ([[task.wait(2.5) local src = nil ]] ..
        [[if type(readfile) == "function" then ]] ..
        [[local ok, s = pcall(readfile, "%s") ]] ..
        [[if ok and type(s) == "string" and #s > 2000 then src = s end end ]] ..
        [[if not src and type(game.HttpGet) == "function" then ]] ..
        [[local ok, s = pcall(function() return game:HttpGet("%s") end) ]] ..
        [[if ok and type(s) == "string" and #s > 2000 then src = s end end ]] ..
        [[if src then local fn = loadstring(src) if fn then pcall(fn) end end ]]):format(SELF_FILE, url)
    local ok = pcall(queue_on_teleport, body)
    return ok
end

local armed = armReload()
if armed then
    log("reload armed: " .. (type(isfile) == "function" and isfile(SELF_FILE)
        and SELF_FILE or CFG.ReloadURL))
else
    log("reload NOT armed - no self file and no URL, the hub ends at the next teleport")
end
api.Rearm = armReload

return api
