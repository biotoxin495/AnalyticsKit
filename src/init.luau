--!strict

--     _                _       _   _          _  ___ _
--    / \   _ __   __ _| |_   _| |_(_) ___ ___| |/ (_) |_
--   / _ \ | '_ \ / _` | | | | | __| |/ __/ __| ' /| | __|
--  / ___ \| | | | (_| | | |_| | |_| | (__\__ \ . \| | |_
-- /_/   \_\_| |_|\__,_|_|\__, |\__|_|\___|___/_|\_\_|\__|
--                        |___/

-- made with ❤️ by biotoxin495

-- A standalone, server-only wrapper around Roblox's AnalyticsService.
-- Centralizes analytics calls, validates payloads, and batches repetitive
-- economy events without merging unrelated SKUs.
--
-- Usage:
--   local AnalyticsKit = require(path.to.AnalyticsKit)
--   local Analytics = AnalyticsKit.new(config)
--
--   Analytics:LogCustomEvent(player, "Quest_Completed", 1)
--   Analytics:LogEconomyEvent(player, Enum.AnalyticsEconomyFlowType.Source, "Coins", 1, 501, nil, "PassiveIncome")
--   Analytics:LogOnboardingFunnelStepEvent(player, 2, "Choose Class")
--   Analytics:LogFunnelStepEvent(player, "ShopCheckout", sessionId, 1, "Opened Shop")
--   Analytics:LogProgressionStartEvent(player, "WorldAreas", 3, "Desert")
--
--   assert(Analytics:RegisterEvents(Catalog))  -- declarative event catalog
--   Analytics:LogEvent(player, "BoostUpgraded", { BoostType = "WalkSpeed", NewLevel = 4 })
--
--   Analytics:FlushEconomyBatches()
--   Analytics:Destroy()                        -- flushes pending batches and cleans up
--
-- Static helpers:
--   AnalyticsKit.CreateCustomFields(a, b, c)    -- pack up to 3 values into the custom-field dictionary
--
-- Config (all optional, constructor argument):
--   Enabled, WarningsEnabled, StrictValidation, StudioBehavior ("Print"|"Record"|"Ignore"),
--   MaxRecordedEvents, DeduplicateFunnelSteps, FlushEconomyBatchesBeforeDirect,
--   DefaultEconomyTransactionType, EconomyTransactionTypes ({ [sku] = transactionType }),
--   EconomyBatching ({ Enabled, Interval, Default, SKUs }),
--   RateLimit ({ Enabled, WarningThreshold, OverflowBehavior ("Warn"|"Drop") }),
--   Transport (function(record) -> () for custom/test transports)
--
-- Signals:
--   EventQueued, EventLogged, EventRecorded, EventIgnored, EventFailed, EventDropped, BatchFlushed
--
-- Features:
-- - Typed wrappers for custom, economy, funnel, onboarding, and progression events
-- - Declarative registered-event catalog
-- - SKU-preserving economy batching
-- - Payload validation and custom-field normalization
-- - Studio print/record/ignore modes and injectable transports
-- - Funnel-step deduplication
-- - Rate-budget diagnostics
-- - Lifecycle cleanup and observable signals

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AnalyticsKit = {}
AnalyticsKit.__index = AnalyticsKit
AnalyticsKit.ServiceName = "AnalyticsKit"

export type EventKind = "Custom" | "Economy" | "Funnel" | "Onboarding" | "Progression"
export type StudioBehavior = "Ignore" | "Print" | "Record"
export type RateLimitBehavior = "Warn" | "Drop"
export type LogStatus = "Logged" | "Queued" | "Recorded" | "Ignored" | "Duplicate"
export type CustomFields = { [string]: string }
export type Resolver<T> = T | ((player: Player, data: any) -> T)

export type EconomyBatchingConfig = {
	Enabled: boolean?,
	Interval: number?,
	Default: boolean?,
	SKUs: { [string]: boolean }?,
}

export type RateLimitConfig = {
	Enabled: boolean?,
	WarningThreshold: number?,
	OverflowBehavior: RateLimitBehavior?,
}

export type EventRecord = {
	Kind: EventKind,
	Player: Player,
	Timestamp: number,
	Clock: number,
	Sequence: number,
	RegisteredName: string?,
	Payload: { [string]: any },
	BatchCount: number?,
	BatchFirstTimestamp: number?,
	BatchLastTimestamp: number?,
}

export type Config = {
	Enabled: boolean?,
	WarningsEnabled: boolean?,
	StrictValidation: boolean?,
	StudioBehavior: StudioBehavior?,
	MaxRecordedEvents: number?,
	DeduplicateFunnelSteps: boolean?,
	FlushEconomyBatchesBeforeDirect: boolean?,
	DefaultEconomyTransactionType: string | EnumItem?,
	EconomyTransactionTypes: { [string]: string | EnumItem }?,
	EconomyBatching: EconomyBatchingConfig?,
	RateLimit: RateLimitConfig?,
	Transport: ((record: EventRecord) -> ())?,
}

type EconomyBatch = {
	Record: EventRecord,
	Count: number,
	FirstSequence: number,
	FirstTimestamp: number,
	LastTimestamp: number,
}

export type Diagnostics = {
	Attempted: number,
	Logged: number,
	Queued: number,
	Recorded: number,
	Ignored: number,
	Failed: number,
	Dropped: number,
	BatchesFlushed: number,
	EventsFlushed: number,
	RateWarnings: number,
	RequestsLastMinute: number,
	EstimatedRateLimit: number,
	RateLimitUsage: number,
	PendingEconomyBatches: number,
	RecordedEventCount: number,
}

export type DefinitionBase = {
	Enabled: Resolver<boolean>?,
	Validate: ((player: Player, data: any) -> (boolean, string?))?,
}

export type CustomEventDefinition = DefinitionBase & {
	Kind: "Custom",
	EventName: Resolver<string>,
	Value: Resolver<number>?,
	CustomFields: Resolver<CustomFields?>?,
}

export type EconomyEventDefinition = DefinitionBase & {
	Kind: "Economy",
	FlowType: Resolver<Enum.AnalyticsEconomyFlowType>,
	CurrencyType: Resolver<string>,
	Amount: Resolver<number>,
	EndingBalance: Resolver<number>,
	TransactionType: Resolver<string | EnumItem?>?,
	ItemSku: Resolver<string>,
	CustomFields: Resolver<CustomFields?>?,
	Batch: Resolver<boolean?>?,
}

export type FunnelEventDefinition = DefinitionBase & {
	Kind: "Funnel",
	FunnelName: Resolver<string>,
	FunnelSessionId: Resolver<string>,
	Step: Resolver<number>,
	StepName: Resolver<string>,
	CustomFields: Resolver<CustomFields?>?,
	AllowDuplicate: Resolver<boolean?>?,
}

export type OnboardingEventDefinition = DefinitionBase & {
	Kind: "Onboarding",
	Step: Resolver<number>,
	StepName: Resolver<string>,
	CustomFields: Resolver<CustomFields?>?,
	AllowDuplicate: Resolver<boolean?>?,
}

export type ProgressionEventDefinition = DefinitionBase & {
	Kind: "Progression",
	ProgressionPathName: Resolver<string>,
	Status: Resolver<Enum.AnalyticsProgressionType>,
	Level: Resolver<number>,
	LevelName: Resolver<string>,
	CustomFields: Resolver<CustomFields?>?,
}

export type RegisteredEventDefinition =
	CustomEventDefinition
	| EconomyEventDefinition
	| FunnelEventDefinition
	| OnboardingEventDefinition
	| ProgressionEventDefinition

export type AnalyticsKit = typeof(setmetatable(
	{} :: {
		Enabled: boolean,
		WarningsEnabled: boolean,
		StrictValidation: boolean,
		StudioBehavior: StudioBehavior,
		MaxRecordedEvents: number,
		DeduplicateFunnelSteps: boolean,
		FlushEconomyBatchesBeforeDirect: boolean,
		DefaultEconomyTransactionType: string | EnumItem,
		EconomyTransactionTypes: { [string]: string | EnumItem },
		EconomyBatching: {
			Enabled: boolean,
			Interval: number,
			Default: boolean,
			SKUs: { [string]: boolean },
		},
		RateLimit: {
			Enabled: boolean,
			WarningThreshold: number,
			OverflowBehavior: RateLimitBehavior,
		},
		Transport: ((record: EventRecord) -> ())?,

		EventQueued: RBXScriptSignal,
		EventLogged: RBXScriptSignal,
		EventRecorded: RBXScriptSignal,
		EventIgnored: RBXScriptSignal,
		EventFailed: RBXScriptSignal,
		EventDropped: RBXScriptSignal,
		BatchFlushed: RBXScriptSignal,

		_destroyed: boolean,
		_isStudio: boolean,
		_sequence: number,
		_flushGeneration: number,
		_playerRemovingConnection: RBXScriptConnection?,
		_events: { BindableEvent },
		_eventQueued: BindableEvent,
		_eventLogged: BindableEvent,
		_eventRecorded: BindableEvent,
		_eventIgnored: BindableEvent,
		_eventFailed: BindableEvent,
		_eventDropped: BindableEvent,
		_batchFlushed: BindableEvent,
		_registeredEvents: { [string]: RegisteredEventDefinition },
		_economyBatches: { [Player]: { [string]: EconomyBatch } },
		_funnelDedupe: { [Player]: { [string]: boolean } },
		_recordedEvents: { EventRecord },
		_requestTimes: { number },
		_requestTimeStart: number,
		_lastRateWarningClock: number,
		_diagnostics: {
			Attempted: number,
			Logged: number,
			Queued: number,
			Recorded: number,
			Ignored: number,
			Failed: number,
			Dropped: number,
			BatchesFlushed: number,
			EventsFlushed: number,
			RateWarnings: number,
		},
	},
	AnalyticsKit
))

local CUSTOM_FIELD_KEYS = {
	Enum.AnalyticsCustomFieldKeys.CustomField01,
	Enum.AnalyticsCustomFieldKeys.CustomField02,
	Enum.AnalyticsCustomFieldKeys.CustomField03,
}

local CUSTOM_FIELD_NAMES = {
	Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
	Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
}

local VALID_STUDIO_BEHAVIORS: { [string]: boolean } = {
	Ignore = true,
	Print = true,
	Record = true,
}

local VALID_RATE_BEHAVIORS: { [string]: boolean } = {
	Warn = true,
	Drop = true,
}

local function clamp(value: number, minimum: number, maximum: number): number
	return math.max(minimum, math.min(maximum, value))
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isNonEmptyString(value: any): boolean
	return typeof(value) == "string" and string.match(value, "%S") ~= nil
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function isEnumItemOf(value: any, enumType: any): boolean
	return typeof(value) == "EnumItem" and value.EnumType == enumType
end

local function encodeKeyPart(value: any): string
	local stringValue = tostring(value)
	return tostring(#stringValue) .. ":" .. stringValue
end

local function cloneDictionary(source: { [any]: any }): { [any]: any }
	local result = {}
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function cloneRecord(record: EventRecord): EventRecord
	local payload = cloneDictionary(record.Payload)
	local customFields = payload.CustomFields
	if typeof(customFields) == "table" then
		payload.CustomFields = cloneDictionary(customFields)
	end

	return {
		Kind = record.Kind,
		Player = record.Player,
		Timestamp = record.Timestamp,
		Clock = record.Clock,
		Sequence = record.Sequence,
		RegisteredName = record.RegisteredName,
		Payload = payload,
		BatchCount = record.BatchCount,
		BatchFirstTimestamp = record.BatchFirstTimestamp,
		BatchLastTimestamp = record.BatchLastTimestamp,
	}
end

local function createBindableEvent(name: string): BindableEvent
	local event = Instance.new("BindableEvent")
	event.Name = name
	return event
end

local function resolve<T>(resolver: Resolver<T>?, player: Player, data: any): (boolean, T?, string?)
	if typeof(resolver) == "function" then
		local ok, result = pcall(resolver :: any, player, data)
		if not ok then
			return false, nil, tostring(result)
		end
		return true, result :: T, nil
	end

	return true, resolver :: T?, nil
end

local function normalizeTransactionType(value: string | EnumItem?): (string?, string?)
	if value == nil then
		return nil, nil
	end

	if isNonEmptyString(value) then
		return value :: string, nil
	end

	if isEnumItemOf(value, Enum.AnalyticsEconomyTransactionType) then
		return (value :: EnumItem).Name, nil
	end

	return nil, "transactionType must be a non-empty string or AnalyticsEconomyTransactionType enum item"
end

local function customFieldsKey(customFields: CustomFields?): string
	if customFields == nil then
		return ""
	end

	local parts = table.create(3)
	for index, name in ipairs(CUSTOM_FIELD_NAMES) do
		parts[index] = encodeKeyPart(customFields[name] or "")
	end
	return table.concat(parts, "|")
end

local function economyBatchKey(payload: { [string]: any }): string
	return table.concat({
		encodeKeyPart((payload.FlowType :: EnumItem).Name),
		encodeKeyPart(payload.CurrencyType),
		encodeKeyPart(payload.TransactionType),
		encodeKeyPart(payload.ItemSku),
		encodeKeyPart(customFieldsKey(payload.CustomFields)),
	}, "|")
end

local function newDiagnostics()
	return {
		Attempted = 0,
		Logged = 0,
		Queued = 0,
		Recorded = 0,
		Ignored = 0,
		Failed = 0,
		Dropped = 0,
		BatchesFlushed = 0,
		EventsFlushed = 0,
		RateWarnings = 0,
	}
end

local function mergeConfig(config: Config?)
	local economyBatching = if config then config.EconomyBatching else nil
	local rateLimit = if config then config.RateLimit else nil

	local studioBehavior: StudioBehavior = "Print"
	if config and config.StudioBehavior and VALID_STUDIO_BEHAVIORS[config.StudioBehavior] then
		studioBehavior = config.StudioBehavior
	end

	local overflowBehavior: RateLimitBehavior = "Warn"
	if rateLimit and rateLimit.OverflowBehavior and VALID_RATE_BEHAVIORS[rateLimit.OverflowBehavior] then
		overflowBehavior = rateLimit.OverflowBehavior
	end

	local batchInterval = if economyBatching and isFiniteNumber(economyBatching.Interval)
		then math.max(1, economyBatching.Interval :: number)
		else 5

	local maxRecordedEvents = if config and isFiniteNumber(config.MaxRecordedEvents)
		then math.max(0, math.floor(config.MaxRecordedEvents :: number))
		else 200

	local warningThreshold = if rateLimit and isFiniteNumber(rateLimit.WarningThreshold)
		then clamp(rateLimit.WarningThreshold :: number, 0, 1)
		else 0.8

	return {
		Enabled = if config and config.Enabled ~= nil then config.Enabled else true,
		WarningsEnabled = if config and config.WarningsEnabled ~= nil then config.WarningsEnabled else true,
		StrictValidation = if config and config.StrictValidation ~= nil then config.StrictValidation else false,
		StudioBehavior = studioBehavior,
		MaxRecordedEvents = maxRecordedEvents,
		DeduplicateFunnelSteps = if config and config.DeduplicateFunnelSteps ~= nil
			then config.DeduplicateFunnelSteps
			else true,
		FlushEconomyBatchesBeforeDirect = if config and config.FlushEconomyBatchesBeforeDirect ~= nil
			then config.FlushEconomyBatchesBeforeDirect
			else true,
		DefaultEconomyTransactionType = if config and config.DefaultEconomyTransactionType ~= nil
			then config.DefaultEconomyTransactionType
			else Enum.AnalyticsEconomyTransactionType.Gameplay,
		EconomyTransactionTypes = if config and config.EconomyTransactionTypes
			then cloneDictionary(config.EconomyTransactionTypes) :: { [string]: string | EnumItem }
			else {},
		EconomyBatching = {
			Enabled = if economyBatching and economyBatching.Enabled ~= nil then economyBatching.Enabled else true,
			Interval = batchInterval,
			Default = if economyBatching and economyBatching.Default ~= nil then economyBatching.Default else false,
			SKUs = if economyBatching and economyBatching.SKUs
				then cloneDictionary(economyBatching.SKUs) :: { [string]: boolean }
				else {},
		},
		RateLimit = {
			Enabled = if rateLimit and rateLimit.Enabled ~= nil then rateLimit.Enabled else true,
			WarningThreshold = warningThreshold,
			OverflowBehavior = overflowBehavior,
		},
		Transport = if config then config.Transport else nil,
	}
end

function AnalyticsKit.CreateCustomFields(...: any): CustomFields?
	local count = select("#", ...)
	if count > 3 then
		error("AnalyticsKit.CreateCustomFields accepts at most three values", 2)
	end

	local result: CustomFields = {}
	for index = 1, count do
		local value = select(index, ...)
		if value ~= nil then
			local valueType = typeof(value)
			if valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean" then
				error(string.format("Custom field %d must be a string, number, boolean, or nil", index), 2)
			end
			if valueType == "number" and not isFiniteNumber(value) then
				error(string.format("Custom field %d must be finite", index), 2)
			end
			result[CUSTOM_FIELD_NAMES[index]] = tostring(value)
		end
	end

	return if next(result) ~= nil then result else nil
end

function AnalyticsKit.new(config: Config?): AnalyticsKit
	assert(RunService:IsServer(), "AnalyticsKit can only be constructed on the server")

	local merged = mergeConfig(config)
	local eventQueued = createBindableEvent("EventQueued")
	local eventLogged = createBindableEvent("EventLogged")
	local eventRecorded = createBindableEvent("EventRecorded")
	local eventIgnored = createBindableEvent("EventIgnored")
	local eventFailed = createBindableEvent("EventFailed")
	local eventDropped = createBindableEvent("EventDropped")
	local batchFlushed = createBindableEvent("BatchFlushed")

	local self = setmetatable({
		Enabled = merged.Enabled,
		WarningsEnabled = merged.WarningsEnabled,
		StrictValidation = merged.StrictValidation,
		StudioBehavior = merged.StudioBehavior,
		MaxRecordedEvents = merged.MaxRecordedEvents,
		DeduplicateFunnelSteps = merged.DeduplicateFunnelSteps,
		FlushEconomyBatchesBeforeDirect = merged.FlushEconomyBatchesBeforeDirect,
		DefaultEconomyTransactionType = merged.DefaultEconomyTransactionType,
		EconomyTransactionTypes = merged.EconomyTransactionTypes,
		EconomyBatching = merged.EconomyBatching,
		RateLimit = merged.RateLimit,
		Transport = merged.Transport,

		EventQueued = eventQueued.Event,
		EventLogged = eventLogged.Event,
		EventRecorded = eventRecorded.Event,
		EventIgnored = eventIgnored.Event,
		EventFailed = eventFailed.Event,
		EventDropped = eventDropped.Event,
		BatchFlushed = batchFlushed.Event,

		_destroyed = false,
		_isStudio = RunService:IsStudio(),
		_sequence = 0,
		_flushGeneration = 0,
		_playerRemovingConnection = nil,
		_events = {
			eventQueued,
			eventLogged,
			eventRecorded,
			eventIgnored,
			eventFailed,
			eventDropped,
			batchFlushed,
		},
		_eventQueued = eventQueued,
		_eventLogged = eventLogged,
		_eventRecorded = eventRecorded,
		_eventIgnored = eventIgnored,
		_eventFailed = eventFailed,
		_eventDropped = eventDropped,
		_batchFlushed = batchFlushed,
		_registeredEvents = {},
		_economyBatches = {},
		_funnelDedupe = {},
		_recordedEvents = {},
		_requestTimes = {},
		_requestTimeStart = 1,
		_lastRateWarningClock = -math.huge,
		_diagnostics = newDiagnostics(),
	}, AnalyticsKit) :: any

	self._playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		self:FlushEconomyBatchesForPlayer(player)
		self._economyBatches[player] = nil
		self._funnelDedupe[player] = nil
	end)

	self:_restartFlushLoop()
	return self
end

function AnalyticsKit:_assertAlive()
	if self._destroyed then
		error("AnalyticsKit has been destroyed", 3)
	end
end

function AnalyticsKit:_warn(message: string)
	if self.WarningsEnabled then
		warn("[AnalyticsKit] " .. message)
	end
end

function AnalyticsKit:_validationFailure(message: string): (boolean, string)
	self._diagnostics.Dropped += 1
	if self.StrictValidation then
		error("[AnalyticsKit] " .. message, 3)
	end
	self:_warn(message)
	return false, message
end

function AnalyticsKit:_nextRecord(
	kind: EventKind,
	player: Player,
	payload: { [string]: any },
	registeredName: string?
): EventRecord
	self._sequence += 1
	return {
		Kind = kind,
		Player = player,
		Timestamp = os.time(),
		Clock = os.clock(),
		Sequence = self._sequence,
		RegisteredName = registeredName,
		Payload = payload,
	}
end

function AnalyticsKit:_normalizeCustomFields(input: any): (CustomFields?, string?)
	if input == nil then
		return nil, nil
	end
	if typeof(input) ~= "table" then
		return nil, "customFields must be a table or nil"
	end

	local validKeyCount = 0
	for key in pairs(input) do
		local valid = false
		if typeof(key) == "number" then
			valid = key >= 1 and key <= 3 and key % 1 == 0
		elseif typeof(key) == "string" then
			valid = table.find(CUSTOM_FIELD_NAMES, key) ~= nil
		elseif typeof(key) == "EnumItem" then
			valid = false
			for _, enumKey in ipairs(CUSTOM_FIELD_KEYS) do
				if key == enumKey then
					valid = true
					break
				end
			end
		end

		if not valid then
			return nil,
				string.format(
					"invalid custom field key %s; use CreateCustomFields() or AnalyticsCustomFieldKeys",
					tostring(key)
				)
		end
		validKeyCount += 1
	end

	if validKeyCount > 3 then
		return nil, "customFields can contain at most three fields"
	end

	local result: CustomFields = {}
	for index, enumKey in ipairs(CUSTOM_FIELD_KEYS) do
		local name = CUSTOM_FIELD_NAMES[index]
		local value = input[index]
		if value == nil then
			value = input[name]
		end
		if value == nil then
			value = input[enumKey]
		end

		if value ~= nil then
			local valueType = typeof(value)
			if valueType ~= "string" and valueType ~= "number" and valueType ~= "boolean" then
				return nil, string.format("custom field %d must be a string, number, boolean, or nil", index)
			end
			if valueType == "number" and not isFiniteNumber(value) then
				return nil, string.format("custom field %d must be finite", index)
			end
			result[name] = tostring(value)
		end
	end

	return if next(result) ~= nil then result else nil, nil
end

function AnalyticsKit:_validatePlayer(player: any): (boolean, string?)
	if not isPlayer(player) then
		return false, "player must be a Player"
	end
	return true, nil
end

function AnalyticsKit:_recordDebugEvent(record: EventRecord)
	if self.MaxRecordedEvents <= 0 then
		return
	end

	table.insert(self._recordedEvents, cloneRecord(record))
	while #self._recordedEvents > self.MaxRecordedEvents do
		table.remove(self._recordedEvents, 1)
	end
end

function AnalyticsKit:_printDebugEvent(record: EventRecord)
	local label = record.RegisteredName or record.Kind
	if record.Kind == "Economy" then
		print(
			string.format(
				"[AnalyticsKit] %s | %s %s %s | SKU=%s | batch=%d",
				label,
				(record.Payload.FlowType :: EnumItem).Name,
				tostring(record.Payload.Amount),
				tostring(record.Payload.CurrencyType),
				tostring(record.Payload.ItemSku),
				record.BatchCount or 1
			)
		)
	else
		print(string.format("[AnalyticsKit] %s | %s", label, record.Kind))
	end
end

function AnalyticsKit:_pruneRequestTimes(now: number)
	local times = self._requestTimes
	local startIndex = self._requestTimeStart
	local cutoff = now - 60

	while startIndex <= #times and times[startIndex] <= cutoff do
		startIndex += 1
	end

	if startIndex > 64 and startIndex > (#times / 2) then
		local compacted = table.create(#times - startIndex + 1)
		for index = startIndex, #times do
			table.insert(compacted, times[index])
		end
		self._requestTimes = compacted
		self._requestTimeStart = 1
	else
		self._requestTimeStart = startIndex
	end
end

function AnalyticsKit:GetEstimatedRateLimit(): number
	return 120 + (20 * #Players:GetPlayers())
end

function AnalyticsKit:GetRequestsInLastMinute(): number
	self:_assertAlive()
	self:_pruneRequestTimes(os.clock())
	return math.max(0, #self._requestTimes - self._requestTimeStart + 1)
end

function AnalyticsKit:GetRateLimitUsage(): number
	local limit = self:GetEstimatedRateLimit()
	if limit <= 0 then
		return 0
	end
	return self:GetRequestsInLastMinute() / limit
end

function AnalyticsKit:_checkRateBudget(record: EventRecord): (boolean, string?)
	if not self.RateLimit.Enabled then
		return true, nil
	end

	local now = os.clock()
	self:_pruneRequestTimes(now)
	local requests = math.max(0, #self._requestTimes - self._requestTimeStart + 1)
	local limit = self:GetEstimatedRateLimit()
	local usageAfterRequest = (requests + 1) / limit

	if usageAfterRequest >= self.RateLimit.WarningThreshold and now - self._lastRateWarningClock >= 60 then
		self._lastRateWarningClock = now
		self._diagnostics.RateWarnings += 1
		self:_warn(
			string.format(
				"estimated AnalyticsService usage is %.0f%% (%d/%d requests in the last minute)",
				usageAfterRequest * 100,
				requests + 1,
				limit
			)
		)
	end

	if requests >= limit and self.RateLimit.OverflowBehavior == "Drop" then
		self._diagnostics.Dropped += 1
		local reason = string.format("estimated AnalyticsService rate budget exhausted (%d requests/minute)", limit)
		self._eventDropped:Fire(cloneRecord(record), reason)
		return false, reason
	end

	return true, nil
end

function AnalyticsKit:_defaultTransport(record: EventRecord)
	local payload = record.Payload

	if record.Kind == "Custom" then
		AnalyticsService:LogCustomEvent(record.Player, payload.EventName, payload.Value, payload.CustomFields)
	elseif record.Kind == "Economy" then
		AnalyticsService:LogEconomyEvent(
			record.Player,
			payload.FlowType,
			payload.CurrencyType,
			payload.Amount,
			payload.EndingBalance,
			payload.TransactionType,
			payload.ItemSku,
			payload.CustomFields
		)
	elseif record.Kind == "Funnel" then
		AnalyticsService:LogFunnelStepEvent(
			record.Player,
			payload.FunnelName,
			payload.FunnelSessionId,
			payload.Step,
			payload.StepName,
			payload.CustomFields
		)
	elseif record.Kind == "Onboarding" then
		AnalyticsService:LogOnboardingFunnelStepEvent(
			record.Player,
			payload.Step,
			payload.StepName,
			payload.CustomFields
		)
	elseif record.Kind == "Progression" then
		AnalyticsService:LogProgressionEvent(
			record.Player,
			payload.ProgressionPathName,
			payload.Status,
			payload.Level,
			payload.LevelName,
			payload.CustomFields
		)
	else
		error("Unsupported analytics event kind " .. tostring(record.Kind))
	end
end

function AnalyticsKit:_dispatchRecord(record: EventRecord): (boolean, string)
	if not self.Enabled then
		self._diagnostics.Ignored += 1
		self._eventIgnored:Fire(cloneRecord(record), "AnalyticsKit is disabled")
		return true, "Ignored"
	end

	if self._isStudio and self.Transport == nil then
		if self.StudioBehavior == "Ignore" then
			self._diagnostics.Ignored += 1
			self._eventIgnored:Fire(cloneRecord(record), "StudioBehavior is Ignore")
			return true, "Ignored"
		end

		if self.StudioBehavior == "Print" then
			self:_printDebugEvent(record)
		else
			self:_recordDebugEvent(record)
		end

		self._diagnostics.Recorded += 1
		self._eventRecorded:Fire(cloneRecord(record), self.StudioBehavior)
		return true, "Recorded"
	end

	local withinBudget, budgetError = self:_checkRateBudget(record)
	if not withinBudget then
		return false, budgetError or "rate budget exceeded"
	end

	local transport = self.Transport
	local ok, err = pcall(function()
		if transport then
			transport(cloneRecord(record))
		else
			self:_defaultTransport(record)
		end
	end)

	if not ok then
		self._diagnostics.Failed += 1
		local message = tostring(err)
		self:_warn("failed to log event: " .. message)
		self._eventFailed:Fire(cloneRecord(record), message)
		return false, message
	end

	table.insert(self._requestTimes, os.clock())
	self._diagnostics.Logged += 1
	self._eventLogged:Fire(cloneRecord(record))
	return true, "Logged"
end

function AnalyticsKit:_shouldBatchEconomySku(itemSku: string, explicitBatch: boolean?): boolean
	if not self.EconomyBatching.Enabled then
		return false
	end
	if explicitBatch ~= nil then
		return explicitBatch
	end

	local skuSetting = self.EconomyBatching.SKUs[itemSku]
	if skuSetting ~= nil then
		return skuSetting
	end
	return self.EconomyBatching.Default
end

function AnalyticsKit:_queueEconomyRecord(record: EventRecord): (boolean, string)
	local playerBatches = self._economyBatches[record.Player]
	if playerBatches == nil then
		playerBatches = {}
		self._economyBatches[record.Player] = playerBatches
	end

	local key = economyBatchKey(record.Payload)
	local batch = playerBatches[key]
	if batch == nil then
		local batchRecord = cloneRecord(record)
		batchRecord.Payload.Amount = 0
		batch = {
			Record = batchRecord,
			Count = 0,
			FirstSequence = record.Sequence,
			FirstTimestamp = record.Timestamp,
			LastTimestamp = record.Timestamp,
		}
		playerBatches[key] = batch
	end

	batch.Record.Payload.Amount += record.Payload.Amount
	batch.Record.Payload.EndingBalance = record.Payload.EndingBalance
	batch.Record.Timestamp = record.Timestamp
	batch.Record.Clock = record.Clock
	batch.Count += 1
	batch.LastTimestamp = record.Timestamp

	self._diagnostics.Queued += 1
	self._eventQueued:Fire(cloneRecord(record), batch.Count)
	return true, "Queued"
end

function AnalyticsKit:_submitCustom(
	player: Player,
	eventName: string,
	value: number?,
	customFields: any,
	registeredName: string?
): (boolean, string)
	self:_assertAlive()
	self._diagnostics.Attempted += 1

	local playerValid, playerError = self:_validatePlayer(player)
	if not playerValid then
		return self:_validationFailure(playerError :: string)
	end
	if not isNonEmptyString(eventName) then
		return self:_validationFailure("eventName must be a non-empty string")
	end

	local normalizedValue = if value == nil then 1 else value
	if not isFiniteNumber(normalizedValue) then
		return self:_validationFailure("custom event value must be a finite number")
	end

	local normalizedFields, fieldError = self:_normalizeCustomFields(customFields)
	if fieldError then
		return self:_validationFailure(fieldError)
	end

	local record = self:_nextRecord("Custom", player, {
		EventName = eventName,
		Value = normalizedValue,
		CustomFields = normalizedFields,
	}, registeredName)

	return self:_dispatchRecord(record)
end

function AnalyticsKit:LogCustomEvent(
	player: Player,
	eventName: string,
	value: number?,
	customFields: CustomFields?
): (boolean, string)
	return self:_submitCustom(player, eventName, value, customFields, nil)
end

function AnalyticsKit:_submitEconomy(
	player: Player,
	flowType: Enum.AnalyticsEconomyFlowType,
	currencyType: string,
	amount: number,
	endingBalance: number,
	transactionType: string | EnumItem?,
	itemSku: string,
	customFields: any,
	batch: boolean?,
	registeredName: string?
): (boolean, string)
	self:_assertAlive()
	self._diagnostics.Attempted += 1

	local playerValid, playerError = self:_validatePlayer(player)
	if not playerValid then
		return self:_validationFailure(playerError :: string)
	end
	if not isEnumItemOf(flowType, Enum.AnalyticsEconomyFlowType) then
		return self:_validationFailure("flowType must be an AnalyticsEconomyFlowType enum item")
	end
	if not isNonEmptyString(currencyType) then
		return self:_validationFailure("currencyType must be a non-empty string")
	end
	if not isFiniteNumber(amount) or amount <= 0 then
		return self:_validationFailure("economy amount must be a finite number greater than zero")
	end
	if not isFiniteNumber(endingBalance) or endingBalance < 0 then
		return self:_validationFailure("endingBalance must be a finite number greater than or equal to zero")
	end
	if not isNonEmptyString(itemSku) then
		return self:_validationFailure("itemSku must be a non-empty string")
	end

	local rawTransactionType = transactionType
	if rawTransactionType == nil then
		rawTransactionType = self.EconomyTransactionTypes[itemSku] or self.DefaultEconomyTransactionType
	end
	local normalizedTransactionType, transactionError = normalizeTransactionType(rawTransactionType)
	if transactionError or normalizedTransactionType == nil then
		return self:_validationFailure(transactionError or "transactionType is required")
	end

	local normalizedFields, fieldError = self:_normalizeCustomFields(customFields)
	if fieldError then
		return self:_validationFailure(fieldError)
	end

	local record = self:_nextRecord("Economy", player, {
		FlowType = flowType,
		CurrencyType = currencyType,
		Amount = amount,
		EndingBalance = endingBalance,
		TransactionType = normalizedTransactionType,
		ItemSku = itemSku,
		CustomFields = normalizedFields,
	}, registeredName)

	if not self.Enabled then
		return self:_dispatchRecord(record)
	end

	if self:_shouldBatchEconomySku(itemSku, batch) then
		return self:_queueEconomyRecord(record)
	end

	if self.FlushEconomyBatchesBeforeDirect and self._economyBatches[player] ~= nil then
		self:FlushEconomyBatchesForPlayer(player)
	end

	return self:_dispatchRecord(record)
end

function AnalyticsKit:LogEconomyEvent(
	player: Player,
	flowType: Enum.AnalyticsEconomyFlowType,
	currencyType: string,
	amount: number,
	endingBalance: number,
	transactionType: string | EnumItem?,
	itemSku: string,
	customFields: CustomFields?,
	batch: boolean?
): (boolean, string)
	return self:_submitEconomy(
		player,
		flowType,
		currencyType,
		amount,
		endingBalance,
		transactionType,
		itemSku,
		customFields,
		batch,
		nil
	)
end

function AnalyticsKit:_dedupeKeyForOnboarding(step: number): string
	return "Onboarding|" .. tostring(step)
end

function AnalyticsKit:_dedupeKeyForFunnel(funnelName: string, funnelSessionId: string, step: number): string
	return table.concat({
		"Funnel",
		encodeKeyPart(funnelName),
		encodeKeyPart(funnelSessionId),
		encodeKeyPart(step),
	}, "|")
end

function AnalyticsKit:_isDuplicateFunnelStep(player: Player, key: string): boolean
	local playerDedupe = self._funnelDedupe[player]
	return playerDedupe ~= nil and playerDedupe[key] == true
end

function AnalyticsKit:_markFunnelStep(player: Player, key: string)
	local playerDedupe = self._funnelDedupe[player]
	if playerDedupe == nil then
		playerDedupe = {}
		self._funnelDedupe[player] = playerDedupe
	end
	playerDedupe[key] = true
end

function AnalyticsKit:_handleDuplicate(record: EventRecord): (boolean, string)
	self._diagnostics.Ignored += 1
	self._eventIgnored:Fire(cloneRecord(record), "Duplicate funnel step")
	return true, "Duplicate"
end

function AnalyticsKit:_submitOnboarding(
	player: Player,
	step: number,
	stepName: string,
	customFields: any,
	allowDuplicate: boolean?,
	registeredName: string?
): (boolean, string)
	self:_assertAlive()
	self._diagnostics.Attempted += 1

	local playerValid, playerError = self:_validatePlayer(player)
	if not playerValid then
		return self:_validationFailure(playerError :: string)
	end
	if not isFiniteNumber(step) or step < 1 or step % 1 ~= 0 then
		return self:_validationFailure("onboarding step must be a positive integer")
	end
	if not isNonEmptyString(stepName) then
		return self:_validationFailure("stepName must be a non-empty string")
	end

	local normalizedFields, fieldError = self:_normalizeCustomFields(customFields)
	if fieldError then
		return self:_validationFailure(fieldError)
	end

	local record = self:_nextRecord("Onboarding", player, {
		Step = step,
		StepName = stepName,
		CustomFields = normalizedFields,
	}, registeredName)

	local dedupeKey = self:_dedupeKeyForOnboarding(step)
	if self.DeduplicateFunnelSteps and allowDuplicate ~= true and self:_isDuplicateFunnelStep(player, dedupeKey) then
		return self:_handleDuplicate(record)
	end

	local success, status = self:_dispatchRecord(record)
	if success and self.DeduplicateFunnelSteps and allowDuplicate ~= true then
		self:_markFunnelStep(player, dedupeKey)
	end
	return success, status
end

function AnalyticsKit:LogOnboardingFunnelStepEvent(
	player: Player,
	step: number,
	stepName: string,
	customFields: CustomFields?,
	allowDuplicate: boolean?
): (boolean, string)
	return self:_submitOnboarding(player, step, stepName, customFields, allowDuplicate, nil)
end

function AnalyticsKit:_submitFunnel(
	player: Player,
	funnelName: string,
	funnelSessionId: string,
	step: number,
	stepName: string,
	customFields: any,
	allowDuplicate: boolean?,
	registeredName: string?
): (boolean, string)
	self:_assertAlive()
	self._diagnostics.Attempted += 1

	local playerValid, playerError = self:_validatePlayer(player)
	if not playerValid then
		return self:_validationFailure(playerError :: string)
	end
	if not isNonEmptyString(funnelName) then
		return self:_validationFailure("funnelName must be a non-empty string")
	end
	if not isNonEmptyString(funnelSessionId) then
		return self:_validationFailure("funnelSessionId must be a non-empty string")
	end
	if not isFiniteNumber(step) or step < 1 or step % 1 ~= 0 then
		return self:_validationFailure("funnel step must be a positive integer")
	end
	if not isNonEmptyString(stepName) then
		return self:_validationFailure("stepName must be a non-empty string")
	end

	local normalizedFields, fieldError = self:_normalizeCustomFields(customFields)
	if fieldError then
		return self:_validationFailure(fieldError)
	end

	local record = self:_nextRecord("Funnel", player, {
		FunnelName = funnelName,
		FunnelSessionId = funnelSessionId,
		Step = step,
		StepName = stepName,
		CustomFields = normalizedFields,
	}, registeredName)

	local dedupeKey = self:_dedupeKeyForFunnel(funnelName, funnelSessionId, step)
	if self.DeduplicateFunnelSteps and allowDuplicate ~= true and self:_isDuplicateFunnelStep(player, dedupeKey) then
		return self:_handleDuplicate(record)
	end

	local success, status = self:_dispatchRecord(record)
	if success and self.DeduplicateFunnelSteps and allowDuplicate ~= true then
		self:_markFunnelStep(player, dedupeKey)
	end
	return success, status
end

function AnalyticsKit:LogFunnelStepEvent(
	player: Player,
	funnelName: string,
	funnelSessionId: string,
	step: number,
	stepName: string,
	customFields: CustomFields?,
	allowDuplicate: boolean?
): (boolean, string)
	return self:_submitFunnel(player, funnelName, funnelSessionId, step, stepName, customFields, allowDuplicate, nil)
end

function AnalyticsKit:_submitProgression(
	player: Player,
	progressionPathName: string,
	status: Enum.AnalyticsProgressionType,
	level: number,
	levelName: string,
	customFields: any,
	registeredName: string?
): (boolean, string)
	self:_assertAlive()
	self._diagnostics.Attempted += 1

	local playerValid, playerError = self:_validatePlayer(player)
	if not playerValid then
		return self:_validationFailure(playerError :: string)
	end
	if not isNonEmptyString(progressionPathName) then
		return self:_validationFailure("progressionPathName must be a non-empty string")
	end
	if not isEnumItemOf(status, Enum.AnalyticsProgressionType) then
		return self:_validationFailure("status must be an AnalyticsProgressionType enum item")
	end
	if not isFiniteNumber(level) or level < 1 or level % 1 ~= 0 then
		return self:_validationFailure("progression level must be a positive integer")
	end
	if not isNonEmptyString(levelName) then
		return self:_validationFailure("levelName must be a non-empty string")
	end

	local normalizedFields, fieldError = self:_normalizeCustomFields(customFields)
	if fieldError then
		return self:_validationFailure(fieldError)
	end

	local record = self:_nextRecord("Progression", player, {
		ProgressionPathName = progressionPathName,
		Status = status,
		Level = level,
		LevelName = levelName,
		CustomFields = normalizedFields,
	}, registeredName)

	return self:_dispatchRecord(record)
end

function AnalyticsKit:LogProgressionEvent(
	player: Player,
	progressionPathName: string,
	status: Enum.AnalyticsProgressionType,
	level: number,
	levelName: string,
	customFields: CustomFields?
): (boolean, string)
	return self:_submitProgression(player, progressionPathName, status, level, levelName, customFields, nil)
end

function AnalyticsKit:LogProgressionStartEvent(
	player: Player,
	progressionPathName: string,
	level: number,
	levelName: string,
	customFields: CustomFields?
): (boolean, string)
	return self:_submitProgression(
		player,
		progressionPathName,
		Enum.AnalyticsProgressionType.Start,
		level,
		levelName,
		customFields,
		nil
	)
end

function AnalyticsKit:LogProgressionCompleteEvent(
	player: Player,
	progressionPathName: string,
	level: number,
	levelName: string,
	customFields: CustomFields?
): (boolean, string)
	return self:_submitProgression(
		player,
		progressionPathName,
		Enum.AnalyticsProgressionType.Complete,
		level,
		levelName,
		customFields,
		nil
	)
end

function AnalyticsKit:LogProgressionFailEvent(
	player: Player,
	progressionPathName: string,
	level: number,
	levelName: string,
	customFields: CustomFields?
): (boolean, string)
	return self:_submitProgression(
		player,
		progressionPathName,
		Enum.AnalyticsProgressionType.Fail,
		level,
		levelName,
		customFields,
		nil
	)
end

function AnalyticsKit:RegisterEvent(
	name: string,
	definition: RegisteredEventDefinition,
	overwrite: boolean?
): (boolean, string?)
	self:_assertAlive()
	if not isNonEmptyString(name) then
		return false, "registered event name must be a non-empty string"
	end
	if typeof(definition) ~= "table" then
		return false, "definition must be a table"
	end
	if self._registeredEvents[name] ~= nil and overwrite ~= true then
		return false, string.format("event %q is already registered", name)
	end

	local kind = (definition :: any).Kind
	if
		kind ~= "Custom"
		and kind ~= "Economy"
		and kind ~= "Funnel"
		and kind ~= "Onboarding"
		and kind ~= "Progression"
	then
		return false, "definition.Kind must be Custom, Economy, Funnel, Onboarding, or Progression"
	end

	self._registeredEvents[name] = definition
	return true, nil
end

function AnalyticsKit:RegisterEvents(
	definitions: { [string]: RegisteredEventDefinition },
	overwrite: boolean?
): (boolean, string?)
	self:_assertAlive()
	for name, definition in pairs(definitions) do
		local success, err = self:RegisterEvent(name, definition, overwrite)
		if not success then
			return false, err
		end
	end
	return true, nil
end

function AnalyticsKit:UnregisterEvent(name: string): boolean
	self:_assertAlive()
	if self._registeredEvents[name] == nil then
		return false
	end
	self._registeredEvents[name] = nil
	return true
end

function AnalyticsKit:HasEvent(name: string): boolean
	self:_assertAlive()
	return self._registeredEvents[name] ~= nil
end

function AnalyticsKit:GetRegisteredEventNames(): { string }
	self:_assertAlive()
	local names = {}
	for name in pairs(self._registeredEvents) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function AnalyticsKit:_resolveDefinitionValue(
	definition: RegisteredEventDefinition,
	key: string,
	player: Player,
	data: any,
	required: boolean
): (boolean, any, string?)
	local resolver = (definition :: any)[key]
	if resolver == nil then
		if required then
			return false, nil, string.format("registered event is missing %s", key)
		end
		return true, nil, nil
	end

	local success, value, err = resolve(resolver, player, data)
	if not success then
		return false, nil, string.format("%s resolver failed: %s", key, err or "unknown error")
	end
	return true, value, nil
end

function AnalyticsKit:LogEvent(player: Player, name: string, data: any?): (boolean, string)
	self:_assertAlive()
	local definition = self._registeredEvents[name]
	if definition == nil then
		return self:_validationFailure(string.format("no registered analytics event named %q", name))
	end

	local enabledOk, enabled, enabledError = self:_resolveDefinitionValue(definition, "Enabled", player, data, false)
	if not enabledOk then
		return self:_validationFailure(enabledError :: string)
	end
	if enabled == false then
		self._diagnostics.Ignored += 1
		return true, "Ignored"
	end

	local validate = (definition :: any).Validate
	if validate ~= nil then
		local ok, valid, message = pcall(validate, player, data)
		if not ok then
			return self:_validationFailure(string.format("Validate callback failed for %q: %s", name, tostring(valid)))
		end
		if valid ~= true then
			return self:_validationFailure(message or string.format("validation failed for %q", name))
		end
	end

	if definition.Kind == "Custom" then
		local eventNameOk, eventName, eventNameError =
			self:_resolveDefinitionValue(definition, "EventName", player, data, true)
		local valueOk, value, valueError = self:_resolveDefinitionValue(definition, "Value", player, data, false)
		local fieldsOk, fields, fieldsError =
			self:_resolveDefinitionValue(definition, "CustomFields", player, data, false)
		if not eventNameOk or not valueOk or not fieldsOk then
			return self:_validationFailure(
				eventNameError or valueError or fieldsError or "failed to resolve custom event"
			)
		end
		return self:_submitCustom(player, eventName, value, fields, name)
	end

	if definition.Kind == "Economy" then
		local flowOk, flow, flowError = self:_resolveDefinitionValue(definition, "FlowType", player, data, true)
		local currencyOk, currency, currencyError =
			self:_resolveDefinitionValue(definition, "CurrencyType", player, data, true)
		local amountOk, amount, amountError = self:_resolveDefinitionValue(definition, "Amount", player, data, true)
		local balanceOk, balance, balanceError =
			self:_resolveDefinitionValue(definition, "EndingBalance", player, data, true)
		local transactionOk, transaction, transactionError =
			self:_resolveDefinitionValue(definition, "TransactionType", player, data, false)
		local skuOk, sku, skuError = self:_resolveDefinitionValue(definition, "ItemSku", player, data, true)
		local fieldsOk, fields, fieldsError =
			self:_resolveDefinitionValue(definition, "CustomFields", player, data, false)
		local batchOk, batch, batchError = self:_resolveDefinitionValue(definition, "Batch", player, data, false)
		if
			not flowOk
			or not currencyOk
			or not amountOk
			or not balanceOk
			or not transactionOk
			or not skuOk
			or not fieldsOk
			or not batchOk
		then
			return self:_validationFailure(
				flowError
					or currencyError
					or amountError
					or balanceError
					or transactionError
					or skuError
					or fieldsError
					or batchError
					or "failed to resolve economy event"
			)
		end
		return self:_submitEconomy(player, flow, currency, amount, balance, transaction, sku, fields, batch, name)
	end

	if definition.Kind == "Onboarding" then
		local stepOk, step, stepError = self:_resolveDefinitionValue(definition, "Step", player, data, true)
		local stepNameOk, stepName, stepNameError =
			self:_resolveDefinitionValue(definition, "StepName", player, data, true)
		local fieldsOk, fields, fieldsError =
			self:_resolveDefinitionValue(definition, "CustomFields", player, data, false)
		local duplicateOk, allowDuplicate, duplicateError =
			self:_resolveDefinitionValue(definition, "AllowDuplicate", player, data, false)
		if not stepOk or not stepNameOk or not fieldsOk or not duplicateOk then
			return self:_validationFailure(
				stepError or stepNameError or fieldsError or duplicateError or "failed to resolve onboarding event"
			)
		end
		return self:_submitOnboarding(player, step, stepName, fields, allowDuplicate, name)
	end

	if definition.Kind == "Funnel" then
		local funnelOk, funnel, funnelError = self:_resolveDefinitionValue(definition, "FunnelName", player, data, true)
		local sessionOk, session, sessionError =
			self:_resolveDefinitionValue(definition, "FunnelSessionId", player, data, true)
		local stepOk, step, stepError = self:_resolveDefinitionValue(definition, "Step", player, data, true)
		local stepNameOk, stepName, stepNameError =
			self:_resolveDefinitionValue(definition, "StepName", player, data, true)
		local fieldsOk, fields, fieldsError =
			self:_resolveDefinitionValue(definition, "CustomFields", player, data, false)
		local duplicateOk, allowDuplicate, duplicateError =
			self:_resolveDefinitionValue(definition, "AllowDuplicate", player, data, false)
		if not funnelOk or not sessionOk or not stepOk or not stepNameOk or not fieldsOk or not duplicateOk then
			return self:_validationFailure(
				funnelError
					or sessionError
					or stepError
					or stepNameError
					or fieldsError
					or duplicateError
					or "failed to resolve funnel event"
			)
		end
		return self:_submitFunnel(player, funnel, session, step, stepName, fields, allowDuplicate, name)
	end

	local pathOk, path, pathError = self:_resolveDefinitionValue(definition, "ProgressionPathName", player, data, true)
	local statusOk, status, statusError = self:_resolveDefinitionValue(definition, "Status", player, data, true)
	local levelOk, level, levelError = self:_resolveDefinitionValue(definition, "Level", player, data, true)
	local levelNameOk, levelName, levelNameError =
		self:_resolveDefinitionValue(definition, "LevelName", player, data, true)
	local fieldsOk, fields, fieldsError = self:_resolveDefinitionValue(definition, "CustomFields", player, data, false)
	if not pathOk or not statusOk or not levelOk or not levelNameOk or not fieldsOk then
		return self:_validationFailure(
			pathError
				or statusError
				or levelError
				or levelNameError
				or fieldsError
				or "failed to resolve progression event"
		)
	end
	return self:_submitProgression(player, path, status, level, levelName, fields, name)
end

function AnalyticsKit:_restartFlushLoop()
	self._flushGeneration += 1
	local generation = self._flushGeneration

	if self._destroyed or not self.EconomyBatching.Enabled then
		return
	end

	local function scheduleNext()
		task.delay(self.EconomyBatching.Interval, function()
			if self._destroyed or generation ~= self._flushGeneration then
				return
			end
			self:FlushEconomyBatches()
			scheduleNext()
		end)
	end

	scheduleNext()
end

function AnalyticsKit:_flushBatchList(player: Player, batches: { EconomyBatch }): (number, number)
	table.sort(batches, function(a, b)
		return a.FirstSequence < b.FirstSequence
	end)

	local logged = 0
	local failed = 0
	local logicalEvents = 0
	for _, batch in ipairs(batches) do
		local record = batch.Record
		record.BatchCount = batch.Count
		record.BatchFirstTimestamp = batch.FirstTimestamp
		record.BatchLastTimestamp = batch.LastTimestamp
		logicalEvents += batch.Count

		local success = self:_dispatchRecord(record)
		if success then
			logged += 1
		else
			failed += 1
		end
	end

	if #batches > 0 then
		self._diagnostics.BatchesFlushed += #batches
		self._diagnostics.EventsFlushed += logicalEvents
		self._batchFlushed:Fire({
			Player = player,
			BatchCount = #batches,
			LogicalEventCount = logicalEvents,
			LoggedCount = logged,
			FailedCount = failed,
		})
	end

	return logged, failed
end

function AnalyticsKit:FlushEconomyBatchesForPlayer(player: Player): (number, number)
	self:_assertAlive()
	local playerBatches = self._economyBatches[player]
	if playerBatches == nil then
		return 0, 0
	end

	self._economyBatches[player] = nil
	local batches = {}
	for _, batch in pairs(playerBatches) do
		table.insert(batches, batch)
	end

	return self:_flushBatchList(player, batches)
end

function AnalyticsKit:FlushEconomyBatches(): (number, number)
	self:_assertAlive()
	local totalLogged = 0
	local totalFailed = 0

	local playersToFlush = {}
	for player in pairs(self._economyBatches) do
		table.insert(playersToFlush, player)
	end

	for _, player in ipairs(playersToFlush) do
		local logged, failed = self:FlushEconomyBatchesForPlayer(player)
		totalLogged += logged
		totalFailed += failed
	end

	return totalLogged, totalFailed
end

function AnalyticsKit:GetPendingEconomyBatchCount(): number
	self:_assertAlive()
	local count = 0
	for _, playerBatches in pairs(self._economyBatches) do
		for _ in pairs(playerBatches) do
			count += 1
		end
	end
	return count
end

function AnalyticsKit:SetEnabled(enabled: boolean)
	self:_assertAlive()
	assert(typeof(enabled) == "boolean", "enabled must be a boolean")
	self.Enabled = enabled
end

function AnalyticsKit:SetEconomyBatchingEnabled(enabled: boolean, flushWhenDisabled: boolean?)
	self:_assertAlive()
	assert(typeof(enabled) == "boolean", "enabled must be a boolean")
	if self.EconomyBatching.Enabled == enabled then
		return
	end

	if not enabled and flushWhenDisabled ~= false then
		self:FlushEconomyBatches()
	end
	self.EconomyBatching.Enabled = enabled
	self:_restartFlushLoop()
end

function AnalyticsKit:SetEconomyBatchInterval(interval: number)
	self:_assertAlive()
	assert(isFiniteNumber(interval) and interval >= 1, "interval must be a finite number greater than or equal to 1")
	self.EconomyBatching.Interval = interval
	self:_restartFlushLoop()
end

function AnalyticsKit:SetEconomySkuBatching(itemSku: string, enabled: boolean?)
	self:_assertAlive()
	assert(isNonEmptyString(itemSku), "itemSku must be a non-empty string")
	if enabled == nil then
		self.EconomyBatching.SKUs[itemSku] = nil
	else
		assert(typeof(enabled) == "boolean", "enabled must be a boolean or nil")
		self.EconomyBatching.SKUs[itemSku] = enabled
	end
end

function AnalyticsKit:SetEconomyTransactionType(itemSku: string, transactionType: string | EnumItem?)
	self:_assertAlive()
	assert(isNonEmptyString(itemSku), "itemSku must be a non-empty string")
	if transactionType == nil then
		self.EconomyTransactionTypes[itemSku] = nil
		return
	end

	local _, err = normalizeTransactionType(transactionType)
	assert(err == nil, err)
	self.EconomyTransactionTypes[itemSku] = transactionType
end

function AnalyticsKit:ResetFunnelDedupe(player: Player?)
	self:_assertAlive()
	if player == nil then
		table.clear(self._funnelDedupe)
	else
		self._funnelDedupe[player] = nil
	end
end

function AnalyticsKit:GetRecordedEvents(clearAfterRead: boolean?): { EventRecord }
	self:_assertAlive()
	local result = table.create(#self._recordedEvents)
	for _, record in ipairs(self._recordedEvents) do
		table.insert(result, cloneRecord(record))
	end
	if clearAfterRead then
		table.clear(self._recordedEvents)
	end
	return result
end

function AnalyticsKit:ClearRecordedEvents()
	self:_assertAlive()
	table.clear(self._recordedEvents)
end

function AnalyticsKit:GetDiagnostics(): Diagnostics
	self:_assertAlive()
	local requests = self:GetRequestsInLastMinute()
	local limit = self:GetEstimatedRateLimit()
	return {
		Attempted = self._diagnostics.Attempted,
		Logged = self._diagnostics.Logged,
		Queued = self._diagnostics.Queued,
		Recorded = self._diagnostics.Recorded,
		Ignored = self._diagnostics.Ignored,
		Failed = self._diagnostics.Failed,
		Dropped = self._diagnostics.Dropped,
		BatchesFlushed = self._diagnostics.BatchesFlushed,
		EventsFlushed = self._diagnostics.EventsFlushed,
		RateWarnings = self._diagnostics.RateWarnings,
		RequestsLastMinute = requests,
		EstimatedRateLimit = limit,
		RateLimitUsage = if limit > 0 then requests / limit else 0,
		PendingEconomyBatches = self:GetPendingEconomyBatchCount(),
		RecordedEventCount = #self._recordedEvents,
	}
end

function AnalyticsKit:ResetDiagnostics()
	self:_assertAlive()
	self._diagnostics = newDiagnostics()
	table.clear(self._requestTimes)
	self._requestTimeStart = 1
	self._lastRateWarningClock = -math.huge
end

function AnalyticsKit:GetPlayerSegmentsAsync(player: Player): ({ [string]: any }?, string?)
	self:_assertAlive()
	local playerValid, playerError = self:_validatePlayer(player)
	if not playerValid then
		return nil, playerError
	end

	if self._isStudio then
		return nil, "GetPlayerSegmentsAsync is unavailable in Studio"
	end

	local success, result = pcall(function()
		return AnalyticsService:GetPlayerSegmentsAsync(player)
	end)
	if not success then
		local message = tostring(result)
		self:_warn("GetPlayerSegmentsAsync failed: " .. message)
		return nil, message
	end
	return result :: { [string]: any }, nil
end

function AnalyticsKit:Destroy(flushPending: boolean?)
	if self._destroyed then
		return
	end

	if flushPending ~= false then
		self:FlushEconomyBatches()
	end

	self._destroyed = true
	self._flushGeneration += 1

	if self._playerRemovingConnection then
		self._playerRemovingConnection:Disconnect()
		self._playerRemovingConnection = nil
	end

	table.clear(self._registeredEvents)
	table.clear(self._economyBatches)
	table.clear(self._funnelDedupe)
	table.clear(self._recordedEvents)
	table.clear(self._requestTimes)

	for _, event in ipairs(self._events) do
		event:Destroy()
	end
	table.clear(self._events)
end

return AnalyticsKit
