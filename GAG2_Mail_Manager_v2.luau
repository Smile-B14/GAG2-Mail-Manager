-- Grow a Garden 2 - Mail Manager v2
-- Exact asset-catalog discovery, authoritative harvested-fruit inventory,
-- live fruit values, large mail payloads, and non-blocking send responses.

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local ENV = getgenv and getgenv() or _G
local STATE_KEY = "SmileB_GAG2MailManager"
local HISTORY_KEY = "SmileB_GAG2MailHistory"
local HISTORY_FILE = "SmileB_GAG2_MailHistory.json"

if ENV[STATE_KEY] and ENV[STATE_KEY].Cleanup then
	pcall(ENV[STATE_KEY].Cleanup)
	task.wait()
end

local State = {
	Dead = false,
	Sending = false,
	SendToken = 0,
	Connections = {},
	Gui = nil,
	Resolved = nil,
	Queue = {},
	Filter = "All",
	InventoryCache = {},
	InventoryScanToken = 0,
	InventoryScanning = false,
	InventoryRefreshRequested = false,
	PlantCatalog = {
		Names = {},
		Display = {},
		Ready = false,
		Scanning = false,
		ScanToken = 0,
	},
	Stock = {
		Entries = {},
		NextRefreshUnix = 0,
		CycleSeconds = 600,
		ClockOffset = 0,
		RequestInFlight = false,
		RequestToken = 0,
		NextRequestClock = 0,
		RetrySeconds = 15,
		TimeoutSeconds = 12,
		LastError = nil,
	},
}
ENV[STATE_KEY] = State

local function track(connection)
	State.Connections[#State.Connections + 1] = connection
	return connection
end

local function cleanup()
	if State.Dead then return end
	State.Dead = true
	State.SendToken += 1
	State.InventoryScanToken += 1
	for _, connection in ipairs(State.Connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(State.Connections)
	if State.Gui then State.Gui:Destroy() end
	if ENV[STATE_KEY] == State then ENV[STATE_KEY] = nil end
end
State.Cleanup = cleanup

-- Live game modules and packet endpoints.
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local ClientModules = ReplicatedStorage:WaitForChild("ClientModules")
local Controllers = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controllers")
local MailboxControllerModule = Controllers:WaitForChild("MailboxController")
local PacketModule = SharedModules:WaitForChild("Packet")
local Packet = require(PacketModule)
local PacketRemote = PacketModule:WaitForChild("RemoteEvent")

for _, packetName in ipairs({ "MailboxSendBatch", "MailboxLookupPlayer", "FruitStockSnapshot", "FruitStockRequest" }) do
	local deadline = os.clock() + 30
	while PacketRemote:GetAttribute(packetName) == nil and os.clock() < deadline do
		task.wait(0.05)
	end
	assert(PacketRemote:GetAttribute(packetName) ~= nil, "Timed out waiting for network packet: " .. packetName)
end

local Networking = {
	Mailbox = {
		SendBatch = Packet("MailboxSendBatch", Packet.NumberF64, Packet.Any, Packet.String):Response(Packet.Boolean8, Packet.String),
		LookupPlayer = Packet("MailboxLookupPlayer", Packet.String):Response(Packet.NumberF64, Packet.String),
	},
	FruitStock = {
		Snapshot = Packet("FruitStockSnapshot", Packet.Any),
		Request = Packet("FruitStockRequest"):Response(Packet.Any),
	},
}

local PlayerStateClientModule = ClientModules:WaitForChild("PlayerStateClient")
local function validInventoryReplica(candidate)
	return type(candidate) == "table" and type(candidate.Data) == "table" and type(candidate.Data.Inventory) == "table"
end
local function replicaFromClient(client)
	if type(client) ~= "table" or type(client.GetLocalReplica) ~= "function" then return nil end
	local ok, candidate = pcall(client.GetLocalReplica, client)
	if ok and validInventoryReplica(candidate) then return candidate end
	return nil
end
local function findLoadedPlayerStateClient()
	if type(getgc) ~= "function" then return nil, nil end
	local ok, objects = pcall(getgc, true)
	if not ok or type(objects) ~= "table" then ok, objects = pcall(getgc) end
	if not ok or type(objects) ~= "table" then return nil, nil end
	local fallbackClient
	for index, object in ipairs(objects) do
		if type(object) == "table" and type(rawget(object, "GetLocalReplica")) == "function" and type(rawget(object, "WaitForLocalReplica")) == "function" then
			fallbackClient = fallbackClient or object
			local candidate = replicaFromClient(object)
			if candidate then return object, candidate end
		end
		if index % 500 == 0 then task.wait() end
	end
	return fallbackClient, nil
end
local function requirePlayerStateClient()
	if type(getrenv) == "function" then
		local envOk, gameEnvironment = pcall(getrenv)
		if envOk and type(gameEnvironment) == "table" and type(gameEnvironment.require) == "function" then
			local ok, client = pcall(gameEnvironment.require, PlayerStateClientModule)
			if ok and type(client) == "table" then return client end
		end
	end
	local ok, client = pcall(require, PlayerStateClientModule)
	if ok and type(client) == "table" then return client end
	return nil
end
local PlayerStateClient, Replica = findLoadedPlayerStateClient()
if not PlayerStateClient then PlayerStateClient = requirePlayerStateClient() end

local MailboxItemCatalog = require(MailboxControllerModule:WaitForChild("MailboxItemCatalog"))
local FruitValueCalc = require(SharedModules:WaitForChild("FruitValueCalc"))
local MutationData = require(SharedModules:WaitForChild("MutationData"))
local WeightFormat = require(SharedModules:WaitForChild("WeightFormat"))
local MailboxFlags = require(SharedModules:WaitForChild("Flags"):WaitForChild("MailboxFlags"))

local replicaDeadline = os.clock() + 60
local nextLoadedClientScan = 0
while not validInventoryReplica(Replica) and os.clock() < replicaDeadline do
	Replica = replicaFromClient(PlayerStateClient)
	if validInventoryReplica(Replica) then break end
	if os.clock() >= nextLoadedClientScan then
		local loadedClient, loadedReplica = findLoadedPlayerStateClient()
		if loadedClient then PlayerStateClient, Replica = loadedClient, loadedReplica end
		nextLoadedClientScan = os.clock() + 2
	end
	if not validInventoryReplica(Replica) and PlayerStateClient and type(PlayerStateClient.WaitForLocalReplica) == "function" then
		local ok, candidate = pcall(PlayerStateClient.WaitForLocalReplica, PlayerStateClient, 1)
		if ok and validInventoryReplica(candidate) then Replica = candidate end
	else
		task.wait(0.25)
	end
end
if not validInventoryReplica(Replica) then
	error("Could not attach to the game's live PlayerState replica. Rejoin, wait for the normal inventory UI to load, then execute again.")
end

local FRUIT_CATEGORY = "HarvestedFruits"
local NOTE_CODEPOINT_LIMIT = 100
local SEND_RESPONSE_TIMEOUT = 8
local SEND_RECONCILE_SECONDS = 2.5
local HISTORY_LIMIT = 250
local CATALOG_ASSET_BATCH = 20
local UI_ROW_BATCH = 12

local COLORS = {
	Back = Color3.fromRGB(15, 18, 24), Panel = Color3.fromRGB(24, 29, 38), Panel2 = Color3.fromRGB(31, 38, 49),
	Line = Color3.fromRGB(57, 68, 84), Text = Color3.fromRGB(240, 244, 250), Muted = Color3.fromRGB(160, 173, 190),
	Green = Color3.fromRGB(82, 211, 133), Green2 = Color3.fromRGB(39, 142, 87), Blue = Color3.fromRGB(77, 148, 255),
	Red = Color3.fromRGB(235, 91, 101), Yellow = Color3.fromRGB(244, 194, 88),
}

local function new(className, properties, parent)
	local object = Instance.new(className)
	for key, value in pairs(properties or {}) do object[key] = value end
	object.Parent = parent
	return object
end
local function corner(parent, radius) return new("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent) end
local function stroke(parent, color, thickness)
	return new("UIStroke", { Color = color or COLORS.Line, Thickness = thickness or 1, Transparency = 0.15 }, parent)
end
local function label(parent, text, position, size, textSize, color, alignment)
	return new("TextLabel", {
		BackgroundTransparency = 1, Position = position, Size = size, Font = Enum.Font.Gotham,
		Text = text or "", TextColor3 = color or COLORS.Text, TextSize = textSize or 14,
		TextXAlignment = alignment or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, parent)
end
local function button(parent, text, position, size, color)
	local object = new("TextButton", {
		AutoButtonColor = true, BackgroundColor3 = color or COLORS.Panel2, Position = position, Size = size,
		Font = Enum.Font.GothamSemibold, Text = text, TextColor3 = COLORS.Text, TextSize = 13,
	}, parent)
	corner(object, 7)
	return object
end
local function box(parent, placeholder, position, size)
	local object = new("TextBox", {
		BackgroundColor3 = COLORS.Panel2, Position = position, Size = size, ClearTextOnFocus = false,
		Font = Enum.Font.Gotham, PlaceholderText = placeholder, PlaceholderColor3 = COLORS.Muted,
		Text = "", TextColor3 = COLORS.Text, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	corner(object, 7); stroke(object)
	new("UIPadding", { PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9) }, object)
	return object
end
local function scrolling(parent, position, size)
	local frame = new("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Position = position, Size = size,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
		ScrollBarImageColor3 = COLORS.Line,
	}, parent)
	new("UIListLayout", { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
	new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 2), PaddingRight = UDim.new(0, 5) }, frame)
	return frame
end
local function clearList(frame)
	for _, child in ipairs(frame:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
end
local function trim(value) return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function clampUtf8(value, maxCodepoints)
	value = tostring(value or "")
	local length = utf8.len(value)
	if length and length > maxCodepoints then
		local byte = utf8.offset(value, maxCodepoints + 1)
		if byte then return string.sub(value, 1, byte - 1) end
	end
	return value
end

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function formatNumber(value)
	value = tonumber(value) or 0
	local absolute = math.abs(value)
	if absolute < 1000 then return tostring(math.floor(value + 0.5)) end
	local tier = math.min(math.floor(math.log10(absolute) / 3), #SUFFIXES)
	local scaled = value / (1000 ^ tier)
	local formatted = string.format(scaled >= 100 and "%.0f%s" or scaled >= 10 and "%.1f%s" or "%.2f%s", scaled, SUFFIXES[tier])
	local numberPart, suffix = formatted:match("^([%-]?[%d%.]+)(%a+)$")
	if numberPart then numberPart = numberPart:gsub("(%..-)0+$", "%1"):gsub("%.$", ""); return numberPart .. suffix end
	return formatted
end
local function formatMultiplier(value)
	value = tonumber(value) or 1
	if math.abs(value - math.floor(value + 0.00001)) < 0.0001 then return tostring(math.floor(value + 0.00001)) .. "x" end
	return string.format("%.2fx", value):gsub("0+x", "x")
end

local function normalizeName(value)
	local text = string.lower(trim(value))
	text = text:gsub("%b[]", " ")
	text = text:gsub("[%p_]", " ")
	text = text:gsub("%s+", " ")
	text = trim(text)
	return text
end
local function stripSeedSuffix(name)
	return trim((name:gsub("%s+seeds?$", "")))
end

local NON_ITEM_CATALOG_KEYS = {
	name = true, displayname = true, fruitname = true, plantname = true, seedname = true, cropname = true,
	icon = true, image = true, price = true, basevalue = true, rarity = true, growthtime = true,
	weight = true, sizemultiplier = true, mutation = true, decayalpha = true, count = true,
	items = true, entries = true, categories = true, metadata = true, config = true, settings = true,
}
local function looksLikePlantName(value)
	if type(value) ~= "string" then return false end
	local display = trim(value)
	if #display < 2 or #display > 80 or not display:match("%a") then return false end
	if display:find("/", 1, true) or display:find("\\", 1, true) or display:find(".", 1, true) then return false end
	local normalized = normalizeName(display)
	if NON_ITEM_CATALOG_KEYS[normalized:gsub("%s+", "")] then return false end
	if #display >= 24 and display:match("^[%x_%-]+$") then return false end
	return true
end

local function addPlantName(name)
	if not looksLikePlantName(name) then return end
	local display = trim(name)
	local normalized = normalizeName(display)
	if normalized == "" then return end
	State.PlantCatalog.Names[normalized] = true
	State.PlantCatalog.Display[normalized] = State.PlantCatalog.Display[normalized] or display
	local withoutSeed = stripSeedSuffix(normalized)
	if withoutSeed ~= normalized and withoutSeed ~= "" then
		State.PlantCatalog.Names[withoutSeed] = true
		State.PlantCatalog.Display[withoutSeed] = State.PlantCatalog.Display[withoutSeed] or display:gsub("%s+[Ss]eeds?$", "")
	end
end

local rebuildInventoryUI
local rebuildQueueUI
local rebuildHistoryUI
local requestInventoryRefresh
local CatalogInfo

local function updateCatalogInfo()
	if not CatalogInfo then return end
	local count = 0; for _ in pairs(State.PlantCatalog.Names) do count += 1 end
	if State.PlantCatalog.Scanning then
		CatalogInfo.Text = string.format("Plant catalog: scanning exact game assets\n%s plant/fruit names found", formatNumber(count))
	else
		CatalogInfo.Text = string.format("Plant catalog: %s names loaded\nInventory updates automatically", formatNumber(count))
	end
end

local function scanAssetCatalog(token)
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	if not assets then return end
	local visited = 0
	for _, folderName in ipairs({ "Fruits", "Plants", "Seeds" }) do
		local folder = assets:FindFirstChild(folderName)
		if folder then
			for _, asset in ipairs(folder:GetChildren()) do
				if State.Dead or token ~= State.PlantCatalog.ScanToken then return end
				local name = folderName == "Seeds" and stripSeedSuffix(asset.Name) or asset.Name
				addPlantName(name)
				for _, attributeName in ipairs({ "FruitName", "PlantName", "SeedName", "CropName", "DisplayName" }) do
					local attribute = asset:GetAttribute(attributeName)
					if type(attribute) == "string" then addPlantName(stripSeedSuffix(attribute)) end
				end
				visited += 1
				if visited % CATALOG_ASSET_BATCH == 0 then updateCatalogInfo(); task.wait() end
			end
		end
	end
end

local function scanPlantCatalog()
	if State.PlantCatalog.Scanning then return end
	State.PlantCatalog.Scanning = true
	State.PlantCatalog.Ready = false
	State.PlantCatalog.ScanToken += 1
	local token = State.PlantCatalog.ScanToken
	scanAssetCatalog(token)
	if State.Dead or token ~= State.PlantCatalog.ScanToken then return end
	State.PlantCatalog.Scanning = false
	State.PlantCatalog.Ready = true
	updateCatalogInfo()
	if requestInventoryRefresh then requestInventoryRefresh() end
end

local function firstField(value, fields)
	if type(value) ~= "table" then return nil end
	for _, field in ipairs(fields) do if value[field] ~= nil then return value[field] end end
	return nil
end
local NAME_FIELDS = { "FruitName", "fruitName", "PlantName", "plantName", "CropName", "cropName", "Name", "name", "DisplayName", "displayName" }
local MUTATION_FIELDS = { "Mutation", "mutation", "MutationName", "mutationName" }
local WEIGHT_FIELDS = { "Weight", "weight", "WeightGrams", "weightGrams", "Grams", "grams" }
local SIZE_FIELDS = { "SizeMultiplier", "sizeMultiplier", "Size", "size" }
local DECAY_FIELDS = { "DecayAlpha", "decayAlpha", "Decay", "decay" }
local function isFavorited(value)
	return type(value) == "table" and value.IsFavorite == true
end

local function normalizeFruitEntry(entryValue, fallbackName)
	if type(entryValue) ~= "table" then return {} end
	local normalized = table.clone(entryValue)
	normalized.FruitName = firstField(entryValue, NAME_FIELDS) or fallbackName
	normalized.Mutation = firstField(entryValue, MUTATION_FIELDS)
	normalized.Weight = tonumber(firstField(entryValue, WEIGHT_FIELDS)) or 0
	normalized.SizeMultiplier = tonumber(firstField(entryValue, SIZE_FIELDS)) or 1
	normalized.DecayAlpha = tonumber(firstField(entryValue, DECAY_FIELDS))
	return normalized
end

local function bestCatalogMatch(rawName)
	local normalized = normalizeName(rawName)
	if normalized == "" then return nil end
	if State.PlantCatalog.Names[normalized] then return normalized end
	local best
	for catalogName in pairs(State.PlantCatalog.Names) do
		if #catalogName >= 3 and normalized:find(catalogName, 1, true) then
			if not best or #catalogName > #best then best = catalogName end
		end
	end
	return best
end
local function inventoryScanActive(token)
	return not State.Dead and token == State.InventoryScanToken
end

local function normalizeImage(image)
	if type(image) == "number" and image > 0 then return "rbxassetid://" .. tostring(math.floor(image)) end
	if type(image) == "string" then if image:match("^%d+$") then return "rbxassetid://" .. image end; return image end
	return ""
end
local function resolveItem(category, itemKey, entryValue)
	local fallbackName = tostring(itemKey); local fallbackImage = ""
	if type(entryValue) == "table" then
		fallbackName = tostring(entryValue.DisplayName or entryValue.FruitName or entryValue.Name or itemKey)
		fallbackImage = normalizeImage(entryValue.Icon or entryValue.Image or entryValue.IconId or entryValue.ImageId)
	end
	local ok, displayName, image = pcall(MailboxItemCatalog.Resolve, category, itemKey, entryValue)
	if not ok then return fallbackName, fallbackImage end
	image = normalizeImage(image)
	return tostring(displayName or fallbackName), image ~= "" and image or fallbackImage
end

local function stockMultiplier(fruitName)
	local entry = State.Stock.Entries[fruitName]
	if type(entry) == "table" then return tonumber(entry.multiplier) or 1 end
	local match = bestCatalogMatch(fruitName)
	if match then
		for name, stock in pairs(State.Stock.Entries) do if normalizeName(name) == match then return tonumber(stock.multiplier) or 1 end end
	end
	return 1
end
local function fruitBaseValue(entryValue, itemKey)
	local normalized = normalizeFruitEntry(entryValue, itemKey)
	local ok, result = pcall(FruitValueCalc, normalized.FruitName or itemKey, normalized.SizeMultiplier or 1, normalized.Mutation, LocalPlayer, normalized.DecayAlpha)
	return ok and type(result) == "number" and result or 0
end
local function fruitLiveValue(entryValue, itemKey)
	local normalized = normalizeFruitEntry(entryValue, itemKey)
	return math.floor(fruitBaseValue(normalized, itemKey) * stockMultiplier(normalized.FruitName or itemKey))
end
local function fruitDetails(entryValue, itemKey)
	local normalized = normalizeFruitEntry(entryValue, itemKey)
	local mutation = normalized.Mutation or "None"
	local mutationMultiplier = 1
	if mutation ~= "None" and mutation ~= "" then
		local ok, result = pcall(MutationData.ReturnPriceMultiplier, mutation)
		if ok and type(result) == "number" then mutationMultiplier = result end
	end
	local formattedWeight = "?"
	pcall(function() formattedWeight = WeightFormat.FormatGrams(tonumber(normalized.Weight) or 0) end)
	return string.format("%s | %s | size %s | mut %s | stock %s", mutation, formattedWeight, formatMultiplier(normalized.SizeMultiplier), formatMultiplier(mutationMultiplier), formatMultiplier(stockMultiplier(normalized.FruitName or itemKey)))
end

local function mailableCategories()
	local categories = {}
	if type(MailboxItemCatalog.Categories) == "table" then
		for _, category in ipairs(MailboxItemCatalog.Categories) do
			if type(category) == "string" and category ~= FRUIT_CATEGORY and category ~= "Pets" then categories[#categories + 1] = category end
		end
	end
	return categories
end
local function groupFor(category)
	if category == FRUIT_CATEGORY then return "Fruits" end
	if category == "Seeds" then return "Seeds" end
	return "Gears"
end

local function buildInventoryEntries(token)
	local output = {}; local inventory = Replica and Replica.Data and Replica.Data.Inventory or {}
	-- Match the official mailbox inventory loop exactly: stackable categories are
	-- numeric counts, Pets are not exposed here, and harvested fruit comes only
	-- from the authoritative Inventory.HarvestedFruits table.
	for _, category in ipairs(mailableCategories()) do
		if not inventoryScanActive(token) then return nil end
		local categoryData = inventory[category]
		if type(categoryData) == "table" then
			for itemKey, entryValue in pairs(categoryData) do
				if not inventoryScanActive(token) then return nil end
				local available = type(entryValue) == "number" and math.max(0, math.floor(entryValue)) or 0
				if available > 0 then
					local displayName, icon = resolveItem(category, itemKey, entryValue)
					output[#output + 1] = { Key = category .. "\31" .. tostring(itemKey), Category = category, Group = groupFor(category), ItemKey = itemKey, EntryValue = entryValue, Available = available, DisplayName = displayName, Icon = icon, LiveValue = 0 }
				end
			end
		end
		task.wait()
	end
	local harvested = inventory[FRUIT_CATEGORY]
	if type(harvested) == "table" then
		for itemKey, entryValue in pairs(harvested) do
			if not inventoryScanActive(token) then return nil end
			if type(entryValue) == "table" and entryValue.Id ~= nil and not isFavorited(entryValue) then
				local normalized = normalizeFruitEntry(entryValue, tostring(itemKey))
				local displayName, icon = resolveItem(FRUIT_CATEGORY, itemKey, normalized)
				output[#output + 1] = {
					Key = FRUIT_CATEGORY .. "\31" .. tostring(itemKey), Category = FRUIT_CATEGORY, Group = "Fruits",
					ItemKey = itemKey, EntryValue = normalized, Available = 1,
					DisplayName = displayName, Icon = icon, LiveValue = fruitLiveValue(normalized, itemKey),
				}
			end
		end
	end
	table.sort(output, function(a, b)
		if a.Group ~= b.Group then return a.Group < b.Group end
		if a.LiveValue ~= b.LiveValue then return a.LiveValue > b.LiveValue end
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)
	return output
end

local function queueUnits()
	local count = 0; for _, entry in pairs(State.Queue) do count += entry.Selected end; return count
end
local function queueFruitValue()
	local value = 0
	for _, entry in pairs(State.Queue) do if entry.Category == FRUIT_CATEGORY then value += (tonumber(entry.LiveValue) or fruitLiveValue(entry.EntryValue, entry.ItemKey)) * entry.Selected end end
	return value
end

-- History persistence.
local History = ENV[HISTORY_KEY]
if type(History) ~= "table" then
	History = {}
	if type(isfile) == "function" and type(readfile) == "function" then
		pcall(function()
			if isfile(HISTORY_FILE) then local decoded = HttpService:JSONDecode(readfile(HISTORY_FILE)); if type(decoded) == "table" then History = decoded end end
		end)
	end
end
ENV[HISTORY_KEY] = History
local function saveHistory()
	while #History > HISTORY_LIMIT do table.remove(History) end
	ENV[HISTORY_KEY] = History
	if type(writefile) == "function" then pcall(function() writefile(HISTORY_FILE, HttpService:JSONEncode(History)) end) end
end

-- UI.
local GuiParent = LocalPlayer:WaitForChild("PlayerGui")
if type(gethui) == "function" then local ok, result = pcall(gethui); if ok and typeof(result) == "Instance" then GuiParent = result end else pcall(function() GuiParent = CoreGui end) end
for _, root in ipairs({ LocalPlayer:FindFirstChildOfClass("PlayerGui"), GuiParent, CoreGui }) do
	if typeof(root) == "Instance" then pcall(function() for _, child in ipairs(root:GetChildren()) do if child:IsA("ScreenGui") and child.Name == "SmileB_GAG2MailManager" then child:Destroy() end end end) end
end
local ScreenGui = new("ScreenGui", { Name = "SmileB_GAG2MailManager", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, nil)
if syn and type(syn.protect_gui) == "function" then pcall(syn.protect_gui, ScreenGui) end
local parented = pcall(function() ScreenGui.Parent = GuiParent end); if not parented then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end
State.Gui = ScreenGui

local Window = new("Frame", { Name = "Window", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = COLORS.Back, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(1040, 660), ClipsDescendants = true }, ScreenGui)
corner(Window, 12); stroke(Window, COLORS.Line, 1.25)
local Scale = new("UIScale", { Scale = 1 }, Window)
local responsiveScale = 1; local transitionInProgress = false
local function updateScale()
	local camera = workspace.CurrentCamera; local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	responsiveScale = math.min(1, math.max(0.1, (viewport.X - 16) / 1040), math.max(0.1, (viewport.Y - 16) / 660))
	if not transitionInProgress then Scale.Scale = responsiveScale end
end
local viewportConnection
local function bindCamera()
	if viewportConnection then pcall(function() viewportConnection:Disconnect() end) end
	local camera = workspace.CurrentCamera; if camera then viewportConnection = track(camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)) end; updateScale()
end
bindCamera(); track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindCamera))

local Header = new("Frame", { BackgroundColor3 = COLORS.Panel, Size = UDim2.new(1, 0, 0, 48) }, Window)
label(Header, "GAG2 Mail Manager", UDim2.fromOffset(16, 0), UDim2.new(0, 300, 1, 0), 17, COLORS.Text)
local StockTimer = label(Header, "Fruit stock: loading...", UDim2.new(1, -420, 0, 0), UDim2.fromOffset(320, 48), 13, COLORS.Yellow, Enum.TextXAlignment.Right)
local MinimizeButton = button(Header, "-", UDim2.new(1, -82, 0, 8), UDim2.fromOffset(32, 32), COLORS.Panel2)
local CloseButton = button(Header, "X", UDim2.new(1, -42, 0, 8), UDim2.fromOffset(32, 32), COLORS.Red)
local MinimizedBubble = button(ScreenGui, "B", UDim2.new(1, -44, 0.5, 0), UDim2.fromOffset(58, 58), COLORS.Green2)
MinimizedBubble.Name = "MinimizedBubble"; MinimizedBubble.AnchorPoint = Vector2.new(0.5, 0.5); MinimizedBubble.Visible = false; MinimizedBubble.ZIndex = 50; MinimizedBubble.TextSize = 22; MinimizedBubble.Font = Enum.Font.GothamBold
corner(MinimizedBubble, 29); stroke(MinimizedBubble, COLORS.Green, 2); new("UIGradient", { Color = ColorSequence.new(COLORS.Green2, COLORS.Blue), Rotation = 45 }, MinimizedBubble)

local Nav = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 54), Size = UDim2.new(1, -24, 0, 34) }, Window)
local ComposeTab = button(Nav, "Compose", UDim2.fromOffset(0, 0), UDim2.fromOffset(110, 32), COLORS.Green2)
local HistoryTab = button(Nav, "History", UDim2.fromOffset(118, 0), UDim2.fromOffset(110, 32), COLORS.Panel2)
local Compose = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 94), Size = UDim2.new(1, -24, 1, -122) }, Window)
local HistoryPage = new("Frame", { BackgroundTransparency = 1, Position = Compose.Position, Size = Compose.Size, Visible = false }, Window)
local Status = label(Window, "Starting...", UDim2.new(0, 14, 1, -27), UDim2.new(1, -28, 0, 22), 12, COLORS.Muted)
local function setStatus(text, color) Status.Text = tostring(text or ""); Status.TextColor3 = color or COLORS.Muted end

local RecipientPanel = new("Frame", { BackgroundColor3 = COLORS.Panel, Size = UDim2.new(0, 244, 1, 0) }, Compose); corner(RecipientPanel, 10); stroke(RecipientPanel)
label(RecipientPanel, "Recipient", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 24), 15, COLORS.Text)
local UsernameBox = box(RecipientPanel, "Username", UDim2.fromOffset(12, 38), UDim2.new(1, -24, 0, 36))
local ResolveButton = button(RecipientPanel, "Resolve username", UDim2.fromOffset(12, 82), UDim2.new(1, -24, 0, 34), COLORS.Blue)
local Avatar = new("ImageLabel", { BackgroundColor3 = COLORS.Panel2, Position = UDim2.new(0.5, -42, 0, 132), Size = UDim2.fromOffset(84, 84), Image = "", Visible = false }, RecipientPanel); corner(Avatar, 42); stroke(Avatar)
local ResolvedName = label(RecipientPanel, "No recipient selected", UDim2.fromOffset(12, 226), UDim2.new(1, -24, 0, 44), 13, COLORS.Muted, Enum.TextXAlignment.Center); ResolvedName.TextWrapped = true
CatalogInfo = label(RecipientPanel, "Plant catalog: preparing...", UDim2.fromOffset(14, 300), UDim2.new(1, -28, 0, 120), 12, COLORS.Muted); CatalogInfo.TextWrapped = true; CatalogInfo.TextYAlignment = Enum.TextYAlignment.Top
local function resetRecipientUI(message, color) State.Resolved = nil; Avatar.Image = ""; Avatar.Visible = false; ResolveButton.Text = "Resolve username"; ResolvedName.Text = message or "No recipient selected"; ResolvedName.TextColor3 = color or COLORS.Muted end

local InventoryPanel = new("Frame", { BackgroundColor3 = COLORS.Panel, Position = UDim2.fromOffset(254, 0), Size = UDim2.new(0, 374, 1, 0) }, Compose); corner(InventoryPanel, 10); stroke(InventoryPanel)
label(InventoryPanel, "Inventory", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 24), 15, COLORS.Text)
local InventorySearch = box(InventoryPanel, "Search items", UDim2.fromOffset(12, 36), UDim2.new(1, -100, 0, 34))
local QuantityBox = box(InventoryPanel, "Qty", UDim2.new(1, -80, 0, 36), UDim2.fromOffset(68, 34)); QuantityBox.Text = "1"; QuantityBox.TextXAlignment = Enum.TextXAlignment.Center
local FilterBar = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 78), Size = UDim2.new(1, -24, 0, 31) }, InventoryPanel)
local FilterButtons = {}; for index, name in ipairs({ "All", "Fruits", "Seeds", "Gears" }) do FilterButtons[name] = button(FilterBar, name, UDim2.fromOffset((index - 1) * 86, 0), UDim2.fromOffset(80, 29), name == "All" and COLORS.Green2 or COLORS.Panel2) end
local InventoryList = scrolling(InventoryPanel, UDim2.fromOffset(10, 116), UDim2.new(1, -20, 1, -126))

local QueuePanel = new("Frame", { BackgroundColor3 = COLORS.Panel, Position = UDim2.fromOffset(638, 0), Size = UDim2.new(1, -638, 1, 0) }, Compose); corner(QueuePanel, 10); stroke(QueuePanel)
local QueueHeader = label(QueuePanel, "Queue: 0", UDim2.fromOffset(12, 7), UDim2.new(1, -95, 0, 25), 15, COLORS.Text)
local ClearButton = button(QueuePanel, "Clear", UDim2.new(1, -78, 0, 7), UDim2.fromOffset(66, 28), COLORS.Panel2)
local QueueValue = label(QueuePanel, "Selected fruit value: 0 Sheckles", UDim2.fromOffset(12, 35), UDim2.new(1, -24, 0, 23), 13, COLORS.Green)
local QueueList = scrolling(QueuePanel, UDim2.fromOffset(10, 64), UDim2.new(1, -20, 1, -210))
local NoteBox = box(QueuePanel, "Optional note", UDim2.new(0, 12, 1, -136), UDim2.new(1, -24, 0, 58)); NoteBox.MultiLine = true; NoteBox.TextWrapped = true; NoteBox.TextYAlignment = Enum.TextYAlignment.Top
local NoteCounter = label(QueuePanel, "0/100", UDim2.new(1, -90, 1, -77), UDim2.fromOffset(76, 18), 11, COLORS.Muted, Enum.TextXAlignment.Right)
local SendButton = button(QueuePanel, "Send queued items", UDim2.new(0, 12, 1, -52), UDim2.new(1, -24, 0, 40), COLORS.Green2)
local HistorySearch = box(HistoryPage, "Search history", UDim2.fromOffset(0, 0), UDim2.new(1, -126, 0, 38))
local ClearHistoryButton = button(HistoryPage, "Clear history", UDim2.new(1, -116, 0, 0), UDim2.fromOffset(116, 38), COLORS.Panel2)
local HistoryList = scrolling(HistoryPage, UDim2.fromOffset(0, 48), UDim2.new(1, 0, 1, -48))

local inventoryUiToken = 0
local function requestedQuantity()
	local number = tonumber(QuantityBox.Text)
	if not number or number ~= number or number <= 0 then return 1 end
	return math.max(1, math.floor(number))
end
local function queueAdd(item)
	if State.Sending then setStatus("Stop sending before editing the queue", COLORS.Yellow); return end
	local current = State.Queue[item.Key]; local already = current and current.Selected or 0
	local amount = math.min(requestedQuantity(), math.max(0, item.Available - already))
	if amount <= 0 then setStatus("That item is already fully queued", COLORS.Yellow); return end
	if not current then current = { Key = item.Key, Category = item.Category, ItemKey = item.ItemKey, EntryValue = item.EntryValue, DisplayName = item.DisplayName, Icon = item.Icon, LiveValue = item.LiveValue, Selected = 0 }; State.Queue[item.Key] = current end
	current.Selected += amount; setStatus(string.format("Queued %s x%s", item.DisplayName, formatNumber(amount)), COLORS.Green); rebuildInventoryUI(); rebuildQueueUI()
end
local function queueRemove(key, amount)
	if State.Sending then return end
	local entry = State.Queue[key]; if not entry then return end
	entry.Selected -= amount or 1; if entry.Selected <= 0 then State.Queue[key] = nil end; rebuildInventoryUI(); rebuildQueueUI()
end

rebuildInventoryUI = function()
	if State.Dead then return end
	inventoryUiToken += 1; local token = inventoryUiToken; clearList(InventoryList)
	local query = string.lower(trim(InventorySearch.Text)); local entries = State.InventoryCache; local filtered = {}
	for _, item in ipairs(entries) do
		local queued = State.Queue[item.Key] and State.Queue[item.Key].Selected or 0; local remaining = math.max(0, item.Available - queued)
		local searchable = string.lower(item.DisplayName .. " " .. item.Category .. " " .. item.Group)
		if remaining > 0 and (State.Filter == "All" or State.Filter == item.Group) and (query == "" or searchable:find(query, 1, true)) then filtered[#filtered + 1] = { item = item, remaining = remaining } end
	end
	task.spawn(function()
		if #filtered == 0 then local empty = label(InventoryList, State.PlantCatalog.Scanning and "Scanning plants and inventory..." or "No matching items", UDim2.new(), UDim2.new(1, -4, 0, 50), 13, COLORS.Muted, Enum.TextXAlignment.Center); empty.LayoutOrder = 1; return end
		for index, wrapped in ipairs(filtered) do
			if State.Dead or token ~= inventoryUiToken then return end
			local item, remaining = wrapped.item, wrapped.remaining
			local row = new("Frame", { BackgroundColor3 = COLORS.Panel2, Size = UDim2.new(1, -4, 0, 82), LayoutOrder = index }, InventoryList); corner(row, 8)
			local icon = new("ImageLabel", { BackgroundColor3 = COLORS.Back, Position = UDim2.fromOffset(7, 10), Size = UDim2.fromOffset(62, 62), Image = item.Icon }, row); corner(icon, 7)
			local nameLabel = label(row, item.DisplayName, UDim2.fromOffset(78, 5), UDim2.new(1, -155, 0, 22), 13, COLORS.Text); nameLabel.Font = Enum.Font.GothamSemibold
			local detail = item.Category == FRUIT_CATEGORY and (fruitDetails(item.EntryValue, item.ItemKey) .. "\n" .. formatNumber(item.LiveValue) .. " each | " .. formatNumber(remaining) .. " available") or (item.Category .. " | available " .. formatNumber(remaining))
			local detailLabel = label(row, detail, UDim2.fromOffset(78, 27), UDim2.new(1, -155, 0, 49), 10, item.Category == FRUIT_CATEGORY and COLORS.Green or COLORS.Muted); detailLabel.TextWrapped = true; detailLabel.TextYAlignment = Enum.TextYAlignment.Top
			local add = button(row, item.Category == FRUIT_CATEGORY and "+ Fruit" or "+ Qty", UDim2.new(1, -70, 0.5, -16), UDim2.fromOffset(62, 32), COLORS.Green2); add.Activated:Connect(function() queueAdd(item) end)
			if index % UI_ROW_BATCH == 0 then task.wait() end
		end
	end)
end

rebuildQueueUI = function()
	if State.Dead then return end
	clearList(QueueList); local entries = {}; for _, entry in pairs(State.Queue) do entries[#entries + 1] = entry end; table.sort(entries, function(a, b) return string.lower(a.DisplayName) < string.lower(b.DisplayName) end)
	for index, entry in ipairs(entries) do
		local row = new("Frame", { BackgroundColor3 = COLORS.Panel2, Size = UDim2.new(1, -4, 0, 68), LayoutOrder = index }, QueueList); corner(row, 8)
		local icon = new("ImageLabel", { BackgroundColor3 = COLORS.Back, Position = UDim2.fromOffset(6, 7), Size = UDim2.fromOffset(53, 53), Image = entry.Icon }, row); corner(icon, 7)
		local nameLabel = label(row, entry.DisplayName, UDim2.fromOffset(68, 5), UDim2.new(1, -142, 0, 22), 12, COLORS.Text); nameLabel.Font = Enum.Font.GothamSemibold
		local detail = "x" .. formatNumber(entry.Selected)
		if entry.Category == FRUIT_CATEGORY then local each = tonumber(entry.LiveValue) or fruitLiveValue(entry.EntryValue, entry.ItemKey); detail ..= " | each " .. formatNumber(each) .. " | selected " .. formatNumber(each * entry.Selected) end
		label(row, detail, UDim2.fromOffset(68, 29), UDim2.new(1, -142, 0, 31), 10, entry.Category == FRUIT_CATEGORY and COLORS.Green or COLORS.Muted)
		local remove = button(row, "-", UDim2.new(1, -66, 0, 8), UDim2.fromOffset(27, 27), COLORS.Panel); local removeAll = button(row, "X", UDim2.new(1, -34, 0, 8), UDim2.fromOffset(27, 27), COLORS.Red)
		remove.Activated:Connect(function() queueRemove(entry.Key, 1) end); removeAll.Activated:Connect(function() queueRemove(entry.Key, entry.Selected) end)
	end
	QueueHeader.Text = "Queue: " .. formatNumber(queueUnits()); QueueValue.Text = "Selected fruit value: " .. formatNumber(queueFruitValue()) .. " Sheckles"
	if #entries == 0 then local empty = label(QueueList, "Queue is empty", UDim2.new(), UDim2.new(1, -4, 0, 50), 13, COLORS.Muted, Enum.TextXAlignment.Center); empty.LayoutOrder = 1 end
end

rebuildHistoryUI = function()
	if State.Dead then return end
	clearList(HistoryList); local query = string.lower(trim(HistorySearch.Text)); local shown = 0
	for historyIndex, entry in ipairs(History) do
		local searchable = string.lower(tostring(entry.RecipientName or "") .. " " .. tostring(entry.Username or "") .. " " .. tostring(entry.Note or "") .. " " .. HttpService:JSONEncode(entry.Items or {}))
		if query == "" or searchable:find(query, 1, true) then
			shown += 1; local row = new("Frame", { BackgroundColor3 = COLORS.Panel, Size = UDim2.new(1, -4, 0, 92), LayoutOrder = shown }, HistoryList); corner(row, 9); stroke(row)
			local titleLabel = label(row, string.format("To %s (@%s) | %s", entry.RecipientName or "Player", entry.Username or "?", os.date("%Y-%m-%d %H:%M", tonumber(entry.Time) or os.time())), UDim2.fromOffset(12, 7), UDim2.new(1, -90, 0, 22), 13, COLORS.Text); titleLabel.Font = Enum.Font.GothamSemibold
			label(row, string.format("%s items | %s Sheckles | %s", formatNumber(entry.Units or 0), formatNumber(entry.TotalValue or 0), tostring(entry.Status or "Done")), UDim2.fromOffset(12, 30), UDim2.new(1, -24, 0, 20), 11, COLORS.Green)
			local summaries = {}; for _, item in ipairs(entry.Items or {}) do summaries[#summaries + 1] = tostring(item.Name) .. " x" .. formatNumber(item.Count) end
			local summaryLabel = label(row, table.concat(summaries, ", "), UDim2.fromOffset(12, 52), UDim2.new(1, -100, 0, 32), 11, COLORS.Muted); summaryLabel.TextWrapped = true
			local delete = button(row, "Delete", UDim2.new(1, -72, 0, 7), UDim2.fromOffset(60, 25), COLORS.Panel2); delete.Activated:Connect(function() table.remove(History, historyIndex); saveHistory(); rebuildHistoryUI() end)
		end
	end
	if shown == 0 then local empty = label(HistoryList, "No matching mail history", UDim2.new(), UDim2.new(1, -4, 0, 60), 13, COLORS.Muted, Enum.TextXAlignment.Center); empty.LayoutOrder = 1 end
end

requestInventoryRefresh = function()
	if State.Dead then return end
	State.InventoryRefreshRequested = true
	if State.InventoryScanning then return end
	State.InventoryScanning = true
	task.spawn(function()
		while not State.Dead and State.InventoryRefreshRequested do
			State.InventoryRefreshRequested = false
			State.InventoryScanToken += 1; local token = State.InventoryScanToken
			task.wait(0.03)
			if State.Dead or token ~= State.InventoryScanToken then break end
			local ok, entries = pcall(buildInventoryEntries, token)
			if ok and type(entries) == "table" and not State.Dead and token == State.InventoryScanToken then
				State.InventoryCache = entries
				local currentByKey = {}; for _, item in ipairs(entries) do currentByKey[item.Key] = item end
				for key, queued in pairs(State.Queue) do
					local current = currentByKey[key]
					if current then
						queued.EntryValue = current.EntryValue; queued.DisplayName = current.DisplayName; queued.Icon = current.Icon; queued.LiveValue = current.LiveValue
					elseif not State.Sending then
						State.Queue[key] = nil
					end
				end
				rebuildInventoryUI(); rebuildQueueUI()
			end
		end
		State.InventoryScanning = false
		if State.InventoryRefreshRequested and not State.Dead then requestInventoryRefresh() end
	end)
end

-- Stock snapshots also contribute names to the runtime catalog.
local function applyStockSnapshot(snapshot)
	if type(snapshot) ~= "table" then return end
	State.Stock.LastError = nil
	if type(snapshot.entries) == "table" then
		local entries = {}
		for fruitName, entry in pairs(snapshot.entries) do
			if type(fruitName) == "string" and type(entry) == "table" then entries[fruitName] = { multiplier = tonumber(entry.multiplier) or 1, tier = tostring(entry.tier or "normal") } end
		end
		State.Stock.Entries = entries
	end
	State.Stock.NextRefreshUnix = tonumber(snapshot.nextRefreshUnix) or State.Stock.NextRefreshUnix; State.Stock.CycleSeconds = tonumber(snapshot.cycleSeconds) or State.Stock.CycleSeconds
	if type(snapshot.server_now_unix) == "number" then State.Stock.ClockOffset = snapshot.server_now_unix - os.time() end
	updateCatalogInfo(); requestInventoryRefresh()
end
local function requestStockSnapshot()
	if State.Dead or State.Stock.RequestInFlight or os.clock() < State.Stock.NextRequestClock then return end
	State.Stock.RequestInFlight = true; State.Stock.RequestToken += 1; State.Stock.NextRequestClock = os.clock() + State.Stock.RetrySeconds; local token = State.Stock.RequestToken
	task.spawn(function()
		local ok, snapshot = pcall(function() return Networking.FruitStock.Request:Fire() end)
		if State.Dead or token ~= State.Stock.RequestToken then return end
		State.Stock.RequestInFlight = false; if ok then applyStockSnapshot(snapshot) else State.Stock.LastError = "request failed" end
	end)
	task.spawn(function() task.wait(State.Stock.TimeoutSeconds); if not State.Dead and token == State.Stock.RequestToken and State.Stock.RequestInFlight then State.Stock.RequestToken += 1; State.Stock.RequestInFlight = false; State.Stock.LastError = "request timed out" end end)
end
local function updateStockTimer()
	local nextRefresh = State.Stock.NextRefreshUnix
	if nextRefresh <= 0 then StockTimer.Text = State.Stock.RequestInFlight and "Fruit Price Stock: refreshing..." or "Fruit stock: loading..."; return end
	local remaining = math.max(0, math.floor(nextRefresh - (os.time() + State.Stock.ClockOffset))); StockTimer.Text = string.format("Fruit Price Stock refresh in %dm %02ds", remaining // 60, remaining % 60)
end

-- Recipient lookup.
local resolveToken = 0
local function resolveRecipient()
	local username = trim(UsernameBox.Text):gsub("^@", "")
	if #username < 3 or #username > 20 or not username:match("^[%w_]+$") then resetRecipientUI("Enter a valid username", COLORS.Red); return end
	resolveToken += 1; local token = resolveToken; resetRecipientUI("Looking up @" .. username, COLORS.Muted); ResolveButton.Text = "Resolving..."
	local finished = false
	task.spawn(function()
		local ok, userId, displayName = pcall(function() return Networking.Mailbox.LookupPlayer:Fire(username) end)
		if State.Dead or token ~= resolveToken then return end; finished = true
		if not ok or type(userId) ~= "number" or userId <= 0 then resetRecipientUI("Player not found", COLORS.Red); return end
		if userId == LocalPlayer.UserId then resetRecipientUI("You cannot mail yourself", COLORS.Red); return end
		State.Resolved = { UserId = userId, Username = username, DisplayName = type(displayName) == "string" and displayName ~= "" and displayName or username }; ResolveButton.Text = "Resolve username"; ResolvedName.Text = State.Resolved.DisplayName .. "\n@" .. username; ResolvedName.TextColor3 = COLORS.Green; setStatus("Recipient resolved", COLORS.Green)
		local imageOk, image = pcall(Players.GetUserThumbnailAsync, Players, userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150); if imageOk and token == resolveToken then Avatar.Image = image; Avatar.Visible = true end
	end)
	task.spawn(function() task.wait(10); if not State.Dead and token == resolveToken and not finished then resolveToken += 1; resetRecipientUI("Lookup timed out", COLORS.Red) end end)
end

local function inventoryAvailabilityMap()
	local map = {}; for _, item in ipairs(State.InventoryCache) do map[item.Key] = item.Available end; return map
end
local function queuePayloadAndPortions()
	local payload = {}; local portions = {}
	for key, entry in pairs(State.Queue) do
		if entry.Selected > 0 then
			local unitValue = entry.Category == FRUIT_CATEGORY and (tonumber(entry.LiveValue) or fruitLiveValue(entry.EntryValue, entry.ItemKey)) or 0
			payload[#payload + 1] = { Category = entry.Category, ItemKey = entry.ItemKey, Count = entry.Selected }
			portions[#portions + 1] = { Key = key, Entry = entry, Count = entry.Selected, UnitValue = unitValue }
		end
	end
	return payload, portions
end
local function sendActive(token)
	return not State.Dead and State.Sending and token == State.SendToken
end
local function responseWithTimeout(userId, payload, note, token)
	local result = { done = false }
	task.spawn(function()
		local ok, success, message = pcall(function() return Networking.Mailbox.SendBatch:Fire(userId, payload, note) end)
		result.ok, result.success, result.message, result.done = ok, success, message, true
	end)
	local started = os.clock()
	while not result.done and sendActive(token) and os.clock() - started < SEND_RESPONSE_TIMEOUT do task.wait(0.05) end
	if token ~= State.SendToken or not State.Sending then return "cancelled" end
	if State.Dead then return "dead" end
	if not result.done then return "timeout" end
	if not result.ok then return "error", false, result.message end
	return "response", result.success == true, result.message
end
local function reconcileDelivered(portions, before, token)
	local deadline = os.clock() + SEND_RECONCILE_SECONDS
	while os.clock() < deadline and sendActive(token) do
		requestInventoryRefresh(); task.wait(0.35)
		if not sendActive(token) then return nil end
		local after = inventoryAvailabilityMap(); local allDropped = true
		for _, portion in ipairs(portions) do
			local old = before[portion.Key] or 0; local now = after[portion.Key] or 0
			if now > math.max(0, old - portion.Count) then allDropped = false; break end
		end
		if allDropped then return true end
	end
	if not sendActive(token) then return nil end
	return false
end
local function resetSendUi()
	State.Sending = false
	pcall(function() SendButton.Text = "Send queued items"; SendButton.BackgroundColor3 = COLORS.Green2; ClearButton.Active = true end)
end
local function recordSent(recipient, note, portions, status)
	local items = {}; local units = 0; local totalValue = 0
	for _, portion in ipairs(portions) do
		local entry, count = portion.Entry, portion.Count; units += count; local value = (tonumber(portion.UnitValue) or 0) * count; totalValue += value
		items[#items + 1] = { Name = entry.DisplayName, Category = entry.Category, Icon = entry.Icon, Count = count, Value = value }
	end
	table.insert(History, 1, { Time = os.time(), RecipientName = recipient.DisplayName, Username = recipient.Username, UserId = recipient.UserId, Note = note, Items = items, Units = units, Batches = 1, TotalValue = totalValue, Status = status }); saveHistory()
end
local function recordSentSafely(recipient, note, portions, status)
	local ok, message = pcall(recordSent, recipient, note, portions, status)
	if not ok then warn("GAG2 Mail Manager: delivery succeeded, but local history could not be saved: " .. tostring(message)) end
end
local function consumeQueue(portions)
	for _, portion in ipairs(portions) do
		local queued = State.Queue[portion.Key]
		if queued then queued.Selected -= portion.Count; if queued.Selected <= 0 then State.Queue[portion.Key] = nil end end
	end
end

local function beginSend()
	if State.Sending then
		State.SendToken += 1; resetSendUi(); requestInventoryRefresh(); setStatus("Stopped locally. Any late server response will be ignored; inventory is refreshing.", COLORS.Yellow); return
	end
	if not State.Resolved then setStatus("Resolve a recipient first", COLORS.Red); return end
	if not MailboxFlags.OpenEnabled:Get() then setStatus("The game's mailbox is currently unavailable", COLORS.Red); return end
	if queueUnits() <= 0 then setStatus("Queue at least one item", COLORS.Red); return end
	local before = inventoryAvailabilityMap()
	for key, entry in pairs(State.Queue) do if entry.Selected > (before[key] or 0) then setStatus("Inventory changed: re-add " .. entry.DisplayName, COLORS.Red); requestInventoryRefresh(); return end end
	local payload, portions = queuePayloadAndPortions(); if #payload == 0 then return end
	local recipient = { UserId = State.Resolved.UserId, Username = State.Resolved.Username, DisplayName = State.Resolved.DisplayName }; local note = clampUtf8(NoteBox.Text, NOTE_CODEPOINT_LIMIT)
	State.Sending = true; State.SendToken += 1; local token = State.SendToken; SendButton.Text = "STOP"; SendButton.BackgroundColor3 = COLORS.Red; ClearButton.Active = false
	setStatus(string.format("Sending %s queued items in one request...", formatNumber(queueUnits())), COLORS.Yellow)
	task.spawn(function()
		local deliveryConfirmed = false
		local safeOk, safeError = pcall(function()
			local kind, success, message = responseWithTimeout(recipient.UserId, payload, note, token)
			if kind == "cancelled" or kind == "dead" then return end
			if not sendActive(token) then return end
			if kind == "response" and success then
				if not sendActive(token) then return end
				deliveryConfirmed = true; consumeQueue(portions); recordSentSafely(recipient, note, portions, "Completed"); setStatus("Sent successfully", COLORS.Green); requestInventoryRefresh(); return
			end
			if kind == "timeout" or kind == "error" then
				setStatus("Server response did not finish; checking inventory...", COLORS.Yellow)
				local delivered = reconcileDelivered(portions, before, token)
				if delivered == nil or not sendActive(token) then return end
				if delivered then
					deliveryConfirmed = true; consumeQueue(portions); recordSentSafely(recipient, note, portions, "Completed (reconciled)"); setStatus("Sent successfully. Inventory confirmed the delivery.", COLORS.Green)
				else
					setStatus("Request finished without a usable response. Queue kept so you can verify before retrying.", COLORS.Red)
				end
				return
			end
			setStatus(type(message) == "string" and message ~= "" and message or "Server rejected the request", COLORS.Red)
		end)
		if State.Dead or token ~= State.SendToken then return end
		resetSendUi(); pcall(rebuildInventoryUI); pcall(rebuildQueueUI)
		if not safeOk then
			if deliveryConfirmed then
				pcall(setStatus, "Sent successfully", COLORS.Green)
			else
				pcall(setStatus, "Send UI recovered after an internal error: " .. tostring(safeError), COLORS.Red)
			end
		end
	end)
end

-- Minimize animation follows the current bubble position.
track(CloseButton.Activated:Connect(cleanup))
local minimized = false; local WINDOW_TWEEN = TweenInfo.new(0.34, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut); local BUBBLE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out); local windowRestorePosition = Window.Position
local function playTween(instance, info, goals) local tween = TweenService:Create(instance, info, goals); tween:Play(); return tween end
local function setMinimized(value)
	local shouldMinimize = value == true; if transitionInProgress or minimized == shouldMinimize then return end; transitionInProgress = true
	if shouldMinimize then
		minimized = true; windowRestorePosition = Window.Position; local target = MinimizedBubble.Position
		playTween(Scale, WINDOW_TWEEN, { Scale = math.max(0.035, responsiveScale * 0.055) }); local move = playTween(Window, WINDOW_TWEEN, { Position = target, Rotation = 540 }); move.Completed:Wait()
		if State.Dead then return end
		Window.Visible = false; Window.Rotation = 0; Window.Position = windowRestorePosition; Scale.Scale = responsiveScale; MinimizedBubble.Size = UDim2.fromOffset(10, 10); MinimizedBubble.Rotation = -180; MinimizedBubble.Visible = true; playTween(MinimizedBubble, BUBBLE_TWEEN, { Size = UDim2.fromOffset(58, 58), Rotation = 0 }).Completed:Wait()
	else
		local origin = MinimizedBubble.Position; playTween(MinimizedBubble, WINDOW_TWEEN, { Size = UDim2.fromOffset(10, 10), Rotation = 180 }).Completed:Wait(); if State.Dead then return end
		MinimizedBubble.Visible = false; MinimizedBubble.Size = UDim2.fromOffset(58, 58); MinimizedBubble.Rotation = 0; Window.Position = origin; Window.Visible = true; Window.Rotation = -540; Scale.Scale = math.max(0.035, responsiveScale * 0.055); playTween(Scale, BUBBLE_TWEEN, { Scale = responsiveScale }); playTween(Window, WINDOW_TWEEN, { Position = windowRestorePosition, Rotation = 0 }).Completed:Wait(); minimized = false
	end
	transitionInProgress = false
end
track(MinimizeButton.Activated:Connect(function() setMinimized(true) end))

local dragging, bubbleDragging, bubbleMoved = false, false, false; local dragStart, startPosition, bubbleDragStart, bubbleStartCenter
track(Header.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = true; dragStart = input.Position; startPosition = Window.Position end end))
track(MinimizedBubble.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then bubbleDragging = true; bubbleMoved = false; bubbleDragStart = input.Position; bubbleStartCenter = Vector2.new(MinimizedBubble.AbsolutePosition.X + MinimizedBubble.AbsoluteSize.X * 0.5, MinimizedBubble.AbsolutePosition.Y + MinimizedBubble.AbsoluteSize.Y * 0.5) end end))
track(UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then local delta = input.Position - dragStart; Window.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X / Scale.Scale, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y / Scale.Scale)
	elseif bubbleDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then local delta = input.Position - bubbleDragStart; if delta.Magnitude > 6 then bubbleMoved = true end; local camera = workspace.CurrentCamera; local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720); local radius = MinimizedBubble.AbsoluteSize.X * 0.5; MinimizedBubble.Position = UDim2.fromOffset(math.clamp(bubbleStartCenter.X + delta.X, radius + 8, viewport.X - radius - 8), math.clamp(bubbleStartCenter.Y + delta.Y, radius + 8, viewport.Y - radius - 8)) end
end))
track(UserInputService.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false; bubbleDragging = false end end))
track(MinimizedBubble.Activated:Connect(function() if not bubbleMoved then setMinimized(false) end end))
track(UserInputService.InputBegan:Connect(function(input, processed) if not processed and input.KeyCode == Enum.KeyCode.RightShift then ScreenGui.Enabled = not ScreenGui.Enabled end end))

local function showPage(name)
	local compose = name == "Compose"; Compose.Visible = compose; HistoryPage.Visible = not compose; ComposeTab.BackgroundColor3 = compose and COLORS.Green2 or COLORS.Panel2; HistoryTab.BackgroundColor3 = compose and COLORS.Panel2 or COLORS.Green2; if not compose then rebuildHistoryUI() end
end
track(ComposeTab.Activated:Connect(function() showPage("Compose") end)); track(HistoryTab.Activated:Connect(function() showPage("History") end)); track(ResolveButton.Activated:Connect(resolveRecipient)); track(UsernameBox.FocusLost:Connect(function(enterPressed) if enterPressed then resolveRecipient() end end))
track(UsernameBox:GetPropertyChangedSignal("Text"):Connect(function() resolveToken += 1; resetRecipientUI("No recipient selected", COLORS.Muted) end)); track(InventorySearch:GetPropertyChangedSignal("Text"):Connect(rebuildInventoryUI))
for name, filterButton in pairs(FilterButtons) do track(filterButton.Activated:Connect(function() State.Filter = name; for otherName, otherButton in pairs(FilterButtons) do otherButton.BackgroundColor3 = otherName == name and COLORS.Green2 or COLORS.Panel2 end; rebuildInventoryUI() end)) end
track(ClearButton.Activated:Connect(function() if not State.Sending then table.clear(State.Queue); rebuildInventoryUI(); rebuildQueueUI(); setStatus("Queue cleared") end end))
track(NoteBox:GetPropertyChangedSignal("Text"):Connect(function() local clamped = clampUtf8(NoteBox.Text, NOTE_CODEPOINT_LIMIT); if clamped ~= NoteBox.Text then NoteBox.Text = clamped end; NoteCounter.Text = tostring(utf8.len(NoteBox.Text) or #NoteBox.Text) .. "/100" end))
track(SendButton.Activated:Connect(beginSend)); track(HistorySearch:GetPropertyChangedSignal("Text"):Connect(rebuildHistoryUI)); track(ClearHistoryButton.Activated:Connect(function() table.clear(History); saveHistory(); rebuildHistoryUI() end))
track(Networking.FruitStock.Snapshot.OnClientEvent:Connect(applyStockSnapshot))

-- Slow/background refresh loops. No large one-frame catalog or inventory traversal.
requestStockSnapshot(); scanPlantCatalog(); requestInventoryRefresh(); rebuildInventoryUI(); rebuildQueueUI(); rebuildHistoryUI(); updateCatalogInfo()
task.spawn(function() while not State.Dead do updateStockTimer(); if not State.Sending then resetSendUi() end; if State.Stock.NextRefreshUnix <= os.time() + State.Stock.ClockOffset then requestStockSnapshot() end; task.wait(1) end end)
task.spawn(function() while not State.Dead do requestInventoryRefresh(); task.wait(1.35) end end)
setStatus("Ready. Building the live plant catalog in the background...", COLORS.Green)
