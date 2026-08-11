-- Grow a Garden 2 - Mail Manager
-- Grounded in the game's MailboxController, MailboxItemCatalog,
-- PlayerStateClient, FruitValueCalc, MutationData, and FruitStock protocols.
-- Executor-side LocalScript. Delta/Solara compatible.
-- Re-running cleans up the previous UI/loops.

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
	Stock = {
		Entries = {},
		NextRefreshUnix = 0,
		LastRefreshUnix = 0,
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

local function disconnectAll()
	for _, connection in ipairs(State.Connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(State.Connections)
end

local function cleanup()
	if State.Dead then
		return
	end
	State.Dead = true
	State.SendToken += 1
	disconnectAll()
	if State.Gui then
		State.Gui:Destroy()
	end
	if ENV[STATE_KEY] == State then
		ENV[STATE_KEY] = nil
	end
end
State.Cleanup = cleanup

-- Exact live-game modules used by the official mailbox/price interfaces.
local SharedModules = ReplicatedStorage:WaitForChild("SharedModules")
local ClientModules = ReplicatedStorage:WaitForChild("ClientModules")
local Controllers = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Controllers")
local MailboxControllerModule = Controllers:WaitForChild("MailboxController")

-- The saved game uses require("./Packet") inside SharedModules.Networking.
-- Roblox's own loader accepts that path form, but Delta/Solara's require hook
-- rejects strings. Build only the packet endpoints this script needs from the
-- underlying ModuleScript so no string require is ever executed here.
local PacketModule = SharedModules:WaitForChild("Packet")
local Packet = require(PacketModule)
local PacketRemote = PacketModule:WaitForChild("RemoteEvent")
local requiredPacketNames = {
	"MailboxSendBatch",
	"MailboxLookupPlayer",
	"FruitStockSnapshot",
	"FruitStockRequest",
}
local packetDeadline = os.clock() + 30
for _, packetName in ipairs(requiredPacketNames) do
	while PacketRemote:GetAttribute(packetName) == nil and os.clock() < packetDeadline do
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
local PlayerStateClient = require(ClientModules:WaitForChild("PlayerStateClient"))
local MailboxItemCatalog = require(MailboxControllerModule:WaitForChild("MailboxItemCatalog"))
local FruitValueCalc = require(SharedModules:WaitForChild("FruitValueCalc"))
local MutationData = require(SharedModules:WaitForChild("MutationData"))
local WeightFormat = require(SharedModules:WaitForChild("WeightFormat"))
local MailboxFlags = require(SharedModules:WaitForChild("Flags"):WaitForChild("MailboxFlags"))

local Replica = PlayerStateClient:WaitForLocalReplica(30)
assert(Replica and Replica.Data and Replica.Data.Inventory, "Player inventory replica did not load")

local MAX_QUEUE_UNITS = 100000
local SERVER_BATCH_UNITS = 20
local NOTE_CODEPOINT_LIMIT = 100
local BATCH_DELAY = 1.65
local HISTORY_LIMIT = 250
local FRUIT_CATEGORY = "HarvestedFruits"

local COLORS = {
	Back = Color3.fromRGB(15, 18, 24),
	Panel = Color3.fromRGB(24, 29, 38),
	Panel2 = Color3.fromRGB(31, 38, 49),
	Line = Color3.fromRGB(57, 68, 84),
	Text = Color3.fromRGB(240, 244, 250),
	Muted = Color3.fromRGB(160, 173, 190),
	Green = Color3.fromRGB(82, 211, 133),
	Green2 = Color3.fromRGB(39, 142, 87),
	Blue = Color3.fromRGB(77, 148, 255),
	Red = Color3.fromRGB(235, 91, 101),
	Yellow = Color3.fromRGB(244, 194, 88),
}

local function safeHistoryString(value, fallback)
	return type(value) == "string" and value or (fallback or "")
end

local function safeHistoryNumber(value, integer)
	local number = tonumber(value)
	if not number or number ~= number or number == math.huge or number == -math.huge then
		return 0
	end
	number = math.max(0, number)
	return integer and math.floor(number) or number
end

local function normalizeHistory(rawHistory)
	local normalized = {}
	if type(rawHistory) ~= "table" then
		return normalized
	end
	for _, entry in ipairs(rawHistory) do
		if #normalized >= HISTORY_LIMIT then
			break
		end
		if type(entry) == "table" then
			local items = {}
			if type(entry.Items) == "table" then
				for _, item in ipairs(entry.Items) do
					if type(item) == "table" then
						local count = safeHistoryNumber(item.Count, true)
						if count > 0 then
							items[#items + 1] = {
								Name = safeHistoryString(item.Name, "Unknown item"),
								Category = safeHistoryString(item.Category, "Unknown"),
								Icon = safeHistoryString(item.Icon),
								Count = count,
								Value = safeHistoryNumber(item.Value, false),
							}
						end
					end
				end
			end
			normalized[#normalized + 1] = {
				Time = safeHistoryNumber(entry.Time, true),
				RecipientName = safeHistoryString(entry.RecipientName, "Player"),
				Username = safeHistoryString(entry.Username, "?"),
				UserId = safeHistoryNumber(entry.UserId, true),
				Note = safeHistoryString(entry.Note),
				Items = items,
				Units = safeHistoryNumber(entry.Units, true),
				Batches = safeHistoryNumber(entry.Batches, true),
				TotalValue = safeHistoryNumber(entry.TotalValue, false),
				Status = safeHistoryString(entry.Status, "Unknown"),
			}
		end
	end
	return normalized
end

local History = ENV[HISTORY_KEY]
if type(History) ~= "table" then
	History = {}
	if type(isfile) == "function" and type(readfile) == "function" then
		pcall(function()
			if isfile(HISTORY_FILE) then
				local decoded = HttpService:JSONDecode(readfile(HISTORY_FILE))
				if type(decoded) == "table" then
					History = decoded
				end
			end
		end)
	end
end
History = normalizeHistory(History)
ENV[HISTORY_KEY] = History

local function saveHistory()
	ENV[HISTORY_KEY] = History
	if type(writefile) == "function" then
		pcall(function()
			writefile(HISTORY_FILE, HttpService:JSONEncode(History))
		end)
	end
end

local function new(className, properties, parent)
	local object = Instance.new(className)
	for key, value in pairs(properties or {}) do
		object[key] = value
	end
	object.Parent = parent
	return object
end

local function corner(parent, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, parent)
end

local function stroke(parent, color, thickness)
	return new("UIStroke", {
		Color = color or COLORS.Line,
		Thickness = thickness or 1,
		Transparency = 0.15,
	}, parent)
end

local function label(parent, text, position, size, textSize, color, alignment)
	return new("TextLabel", {
		BackgroundTransparency = 1,
		Position = position,
		Size = size,
		Font = Enum.Font.Gotham,
		Text = text or "",
		TextColor3 = color or COLORS.Text,
		TextSize = textSize or 14,
		TextXAlignment = alignment or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, parent)
end

local function button(parent, text, position, size, color)
	local object = new("TextButton", {
		AutoButtonColor = true,
		BackgroundColor3 = color or COLORS.Panel2,
		Position = position,
		Size = size,
		Font = Enum.Font.GothamSemibold,
		Text = text,
		TextColor3 = COLORS.Text,
		TextSize = 13,
	}, parent)
	corner(object, 7)
	return object
end

local function box(parent, placeholder, position, size)
	local object = new("TextBox", {
		BackgroundColor3 = COLORS.Panel2,
		Position = position,
		Size = size,
		ClearTextOnFocus = false,
		Font = Enum.Font.Gotham,
		PlaceholderText = placeholder,
		PlaceholderColor3 = COLORS.Muted,
		Text = "",
		TextColor3 = COLORS.Text,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, parent)
	corner(object, 7)
	stroke(object)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 9),
		PaddingRight = UDim.new(0, 9),
	}, object)
	return object
end

local function scrolling(parent, position, size)
	local frame = new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = position,
		Size = size,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = COLORS.Line,
	}, parent)
	local layout = new("UIListLayout", {
		Padding = UDim.new(0, 7),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, frame)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 2),
		PaddingRight = UDim.new(0, 5),
	}, frame)
	return frame, layout
end

local function clearList(frame)
	for _, child in ipairs(frame:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clampUtf8(value, maxCodepoints)
	value = tostring(value or "")
	local length = utf8.len(value)
	if length and length > maxCodepoints then
		local byte = utf8.offset(value, maxCodepoints + 1)
		if byte then
			return string.sub(value, 1, byte - 1)
		end
	end
	if #value > maxCodepoints * 4 then
		return string.sub(value, 1, maxCodepoints * 4)
	end
	return value
end

local SUFFIXES = { "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
local function formatNumber(value)
	value = tonumber(value) or 0
	local absolute = math.abs(value)
	if absolute < 1000 then
		return tostring(math.floor(value + 0.5))
	end
	local rawTier = math.floor(math.log10(absolute) / 3)
	local tier = math.min(rawTier, #SUFFIXES)
	local scaled = value / (1000 ^ tier)
	local formatted = string.format(scaled >= 100 and "%.0f%s" or scaled >= 10 and "%.1f%s" or "%.2f%s", scaled, SUFFIXES[tier])
	local numberPart, suffix = formatted:match("^([%-]?[%d%.]+)(%a+)$")
	if numberPart and suffix then
		numberPart = numberPart:gsub("(%..-)0+$", "%1"):gsub("%.$", "")
		return numberPart .. suffix
	end
	return formatted
end

local function formatMultiplier(value)
	value = tonumber(value) or 1
	if math.abs(value - math.floor(value + 0.00001)) < 0.0001 then
		return tostring(math.floor(value + 0.00001)) .. "x"
	end
	return string.format("%.2fx", value):gsub("0+x", "x")
end

local function groupFor(category)
	if category == FRUIT_CATEGORY then
		return "Fruits"
	elseif category == "Seeds" then
		return "Seeds"
	end
	return "Gears"
end

local function stockMultiplier(fruitName)
	local entry = State.Stock.Entries[fruitName]
	return type(entry) == "table" and tonumber(entry.multiplier) or 1
end

local function firstField(value, fields)
	if type(value) ~= "table" then
		return nil
	end
	for _, field in ipairs(fields) do
		local result = value[field]
		if result ~= nil then
			return result
		end
	end
	return nil
end

local FRUIT_NAME_FIELDS = { "FruitName", "fruitName", "Fruit", "fruit", "Name", "name", "DisplayName", "displayName" }
local FRUIT_ID_FIELDS = { "Id", "ID", "id", "Uuid", "UUID", "uuid", "Uid", "UID", "uid", "ItemId", "ItemID", "itemId", "InventoryId", "InventoryID", "inventoryId", "UniqueId", "UniqueID", "uniqueId" }
local FRUIT_MUTATION_FIELDS = { "Mutation", "mutation", "MutationName", "mutationName" }
local FRUIT_WEIGHT_FIELDS = { "Weight", "weight", "WeightGrams", "weightGrams", "Grams", "grams" }
local FRUIT_SIZE_FIELDS = { "SizeMultiplier", "sizeMultiplier", "Size", "size" }
local FRUIT_DECAY_FIELDS = { "DecayAlpha", "decayAlpha", "Decay", "decay" }
local FRUIT_COUNT_FIELDS = { "Count", "count", "Amount", "amount", "Quantity", "quantity", "Stack", "stack" }

local function normalizeFruitEntry(entryValue, fallbackName)
	if type(entryValue) ~= "table" then
		return entryValue
	end
	local normalized = table.clone(entryValue)
	normalized.FruitName = firstField(entryValue, FRUIT_NAME_FIELDS) or fallbackName
	normalized.Mutation = firstField(entryValue, FRUIT_MUTATION_FIELDS)
	normalized.Weight = tonumber(firstField(entryValue, FRUIT_WEIGHT_FIELDS)) or 0
	normalized.SizeMultiplier = tonumber(firstField(entryValue, FRUIT_SIZE_FIELDS)) or 1
	normalized.DecayAlpha = tonumber(firstField(entryValue, FRUIT_DECAY_FIELDS))
	return normalized
end

local function fruitBaseValue(entryValue, itemKey)
	if type(entryValue) ~= "table" then
		return 0
	end
	local normalized = normalizeFruitEntry(entryValue, itemKey)
	local ok, result = pcall(
		FruitValueCalc,
		normalized.FruitName or itemKey,
		normalized.SizeMultiplier or 1,
		normalized.Mutation,
		LocalPlayer,
		normalized.DecayAlpha
	)
	return ok and type(result) == "number" and result or 0
end

local function fruitLiveValue(entryValue, itemKey)
	local normalized = type(entryValue) == "table" and normalizeFruitEntry(entryValue, itemKey) or {}
	local fruitName = normalized.FruitName or itemKey
	return math.floor(fruitBaseValue(normalized, itemKey) * stockMultiplier(fruitName))
end

local function fruitDetails(entryValue, itemKey)
	local normalized = type(entryValue) == "table" and normalizeFruitEntry(entryValue, itemKey) or {}
	local fruitName = normalized.FruitName or itemKey
	local mutation = normalized.Mutation or "None"
	local size = tonumber(normalized.SizeMultiplier) or 1
	local weight = tonumber(normalized.Weight) or 0
	local mutationMultiplier = 1
	if mutation ~= "None" and mutation ~= "" then
		local ok, result = pcall(MutationData.ReturnPriceMultiplier, mutation)
		if ok and type(result) == "number" then
			mutationMultiplier = result
		end
	end
	local formattedWeight = WeightFormat.FormatGrams(weight)
	return string.format(
		"%s | %s | size %s | mut %s | stock %s",
		mutation,
		formattedWeight,
		formatMultiplier(size),
		formatMultiplier(mutationMultiplier),
		formatMultiplier(stockMultiplier(fruitName))
	)
end

local function normalizeImage(image)
	if type(image) == "number" and image > 0 then
		return "rbxassetid://" .. tostring(math.floor(image))
	end
	if type(image) == "string" then
		if image:match("^%d+$") then
			return "rbxassetid://" .. image
		end
		return image
	end
	return ""
end

local function resolveItem(category, itemKey, entryValue)
	local fallbackName = tostring(itemKey)
	local fallbackImage = ""
	if type(entryValue) == "table" then
		fallbackName = tostring(entryValue.DisplayName or entryValue.FruitName or entryValue.Name or itemKey)
		fallbackImage = normalizeImage(entryValue.Icon or entryValue.Image or entryValue.IconId or entryValue.ImageId)
	end
	local ok, displayName, image = pcall(MailboxItemCatalog.Resolve, category, itemKey, entryValue)
	if not ok then
		return fallbackName, fallbackImage
	end
	return tostring(displayName or fallbackName), normalizeImage(image) ~= "" and normalizeImage(image) or fallbackImage
end

local function getInventory()
	return Replica and Replica.Data and Replica.Data.Inventory or {}
end

local function fruitSignalScore(value)
	if type(value) ~= "table" then
		return 0
	end
	local score = 0
	if firstField(value, FRUIT_ID_FIELDS) ~= nil then score += 2 end
	if firstField(value, FRUIT_MUTATION_FIELDS) ~= nil then score += 2 end
	if firstField(value, FRUIT_WEIGHT_FIELDS) ~= nil then score += 2 end
	if firstField(value, FRUIT_SIZE_FIELDS) ~= nil then score += 2 end
	if firstField(value, FRUIT_DECAY_FIELDS) ~= nil then score += 1 end
	if value.FruitName ~= nil or value.fruitName ~= nil then score += 4 end
	return score
end

local function isFruitEntry(value, insideFruitContainer)
	local score = fruitSignalScore(value)
	return score >= 3 or (insideFruitContainer and score >= 1)
end

local function fruitIdentity(containerKey, entryValue)
	local explicit = firstField(entryValue, FRUIT_ID_FIELDS)
	if explicit ~= nil and tostring(explicit) ~= "" then
		return explicit
	end
	return containerKey
end

local function fruitAvailable(entryValue)
	local count = tonumber(firstField(entryValue, FRUIT_COUNT_FIELDS))
	if count and count > 0 then
		return math.max(1, math.floor(count))
	end
	return 1
end

local function addFruitCandidate(output, seen, containerKey, entryValue, sourceName, iconOverride)
	if type(entryValue) ~= "table" then
		return
	end
	local itemKey = fruitIdentity(containerKey, entryValue)
	if itemKey == nil then
		return
	end
	local normalized = normalizeFruitEntry(entryValue, type(containerKey) == "string" and containerKey or nil)
	local stableId = firstField(normalized, FRUIT_ID_FIELDS)
	local identity = tostring(stableId or itemKey)
	if identity == "" or seen[identity] then
		return
	end
	seen[identity] = true
	output[#output + 1] = {
		ItemKey = itemKey,
		EntryValue = normalized,
		Available = fruitAvailable(normalized),
		Source = sourceName,
		Icon = normalizeImage(iconOverride),
	}
end

local function collectFruitEntries(container, output, seen, depth, insideFruitContainer, path)
	if type(container) ~= "table" or depth > 7 then
		return
	end
	for containerKey, entryValue in pairs(container) do
		local keyName = type(containerKey) == "string" and string.lower(containerKey) or ""
		local childFruitContext = insideFruitContainer
			or string.find(keyName, "fruit", 1, true) ~= nil
			or string.find(keyName, "harvest", 1, true) ~= nil
			or string.find(keyName, "produce", 1, true) ~= nil
		local childPath = path .. "/" .. tostring(containerKey)
		if isFruitEntry(entryValue, childFruitContext) then
			addFruitCandidate(output, seen, containerKey, entryValue, childPath)
		elseif type(entryValue) == "table" then
			collectFruitEntries(entryValue, output, seen, depth + 1, childFruitContext, childPath)
		end
	end
end

local function toolAttributeTable(tool)
	local data = {}
	for _, name in ipairs({
		"FruitName", "fruitName", "Name", "DisplayName",
		"Id", "ID", "id", "Uuid", "UUID", "uuid", "Uid", "UID", "uid",
		"ItemId", "ItemID", "itemId", "InventoryId", "InventoryID", "inventoryId",
		"UniqueId", "UniqueID", "uniqueId", "Mutation", "mutation", "MutationName",
		"Weight", "weight", "WeightGrams", "weightGrams", "Grams", "grams",
		"SizeMultiplier", "sizeMultiplier", "DecayAlpha", "decayAlpha",
		"Count", "count", "Amount", "amount", "Quantity", "quantity",
		"Icon", "Image", "IconId", "ImageId",
	}) do
		local ok, value = pcall(tool.GetAttribute, tool, name)
		if ok and value ~= nil then
			data[name] = value
		end
	end
	data.FruitName = data.FruitName or data.fruitName or tool.Name:match("^([^%[]+)") or tool.Name
	data.DisplayName = data.DisplayName or tool.Name
	return data
end

local function collectToolFruits(output, seen)
	local function inspect(container)
		if not container then return end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				local data = toolAttributeTable(child)
				if fruitSignalScore(data) >= 3 then
					local id = firstField(data, FRUIT_ID_FIELDS)
					if id ~= nil then
						addFruitCandidate(output, seen, id, data, "Tool:" .. child.Name, child.TextureId)
					end
				end
			end
		end
	end
	inspect(LocalPlayer:FindFirstChildOfClass("Backpack"))
	inspect(LocalPlayer.Character)
end

local function harvestedFruitEntries()
	local output = {}
	local seen = {}
	local data = Replica and Replica.Data
	if type(data) ~= "table" then
		return output
	end

	-- Search the whole player replica, not just catalog-named containers. The
	-- live game can store grown fruit under generic collection/wrapper keys and
	-- the native mailbox catalog intentionally omits this item class.
	collectFruitEntries(data.Inventory, output, seen, 0, false, "Inventory")
	collectFruitEntries(data, output, seen, 0, false, "Data")
	-- Some executor/game builds expose harvested fruit as Backpack/Character
	-- tools. Use their stable inventory UUID only; display names are never used
	-- as the transport key when no ID is present.
	collectToolFruits(output, seen)
	return output
end

local function mailableCategories()
	local categories = {}
	local catalogCategories = MailboxItemCatalog.Categories
	if type(catalogCategories) == "table" then
		for _, category in ipairs(catalogCategories) do
			if type(category) == "string" and category ~= FRUIT_CATEGORY then
				categories[#categories + 1] = category
			end
		end
	end
	return categories
end

local function inventoryEntries()
	local output = {}
	local inventory = getInventory()

	for _, category in ipairs(mailableCategories()) do
		if category ~= "Pets" then
			local categoryData = inventory[category]
			if type(categoryData) == "table" then
				for itemKey, entryValue in pairs(categoryData) do
					local available = type(entryValue) == "number" and math.max(0, math.floor(entryValue)) or 0
					if available > 0 then
						local displayName, icon = resolveItem(category, itemKey, entryValue)
						output[#output + 1] = {
							Key = category .. "\31" .. tostring(itemKey),
							Category = category,
							Group = groupFor(category),
							ItemKey = itemKey,
							EntryValue = entryValue,
							Available = available,
							DisplayName = displayName,
							Icon = icon,
							LiveValue = 0,
						}
					end
				end
			end
		end
	end

	for _, fruit in ipairs(harvestedFruitEntries()) do
		local itemKey = fruit.ItemKey
		local entryValue = fruit.EntryValue
		local displayName, icon = resolveItem(FRUIT_CATEGORY, itemKey, entryValue)
		if icon == "" then icon = fruit.Icon or "" end
		output[#output + 1] = {
			Key = FRUIT_CATEGORY .. "\31" .. tostring(itemKey),
			Category = FRUIT_CATEGORY,
			Group = "Fruits",
			ItemKey = itemKey,
			EntryValue = entryValue,
			Available = fruit.Available or 1,
			DisplayName = displayName,
			Icon = icon,
			LiveValue = fruitLiveValue(entryValue, itemKey),
		}
	end

	table.sort(output, function(a, b)
		if a.Group ~= b.Group then
			return a.Group < b.Group
		end
		if a.LiveValue ~= b.LiveValue then
			return a.LiveValue > b.LiveValue
		end
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)
	return output
end

local function queueUnits()
	local count = 0
	for _, entry in pairs(State.Queue) do
		count += entry.Selected
	end
	return count
end

local function queueFruitValue()
	local value = 0
	for _, entry in pairs(State.Queue) do
		if entry.Category == FRUIT_CATEGORY then
			value += fruitLiveValue(entry.EntryValue, entry.ItemKey) * entry.Selected
		end
	end
	return value
end

local GuiParent = LocalPlayer:WaitForChild("PlayerGui")
if type(gethui) == "function" then
	local ok, result = pcall(gethui)
	if ok and typeof(result) == "Instance" then
		GuiParent = result
	end
else
	pcall(function()
		GuiParent = CoreGui
	end)
end

local function destroyStaleGuiCopies(root)
	if typeof(root) ~= "Instance" then return end
	pcall(function()
		for _, child in ipairs(root:GetChildren()) do
			if child:IsA("ScreenGui") and child.Name == "SmileB_GAG2MailManager" then
				child:Destroy()
			end
		end
	end)
end

destroyStaleGuiCopies(LocalPlayer:FindFirstChildOfClass("PlayerGui"))
destroyStaleGuiCopies(GuiParent)
destroyStaleGuiCopies(CoreGui)

local ScreenGui = new("ScreenGui", {
	Name = "SmileB_GAG2MailManager",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, nil)
if syn and type(syn.protect_gui) == "function" then pcall(syn.protect_gui, ScreenGui) end
local parented = pcall(function() ScreenGui.Parent = GuiParent end)
if not parented then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end
State.Gui = ScreenGui

local Window = new("Frame", {
	Name = "Window",
	AnchorPoint = Vector2.new(0.5, 0.5),
	BackgroundColor3 = COLORS.Back,
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(1040, 660),
	ClipsDescendants = true,
}, ScreenGui)
corner(Window, 12)
stroke(Window, COLORS.Line, 1.25)

local Scale = new("UIScale", { Scale = 1 }, Window)
local responsiveScale = 1
local transitionInProgress = false
local function updateScale()
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
	local widthScale = math.max(0.1, (viewport.X - 16) / 1040)
	local heightScale = math.max(0.1, (viewport.Y - 16) / 660)
	responsiveScale = math.min(1, widthScale, heightScale)
	if not transitionInProgress then Scale.Scale = responsiveScale end
end

local viewportConnection
local function bindViewportCamera()
	if viewportConnection then
		pcall(function() viewportConnection:Disconnect() end)
		viewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then viewportConnection = track(camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)) end
	updateScale()
end
bindViewportCamera()
track(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(bindViewportCamera))

local Header = new("Frame", { BackgroundColor3 = COLORS.Panel, Size = UDim2.new(1, 0, 0, 48) }, Window)
label(Header, "GAG2 Mail Manager", UDim2.fromOffset(16, 0), UDim2.new(0, 300, 1, 0), 17, COLORS.Text)
local StockTimer = label(Header, "Fruit stock: loading...", UDim2.new(1, -420, 0, 0), UDim2.fromOffset(320, 48), 13, COLORS.Yellow, Enum.TextXAlignment.Right)
local MinimizeButton = button(Header, "-", UDim2.new(1, -82, 0, 8), UDim2.fromOffset(32, 32), COLORS.Panel2)
local CloseButton = button(Header, "X", UDim2.new(1, -42, 0, 8), UDim2.fromOffset(32, 32), COLORS.Red)

local MinimizedBubble = button(ScreenGui, "B", UDim2.new(1, -44, 0.5, 0), UDim2.fromOffset(58, 58), COLORS.Green2)
MinimizedBubble.Name = "MinimizedBubble"
MinimizedBubble.AnchorPoint = Vector2.new(0.5, 0.5)
MinimizedBubble.Visible = false
MinimizedBubble.ZIndex = 50
MinimizedBubble.TextSize = 22
MinimizedBubble.Font = Enum.Font.GothamBold
corner(MinimizedBubble, 29)
stroke(MinimizedBubble, COLORS.Green, 2)
new("UIGradient", { Color = ColorSequence.new(COLORS.Green2, COLORS.Blue), Rotation = 45 }, MinimizedBubble)

local Nav = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 54), Size = UDim2.new(1, -24, 0, 34) }, Window)
local ComposeTab = button(Nav, "Compose", UDim2.fromOffset(0, 0), UDim2.fromOffset(110, 32), COLORS.Green2)
local HistoryTab = button(Nav, "History", UDim2.fromOffset(118, 0), UDim2.fromOffset(110, 32), COLORS.Panel2)
local Compose = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 94), Size = UDim2.new(1, -24, 1, -122) }, Window)
local HistoryPage = new("Frame", { BackgroundTransparency = 1, Position = Compose.Position, Size = Compose.Size, Visible = false }, Window)
local Status = label(Window, "Ready", UDim2.new(0, 14, 1, -27), UDim2.new(1, -28, 0, 22), 12, COLORS.Muted)
local function setStatus(text, color) Status.Text = tostring(text or ""); Status.TextColor3 = color or COLORS.Muted end

local RecipientPanel = new("Frame", { BackgroundColor3 = COLORS.Panel, Size = UDim2.new(0, 244, 1, 0) }, Compose)
corner(RecipientPanel, 10); stroke(RecipientPanel)
label(RecipientPanel, "Recipient", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 24), 15, COLORS.Text)
local UsernameBox = box(RecipientPanel, "Username", UDim2.fromOffset(12, 38), UDim2.new(1, -24, 0, 36))
local ResolveButton = button(RecipientPanel, "Resolve username", UDim2.fromOffset(12, 82), UDim2.new(1, -24, 0, 34), COLORS.Blue)
local Avatar = new("ImageLabel", { BackgroundColor3 = COLORS.Panel2, Position = UDim2.new(0.5, -42, 0, 132), Size = UDim2.fromOffset(84, 84), Image = "", Visible = false }, RecipientPanel)
corner(Avatar, 42); stroke(Avatar)
local ResolvedName = label(RecipientPanel, "No recipient selected", UDim2.fromOffset(12, 226), UDim2.new(1, -24, 0, 44), 13, COLORS.Muted, Enum.TextXAlignment.Center)
ResolvedName.TextWrapped = true
local function resetRecipientUI(message, color)
	State.Resolved = nil; Avatar.Image = ""; Avatar.Visible = false; ResolveButton.Text = "Resolve username"
	ResolvedName.Text = message or "No recipient selected"; ResolvedName.TextColor3 = color or COLORS.Muted
end
local LimitInfo = label(RecipientPanel, "Real game limits\n\n- 20 units per mail\n- 100-character note\n- Mailbox capacity: " .. tostring(MailboxFlags.Capacity:Get()) .. "\n\nLarge queues are sent as separate 20-unit batches and stop safely if the server rejects one.", UDim2.fromOffset(14, 294), UDim2.new(1, -28, 0, 190), 12, COLORS.Muted)
LimitInfo.TextWrapped = true; LimitInfo.TextYAlignment = Enum.TextYAlignment.Top

local InventoryPanel = new("Frame", { BackgroundColor3 = COLORS.Panel, Position = UDim2.fromOffset(254, 0), Size = UDim2.new(0, 374, 1, 0) }, Compose)
corner(InventoryPanel, 10); stroke(InventoryPanel)
label(InventoryPanel, "Mailable inventory", UDim2.fromOffset(12, 8), UDim2.new(1, -24, 0, 24), 15, COLORS.Text)
local InventorySearch = box(InventoryPanel, "Search items", UDim2.fromOffset(12, 36), UDim2.new(1, -100, 0, 34))
local QuantityBox = box(InventoryPanel, "Qty", UDim2.new(1, -80, 0, 36), UDim2.fromOffset(68, 34)); QuantityBox.Text = "1"; QuantityBox.TextXAlignment = Enum.TextXAlignment.Center
local FilterBar = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 78), Size = UDim2.new(1, -24, 0, 31) }, InventoryPanel)
local FilterButtons = {}
for index, name in ipairs({ "All", "Fruits", "Seeds", "Gears" }) do
	FilterButtons[name] = button(FilterBar, name, UDim2.fromOffset((index - 1) * 86, 0), UDim2.fromOffset(80, 29), name == "All" and COLORS.Green2 or COLORS.Panel2)
end
local InventoryList = scrolling(InventoryPanel, UDim2.fromOffset(10, 116), UDim2.new(1, -20, 1, -126))

local QueuePanel = new("Frame", { BackgroundColor3 = COLORS.Panel, Position = UDim2.fromOffset(638, 0), Size = UDim2.new(1, -638, 1, 0) }, Compose)
corner(QueuePanel, 10); stroke(QueuePanel)
local QueueHeader = label(QueuePanel, "Queue: 0 / 100,000", UDim2.fromOffset(12, 7), UDim2.new(1, -95, 0, 25), 15, COLORS.Text)
local ClearButton = button(QueuePanel, "Clear", UDim2.new(1, -78, 0, 7), UDim2.fromOffset(66, 28), COLORS.Panel2)
local QueueValue = label(QueuePanel, "Selected fruit value: 0 Sheckles", UDim2.fromOffset(12, 35), UDim2.new(1, -24, 0, 23), 13, COLORS.Green)
local QueueList = scrolling(QueuePanel, UDim2.fromOffset(10, 64), UDim2.new(1, -20, 1, -210))
local NoteBox = box(QueuePanel, "Optional note (100 characters)", UDim2.new(0, 12, 1, -136), UDim2.new(1, -24, 0, 58)); NoteBox.MultiLine = true; NoteBox.TextWrapped = true; NoteBox.TextYAlignment = Enum.TextYAlignment.Top
local NoteCounter = label(QueuePanel, "0/100", UDim2.new(1, -90, 1, -77), UDim2.fromOffset(76, 18), 11, COLORS.Muted, Enum.TextXAlignment.Right)
local SendButton = button(QueuePanel, "Send queued items", UDim2.new(0, 12, 1, -52), UDim2.new(1, -24, 0, 40), COLORS.Green2)
local HistorySearch = box(HistoryPage, "Search recipient, note, or item", UDim2.fromOffset(0, 0), UDim2.new(1, -126, 0, 38))
local ClearHistoryButton = button(HistoryPage, "Clear history", UDim2.new(1, -116, 0, 0), UDim2.fromOffset(116, 38), COLORS.Panel2)
local HistoryList = scrolling(HistoryPage, UDim2.fromOffset(0, 48), UDim2.new(1, 0, 1, -48))

local rebuildInventoryUI; local rebuildQueueUI; local rebuildHistoryUI
local function requestedQuantity()
	local number = tonumber(QuantityBox.Text); if not number or number ~= number then return 1 end
	return math.clamp(math.floor(number), 1, MAX_QUEUE_UNITS)
end
local function queueAdd(item)
	if State.Sending then setStatus("Stop the current send before editing the queue", COLORS.Yellow); return end
	local current = State.Queue[item.Key]; local already = current and current.Selected or 0
	local requested = item.Category == FRUIT_CATEGORY and math.min(requestedQuantity(), item.Available) or requestedQuantity()
	local amount = math.min(requested, math.max(0, item.Available - already), math.max(0, MAX_QUEUE_UNITS - queueUnits()))
	if amount <= 0 then setStatus("That item is already fully queued, or the 100,000-unit queue is full", COLORS.Yellow); return end
	if not current then
		current = { Key = item.Key, Category = item.Category, ItemKey = item.ItemKey, EntryValue = item.EntryValue, DisplayName = item.DisplayName, Icon = item.Icon, Selected = 0 }
		State.Queue[item.Key] = current
	end
	current.Selected += amount
	setStatus(string.format("Queued %s x%s", item.DisplayName, formatNumber(amount)), COLORS.Green)
	rebuildInventoryUI(); rebuildQueueUI()
end
local function queueRemove(key, amount)
	if State.Sending then return end
	local entry = State.Queue[key]; if not entry then return end
	entry.Selected -= amount or 1; if entry.Selected <= 0 then State.Queue[key] = nil end
	rebuildInventoryUI(); rebuildQueueUI()
end

rebuildInventoryUI = function()
	if State.Dead then return end
	clearList(InventoryList)
	local query = string.lower(trim(InventorySearch.Text)); local entries = inventoryEntries(); local shown = 0
	for _, item in ipairs(entries) do
		local queued = State.Queue[item.Key] and State.Queue[item.Key].Selected or 0
		local remaining = math.max(0, item.Available - queued)
		local searchable = string.lower(item.DisplayName .. " " .. item.Category .. " " .. item.Group)
		if remaining > 0 and (State.Filter == "All" or State.Filter == item.Group) and (query == "" or string.find(searchable, query, 1, true)) then
			shown += 1
			local row = new("Frame", { BackgroundColor3 = COLORS.Panel2, Size = UDim2.new(1, -4, 0, 82), LayoutOrder = shown }, InventoryList); corner(row, 8)
			local icon = new("ImageLabel", { BackgroundColor3 = COLORS.Back, Position = UDim2.fromOffset(7, 10), Size = UDim2.fromOffset(62, 62), Image = item.Icon }, row); corner(icon, 7)
			local nameLabel = label(row, item.DisplayName, UDim2.fromOffset(78, 5), UDim2.new(1, -155, 0, 22), 13, COLORS.Text); nameLabel.Font = Enum.Font.GothamSemibold
			local detail
			if item.Category == FRUIT_CATEGORY then
				detail = fruitDetails(item.EntryValue, item.ItemKey) .. "\n" .. formatNumber(item.LiveValue) .. " each | " .. formatNumber(remaining) .. " available"
			else
				detail = item.Category .. " | available " .. formatNumber(remaining)
			end
			local detailLabel = label(row, detail, UDim2.fromOffset(78, 27), UDim2.new(1, -155, 0, 49), 10, item.Category == FRUIT_CATEGORY and COLORS.Green or COLORS.Muted); detailLabel.TextWrapped = true; detailLabel.TextYAlignment = Enum.TextYAlignment.Top
			local add = button(row, item.Category == FRUIT_CATEGORY and "+ Fruit" or "+ Qty", UDim2.new(1, -70, 0.5, -16), UDim2.fromOffset(62, 32), COLORS.Green2)
			add.Activated:Connect(function() queueAdd(item) end)
		end
	end
	if shown == 0 then local empty = label(InventoryList, State.Filter == "Fruits" and "No grown fruits detected in inventory" or "No matching mailable items", UDim2.new(), UDim2.new(1, -4, 0, 50), 13, COLORS.Muted, Enum.TextXAlignment.Center); empty.LayoutOrder = 1 end
end

rebuildQueueUI = function()
	if State.Dead then return end
	clearList(QueueList)
	local entries = {}; for _, entry in pairs(State.Queue) do entries[#entries + 1] = entry end
	table.sort(entries, function(a, b) return string.lower(a.DisplayName) < string.lower(b.DisplayName) end)
	for index, entry in ipairs(entries) do
		local row = new("Frame", { BackgroundColor3 = COLORS.Panel2, Size = UDim2.new(1, -4, 0, 68), LayoutOrder = index }, QueueList); corner(row, 8)
		local icon = new("ImageLabel", { BackgroundColor3 = COLORS.Back, Position = UDim2.fromOffset(6, 7), Size = UDim2.fromOffset(53, 53), Image = entry.Icon }, row); corner(icon, 7)
		local nameLabel = label(row, entry.DisplayName, UDim2.fromOffset(68, 5), UDim2.new(1, -142, 0, 22), 12, COLORS.Text); nameLabel.Font = Enum.Font.GothamSemibold
		local detail = "x" .. formatNumber(entry.Selected)
		if entry.Category == FRUIT_CATEGORY then
			local each = fruitLiveValue(entry.EntryValue, entry.ItemKey)
			detail ..= " | each " .. formatNumber(each) .. " | selected " .. formatNumber(each * entry.Selected)
		end
		label(row, detail, UDim2.fromOffset(68, 29), UDim2.new(1, -142, 0, 31), 10, entry.Category == FRUIT_CATEGORY and COLORS.Green or COLORS.Muted)
		local remove = button(row, "-", UDim2.new(1, -66, 0, 8), UDim2.fromOffset(27, 27), COLORS.Panel)
		local removeAll = button(row, "X", UDim2.new(1, -34, 0, 8), UDim2.fromOffset(27, 27), COLORS.Red)
		remove.Activated:Connect(function() queueRemove(entry.Key, 1) end); removeAll.Activated:Connect(function() queueRemove(entry.Key, entry.Selected) end)
	end
	QueueHeader.Text = string.format("Queue: %s / 100,000", formatNumber(queueUnits()))
	QueueValue.Text = string.format("Selected fruit value: %s Sheckles", formatNumber(queueFruitValue()))
	if #entries == 0 then local empty = label(QueueList, "Queue is empty", UDim2.new(), UDim2.new(1, -4, 0, 50), 13, COLORS.Muted, Enum.TextXAlignment.Center); empty.LayoutOrder = 1 end
end

local function historyMatches(entry, query)
	if query == "" then return true end
	local parts = { tostring(entry.RecipientName or ""), tostring(entry.Username or ""), tostring(entry.Note or ""), tostring(entry.Status or "") }
	for _, item in ipairs(entry.Items or {}) do parts[#parts + 1] = tostring(item.Name or ""); parts[#parts + 1] = tostring(item.Category or "") end
	return string.find(string.lower(table.concat(parts, " ")), query, 1, true) ~= nil
end

rebuildHistoryUI = function()
	if State.Dead then return end
	clearList(HistoryList); local query = string.lower(trim(HistorySearch.Text)); local shown = 0
	for historyIndex, entry in ipairs(History) do
		if historyMatches(entry, query) then
			shown += 1
			local row = new("Frame", { BackgroundColor3 = COLORS.Panel, Size = UDim2.new(1, -4, 0, 102), LayoutOrder = shown }, HistoryList); corner(row, 9); stroke(row)
			local when = os.date("%Y-%m-%d %H:%M", tonumber(entry.Time) or os.time())
			local titleLabel = label(row, string.format("To %s (@%s) | %s", entry.RecipientName or "Player", entry.Username or "?", when), UDim2.fromOffset(12, 7), UDim2.new(1, -90, 0, 22), 13, COLORS.Text); titleLabel.Font = Enum.Font.GothamSemibold
			local historyStatus = tostring(entry.Status or "Unknown"); local historyColor = historyStatus == "Completed" and COLORS.Green or COLORS.Yellow
			label(row, string.format("%s units | %s batch(es) | %s Sheckles | %s", formatNumber(entry.Units or 0), tostring(entry.Batches or 0), formatNumber(entry.TotalValue or 0), historyStatus), UDim2.fromOffset(12, 29), UDim2.new(1, -24, 0, 20), 11, historyColor)
			local summaries = {}; for _, item in ipairs(entry.Items or {}) do summaries[#summaries + 1] = tostring(item.Name) .. " x" .. formatNumber(item.Count) end
			local summary = table.concat(summaries, ", "); if entry.Note and entry.Note ~= "" then summary ..= " | Note: " .. entry.Note end
			local summaryLabel = label(row, summary, UDim2.fromOffset(12, 51), UDim2.new(1, -210, 0, 42), 11, COLORS.Muted); summaryLabel.TextWrapped = true; summaryLabel.TextYAlignment = Enum.TextYAlignment.Top
			local icons = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(1, -190, 0, 49), Size = UDim2.fromOffset(178, 44) }, row)
			for iconIndex = 1, math.min(4, #(entry.Items or {})) do local item = entry.Items[iconIndex]; local image = new("ImageLabel", { BackgroundColor3 = COLORS.Panel2, Position = UDim2.fromOffset((iconIndex - 1) * 43, 1), Size = UDim2.fromOffset(40, 40), Image = item.Icon or "" }, icons); corner(image, 6) end
			local delete = button(row, "Delete", UDim2.new(1, -72, 0, 7), UDim2.fromOffset(60, 25), COLORS.Panel2)
			delete.Activated:Connect(function() table.remove(History, historyIndex); saveHistory(); rebuildHistoryUI() end)
		end
	end
	if shown == 0 then local empty = label(HistoryList, "No matching mail history", UDim2.new(), UDim2.new(1, -4, 0, 60), 13, COLORS.Muted, Enum.TextXAlignment.Center); empty.LayoutOrder = 1 end
end

local function applyStockSnapshot(snapshot)
	if type(snapshot) ~= "table" then return end
	State.Stock.LastError = nil
	if type(snapshot.entries) == "table" then
		local entries = {}
		for fruitName, entry in pairs(snapshot.entries) do if type(fruitName) == "string" and type(entry) == "table" then entries[fruitName] = { multiplier = type(entry.multiplier) == "number" and entry.multiplier or 1, tier = type(entry.tier) == "string" and entry.tier or "normal" } end end
		State.Stock.Entries = entries
	end
	State.Stock.LastRefreshUnix = tonumber(snapshot.lastRefreshUnix) or State.Stock.LastRefreshUnix
	State.Stock.NextRefreshUnix = tonumber(snapshot.nextRefreshUnix) or State.Stock.NextRefreshUnix
	State.Stock.CycleSeconds = tonumber(snapshot.cycleSeconds) or State.Stock.CycleSeconds
	if type(snapshot.server_now_unix) == "number" then State.Stock.ClockOffset = snapshot.server_now_unix - os.time() end
	rebuildInventoryUI(); rebuildQueueUI()
end

local function requestStockSnapshot()
	if State.Dead or State.Stock.RequestInFlight or os.clock() < State.Stock.NextRequestClock then return end
	State.Stock.RequestInFlight = true; State.Stock.RequestToken += 1; State.Stock.LastError = nil; State.Stock.NextRequestClock = os.clock() + State.Stock.RetrySeconds
	local token = State.Stock.RequestToken
	task.spawn(function()
		local ok, snapshot = pcall(function() return Networking.FruitStock.Request:Fire() end)
		if State.Dead or token ~= State.Stock.RequestToken then return end
		State.Stock.RequestInFlight = false; if ok then applyStockSnapshot(snapshot) else State.Stock.LastError = "request failed" end
	end)
	task.spawn(function()
		task.wait(State.Stock.TimeoutSeconds)
		if State.Dead or token ~= State.Stock.RequestToken or not State.Stock.RequestInFlight then return end
		State.Stock.RequestToken += 1; State.Stock.RequestInFlight = false; State.Stock.LastError = "request timed out"; State.Stock.NextRequestClock = os.clock() + State.Stock.RetrySeconds
	end)
end

local function updateStockTimer()
	local nextRefresh = State.Stock.NextRefreshUnix
	if nextRefresh <= 0 then
		if State.Stock.RequestInFlight then StockTimer.Text = "Fruit Price Stock: refreshing..." elseif State.Stock.LastError then StockTimer.Text = "Fruit stock: " .. State.Stock.LastError .. "; retrying..." else StockTimer.Text = "Fruit stock: unavailable" end
		return
	end
	local remaining = math.max(0, math.floor(nextRefresh - (os.time() + State.Stock.ClockOffset)))
	if remaining == 0 and State.Stock.RequestInFlight then StockTimer.Text = "Fruit Price Stock: refreshing..." else StockTimer.Text = string.format("Fruit Price Stock refresh in %dm %02ds", remaining // 60, remaining % 60) end
end

local RECIPIENT_LOOKUP_TIMEOUT = 12
local resolveToken = 0
local function resolveRecipient()
	local username = trim(UsernameBox.Text):gsub("^@", "")
	if #username < 3 or #username > 20 or not username:match("^[%w_]+$") then resolveToken += 1; resetRecipientUI("Enter a valid Roblox username", COLORS.Red); setStatus("Username must be 3-20 letters, numbers, or underscores", COLORS.Red); return end
	resolveToken += 1; local token = resolveToken; local finished = false; resetRecipientUI("Looking up @" .. username, COLORS.Muted); ResolveButton.Text = "Resolving..."
	task.spawn(function()
		local ok, userId, displayName = pcall(function() return Networking.Mailbox.LookupPlayer:Fire(username) end)
		if State.Dead or token ~= resolveToken then return end; finished = true
		if not ok or type(userId) ~= "number" or userId <= 0 then resetRecipientUI("Player not found", COLORS.Red); setStatus("The game could not resolve that username", COLORS.Red); return end
		if userId == LocalPlayer.UserId then resetRecipientUI("You cannot mail yourself", COLORS.Red); setStatus("Choose another player", COLORS.Red); return end
		ResolveButton.Text = "Resolve username"; displayName = type(displayName) == "string" and displayName ~= "" and displayName or username
		State.Resolved = { UserId = userId, Username = username, DisplayName = displayName }; ResolvedName.Text = displayName .. "\n@" .. username; ResolvedName.TextColor3 = COLORS.Green; setStatus("Recipient resolved", COLORS.Green)
		local imageOk, image = pcall(Players.GetUserThumbnailAsync, Players, userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		if imageOk and type(image) == "string" and image ~= "" and token == resolveToken and not State.Dead then Avatar.Image = image; Avatar.Visible = true end
	end)
	task.spawn(function() task.wait(RECIPIENT_LOOKUP_TIMEOUT); if State.Dead or finished or token ~= resolveToken then return end; resolveToken += 1; resetRecipientUI("Lookup timed out", COLORS.Red); setStatus("Username lookup timed out; try again", COLORS.Red) end)
end

local function addHistory(recipient, note, sentItems, units, batches, totalValue, finalStatus)
	if units <= 0 then return end
	local items = {}; for _, item in pairs(sentItems) do items[#items + 1] = item end; table.sort(items, function(a, b) return string.lower(a.Name) < string.lower(b.Name) end)
	table.insert(History, 1, { Time = os.time(), RecipientName = recipient.DisplayName, Username = recipient.Username, UserId = recipient.UserId, Note = note, Items = items, Units = units, Batches = batches, TotalValue = totalValue, Status = finalStatus })
	while #History > HISTORY_LIMIT do table.remove(History) end; saveHistory(); rebuildHistoryUI()
end

local function buildJob()
	local job = {}
	for key, entry in pairs(State.Queue) do if entry.Selected > 0 then job[#job + 1] = { Key = key, Category = entry.Category, ItemKey = entry.ItemKey, EntryValue = entry.EntryValue, DisplayName = entry.DisplayName, Icon = entry.Icon, Remaining = entry.Selected } end end
	table.sort(job, function(a, b) if a.Category == b.Category then return tostring(a.ItemKey) < tostring(b.ItemKey) end; return a.Category < b.Category end)
	return job
end
local function nextBatch(job)
	local capacity = SERVER_BATCH_UNITS; local payload = {}; local portions = {}
	for _, entry in ipairs(job) do
		if capacity <= 0 then break end
		if entry.Remaining > 0 then
			local amount = math.min(entry.Remaining, capacity)
			payload[#payload + 1] = { Category = entry.Category, ItemKey = entry.ItemKey, Count = amount }
			portions[#portions + 1] = { Entry = entry, Count = amount }; capacity -= amount
		end
	end
	return payload, portions
end

local function beginSend()
	if State.Sending then State.SendToken += 1; setStatus("Stopping after the current server response...", COLORS.Yellow); return end
	if not State.Resolved then setStatus("Resolve a recipient first", COLORS.Red); return end
	if not MailboxFlags.OpenEnabled:Get() then setStatus("The game's mailbox is currently unavailable", COLORS.Red); return end
	if queueUnits() <= 0 then setStatus("Queue at least one item", COLORS.Red); return end
	local availableByKey = {}; for _, item in ipairs(inventoryEntries()) do availableByKey[item.Key] = item.Available end
	for key, entry in pairs(State.Queue) do if entry.Selected > (availableByKey[key] or 0) then setStatus("Inventory changed: reduce or re-add " .. entry.DisplayName .. " before sending", COLORS.Red); rebuildInventoryUI(); return end end
	local recipient = { UserId = State.Resolved.UserId, Username = State.Resolved.Username, DisplayName = State.Resolved.DisplayName }
	local note = clampUtf8(NoteBox.Text, NOTE_CODEPOINT_LIMIT); local job = buildJob(); local total = queueUnits(); local expectedBatches = math.ceil(total / SERVER_BATCH_UNITS)
	State.Sending = true; State.SendToken += 1; local token = State.SendToken; SendButton.Text = "STOP"; SendButton.BackgroundColor3 = COLORS.Red; ClearButton.Active = false
	setStatus(string.format("Sending 0/%s units in up to %s batches...", formatNumber(total), formatNumber(expectedBatches)), COLORS.Yellow)
	task.spawn(function()
		local sentUnits, sentBatches, sentValue = 0, 0, 0; local sentItems = {}; local finalStatus = "Completed"; local failureReason; local deliveryUncertain = false
		while not State.Dead and token == State.SendToken do
			local payload, portions = nextBatch(job); if #payload == 0 then break end
			local ok, success, message = pcall(function() return Networking.Mailbox.SendBatch:Fire(recipient.UserId, payload, note) end)
			if State.Dead then return end
			if not ok then failureReason = "Batch response failed; delivery could not be confirmed"; finalStatus = "Delivery uncertain"; deliveryUncertain = true; break end
			if success ~= true then failureReason = type(message) == "string" and message ~= "" and message or "Server rejected this batch"; finalStatus = "Stopped"; break end
			sentBatches += 1
			for _, portion in ipairs(portions) do
				local entry, count = portion.Entry, portion.Count; entry.Remaining -= count; sentUnits += count
				local queued = State.Queue[entry.Key]; if queued then queued.Selected -= count; if queued.Selected <= 0 then State.Queue[entry.Key] = nil end end
				local historyKey = entry.Category .. "\31" .. entry.DisplayName .. "\31" .. entry.Icon; local historyItem = sentItems[historyKey]
				if not historyItem then historyItem = { Name = entry.DisplayName, Category = entry.Category, Icon = entry.Icon, Count = 0, Value = 0 }; sentItems[historyKey] = historyItem end
				historyItem.Count += count
				if entry.Category == FRUIT_CATEGORY then local value = fruitLiveValue(entry.EntryValue, entry.ItemKey) * count; historyItem.Value += value; sentValue += value end
			end
			rebuildInventoryUI(); rebuildQueueUI(); setStatus(string.format("Sent %s/%s units | batch %s/%s", formatNumber(sentUnits), formatNumber(total), formatNumber(sentBatches), formatNumber(expectedBatches)), COLORS.Yellow)
			if sentUnits < total and token == State.SendToken then task.wait(BATCH_DELAY) end
		end
		if token ~= State.SendToken and sentUnits < total then finalStatus = "Stopped"; failureReason = failureReason or "Stopped by user" end
		addHistory(recipient, note, sentItems, sentUnits, sentBatches, sentValue, finalStatus)
		if State.Dead then return end
		State.Sending = false; SendButton.Text = "Send queued items"; SendButton.BackgroundColor3 = COLORS.Green2; ClearButton.Active = true
		if deliveryUncertain then setStatus(string.format("%s. Confirm inventory or mail state before retrying; the unconfirmed batch remains queued. Confirmed sent: %s units.", failureReason, formatNumber(sentUnits)), COLORS.Red)
		elseif failureReason then setStatus(string.format("%s. Sent %s units; unsent items remain queued.", failureReason, formatNumber(sentUnits)), COLORS.Red)
		else setStatus(string.format("Finished: sent %s units in %s batches", formatNumber(sentUnits), formatNumber(sentBatches)), COLORS.Green) end
		rebuildInventoryUI(); rebuildQueueUI()
	end)
end

track(CloseButton.Activated:Connect(cleanup))
local minimized = false; local activePage = "Compose"
local WINDOW_TWEEN = TweenInfo.new(0.34, Enum.EasingStyle.Quart, Enum.EasingDirection.InOut)
local BUBBLE_TWEEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local windowRestorePosition = Window.Position
local function playTween(instance, tweenInfo, goals) local tween = TweenService:Create(instance, tweenInfo, goals); tween:Play(); return tween end
local function setMinimized(value)
	local shouldMinimize = value == true
	if transitionInProgress or minimized == shouldMinimize then return end
	transitionInProgress = true
	if shouldMinimize then
		minimized = true; windowRestorePosition = Window.Position
		local targetPosition = MinimizedBubble.Position
		local scaleTween = playTween(Scale, WINDOW_TWEEN, { Scale = math.max(0.035, responsiveScale * 0.055) })
		local moveTween = playTween(Window, WINDOW_TWEEN, { Position = targetPosition, Rotation = 540 })
		moveTween.Completed:Wait()
		if State.Dead then return end
		Window.Visible = false; Window.Rotation = 0; Window.Position = windowRestorePosition; Scale.Scale = responsiveScale
		MinimizedBubble.Size = UDim2.fromOffset(10, 10); MinimizedBubble.Rotation = -180; MinimizedBubble.Visible = true
		playTween(MinimizedBubble, BUBBLE_TWEEN, { Size = UDim2.fromOffset(58, 58), Rotation = 0 }).Completed:Wait()
	else
		local origin = MinimizedBubble.Position
		playTween(MinimizedBubble, WINDOW_TWEEN, { Size = UDim2.fromOffset(10, 10), Rotation = 180 }).Completed:Wait()
		if State.Dead then return end
		MinimizedBubble.Visible = false; MinimizedBubble.Size = UDim2.fromOffset(58, 58); MinimizedBubble.Rotation = 0
		Window.Position = origin; Window.Visible = true; Window.Rotation = -540; Scale.Scale = math.max(0.035, responsiveScale * 0.055)
		local scaleTween = playTween(Scale, BUBBLE_TWEEN, { Scale = responsiveScale })
		local moveTween = playTween(Window, WINDOW_TWEEN, { Position = windowRestorePosition, Rotation = 0 })
		moveTween.Completed:Wait(); minimized = false
	end
	transitionInProgress = false
end

task.defer(function()
	if State.Dead then return end
	transitionInProgress = true; Window.Rotation = -12; Scale.Scale = math.max(0.04, responsiveScale * 0.18)
	local scaleTween = playTween(Scale, BUBBLE_TWEEN, { Scale = responsiveScale }); playTween(Window, BUBBLE_TWEEN, { Rotation = 0 }); scaleTween.Completed:Wait(); transitionInProgress = false
end)
track(MinimizeButton.Activated:Connect(function() setMinimized(true) end))

local dragging = false; local dragStart; local startPosition; local bubbleDragging = false; local bubbleMoved = false; local bubbleDragStart; local bubbleStartCenter
track(Header.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = true; dragStart = input.Position; startPosition = Window.Position end end))
track(MinimizedBubble.InputBegan:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then bubbleDragging = true; bubbleMoved = false; bubbleDragStart = input.Position; bubbleStartCenter = Vector2.new(MinimizedBubble.AbsolutePosition.X + MinimizedBubble.AbsoluteSize.X * 0.5, MinimizedBubble.AbsolutePosition.Y + MinimizedBubble.AbsoluteSize.Y * 0.5) end end))
track(UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - dragStart; Window.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X / Scale.Scale, startPosition.Y.Scale, startPosition.Y.Offset + delta.Y / Scale.Scale)
	elseif bubbleDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local delta = input.Position - bubbleDragStart; if delta.Magnitude > 6 then bubbleMoved = true end
		local camera = workspace.CurrentCamera; local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720); local radius = MinimizedBubble.AbsoluteSize.X * 0.5; local padding = 8
		local centerX = math.clamp(bubbleStartCenter.X + delta.X, radius + padding, viewport.X - radius - padding); local centerY = math.clamp(bubbleStartCenter.Y + delta.Y, radius + padding, viewport.Y - radius - padding)
		MinimizedBubble.Position = UDim2.fromOffset(centerX, centerY)
	end
end))
track(UserInputService.InputEnded:Connect(function(input) if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false; bubbleDragging = false end end))
track(MinimizedBubble.Activated:Connect(function() if not bubbleMoved then setMinimized(false) end end))
track(UserInputService.InputBegan:Connect(function(input, processed) if not processed and input.KeyCode == Enum.KeyCode.RightShift then ScreenGui.Enabled = not ScreenGui.Enabled end end))

local function showPage(name)
	activePage = name; local compose = name == "Compose"; Compose.Visible = compose; HistoryPage.Visible = not compose; ComposeTab.BackgroundColor3 = compose and COLORS.Green2 or COLORS.Panel2; HistoryTab.BackgroundColor3 = compose and COLORS.Panel2 or COLORS.Green2
	if not compose then rebuildHistoryUI() end
end
track(ComposeTab.Activated:Connect(function() showPage("Compose") end)); track(HistoryTab.Activated:Connect(function() showPage("History") end)); track(ResolveButton.Activated:Connect(resolveRecipient))
track(UsernameBox.FocusLost:Connect(function(enterPressed) if enterPressed then resolveRecipient() end end))
track(UsernameBox:GetPropertyChangedSignal("Text"):Connect(function() resolveToken += 1; resetRecipientUI("No recipient selected", COLORS.Muted) end))
track(InventorySearch:GetPropertyChangedSignal("Text"):Connect(function() rebuildInventoryUI() end))
for name, filterButton in pairs(FilterButtons) do track(filterButton.Activated:Connect(function() State.Filter = name; for otherName, otherButton in pairs(FilterButtons) do otherButton.BackgroundColor3 = otherName == name and COLORS.Green2 or COLORS.Panel2 end; rebuildInventoryUI() end)) end
track(ClearButton.Activated:Connect(function() if State.Sending then return end; table.clear(State.Queue); rebuildInventoryUI(); rebuildQueueUI(); setStatus("Queue cleared") end))
track(NoteBox:GetPropertyChangedSignal("Text"):Connect(function() local clamped = clampUtf8(NoteBox.Text, NOTE_CODEPOINT_LIMIT); if clamped ~= NoteBox.Text then NoteBox.Text = clamped end; NoteCounter.Text = tostring(utf8.len(NoteBox.Text) or #NoteBox.Text) .. "/100" end))
track(SendButton.Activated:Connect(beginSend)); track(HistorySearch:GetPropertyChangedSignal("Text"):Connect(function() rebuildHistoryUI() end))
track(ClearHistoryButton.Activated:Connect(function() table.clear(History); saveHistory(); rebuildHistoryUI(); setStatus("Mail history cleared") end))

track(Networking.FruitStock.Snapshot.OnClientEvent:Connect(applyStockSnapshot)); requestStockSnapshot()
task.spawn(function() while not State.Dead do updateStockTimer(); local serverNow = os.time() + State.Stock.ClockOffset; if State.Stock.NextRefreshUnix <= serverNow then requestStockSnapshot() end; task.wait(1) end end)

local function inventoryFingerprint()
	local parts = {}
	for _, item in ipairs(inventoryEntries()) do
		local value = item.EntryValue
		parts[#parts + 1] = table.concat({
			item.Key,
			tostring(item.Available),
			tostring(type(value) == "table" and firstField(value, FRUIT_NAME_FIELDS) or ""),
			tostring(type(value) == "table" and firstField(value, FRUIT_ID_FIELDS) or ""),
			tostring(type(value) == "table" and firstField(value, FRUIT_MUTATION_FIELDS) or ""),
			tostring(type(value) == "table" and firstField(value, FRUIT_WEIGHT_FIELDS) or ""),
			tostring(type(value) == "table" and firstField(value, FRUIT_SIZE_FIELDS) or ""),
			tostring(type(value) == "table" and firstField(value, FRUIT_DECAY_FIELDS) or ""),
		}, "\30")
	end
	table.sort(parts); return table.concat(parts, "\27")
end
local function syncQueuedMetadata()
	local currentByKey = {}; for _, item in ipairs(inventoryEntries()) do currentByKey[item.Key] = item end
	for key, queued in pairs(State.Queue) do local current = currentByKey[key]; if current then queued.EntryValue = current.EntryValue; queued.DisplayName = current.DisplayName; queued.Icon = current.Icon end end
end
task.spawn(function()
	local lastFingerprint = ""
	while not State.Dead do
		local fingerprint = inventoryFingerprint()
		if fingerprint ~= lastFingerprint then lastFingerprint = fingerprint; syncQueuedMetadata(); rebuildInventoryUI(); rebuildQueueUI() end
		task.wait(1.25)
	end
end)

rebuildInventoryUI(); rebuildQueueUI(); rebuildHistoryUI(); updateStockTimer(); setStatus("Ready | grown fruits + live values enabled | Right Shift toggles UI", COLORS.Green)
