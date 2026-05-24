# TRANSLaiTOR

Compilador local de prompts. Transforma ideias informais em XML estruturado (`<task>/<context>/<constraints>`) usando um LLM local (Ollama + Llama 3.2 3B), antes de enviar para o Claude ou outro LLM pago.

```
ideia informal → c.ps1 → Ollama (local, grátis) → XML estruturado → Claude CLI / clipboard
```

## Requisitos

- Windows 10/11, PowerShell 5.1+
- [Ollama](https://ollama.com) instalado (~3 GB para o modelo base)
- Opcional: [Claude CLI](https://docs.anthropic.com/en/docs/claude-code) para `-Send`

## Instalar

```powershell
git clone https://github.com/hhthunderbird/TRANSLaiTOR.git C:\Projetos\TRANSLaiTOR
& C:\Projetos\TRANSLaiTOR\install.ps1
```

O instalador copia os arquivos para `%USERPROFILE%\Scripts` (no PATH), cria os modelos Ollama e faz um smoke test. Idempotente — rode de novo para atualizar. Verifique com:

```powershell
c -NoRefine -Raw "test input"
# esperado: <task>...</task><context>...</context><constraints>...</constraints>
```

Para desinstalar: `& $env:USERPROFILE\Scripts\uninstall.ps1`

## Usar

```powershell
c "spawn 1000 inimigos com pooling no ecs"     # compila → clipboard
c "fazer parser csv em C#" -Send                # compila e envia ao Claude CLI
c "query sql lenta" -Raw                        # XML em stdout (scriptável)
c "query sql lenta" -NoRefine                   # pula refiner, só compila
c "algo vago" -Interactive                      # pergunta antes de compilar
c -Last                                         # mostra último XML gerado
c -Help                                         # ajuda completa
```

### No Claude Code

Duas integrações disponíveis:

- **Hook automático** — `UserPromptSubmit` refina cada prompt relevante. Prefixe com `\\` para desativar pontualmente.
- **Slash command** — `/c <prompt>` compila e envia só o XML ao Claude. Instalado em `~/.claude/commands/c.md`.

### Métricas

```powershell
cstats                            # resumo geral
cstats -Last 20                   # últimas 20 entradas
cstats -Since 7d                  # última semana
cstats -By mode                   # agrupado por modo (refiner/cache/raw)
cstats -Since 24h -By model       # filtrar + agrupar
```

Mostra: cache hit rate, latência p50/p95, eval rate do compilador, cold starts. Com `-Send`: tokens e custo do Claude.

## Pipeline

1. **Refiner** (`prompt-refiner`) — classifica input. Se concreto: passthrough. Se vago: faz 1 pergunta. Bypass: `-NoRefine`.
2. **Compiler** (`prompt-opt`) — gera XML `<task>/<context>/<constraints>`. Cache por modelo + input.
3. **Saída** — clipboard (padrão), `claude -p` (`-Send`), ou stdout (`-Raw`).

## Testes

```powershell
Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester ./Tests
```

252 testes: unitários (parser, métricas, summary), integração (pipeline completo com mock de ollama/claude), qualidade do refiner (regressão estatística).

## Arquivos

| Arquivo | Função |
|---------|--------|
| `c.ps1` | Entrypoint — args, Ollama, Claude pipe |
| `cprompt.psm1` | Módulo: XML parser, cache, métricas, helpers |
| `cstats.ps1` | CLI de métricas com -Since/-By/-Last |
| `install.ps1` / `uninstall.ps1` | Instalador/desinstalador |
| `Modelfile.compiler` | Modelfile do compilador (prompt-opt) |
| `Modelfile.refiner` | Modelfile do refiner (prompt-refiner) |

## Licença

Uso pessoal.
