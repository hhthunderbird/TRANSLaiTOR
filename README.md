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

### Scripted install (recommended)

The repo is split into two locations:

- **Source / dev tree** — where you cloned the repo (e.g. `C:\Projetos\TRANSLaiTOR`).
  Contains `.git`, tests, plans, README. Not on `PATH`.
- **Install dir** — where `install.ps1` copies the runtime files
  (`c.ps1`, `c.cmd`, `cprompt.psm1`, `cstats.ps1`, `cinstall.psm1`,
  the two `Modelfile.*`, and `uninstall.ps1`). On `PATH`. Default:
  `%USERPROFILE%\Scripts`.

After installing the Ollama MSI from <https://ollama.com>, clone the
repo anywhere outside the install dir and run `install.ps1` from there:

```powershell
git clone https://github.com/hhthunderbird/TRANSLaiTOR.git C:\Projetos\TRANSLaiTOR
& C:\Projetos\TRANSLaiTOR\install.ps1
```

The installer is idempotent: re-running it re-copies the runtime files
and skips already-completed env changes. Switches:

- `-InstallDir <path>` — override the install target (default
  `%USERPROFILE%\Scripts`).
- `-CommandsDir <path>` — override the Claude Code commands directory
  the `/c` slash command file is copied into (default
  `%USERPROFILE%\.claude\commands`).
- `-NoPathExt` — skip registering `.PS1` in `PATHEXT` (use the bundled
  `c.cmd` shim instead).
- `-NoSlashCommand` — skip installing the `/c` slash command for Claude
  Code.
- `-SkipSmoke` — skip the post-install `c -NoRefine -Raw 'test input'`
  invocation.

### Manual install

The instructions below assume the dev tree lives at
`C:\Projetos\TRANSLaiTOR` and the install dir is `%USERPROFILE%\Scripts`.
Substitute your own paths if different.

1. **Clone the repo into a dev location.**
   ```powershell
   git clone https://github.com/hhthunderbird/TRANSLaiTOR.git C:\Projetos\TRANSLaiTOR
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
   ollama create prompt-opt      -f C:\Projetos\TRANSLaiTOR\Modelfile.compiler
   ollama create prompt-refiner  -f C:\Projetos\TRANSLaiTOR\Modelfile.refiner
   ```
   Verify:
   ```powershell
   ollama list   # expect rows for prompt-opt and prompt-refiner
   ```

5. **Copy runtime files to the install dir** (`%USERPROFILE%\Scripts`):
   ```powershell
   New-Item -ItemType Directory -Force $env:USERPROFILE\Scripts | Out-Null
   Copy-Item C:\Projetos\TRANSLaiTOR\c.ps1,
             C:\Projetos\TRANSLaiTOR\c.cmd,
             C:\Projetos\TRANSLaiTOR\cprompt.psm1,
             C:\Projetos\TRANSLaiTOR\cstats.ps1,
             C:\Projetos\TRANSLaiTOR\cinstall.psm1,
             C:\Projetos\TRANSLaiTOR\Modelfile.compiler,
             C:\Projetos\TRANSLaiTOR\Modelfile.refiner,
             C:\Projetos\TRANSLaiTOR\uninstall.ps1 $env:USERPROFILE\Scripts -Force
   ```

6. **Put the install dir on `PATH`.** Pick ONE of:
   - **Option A — PowerShell-native.** Add `%USERPROFILE%\Scripts` to `PATH` AND add `.PS1` to `PATHEXT` (System Properties → Environment Variables). After restarting the shell:
     ```powershell
     c -Help
     ```
   - **Option B — bundled `c.cmd` shim.** Only add `%USERPROFILE%\Scripts` to `PATH`. The shim invokes `c.ps1` for you from `cmd.exe`, Windows Terminal, or any non-PowerShell host:
     ```cmd
     c -Help
     ```

7. **First-run smoke test.**
   ```powershell
   c -NoRefine "test input" -Raw
   ```
   Expected: a `<task>...</task><context>...</context><constraints>...</constraints>` block printed to stdout. If you see `ERRO: ollama nao encontrado` step 2 or 6 needs fixing.

## Uninstall

```powershell
& $env:USERPROFILE\Scripts\uninstall.ps1
```

By default the uninstaller removes the two local models and reverts the
PATH/PATHEXT entries the installer added. Optional purges:

- `-InstallDir <path>` — override the install dir removed from `PATH`
  (default `%USERPROFILE%\Scripts`, matching `install.ps1`).
- `-CommandsDir <path>` — override the Claude Code commands directory
  the `/c` slash command file is removed from (default
  `%USERPROFILE%\.claude\commands`).
- `-PurgeBase`    — also removes the `llama3.2:3b` base model.
- `-PurgeState`   — also deletes `%USERPROFILE%\.cprompt\` (cache, history,
  metrics). Irreversible.
- `-PurgeInstall` — also deletes the runtime files copied into the
  install dir (and removes the dir if it ends up empty).
- `-Force`        — skip the confirmation prompt.

The uninstaller never touches the dev tree (where you cloned the repo) —
remove that manually when you are done.

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

The cache key is a SHA256 of `(Model + null + Text)`, so switching
`-Model` to a different compiler implicitly bypasses the cache for
that prompt. `-NoCache` is only needed when you want to force a
re-run against the same model (e.g. after retuning the Modelfile).

### Inside Claude Code (`/c` slash command)

`install.ps1` copies a `/c` slash command file to
`%USERPROFILE%\.claude\commands\c.md`. Inside a Claude Code session,
typing `/c <prompt text>` runs `c.cmd -NoRefine -Raw <prompt text>` and
sends only the resulting XML block to Claude — your raw text is
replaced by the distilled `<task>/<context>/<constraints>`.

```
/c quero implementar cache LRU em Go com ttl
```

Restart Claude Code after install for the new command to appear in the
slash menu.

Limitations:

- The argument string is passed unquoted to `c.cmd`. Prompts with
  characters the shell treats specially (`"`, backticks, `$`, `|`, `;`)
  may not survive intact — escape them or fall back to the terminal CLI.
- Refiner Q&A is bypassed (`-NoRefine`). Use the terminal CLI when you
  want the refiner to ask follow-up questions.

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
- `cstats.ps1` — CLI that summarises `metrics.jsonl`.
- `install.ps1` — scripted installer (idempotent; user-scope env vars).
- `uninstall.ps1` — reverses `install.ps1`; optional `-PurgeBase` / `-PurgeState`.
- `cinstall.psm1` — pure helpers for PATH-string manipulation.
- `c.cmd` — Windows shim so `c` works in cmd.exe and plain `PATH` setups.
- `commands/c.md` — `/c` slash command file for Claude Code, copied by
  `install.ps1` to `%USERPROFILE%\.claude\commands\c.md`.
- `cprompt.psm1` — pure helpers (BOM strip, XML extraction, tool resolution).
- `Modelfile.compiler` — Ollama Modelfile for the compiler stage
  (`prompt-opt` model): emits the `<task>/<context>/<constraints>` block.
- `Modelfile.refiner` — Ollama Modelfile for the refiner stage
  (`prompt-refiner` model): emits `<passthrough>` or `<questions>`.
- `Tests/cprompt.Tests.ps1` — Pester v3 unit tests.
- `Tests/cinstall.Tests.ps1` — Pester v3 unit tests for cinstall.

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
Invoke-Pester C:\Projetos\TRANSLaiTOR\Tests
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
