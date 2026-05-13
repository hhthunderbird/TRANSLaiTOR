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
2. Create the local model:
   ```powershell
   ollama create prompt-opt -f C:\Users\hhthu\Scripts\ModelFile
   ```
3. Put `C:\Users\hhthu\Scripts` on `PATH` and add `.PS1` to `PATHEXT`, or use the
   bundled `c.cmd` shim and put only `C:\Users\hhthu\Scripts` on `PATH`.

## Usage

```powershell
c "spawn 1000 inimigos com pooling no ecs"           # distill + copy XML to clipboard
c "..." -Raw                                          # print XML to stdout (scriptable)
c "..." -Send                                         # pipe XML directly to claude -p
c "..." -Model prompt-opt-other                       # use a different Ollama model
```

## Files

- `c.ps1` — entrypoint, argument parsing, Ollama call, Claude pipe.
- `c.cmd` — Windows shim so `c` works in cmd.exe and plain `PATH` setups.
- `cprompt.psm1` — pure helpers (BOM strip, XML extraction, tool resolution).
- `ModelFile` — Ollama Modelfile (system prompt + few-shots + decoding params).
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
