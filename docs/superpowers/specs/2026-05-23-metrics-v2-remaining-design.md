# Metrics v2 — remaining sub-items

Date: 2026-05-23
Status: design approved, awaiting plan
Depends on: PR #29 (metrics v2 eval rate, merged 2026-05-21)

## Problem

PR #29 added per-run ollama eval stats (eval rate, eval count, durations) to
metrics.jsonl and surfaced them in cstats. Three sub-items remain:

1. **Claude API token usage on `-Send`** — when the user pipes compiled XML to
   Claude via `claude -p`, no token/cost data is captured.
2. **Cold-start flag** — ollama's first model load is slow (seconds vs.
   milliseconds warm). There is no way to distinguish cold-start latency from
   slow generation in the current data.
3. **cstats `-Since` / `-By` groupings** — cstats only supports `-Last`
   (count). No time-based filtering or grouping by mode/model.

## Non-goals

- HTTP API (`/api/generate`) integration for ollama. Stays on CLI.
- Claude API direct call (replacing `claude -p` with `Invoke-RestMethod`).
- Modifying historical JSONL entries. New fields are additive.
- Refiner eval-rate summary in cstats (already shipped in PR #29).

## Sub-item 1: Claude API token usage on `-Send`

### Capture path

Change `c.ps1` lines 307-316. Current flow:

```powershell
$xml | & claude -p
exit $LASTEXITCODE
```

New flow:

```powershell
$claudeRaw = $xml | & claude -p --output-format json
# Parse JSON; extract .result for display, .usage/.total_cost_usd for metrics.
```

**Streaming trade-off**: `--output-format json` buffers the entire response
before returning (no streaming). The user will wait silently, then see the
full answer at once. This is a UX downgrade from the current `claude -p` which
streams incrementally. Accepted trade-off: `-Send` is a scripted/pipeline
path, not an interactive chat. The token/cost data is worth the buffering.

**stderr passthrough**: Do NOT suppress stderr (`2>$null`). Claude CLI errors
(rate limits, auth failures) go to stderr and must reach the user. Let stderr
flow to the console naturally.

Claude CLI `--output-format json` returns a JSON object with fields:
- `result` (string) — the text answer
- `usage.input_tokens`, `usage.output_tokens` (int)
- `usage.cache_read_input_tokens`, `usage.cache_creation_input_tokens` (int)
- `total_cost_usd` (double)
- `duration_ms` (int)
- `modelUsage` (object keyed by model ID, each with `costUSD`, token counts)

When `--fallback-model` is active, `modelUsage` may contain multiple model
entries. Sum token counts and costs across all models for the aggregate
`claudeUsage`; store the primary model (first key) as `model`.

Verified on Claude Code CLI 2026-05-23; `--output-format json` documented in
`claude --help`.

### Error handling

If `ConvertFrom-Json` fails (old CLI, unexpected output), treat `$claudeRaw`
as plain text answer. Set `$claudeUsage = $null`. Emit Write-Warning. User
still sees the answer.

### Metrics entry

New optional top-level key `claudeUsage`:

```json
{
  "claudeUsage": {
    "inputTokens": 2,
    "outputTokens": 48,
    "cacheReadTokens": 0,
    "cacheCreationTokens": 27748,
    "costUsd": 0.1746,
    "durationMs": 5005,
    "model": "claude-opus-4-7[1m]"
  }
}
```

Source mapping:
- `inputTokens` ← `usage.input_tokens`
- `outputTokens` ← `usage.output_tokens`
- `cacheReadTokens` ← `usage.cache_read_input_tokens`
- `cacheCreationTokens` ← `usage.cache_creation_input_tokens`
- `costUsd` ← `total_cost_usd` (full double; round at display only)
- `durationMs` ← `duration_ms`
- `model` ← first key of `modelUsage` (primary model)

Absent when `-Send` not used or parse fails.

### Metrics write timing

The metrics entry must be written AFTER the claude call returns (not before as
currently happens at line 295). Move `Add-MetricEntry` to after the `-Send`
block so `claudeUsage` can be appended. On non-Send paths, write at the
current location (no change).

### Display flow

Replace current `$xml | & claude -p` stdout passthrough with:

```powershell
$claudeRaw  = $xml | & claude -p --output-format json
$claudeExit = $LASTEXITCODE
try {
    $claudeObj  = $claudeRaw | ConvertFrom-Json
    $claudeText = $claudeObj.result
    # ... build $claudeUsage hashtable from $claudeObj.usage / $claudeObj.total_cost_usd ...
} catch {
    $claudeText  = $claudeRaw
    $claudeUsage = $null
    Write-Warning "Could not parse Claude JSON output; token usage not captured."
}
Write-Output $claudeText
```

### Get-MetricsSummary additions

New summary fields (zero-default, computed only when ≥1 entry has `claudeUsage`):

| Field | Type | Computation |
|-------|------|-------------|
| `ClaudeSendCount` | int | count of entries with `claudeUsage` |
| `ClaudeCostTotal` | double | sum of `claudeUsage.costUsd` |
| `ClaudeCostAvg` | double | `ClaudeCostTotal / ClaudeSendCount` |
| `ClaudeAvgInputTokens` | int | mean of `claudeUsage.inputTokens` |
| `ClaudeAvgOutputTokens` | int | mean of `claudeUsage.outputTokens` |

### cstats display

Guarded on `ClaudeSendCount > 0`:

```
Claude sends     : 5
Claude cost total: $0.87
Claude cost avg  : $0.17
Claude tokens avg: 42 out / 950 in
```

## Sub-item 2: Cold-start flag

### Parser extension

Extend `ConvertFrom-OllamaVerboseStats` (cprompt.psm1) with two new regexes
using the existing `$toMs` helper:

```
total duration:  <float>(ms|s)  → totalDurationMs
load duration:   <float>(ms|s)  → loadDurationMs
```

These fields land inside the returned hashtable alongside existing keys
(`evalRate`, `evalCount`, etc.). No new function needed.

Verified format on Ollama 0.24.0:
```
total duration:       4.5019843s
load duration:        2.8218176s
```

### Metrics entry

`loadDurationMs` and `totalDurationMs` live inside existing `refinerEval` /
`compilerEval` objects. No new top-level keys. Example:

```json
{
  "compilerEval": {
    "evalRate": 75.91,
    "evalCount": 99,
    "loadDurationMs": 2822,
    "totalDurationMs": 4502
  }
}
```

Cold-start detection is derived at read time in `Get-MetricsSummary`, not
stored. This avoids denormalization: raw `loadDurationMs` is the single source
of truth; the threshold can change without stale flags in old entries.

Threshold: `loadDurationMs > 500` = cold start. Warm loads are typically
<50ms; 500ms gives safe margin.

### Get-MetricsSummary additions

Cold-start is derived per entry: an entry counts as cold if either
`refinerEval.loadDurationMs > 500` or `compilerEval.loadDurationMs > 500`.

| Field | Type | Computation |
|-------|------|-------------|
| `ColdStartCount` | int | entries where derived cold-start is true |
| `ColdStartRate` | double | `ColdStartCount / Count` |

### cstats display

Guarded on `ColdStartCount > 0`:

```
Cold starts      : 3/25 (12.0%)
```

### Integration test fixtures

Extend `Tests/integration/fixtures/*.json` verbose blocks:
- One fixture with `load duration: 2.8218176s` (cold) + `total duration: 4.5019843s`
- One fixture with `load duration: 23.1902ms` (warm) + `total duration: 1.5019843s`

Unit tests for `ConvertFrom-OllamaVerboseStats`: assert `loadDurationMs` and
`totalDurationMs` parsed from both cold and warm samples.

## Sub-item 3: cstats `-Since` / `-By` groupings

### New parameters

```powershell
param(
    [int]$Last = 0,
    [string]$Since,
    [string]$By,
    [string]$Path = (Join-Path $env:USERPROFILE '.cprompt/metrics.jsonl')
)
```

### `-Since` parsing

New exported function in cprompt.psm1: `ConvertTo-SinceDate`.

Input: string. Output: `[datetime]` or throws.

Accepted formats:
- Relative: `\d+(h|d|w)` — subtract from `[datetime]::Now`
  - `24h` → 24 hours ago
  - `7d` → 7 days ago
  - `1w` → 7 days ago (1 week = 7 days)
- Absolute ISO-8601: `2026-05-01` or `2026-05-01T14:00:00`
- Invalid → `Write-Error` + return `$null`

Filtering in cstats.ps1:

```powershell
if ($Since) {
    $sinceDate = ConvertTo-SinceDate $Since
    if ($null -eq $sinceDate) { exit 1 }
    $entries = @($entries | Where-Object { [datetime]$_.ts -ge $sinceDate })
}
```

Applied BEFORE `-Last` so `-Since 7d -Last 10` means "last 10 entries from
past week."

`ts` format is ISO-8601 round-trip (`ToString('o')`) with `Z` suffix (UTC).
Example: `2026-05-14T00:34:51.4225866Z`. `[datetime]::Parse()` handles this
correctly.

### `-By` grouping

Accepted values: `mode`, `model`. Any other value → error, exit.

When set:
1. Group entries by field value, using the `$hasField` helper from
   `Get-MetricsSummary` to guard access (older entries may lack `model`).
   Entries missing the field go into an `(unknown)` group.
2. Call `Get-MetricsSummary` per group
3. Display one summary block per group, sorted by entry count descending

Output format:

```
=== mode: refiner (42 entries) ===
Cache hits   : 14.3%
p50 totalMs  : 3200
p95 totalMs  : 8100
Avg xml/input: 3.21
...

=== mode: raw (15 entries) ===
Cache hits   : 0.0%
p50 totalMs  : 2100
...
```

When `-By` NOT set: current single-summary behavior (no change).

### Composability matrix

| Combination | Behavior |
|-------------|----------|
| `cstats` | all entries, single summary |
| `cstats -Since 7d` | filter by time, single summary |
| `cstats -By mode` | all entries, grouped |
| `cstats -Since 24h -By model` | filter then group |
| `cstats -Last 50` | last 50 entries, single summary |
| `cstats -Since 7d -Last 50` | filter, take last 50, single summary |
| `cstats -Since 7d -By mode -Last 50` | filter, take last 50, group |

### No changes to Get-MetricsSummary for this sub-item

Grouping logic lives in `cstats.ps1`. Each group calls existing
`Get-MetricsSummary`. Display loop in cstats handles the per-group output.

## Implementation scope

This spec covers three independent sub-items. Each ships as its own branch
and PR, following the project's one-branch-per-task workflow:

1. **PR A**: Cold-start flag (parser + summary + cstats line + tests)
2. **PR B**: Claude API token usage on `-Send` (c.ps1 restructure + summary + cstats + tests)
3. **PR C**: cstats `-Since` / `-By` groupings (ConvertTo-SinceDate + cstats params + tests)

Order: A before B (B depends on summary fields that A also touches). C is
independent and can land in any order.

## Testing strategy

### Unit tests (cprompt.Tests.ps1)

- `ConvertFrom-OllamaVerboseStats`: assert `loadDurationMs` and
  `totalDurationMs` from cold and warm samples
- `ConvertTo-SinceDate`: relative (`7d`, `24h`, `1w`), absolute ISO-8601,
  invalid input returns `$null`
- `Get-MetricsSummary`: assert `ColdStartCount`, `ColdStartRate`,
  `ClaudeSendCount`, `ClaudeCostTotal`, `ClaudeCostAvg`,
  `ClaudeAvgInputTokens`, `ClaudeAvgOutputTokens` from synthetic entries

### Integration tests (c.Integration.Tests.ps1)

- `-Send` path: mock `claude` CLI with a shim that outputs valid JSON. Assert
  `claudeUsage` fields in metrics entry.
- Cold-start: extend fixture verbose blocks with `load duration` / `total
  duration`. Assert `compilerEval.loadDurationMs` / `refinerEval.loadDurationMs`
  in metrics entry.

### cstats tests

- `-Since` filtering: create temp metrics.jsonl with entries at known
  timestamps. Assert filtered count.
- `-By mode` grouping: assert output contains expected group headers.
- Composability: `-Since` + `-By` + `-Last` together.

## File change summary

| File | Changes |
|------|---------|
| `cprompt.psm1` | Add `loadDurationMs`/`totalDurationMs` regexes to `ConvertFrom-OllamaVerboseStats`; add `ConvertTo-SinceDate` function; extend `Get-MetricsSummary` with cold-start detection (derived from `loadDurationMs > 500`) and claude-usage aggregation fields; export `ConvertTo-SinceDate` |
| `c.ps1` | Restructure `-Send` block for JSON capture; move `Add-MetricEntry` for `-Send` path; build `claudeUsage` object |
| `cstats.ps1` | Add `-Since`/`-By` params; filtering logic; grouped display loop; claude/cold-start display lines |
| `Tests/cprompt.Tests.ps1` | Unit tests for parser extensions, `ConvertTo-SinceDate`, summary fields |
| `Tests/c.Integration.Tests.ps1` | Integration tests for `-Send` JSON capture, cold-start flag |
| `Tests/integration/fixtures/*.json` | Add `load duration`/`total duration` to verbose blocks |
| `Tests/integration/ollama-impl.ps1` | No changes needed (already emits verbose text from fixtures) |
