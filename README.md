# AnalyticsKit — A standalone server-only wrapper for Roblox's AnalyticsService

**AnalyticsKit**, a standalone, server-only wrapper around Roblox's `AnalyticsService`.

Calling `AnalyticsService` directly from scattered locations in a codebase tends to get messy: payloads go unvalidated, custom fields get encoded inconsistently, Studio calls silently vanish into the void, and repetitive economy events (passive income ticks, per-hit rewards) flood the dashboard with one request per tick.

**AnalyticsKit** addresses these pain points. It centralizes analytics calls, validates event payloads, provides Studio-friendly diagnostics, supports declarative event catalogs, and can batch repetitive economy events without merging unrelated SKUs.

## 🚀 Features

- Direct wrappers for custom, economy, onboarding, funnel, and progression events
- Declarative registered events through `RegisterEvent()` and `LogEvent()`
- Economy batching that preserves player, flow, currency, transaction type, SKU, and custom fields
- Per-SKU batching rules and explicit per-call overrides
- Automatic custom-field conversion to Roblox's three supported analytics fields
- Input validation with warning or strict-error modes
- Studio print, record, or ignore behavior
- Injectable transport for tests and custom inspection
- Funnel-step deduplication
- Estimated AnalyticsService rate-budget tracking
- Event lifecycle signals and diagnostic counters
- Player-leave flushing and explicit cleanup
- No Kernel, Promise, Signal, or framework dependency

## 🛠️ Installation

Place `AnalyticsKit.luau` in a server-accessible package location, such as:

```text
ReplicatedStorage
└── Packages
    └── AnalyticsKit
```

Require and construct it from a server Script or server ModuleScript:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsKit = require(ReplicatedStorage.Packages.AnalyticsKit)

local Analytics = AnalyticsKit.new()
```

AnalyticsKit must be constructed on the server.

## 📖 Quick start

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsKit = require(ReplicatedStorage.Packages.AnalyticsKit)

local Analytics = AnalyticsKit.new({
	StudioBehavior = "Print",

	EconomyTransactionTypes = {
		PassiveIncome = Enum.AnalyticsEconomyTransactionType.Gameplay,
		DailyReward = Enum.AnalyticsEconomyTransactionType.TimedReward,
		CoinPack = Enum.AnalyticsEconomyTransactionType.IAP,
	},

	EconomyBatching = {
		Enabled = true,
		Interval = 5,
		Default = false,
		SKUs = {
			PassiveIncome = true,
		},
	},
})

Analytics:LogCustomEvent(player, "Quest_Completed", 1)

Analytics:LogEconomyEvent(
	player,
	Enum.AnalyticsEconomyFlowType.Source,
	"Coins",
	1,
	501,
	nil,
	"PassiveIncome"
)
```

When `transactionType` is `nil`, AnalyticsKit checks `EconomyTransactionTypes[itemSku]`, then falls back to `DefaultEconomyTransactionType`.

## Custom fields

Roblox analytics supports up to three custom fields. `CreateCustomFields()` converts strings, numbers, and booleans into the expected dictionary:

```luau
local fields = AnalyticsKit.CreateCustomFields(
	"Warrior",
	12,
	true
)

Analytics:LogCustomEvent(player, "Mission_Completed", 90, fields)
```

This produces:

```luau
{
	[Enum.AnalyticsCustomFieldKeys.CustomField01.Name] = "Warrior",
	[Enum.AnalyticsCustomFieldKeys.CustomField02.Name] = "12",
	[Enum.AnalyticsCustomFieldKeys.CustomField03.Name] = "true",
}
```

Direct dictionaries using the Roblox enum keys or their `.Name` strings are also accepted and normalized.

## Economy batching

AnalyticsKit batches only economy events that resolve to the same complete analytics identity:

- Player
- Economy flow type
- Currency type
- Transaction type
- Item SKU
- Custom-field values

For example, these calls can become one request:

```luau
Analytics:LogEconomyEvent(
	player,
	Enum.AnalyticsEconomyFlowType.Source,
	"Coins",
	1,
	101,
	nil,
	"PassiveIncome"
)

Analytics:LogEconomyEvent(
	player,
	Enum.AnalyticsEconomyFlowType.Source,
	"Coins",
	1,
	102,
	nil,
	"PassiveIncome"
)
```

The flushed event reports an amount of `2`, the latest ending balance of `102`, and the unchanged SKU `PassiveIncome`.

A different SKU is always stored in a different batch:

```text
PassiveIncome != DailyReward != QuestReward
```

This avoids synthetic combined SKU names and preserves source/sink attribution in the Roblox analytics dashboard.

### Recommended batching policy

Batch repetitive, low-value events such as:

- Passive income ticks
- Repeated resource pickups
- Rapid low-value sales
- Per-hit or per-tick resource rewards

Do not normally batch singular events such as:

- In-app purchases
- Area unlocks
- Upgrades
- Major rewards
- One-time purchases

Batching is opt-in by default:

```luau
EconomyBatching = {
	Enabled = true,
	Interval = 5,
	Default = false,
	SKUs = {
		PassiveIncome = true,
		StickSold = true,
	},
}
```

To batch every SKU unless specifically disabled:

```luau
EconomyBatching = {
	Default = true,
	SKUs = {
		CoinPack = false,
		AreaUnlock = false,
	},
}
```

A call can override the configured policy with the final `batch` argument:

```luau
Analytics:LogEconomyEvent(
	player,
	Enum.AnalyticsEconomyFlowType.Source,
	"Coins",
	5,
	205,
	nil,
	"TemporaryReward",
	nil,
	true
)
```

When a direct, non-batched economy event is logged, AnalyticsKit flushes that player's existing economy batches first by default. This reduces event reordering around important transactions. Set `FlushEconomyBatchesBeforeDirect = false` to disable that behavior.

### Batching trade-off

Batching preserves total amounts and SKU identity, but it intentionally reduces transaction count. It also retains only the latest ending balance for the batch. Use it for repetitive events where reduced request volume matters more than one-row-per-transaction reporting.

## ⚙️ Direct API

### Custom events

```luau
Analytics:LogCustomEvent(
	player,
	"Minigame_Run_Completed",
	42.5,
	AnalyticsKit.CreateCustomFields("Obby", true)
)
```

```luau
LogCustomEvent(
	player: Player,
	eventName: string,
	value: number?,
	customFields: CustomFields?
): (boolean, string)
```

The value defaults to `1`.

### Economy events

```luau
Analytics:LogEconomyEvent(
	player,
	Enum.AnalyticsEconomyFlowType.Sink,
	"Coins",
	250,
	750,
	Enum.AnalyticsEconomyTransactionType.Shop,
	"DoubleJumpUpgrade",
	AnalyticsKit.CreateCustomFields("MainShop"),
	false
)
```

```luau
LogEconomyEvent(
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
```

`amount` must always be positive. The flow type determines whether Roblox treats it as a source or sink.

### Onboarding funnel steps

```luau
Analytics:LogOnboardingFunnelStepEvent(
	player,
	2,
	"Choose Class",
	AnalyticsKit.CreateCustomFields("Mage")
)
```

```luau
LogOnboardingFunnelStepEvent(
	player: Player,
	step: number,
	stepName: string,
	customFields: CustomFields?,
	allowDuplicate: boolean?
): (boolean, string)
```

### Recurring funnel steps

```luau
local HttpService = game:GetService("HttpService")
local sessionId = HttpService:GenerateGUID(false)

Analytics:LogFunnelStepEvent(
	player,
	"ShopCheckout",
	sessionId,
	1,
	"Opened Shop"
)
```

```luau
LogFunnelStepEvent(
	player: Player,
	funnelName: string,
	funnelSessionId: string,
	step: number,
	stepName: string,
	customFields: CustomFields?,
	allowDuplicate: boolean?
): (boolean, string)
```

### Progression events

```luau
Analytics:LogProgressionStartEvent(player, "WorldAreas", 3, "Desert")
Analytics:LogProgressionCompleteEvent(player, "WorldAreas", 3, "Desert")
Analytics:LogProgressionFailEvent(player, "WorldAreas", 3, "Desert")
```

The general method is also available:

```luau
Analytics:LogProgressionEvent(
	player,
	"WorldAreas",
	Enum.AnalyticsProgressionType.Complete,
	3,
	"Desert"
)
```

## Registered events

Registered events provide a centralized, project-specific event catalog without placing game logic inside AnalyticsKit.

```luau
local Catalog = {
	BoostUpgraded = {
		Kind = "Custom",
		EventName = "Boost_Upgraded",
		Value = 1,
		CustomFields = function(_player, data)
			return AnalyticsKit.CreateCustomFields(
				data.BoostType,
				data.NewLevel
			)
		end,
	},

	CurrencyEarned = {
		Kind = "Economy",
		FlowType = Enum.AnalyticsEconomyFlowType.Source,
		CurrencyType = function(_player, data)
			return data.CurrencyType
		end,
		Amount = function(_player, data)
			return data.Amount
		end,
		EndingBalance = function(_player, data)
			return data.NewBalance
		end,
		ItemSku = function(_player, data)
			return data.ItemSku
		end,
	},
}

assert(Analytics:RegisterEvents(Catalog))
```

Gameplay code can then use one stable entry point:

```luau
Analytics:LogEvent(player, "BoostUpgraded", {
	BoostType = "WalkSpeed",
	NewLevel = 4,
})
```

Definition fields can be fixed values or resolver functions:

```luau
function(player: Player, data: any): any
```

A definition may also include:

```luau
Enabled = true

Validate = function(player, data)
	if data.ItemSku == nil then
		return false, "ItemSku is required"
	end
	return true
end
```

### Supported definition kinds

- `Custom`
- `Economy`
- `Onboarding`
- `Funnel`
- `Progression`

See `AnalyticsCatalog.example.luau` for a compact example. `MigratedCatalog.example.luau` mirrors the project-specific event catalog from the earlier wrapper.

## Studio behavior

Roblox analytics events are not delivered from Studio, so AnalyticsKit provides explicit development behavior.

### Print

```luau
StudioBehavior = "Print"
```

Prints normalized event summaries to the output. This is the default.

### Record

```luau
StudioBehavior = "Record"
```

Stores normalized events in memory:

```luau
local events = Analytics:GetRecordedEvents()
local eventsAndClear = Analytics:GetRecordedEvents(true)
Analytics:ClearRecordedEvents()
```

The retained count is controlled by `MaxRecordedEvents`.

### Ignore

```luau
StudioBehavior = "Ignore"
```

Accepts valid calls but performs no Studio output or recording.

## Custom transport and testing

Pass a transport callback to inspect normalized events without calling Roblox's AnalyticsService:

```luau
local captured = {}

local Analytics = AnalyticsKit.new({
	Transport = function(record)
		table.insert(captured, record)
	end,
	RateLimit = {
		Enabled = false,
	},
})
```

A custom transport is used in both Studio and live servers. Transport errors are caught and emitted through `EventFailed`.

Normalized records contain:

```luau
{
	Kind = "Economy",
	Player = player,
	Timestamp = os.time(),
	Clock = os.clock(),
	Sequence = 12,
	RegisteredName = "CurrencyEarned",
	Payload = {
		FlowType = Enum.AnalyticsEconomyFlowType.Source,
		CurrencyType = "Coins",
		Amount = 10,
		EndingBalance = 250,
		TransactionType = "Gameplay",
		ItemSku = "PassiveIncome",
		CustomFields = nil,
	},
	BatchCount = 10,
}
```

## Signals

AnalyticsKit exposes native `RBXScriptSignal` values backed by internal `BindableEvent` instances.

```luau
Analytics.EventQueued:Connect(function(record, currentBatchCount)
	print("Queued", record.Payload.ItemSku, currentBatchCount)
end)

Analytics.EventLogged:Connect(function(record)
	print("Logged", record.Kind)
end)

Analytics.EventFailed:Connect(function(record, errorMessage)
	warn(record.Kind, errorMessage)
end)
```

Available signals:

| Signal | Arguments | Meaning |
| --- | --- | --- |
| `EventQueued` | `record, currentBatchCount` | An economy event was added to a batch |
| `EventLogged` | `record` | The Roblox or custom transport completed successfully |
| `EventRecorded` | `record, studioBehavior` | Studio printed or recorded an event |
| `EventIgnored` | `record, reason` | A valid event was intentionally ignored |
| `EventFailed` | `record, errorMessage` | The transport raised an error |
| `EventDropped` | `record, reason` | Rate protection dropped a normalized event |
| `BatchFlushed` | `summary` | One player's economy batches were flushed |

## Validation

AnalyticsKit validates common mistakes before they reach AnalyticsService:

- Invalid or missing player
- Empty event, SKU, currency, funnel, or progression names
- Non-finite numbers
- Economy amounts less than or equal to zero
- Negative economy balances
- Invalid enum types
- Invalid funnel or progression levels
- Unsupported custom-field keys or values
- More than three custom fields

Default behavior warns and returns `false`:

```luau
local success, result = Analytics:LogCustomEvent(player, "", 1)
```

Strict mode raises an error instead:

```luau
local Analytics = AnalyticsKit.new({
	StrictValidation = true,
})
```

All logging methods return:

```luau
success: boolean, statusOrError: string
```

Common successful statuses are:

- `Logged`
- `Queued`
- `Recorded`
- `Ignored`
- `Duplicate`

## Funnel deduplication

With `DeduplicateFunnelSteps = true`, repeated steps are ignored within the current server session.

Onboarding deduplication uses:

```text
player + onboarding step
```

Recurring funnel deduplication uses:

```text
player + funnel name + funnel session ID + step
```

The session ID keeps separate runs of the same recurring funnel independent.

Pass `allowDuplicate = true` to a direct funnel call, or set `AllowDuplicate` in a registered definition, when repeated calls are intentional.

Reset cached steps with:

```luau
Analytics:ResetFunnelDedupe(player)
Analytics:ResetFunnelDedupe()
```

## Rate-budget diagnostics

Roblox documents a global AnalyticsService request limit based on concurrent users. AnalyticsKit estimates the current minute's usage from successful transport calls.

```luau
local requests = Analytics:GetRequestsInLastMinute()
local estimatedLimit = Analytics:GetEstimatedRateLimit()
local usage = Analytics:GetRateLimitUsage()
```

Configure warning and overflow behavior:

```luau
RateLimit = {
	Enabled = true,
	WarningThreshold = 0.8,
	OverflowBehavior = "Warn",
}
```

`Warn` reports the estimate but still attempts the event. `Drop` prevents calls after the estimated budget has been exhausted and fires `EventDropped`.

The estimate is local to the AnalyticsKit instance. Calls made directly to `AnalyticsService` elsewhere are not visible to it, so centralizing calls remains important.

## Diagnostics

```luau
local diagnostics = Analytics:GetDiagnostics()

print(diagnostics.Attempted)
print(diagnostics.Logged)
print(diagnostics.Queued)
print(diagnostics.Failed)
print(diagnostics.PendingEconomyBatches)
print(diagnostics.RateLimitUsage)
```

Available values:

```luau
{
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
```

Reset counters with:

```luau
Analytics:ResetDiagnostics()
```

## Runtime controls

```luau
Analytics:SetEnabled(false)

Analytics:SetEconomyBatchingEnabled(false)
Analytics:SetEconomyBatchingEnabled(false, false) -- Do not flush first
Analytics:SetEconomyBatchInterval(10)

Analytics:SetEconomySkuBatching("PassiveIncome", true)
Analytics:SetEconomySkuBatching("PassiveIncome", nil) -- Return to default policy

Analytics:SetEconomyTransactionType(
	"CoinPack",
	Enum.AnalyticsEconomyTransactionType.IAP
)
```

Manual flushing:

```luau
Analytics:FlushEconomyBatchesForPlayer(player)
Analytics:FlushEconomyBatches()
```

## Player segments

AnalyticsKit includes a protected wrapper for Roblox's yielding segment lookup:

```luau
local segments, errorMessage = Analytics:GetPlayerSegmentsAsync(player)
if segments then
	print(segments.ActivePayerStatus)
else
	warn(errorMessage)
end
```

The method returns an error in Studio.

## Configuration

```luau
local Analytics = AnalyticsKit.new({
	Enabled = true,
	WarningsEnabled = true,
	StrictValidation = false,
	StudioBehavior = "Print",
	MaxRecordedEvents = 200,
	DeduplicateFunnelSteps = true,
	FlushEconomyBatchesBeforeDirect = true,

	DefaultEconomyTransactionType = Enum.AnalyticsEconomyTransactionType.Gameplay,
	EconomyTransactionTypes = {},

	EconomyBatching = {
		Enabled = true,
		Interval = 5,
		Default = false,
		SKUs = {},
	},

	RateLimit = {
		Enabled = true,
		WarningThreshold = 0.8,
		OverflowBehavior = "Warn",
	},

	Transport = nil,
})
```

## Cleanup

AnalyticsKit automatically flushes and clears a player's pending economy data when the player leaves.

Destroy the instance when the owning system shuts down:

```luau
Analytics:Destroy()
```

`Destroy()` flushes pending economy batches by default. Pass `false` to discard them:

```luau
Analytics:Destroy(false)
```

For server shutdown:

```luau
game:BindToClose(function()
	Analytics:Destroy(true)
end)
```

After destruction, methods raise an error and all internal signals are destroyed.

## Migration from the earlier wrapper

Earlier usage:

```luau
Analytics:LogEvent(player, "Economy", "CurrencyEarned", data)
```

AnalyticsKit registered usage:

```luau
Analytics:LogEvent(player, "CurrencyEarned", data)
```

The event kind now belongs to the registered definition rather than every call site.

Earlier economy mappings:

```luau
RarePileChanceBonus = {
	Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
}
```

AnalyticsKit mappings:

```luau
RarePileChanceBonus = Enum.AnalyticsEconomyTransactionType.Gameplay
```

Earlier global batching merged multiple purchase names into generated strings. AnalyticsKit never creates combined SKU names. Each complete SKU identity is aggregated independently.

## Package files

```text
AnalyticsKit.luau                  Main standalone module
AnalyticsCatalog.example.luau    Compact project event catalog
MigratedCatalog.example.luau     Migration of the original event catalog
Example.server.luau              Minimal server setup and lifecycle
MigratedSetup.example.luau       Setup using the migrated catalog and SKU map
README.md                        Documentation
```

## 📝 Notes

- Analytics events should be emitted after the tracked gameplay action succeeds.
- AnalyticsService event calls are server-only.
- Roblox does not deliver these events from Studio.
- Economy amounts should be positive for both sources and sinks.
- Use stable, bounded event names, transaction types, SKUs, and custom-field values.
- Use batching selectively because it changes event counts even when total value remains correct.

Refer to the Roblox Creator Hub documentation for the current AnalyticsService API and platform limits.

made with ❤️ by biotoxin495
