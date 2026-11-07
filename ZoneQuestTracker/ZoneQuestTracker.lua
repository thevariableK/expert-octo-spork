-- Zone Quest Tracker
-- Keeps the objective tracker limited to quests in the current zone, sorted by level.
--
-- The Forever client uses the Mainline ObjectiveTracker, which renders quests in the
-- order of C_QuestLog's watch list. Rather than overriding Blizzard tracker code (which
-- owns secure quest-item buttons and would taint them), this addon manages the watch
-- list itself through the public C_QuestLog API.
--
-- Player intent (manual track/untrack) is detected by diffing the live watch list
-- against the one we last applied, not by interpreting individual watch events, so it
-- is unaffected by event timing or Blizzard's own re-sorting.

local addonName, ns = ...

local MAX_WATCHES = (Constants and Constants.QuestWatchConsts and Constants.QuestWatchConsts.MAX_QUEST_WATCHES) or 25
local REFRESH_DELAY = 0.2

local db
local refreshQueued = false
local refreshAfterCombat = false
local restoreAfterCombat = false

local zoneNames = {}        -- names that count as the current zone (cached per zone change)
local lastApplied           -- set of questIDs watched after our last refresh; nil = no baseline yet
local lastInLog = {}        -- set of questIDs that were in the quest log at our last refresh
local lastDesiredKey        -- desired order we already tried to apply (guards against reorder loops)
local dismissed = {}        -- zone quests the player untracked; cleared on zone change
local warnedTruncated = false
local sessionSnapshot       -- watch list captured when enabled via /zqt this session

local function Print(msg)
	print("|cff33ff99ZoneQuestTracker|r: " .. msg)
end

local function UpdateZoneNames()
	wipe(zoneNames)
	local real = GetRealZoneText()
	if real and real ~= "" then zoneNames[real] = true end
	local mapID = C_Map.GetBestMapForUnit("player")
	if mapID then
		local info = C_Map.GetMapInfo(mapID)
		-- walk up to the zone-level map so subzone maps still match
		while info and info.mapType and Enum.UIMapType and info.mapType > Enum.UIMapType.Zone and info.parentMapID and info.parentMapID ~= 0 do
			info = C_Map.GetMapInfo(info.parentMapID)
		end
		if info and info.name then zoneNames[info.name] = true end
	end
end

-- Returns a map questID -> { level, title, inZone } for every trackable quest in the log.
local function CollectQuests()
	local quests = {}
	local currentHeader

	for i = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(i)
		if info then
			if info.isHeader then
				currentHeader = info.title
			elseif info.questID and info.questID ~= 0 and not info.isHidden and not info.isTask and not info.isBounty then
				quests[info.questID] = {
					level = (info.difficultyLevel and info.difficultyLevel > 0) and info.difficultyLevel or info.level or 0,
					title = info.title or "",
					inZone = (currentHeader and zoneNames[currentHeader]) or info.isOnMap or false,
				}
			end
		end
	end

	return quests
end

local function SortByLevel(list, quests)
	table.sort(list, function(a, b)
		local qa, qb = quests[a], quests[b]
		if qa.level ~= qb.level then return qa.level < qb.level end
		if qa.title ~= qb.title then return qa.title < qb.title end
		return a < b
	end)
end

local function CurrentWatchList()
	local list = {}
	for i = 1, C_QuestLog.GetNumQuestWatches() do
		local questID = C_QuestLog.GetQuestIDForQuestWatchIndex(i)
		if questID then table.insert(list, questID) end
	end
	return list
end

local function ToSet(list)
	local set = {}
	for _, v in ipairs(list) do set[v] = true end
	return set
end

local function ListsEqual(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local function SetsEqual(a, b)
	if #a ~= #b then return false end
	local set = ToSet(a)
	for _, v in ipairs(b) do
		if not set[v] then return false end
	end
	return true
end

-- Compare the live watch list against what we last applied to learn what the player did.
local function DetectPlayerChanges(current, quests)
	if not lastApplied then return end
	local currentSet = ToSet(current)

	for _, questID in ipairs(current) do
		-- Only quests that were already in the log count as player tracks; a quest that
		-- just entered the log was auto-watched on accept and follows the normal rules.
		if not lastApplied[questID] and lastInLog[questID] and quests[questID] then
			dismissed[questID] = nil
			if not quests[questID].inZone then
				db.pinned[questID] = true
			end
		end
	end

	for questID in pairs(lastApplied) do
		-- Still in the log but no longer watched: the player untracked it.
		if not currentSet[questID] and quests[questID] then
			db.pinned[questID] = nil
			if quests[questID].inZone then
				dismissed[questID] = true
			end
		end
	end
end

local function BuildDesired(quests)
	for questID in pairs(db.pinned) do
		if not quests[questID] then db.pinned[questID] = nil end
	end

	local zoneList, pinList = {}, {}
	for questID, q in pairs(quests) do
		if q.inZone then
			if not dismissed[questID] then table.insert(zoneList, questID) end
		elseif db.pinned[questID] then
			table.insert(pinList, questID)
		end
	end
	SortByLevel(zoneList, quests)
	SortByLevel(pinList, quests)

	-- Pins are explicit player choices, so they get their slots first.
	while #pinList > MAX_WATCHES do table.remove(pinList) end
	local zoneCapacity = MAX_WATCHES - #pinList
	if #zoneList > zoneCapacity then
		if not warnedTruncated then
			warnedTruncated = true
			Print(("%d quests in this zone; showing the lowest %d (watch limit is %d)."):format(#zoneList, zoneCapacity, MAX_WATCHES))
		end
		while #zoneList > zoneCapacity do table.remove(zoneList) end
	end

	for _, questID in ipairs(pinList) do table.insert(zoneList, questID) end
	return zoneList
end

local function ApplyWatches(current, desired)
	if ListsEqual(current, desired) then return end

	-- If the set is already right and we already tried this order, the client is
	-- keeping its own order; don't fight it in a loop until something changes.
	local key = table.concat(desired, ",")
	if key == lastDesiredKey and SetsEqual(current, desired) then return end
	lastDesiredKey = key

	local superTracked = C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID and C_SuperTrack.GetSuperTrackedQuestID()

	-- Keep the matching prefix; only rewrite from the first difference onwards.
	local prefix = 0
	while prefix < #current and prefix < #desired and current[prefix + 1] == desired[prefix + 1] do
		prefix = prefix + 1
	end
	for i = #current, prefix + 1, -1 do
		C_QuestLog.RemoveQuestWatch(current[i])
	end
	for i = prefix + 1, #desired do
		C_QuestLog.AddQuestWatch(desired[i])
	end

	if superTracked and superTracked ~= 0 and ToSet(desired)[superTracked]
		and C_SuperTrack.GetSuperTrackedQuestID() ~= superTracked then
		C_SuperTrack.SetSuperTrackedQuestID(superTracked)
	end
end

local function Refresh()
	refreshQueued = false
	if not db.enabled then return end

	if InCombatLockdown() then
		refreshAfterCombat = true
		return
	end

	local quests = CollectQuests()
	local current = CurrentWatchList()

	DetectPlayerChanges(current, quests)
	ApplyWatches(current, BuildDesired(quests))

	lastApplied = ToSet(CurrentWatchList())
	wipe(lastInLog)
	for questID in pairs(quests) do lastInLog[questID] = true end
end

local function QueueRefresh()
	if refreshQueued or not db or not db.enabled then return end
	refreshQueued = true
	C_Timer.After(REFRESH_DELAY, Refresh)
end

local function ResetBaseline()
	lastApplied = nil
	lastDesiredKey = nil
	wipe(dismissed)
end

local function Enable()
	db.enabled = true
	sessionSnapshot = CurrentWatchList()
	ResetBaseline()
	UpdateZoneNames()
	QueueRefresh()
end

-- Restores the list from when the addon was turned on this session, if there is one.
-- Returns "restored", "kept" (no snapshot this session; current list left as is) or "deferred".
local function RestoreWatches()
	if InCombatLockdown() then
		restoreAfterCombat = true
		return "deferred"
	end
	local saved = sessionSnapshot
	sessionSnapshot = nil
	if not saved then return "kept" end

	for _, questID in ipairs(CurrentWatchList()) do
		C_QuestLog.RemoveQuestWatch(questID)
	end
	for _, questID in ipairs(saved) do
		if C_QuestLog.GetLogIndexForQuestID(questID) then
			C_QuestLog.AddQuestWatch(questID)
		end
	end
	return "restored"
end

local function Disable()
	db.enabled = false
	refreshAfterCombat = false
	ResetBaseline()
	return RestoreWatches()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

local lastZone

frame:SetScript("OnEvent", function(self, event, ...)
	if event == "ADDON_LOADED" then
		if ... ~= addonName then return end
		ZoneQuestTrackerDB = ZoneQuestTrackerDB or {}
		db = ZoneQuestTrackerDB
		if db.enabled == nil then db.enabled = true end
		db.pinned = db.pinned or {}
		db.savedWatches = nil -- obsolete field from 1.0.0
		self:UnregisterEvent("ADDON_LOADED")
		return
	end
	if not db then return end

	if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
		UpdateZoneNames()
		local zone = GetRealZoneText()
		if zone ~= lastZone then
			lastZone = zone
			wipe(dismissed)
			warnedTruncated = false
		end
		-- Blizzard re-sorts watches by proximity on zone change; allow re-applying our order.
		lastDesiredKey = nil
		QueueRefresh()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if restoreAfterCombat then
			restoreAfterCombat = false
			if not db.enabled then
				RestoreWatches()
				Print("previous tracked quests restored.")
			end
		end
		if refreshAfterCombat then
			refreshAfterCombat = false
			QueueRefresh()
		end
	else
		-- Quest log / watch changes. Bursts are coalesced into one refresh by QueueRefresh.
		QueueRefresh()
	end
end)

SLASH_ZONEQUESTTRACKER1 = "/zqt"
SlashCmdList.ZONEQUESTTRACKER = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "on" or (msg == "" and not db.enabled) then
		Enable()
		Print("enabled - tracking current-zone quests sorted by level.")
	elseif msg == "off" or msg == "" then
		local result = Disable()
		if result == "restored" then
			Print("disabled - previous tracked quests restored.")
		elseif result == "deferred" then
			Print("disabled - previous tracked quests will be restored after combat.")
		else
			Print("disabled - tracked quests left as they are.")
		end
	elseif msg == "unpin" then
		wipe(db.pinned)
		wipe(dismissed)
		lastDesiredKey = nil
		QueueRefresh()
		Print("cleared pinned and dismissed quests.")
	else
		Print("commands: /zqt (toggle), /zqt on, /zqt off, /zqt unpin")
	end
end
