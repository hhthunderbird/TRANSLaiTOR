# TRANSLaiTOR

Local prompt-compiler middleware. Takes informal terminal input, distills it into a
structured XML block via a small local LLM (Ollama + Llama 3.2 3B), pipes the result
to the Claude CLI. Goal: cut token spend and tighten precision before paid inference.

## Pipeline

```
user idea → c.ps1 → Ollama (prompt-opt model) → <task><context><constraints> → Claude CLI / clipboard
```

## Prerequisites

- Windows 10/11.
- PowerShell 5.1+ (`$PSVersionTable.PSVersion`).
- [Ollama](https://ollama.com) for Windows (≥ 0.1.30).
- ~3 GB of disk for the `llama3.2:3b` base model.
- Optional: Anthropic [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) on `PATH` — required only for `-Send`.
- Optional: Pester v3+ (`Install-Module Pester -RequiredVersion 3.4.6 -Scope CurrentUser`) — required only for running the test suite.

## Install

The instructions below assume the repo lives at `%USERPROFILE%\Scripts`. Substitute
your own path if you cloned elsewhere.

1. **Clone the repo.**
   ```powershell
   git clone https://github.com/hhthunderbird/TRANSLaiTOR.git $env:USERPROFILE\Scripts
   ```

2. **Install Ollama** from <https://ollama.com> and confirm it is on `PATH`:
   ```powershell
   ollama --version
   ```

3. **Pull the base model.**
   ```powershell
   ollama pull llama3.2:3b
   ```

4. **Build the two local models** from the bundled Modelfiles:
   ```powershell
   ollama create prompt-opt      -f $env:USERPROFILE\Scripts\Modelfile.compiler
   ollama create prompt-refiner  -f $env:USERPROFILE\Scripts\Modelfile.refiner
   ```
   Verify:
   ```powershell
   ollama list   # expect rows for prompt-opt and prompt-refiner
   ```

5. **Put the scripts directory on `PATH`.** Pick ONE of:
   - **Option A — PowerShell-native.** Add `%USERPROFILE%\Scripts` to `PATH` AND add `.PS1` to `PATHEXT` (System Properties → Environment Variables). After restarting the shell:
     ```powershell
     c -Help
     ```
   - **Option B — bundled `c.cmd` shim.** Only add `%USERPROFILE%\Scripts` to `PATH`. The shim invokes `c.ps1` for you from `cmd.exe`, Windows Terminal, or any non-PowerShell host:
     ```cmd
     c -Help
     ```

6. **First-run smoke test.**
   ```powershell
   c -NoRefine "test input" -Raw
   ```
   Expected: a `<task>...</task><context>...</context><constraints>...</constraints>` block printed to stdout. If you see `ERRO: ollama nao encontrado` step 2 or 5 needs fixing.

## Usage

Quick reference of common invocations:

```powershell
c "spawn 1000 inimigos com pooling no ecs"   # distill + copy XML to clipboard
c "..." -Raw                                 # print XML to stdout (scriptable; implies -NoRefine)
c "..." -Send                                # pipe XML directly to claude -p
c "..." -NoRefine                            # skip the refiner stage, go straight to compiler
c "..." -NoCache                             # bypass the local XML cache, force a fresh ollama call
c "..." -Model prompt-opt-other              # use a different compiler model
c "..." -RefinerModel prompt-refiner-other   # use a different refiner model
c -Last                                      # print the most recent XML from history
c -Help                                      # show usage banner
```

### Typical session

```powershell
PS> c "preciso de cache lru com ttl em go"
--- refinando input (prompt-refiner) ---
1) Qual a capacidade maxima desejada?
> 1000
2) TTL em segundos?
> 60
--- destilando prompt local (prompt-opt) ---

<task>...</task>
<context>...</context>
<constraints>...</constraints>

copiado p/ clipboard (Ctrl+V). use -Send p/ pipe direto no claude.
```

On the second identical run the cache short-circuits the compile stage:

```powershell
PS> c "preciso de cache lru com ttl em go"
--- cache hit (prompt-opt) ---
...
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
- `c.cmd` — Windows shim so `c` works in cmd.exe and plain `PATH` setups.
- `cprompt.psm1` — pure helpers (BOM strip, XML extraction, tool resolution).
- `Modelfile.compiler` — Ollama Modelfile for the compiler stage
  (`prompt-opt` model): emits the `<task>/<context>/<constraints>` block.
- `Modelfile.refiner` — Ollama Modelfile for the refiner stage
  (`prompt-refiner` model): emits `<passthrough>` or `<questions>`.
- `Tests/cprompt.Tests.ps1` — Pester v3 unit tests.

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
