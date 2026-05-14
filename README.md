# TRANSLaiTOR

Local prompt-compiler middleware. Takes informal terminal input, distills it into a
structured XML block via a small local LLM (Ollama + Llama 3.2 3B), pipes the result
to the Claude CLI. Goal: cut token spend and tighten precision before paid inference.

## Pipeline

```
user idea → c.ps1 → Ollama (prompt-opt model) → <task><context><constraints> → Claude CLI / clipboard
```

## Install

1. Install [Ollama](https://ollama.com) and pull base: `ollama pull llama3.2:3b`.
2. Create the local models:
   ```powershell
   ollama create prompt-opt      -f C:\Users\hhthu\Scripts\Modelfile.compiler
   ollama create prompt-refiner  -f C:\Users\hhthu\Scripts\Modelfile.refiner
   ```
3. Put `C:\Users\hhthu\Scripts` on `PATH` and add `.PS1` to `PATHEXT`, or use the
   bundled `c.cmd` shim and put only `C:\Users\hhthu\Scripts` on `PATH`.

## Usage

```powershell
c "spawn 1000 inimigos com pooling no ecs"           # distill + copy XML to clipboard
c "..." -Raw                                          # print XML to stdout (scriptable)
c "..." -Send                                         # pipe XML directly to claude -p
c "..." -Model prompt-opt-other                       # use a different Ollama model
c "..." -NoRefine                                     # skip the refiner, go straight to compiler
c "..." -RefinerModel prompt-refiner-other            # use a different refiner Ollama model
```

## Pipeline stages

1. **Refiner** (`prompt-refiner`): inspects the raw input. Emits
   `<passthrough>` when the input is already specific, or `<questions>`
   with 1–3 clarifying questions when the input is vague. Answers are
   collected in the terminal and merged into the input. Bypassed by
   `-NoRefine` or `-Raw`. Failure falls back to the raw input.
2. **Compiler** (`prompt-opt`): turns the (possibly enriched) input
   into the three-tag XML block. Cached by `(model, final input)`.
3. **Sink**: clipboard (default), `claude -p` (`-Send`), or stdout
   (`-Raw`).

## Files

- `c.ps1` — entrypoint, argument parsing, Ollama call, Claude pipe.
- `cstats.ps1` — CLI that summarises `metrics.jsonl`.
- `c.cmd` — Windows shim so `c` works in cmd.exe and plain `PATH` setups.
- `cprompt.psm1` — pure helpers (BOM strip, XML extraction, tool resolution).
- `Modelfile.compiler` — Ollama Modelfile for the compiler stage
  (`prompt-opt` model): emits the `<task>/<context>/<constraints>` block.
- `Modelfile.refiner` — Ollama Modelfile for the refiner stage
  (`prompt-refiner` model): emits `<passthrough>` or `<questions>`.
- `Tests/cprompt.Tests.ps1` — Pester v3 unit tests.

## Metrics

Every run of `c.ps1` appends one JSONL entry to
`%USERPROFILE%\.cprompt\metrics.jsonl` with timing, mode
(`raw` / `passthrough` / `questions` / `skip` / `cache`), input/output
sizes, and the flag set. Failures in the metrics path are swallowed and
never abort the user-facing run.

Summarise the log with:

```powershell
.\cstats.ps1            # all entries
.\cstats.ps1 -Last 50   # last 50 entries only
```

The summary prints entry count, cache hit rate, p50/p95 of total wall
time, average `xmlChars / inputChars` ratio, and a per-mode count.

**Caveat:** if `ollama` is missing from `PATH` the compile stage exits
with code 2 *before* the metric line is written, so failed runs of that
kind are not logged.

## Run tests

```powershell
Invoke-Pester C:\Users\hhthu\Scripts\Tests
```

## Troubleshooting

- **`Error: (line N) command must be one of …` on `ollama create`** — every
  `MESSAGE assistant` body must fit a single line in the Modelfile.
- **`uso: c <ideia>` banner with args present** — your `param()` block likely
  swallows positional input. `c.ps1` uses `PositionalBinding=$false` + a
  `ValueFromRemainingArguments` array; preserve that pattern.
- **No XML returned** — the Modelfile system rule 6 lists exact close tags;
  if the 3B model hallucinates, `Get-PromptXml` salvages by extracting tags
  independently and recombining canonical XML.

## License

Personal use.
