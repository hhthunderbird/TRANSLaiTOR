$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$module = Join-Path (Split-Path -Parent $here) 'cprompt.psm1'
Remove-Module cprompt -ErrorAction SilentlyContinue
Import-Module $module -Force

Describe 'Remove-Bom' {
    It 'strips UTF-8 BOM from start of string' {
        $bom = [char]0xFEFF
        $input = "$bom<task>x</task>"
        (Remove-Bom $input) | Should Be '<task>x</task>'
    }

    It 'returns identical string when no BOM present' {
        (Remove-Bom 'plain text') | Should Be 'plain text'
    }

    It 'handles empty string' {
        (Remove-Bom '') | Should Be ''
    }

    It 'handles null input as empty string' {
        (Remove-Bom $null) | Should Be ''
    }

    It 'only strips BOM at start, not middle' {
        $bom = [char]0xFEFF
        $input = "a${bom}b"
        (Remove-Bom $input) | Should Be "a${bom}b"
    }
}

Describe 'Get-PromptXml' {
    It 'extracts clean XML block from clean input' {
        $raw = "<task>A</task>`n<context>B</context>`n<constraints>C</constraints>"
        $result = Get-PromptXml $raw
        $result | Should Match '<task>A</task>'
        $result | Should Match '<context>B</context>'
        $result | Should Match '<constraints>C</constraints>'
    }

    It 'strips preamble noise before <task>' {
        $raw = "Here is the output you requested:`n`n<task>A</task>`n<context>B</context>`n<constraints>C</constraints>"
        $result = Get-PromptXml $raw
        $result.StartsWith('<task>') | Should Be $true
    }

    It 'strips trailing noise after </constraints>' {
        $raw = "<task>A</task><context>B</context><constraints>C</constraints>`n`nHope this helps!"
        $result = Get-PromptXml $raw
        $result.EndsWith('</constraints>') | Should Be $true
    }

    It 'returns $null when <task> tag missing' {
        $raw = '<context>B</context><constraints>C</constraints>'
        (Get-PromptXml $raw) | Should BeNullOrEmpty
    }

    It 'returns $null when <constraints> open tag entirely missing' {
        $raw = '<task>A</task><context>B</context>'
        (Get-PromptXml $raw) | Should BeNullOrEmpty
    }

    It 'returns $null on empty input' {
        (Get-PromptXml '') | Should BeNullOrEmpty
    }

    It 'handles BOM-prefixed dirty output' {
        $bom = [char]0xFEFF
        $raw = "${bom}prefix junk <task>A</task><context>B</context><constraints>C</constraints>"
        $result = Get-PromptXml $raw
        $result.StartsWith('<task>') | Should Be $true
        $result.EndsWith('</constraints>') | Should Be $true
    }

    It 'survives repetition-loop output by taking first valid block' {
        $raw = '<task>A</task><context>B</context><constraints>C</constraints><task>A</task><context>B</context><constraints>C</constraints>'
        $result = Get-PromptXml $raw
        ($result -split '<task>').Count - 1 | Should Be 1
    }

    It 'salvages output when model hallucinates a wrong closing tag name' {
        $raw = '<task>A</task><context>B</context><constraints>C</coordinates>'
        $result = Get-PromptXml $raw
        $result | Should Not BeNullOrEmpty
        $result | Should Match '<task>A</task>'
        $result | Should Match '<context>B</context>'
        $result | Should Match '<constraints>C</constraints>'
    }

    It 'salvages output when constraints close tag entirely missing (EOF terminator)' {
        $raw = '<task>A</task><context>B</context><constraints>C and more text'
        $result = Get-PromptXml $raw
        $result | Should Not BeNullOrEmpty
        $result | Should Match '<task>A</task>'
        $result | Should Match '<constraints>C and more text</constraints>'
    }

    It 'salvages output when model emits prose between tags' {
        $raw = "<task>A</task>`nExplanation: this matters because ...`n<context>B</context>`nNote: also relevant.`n<constraints>C</constraints>"
        $result = Get-PromptXml $raw
        $result | Should Not BeNullOrEmpty
        $result | Should Match '<task>A</task>'
        $result | Should Match '<context>B</context>'
        $result | Should Match '<constraints>C</constraints>'
    }

    It 'preserves literal "0" as valid content (PowerShell truthiness trap)' {
        $raw = '<task>0</task><context>0</context><constraints>0</constraints>'
        $result = Get-PromptXml $raw
        $result | Should Be '<task>0</task><context>0</context><constraints>0</constraints>'
    }

    It 'returns $null when a tag contains only whitespace' {
        $raw = "<task>A</task><context>   </context><constraints>C</constraints>"
        (Get-PromptXml $raw) | Should BeNullOrEmpty
    }
}

Describe 'Test-PromptXml' {
    It 'returns $true for valid three-tag block' {
        $xml = '<task>A</task><context>B</context><constraints>C</constraints>'
        (Test-PromptXml $xml) | Should Be $true
    }

    It 'returns $false when any tag content is empty' {
        $xml = '<task></task><context>B</context><constraints>C</constraints>'
        (Test-PromptXml $xml) | Should Be $false
    }

    It 'returns $false on $null input' {
        (Test-PromptXml $null) | Should Be $false
    }
}

Describe 'Resolve-Tool' {
    It 'returns command object for existing tool' {
        $cmd = Resolve-Tool 'powershell'
        $cmd | Should Not BeNullOrEmpty
    }

    It 'throws specifically with "Tool ... not found" message' {
        { Resolve-Tool 'definitely-not-a-real-tool-xyz-12345' } | Should Throw "Tool 'definitely-not-a-real-tool-xyz-12345' not found"
    }
}

Describe 'Get-CacheKey' {
    It 'returns deterministic hex hash for same model + input' {
        $a = Get-CacheKey -Model 'm1' -Text 'hello'
        $b = Get-CacheKey -Model 'm1' -Text 'hello'
        $a | Should Be $b
        $a | Should Match '^[0-9a-f]+$'
    }

    It 'returns different hash for different input' {
        $a = Get-CacheKey -Model 'm1' -Text 'hello'
        $b = Get-CacheKey -Model 'm1' -Text 'world'
        $a | Should Not Be $b
    }

    It 'returns different hash for different model with same input' {
        $a = Get-CacheKey -Model 'm1' -Text 'hello'
        $b = Get-CacheKey -Model 'm2' -Text 'hello'
        $a | Should Not Be $b
    }
}

Describe 'Cache roundtrip' {
    It 'returns $null on miss' {
        $dir = Join-Path $TestDrive 'cache1'
        (Get-CachedXml -Key 'abc' -CacheDir $dir) | Should BeNullOrEmpty
    }

    It 'writes and reads the same value' {
        $dir = Join-Path $TestDrive 'cache2'
        $xml = '<task>A</task><context>B</context><constraints>C</constraints>'
        Set-CachedXml -Key 'abc' -Xml $xml -CacheDir $dir
        (Get-CachedXml -Key 'abc' -CacheDir $dir) | Should Be $xml
    }

    It 'creates the cache directory if missing' {
        $dir = Join-Path $TestDrive 'cache3/nested'
        Set-CachedXml -Key 'k' -Xml 'v' -CacheDir $dir
        (Test-Path $dir) | Should Be $true
    }
}

Describe 'History' {
    It 'returns $null when history file does not exist' {
        $path = Join-Path $TestDrive 'h1.jsonl'
        (Get-LastHistoryEntry -Path $path) | Should BeNullOrEmpty
    }

    It 'roundtrips a single entry' {
        $path = Join-Path $TestDrive 'h2.jsonl'
        Add-HistoryEntry -Path $path -Entry @{ input = 'foo'; xml = '<task>x</task>'; model = 'm1' }
        $last = Get-LastHistoryEntry -Path $path
        $last.input | Should Be 'foo'
        $last.xml | Should Be '<task>x</task>'
        $last.model | Should Be 'm1'
    }

    It 'returns the most recent entry when multiple exist' {
        $path = Join-Path $TestDrive 'h3.jsonl'
        Add-HistoryEntry -Path $path -Entry @{ input = 'first';  xml = 'x1' }
        Add-HistoryEntry -Path $path -Entry @{ input = 'second'; xml = 'x2' }
        Add-HistoryEntry -Path $path -Entry @{ input = 'third';  xml = 'x3' }
        (Get-LastHistoryEntry -Path $path).input | Should Be 'third'
    }

    It 'creates the directory for the history file if missing' {
        $path = Join-Path $TestDrive 'sub/dir/h.jsonl'
        Add-HistoryEntry -Path $path -Entry @{ input = 'x' }
        (Test-Path $path) | Should Be $true
    }
}

Describe 'Test-InputAcceptable' {
    It 'returns $true for input within limit' {
        (Test-InputAcceptable -Text 'short prompt' -MaxLength 100) | Should Be $true
    }

    It 'returns $false for input over limit' {
        $long = 'x' * 200
        (Test-InputAcceptable -Text $long -MaxLength 100) | Should Be $false
    }

    It 'returns $false for empty or null input' {
        (Test-InputAcceptable -Text '' -MaxLength 100) | Should Be $false
        (Test-InputAcceptable -Text $null -MaxLength 100) | Should Be $false
    }

    It 'returns $false for whitespace-only input' {
        (Test-InputAcceptable -Text "   `n  `t" -MaxLength 100) | Should Be $false
    }
}

Describe 'Get-RefinerOutput' {
    It 'parses a clean passthrough envelope' {
        $raw = '<passthrough>preserve this exactly</passthrough>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'passthrough'
        $result.Payload | Should Be 'preserve this exactly'
    }

    It 'parses a single-question envelope' {
        $raw = '<questions><q>which language?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'questions'
        $result.Payload.Count | Should Be 1
        $result.Payload[0] | Should Be 'which language?'
    }

    It 'parses a two-question envelope' {
        $raw = '<questions><q>a?</q><q>b?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 2
        $result.Payload[0] | Should Be 'a?'
        $result.Payload[1] | Should Be 'b?'
    }

    It 'parses a three-question envelope' {
        $raw = '<questions><q>a?</q><q>b?</q><q>c?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 3
    }

    It 'caps the question list at 3 even if the model emits more' {
        $raw = '<questions><q>1?</q><q>2?</q><q>3?</q><q>4?</q><q>5?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 3
        $result.Payload[0] | Should Be '1?'
        $result.Payload[2] | Should Be '3?'
    }

    It 'drops empty <q></q> elements before counting' {
        $raw = '<questions><q>a?</q><q>   </q><q>b?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Payload.Count | Should Be 2
        $result.Payload[0] | Should Be 'a?'
        $result.Payload[1] | Should Be 'b?'
    }

    It 'salvages passthrough when close tag is hallucinated' {
        $raw = '<passthrough>keep me</wrong>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'passthrough'
        $result.Payload | Should Be 'keep me'
    }

    It 'salvages questions when outer close tag is hallucinated' {
        $raw = '<questions><q>x?</q><q>y?</q></ask>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'questions'
        $result.Payload.Count | Should Be 2
    }

    It 'salvages each q when q close tag is hallucinated' {
        $raw = '<questions><q>x?</question><q>y?</q></questions>'
        $result = Get-RefinerOutput $raw
        $result.Mode | Should Be 'questions'
        $result.Payload[0] | Should Be 'x?'
        $result.Payload[1] | Should Be 'y?'
    }

    It 'returns $null on empty input' {
        (Get-RefinerOutput '') | Should BeNullOrEmpty
    }

    It 'returns $null when no recognizable envelope is present' {
        (Get-RefinerOutput 'just some prose, no tags at all') | Should BeNullOrEmpty
    }

    It 'returns $null when passthrough body is whitespace only' {
        (Get-RefinerOutput '<passthrough>   </passthrough>') | Should BeNullOrEmpty
    }

    It 'returns $null when questions body has only empty <q> items' {
        (Get-RefinerOutput '<questions><q></q><q>   </q></questions>') | Should BeNullOrEmpty
    }
}

Describe 'Test-RefinerOutput' {
    It 'returns $true for a valid passthrough hashtable' {
        (Test-RefinerOutput @{ Mode = 'passthrough'; Payload = 'x' }) | Should Be $true
    }

    It 'returns $true for a valid questions hashtable' {
        (Test-RefinerOutput @{ Mode = 'questions'; Payload = @('a?', 'b?') }) | Should Be $true
    }

    It 'returns $false for $null' {
        (Test-RefinerOutput $null) | Should Be $false
    }

    It 'returns $false for unknown Mode' {
        (Test-RefinerOutput @{ Mode = 'banana'; Payload = 'x' }) | Should Be $false
    }

    It 'returns $false for passthrough with empty Payload' {
        (Test-RefinerOutput @{ Mode = 'passthrough'; Payload = '' }) | Should Be $false
    }

    It 'returns $false for questions with empty list' {
        (Test-RefinerOutput @{ Mode = 'questions'; Payload = @() }) | Should Be $false
    }
}

Describe 'Merge-RefinementAnswers' {
    It 'appends each question/answer pair on its own line, separated from raw' {
        $result = Merge-RefinementAnswers -Raw 'preciso ajuda com cache' -Pairs @(
            @{ Question = 'qual stack?'; Answer = 'Python + Redis' }
            @{ Question = 'leitura ou escrita?'; Answer = 'leitura, 100x mais' }
        )
        $expected = "preciso ajuda com cache`n`nqual stack?: Python + Redis`nleitura ou escrita?: leitura, 100x mais"
        $result | Should Be $expected
    }

    It 'drops pairs whose answer is empty or whitespace' {
        $result = Merge-RefinementAnswers -Raw 'x' -Pairs @(
            @{ Question = 'a?'; Answer = '' }
            @{ Question = 'b?'; Answer = '   ' }
            @{ Question = 'c?'; Answer = 'yes' }
        )
        $result | Should Be "x`n`nc?: yes"
    }

    It 'returns the raw input unchanged when all pairs are empty' {
        $result = Merge-RefinementAnswers -Raw 'x' -Pairs @(
            @{ Question = 'a?'; Answer = '' }
        )
        $result | Should Be 'x'
    }

    It 'returns the raw input unchanged when Pairs is empty' {
        (Merge-RefinementAnswers -Raw 'x' -Pairs @()) | Should Be 'x'
    }
}

Describe 'Add-MetricEntry' {
    It 'creates the directory and writes a JSONL line' {
        $path = Join-Path $TestDrive 'm1/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ mode = 'passthrough'; totalMs = 100 }
        (Test-Path $path) | Should Be $true
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
        $lines.Count | Should Be 1
        $obj = $lines[0] | ConvertFrom-Json
        $obj.mode | Should Be 'passthrough'
        $obj.totalMs | Should Be 100
    }

    It 'auto-injects a UTC ts field when missing' {
        $path = Join-Path $TestDrive 'm2/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ mode = 'cache' }
        $obj = (Get-Content -LiteralPath $path -Encoding UTF8) | ConvertFrom-Json
        $obj.ts | Should Match '^\d{4}-\d{2}-\d{2}T'
    }

    It 'preserves a caller-supplied ts field' {
        $path = Join-Path $TestDrive 'm3/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ ts = '2020-01-01T00:00:00Z'; mode = 'raw' }
        $obj = (Get-Content -LiteralPath $path -Encoding UTF8) | ConvertFrom-Json
        $obj.ts | Should Be '2020-01-01T00:00:00Z'
    }

    It 'appends additional entries on subsequent calls' {
        $path = Join-Path $TestDrive 'm4/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ mode = 'raw' }
        Add-MetricEntry -Path $path -Entry @{ mode = 'questions' }
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
        $lines.Count | Should Be 2
    }
}

Describe 'Read-MetricsFile' {
    It 'returns an empty array when the file does not exist' {
        $path = Join-Path $TestDrive 'r1/missing.jsonl'
        $entries = Read-MetricsFile -Path $path
        @($entries).Count | Should Be 0
    }

    It 'parses each non-blank JSONL line into an object' {
        $path = Join-Path $TestDrive 'r2/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ mode = 'raw'; totalMs = 1 }
        Add-MetricEntry -Path $path -Entry @{ mode = 'passthrough'; totalMs = 2 }
        $entries = @(Read-MetricsFile -Path $path)
        $entries.Count | Should Be 2
        $entries[0].mode | Should Be 'raw'
        $entries[1].totalMs | Should Be 2
    }

    It 'skips blank lines without erroring' {
        $path = Join-Path $TestDrive 'r3/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ mode = 'cache' }
        Add-Content -LiteralPath $path -Value '' -Encoding UTF8
        Add-Content -LiteralPath $path -Value '   ' -Encoding UTF8
        $entries = @(Read-MetricsFile -Path $path)
        $entries.Count | Should Be 1
    }

    It 'silently drops lines that fail to parse as JSON' {
        $path = Join-Path $TestDrive 'r4/metrics.jsonl'
        Add-MetricEntry -Path $path -Entry @{ mode = 'raw' }
        Add-Content -LiteralPath $path -Value '{ not json' -Encoding UTF8
        Add-MetricEntry -Path $path -Entry @{ mode = 'questions' }
        $entries = @(Read-MetricsFile -Path $path)
        $entries.Count | Should Be 2
    }
}

Describe 'Get-MetricsSummary' {
    It 'returns zeroed summary on empty input' {
        $s = Get-MetricsSummary -Entries @()
        $s.Count | Should Be 0
        $s.CacheHitRate | Should Be 0
        $s.LatencyP50 | Should Be 0
        $s.LatencyP95 | Should Be 0
    }

    It 'computes count and cache hit rate' {
        $entries = @(
            @{ mode = 'cache'; totalMs = 5 },
            @{ mode = 'passthrough'; totalMs = 100 },
            @{ mode = 'cache'; totalMs = 6 },
            @{ mode = 'raw'; totalMs = 50 }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.Count | Should Be 4
        $s.CacheHitRate | Should Be 0.5
    }

    It 'computes mode distribution as a hashtable of counts' {
        $entries = @(
            @{ mode = 'raw' }, @{ mode = 'raw' }, @{ mode = 'questions' },
            @{ mode = 'passthrough' }, @{ mode = 'passthrough' }, @{ mode = 'passthrough' }
        )
        $s = Get-MetricsSummary -Entries $entries
        $s.ModeCounts['raw'] | Should Be 2
        $s.ModeCounts['questions'] | Should Be 1
        $s.ModeCounts['passthrough'] | Should Be 3
    }

    It 'computes p50 and p95 of totalMs' {
        $entries = 1..20 | ForEach-Object { @{ mode = 'passthrough'; totalMs = ($_ * 10) } }
        $s = Get-MetricsSummary -Entries $entries
        # 20 entries, values 10..200 step 10.
        # p50 = element at ceil(0.5 * 20) = 10th -> 100.
        # p95 = element at ceil(0.95 * 20) = 19th -> 190.
        $s.LatencyP50 | Should Be 100
        $s.LatencyP95 | Should Be 190
    }

    It 'computes average compression ratio over entries with both fields' {
        $entries = @(
            @{ mode = 'passthrough'; inputChars = 100; xmlChars = 200 },
            @{ mode = 'passthrough'; inputChars = 50;  xmlChars = 150 },
            @{ mode = 'raw';         inputChars = 0;   xmlChars = 0   }
        )
        $s = Get-MetricsSummary -Entries $entries
        # Only the first two entries qualify (inputChars > 0). Ratios: 2.0, 3.0. Mean = 2.5.
        $s.AvgCompressionRatio | Should Be 2.5
    }
}

Describe 'Get-MetricsSummary strict-mode robustness' {
    It 'tolerates PSCustomObject entries that omit the mode field' {
        $json = '{"totalMs":50}'
        $entry = $json | ConvertFrom-Json
        $s = Get-MetricsSummary -Entries @($entry)
        $s.Count | Should Be 1
        $s.ModeCounts['unknown'] | Should Be 1
    }

    It 'tolerates PSCustomObject entries that omit totalMs and char fields' {
        $json = '{"mode":"raw"}'
        $entry = $json | ConvertFrom-Json
        $s = Get-MetricsSummary -Entries @($entry)
        $s.Count | Should Be 1
        $s.LatencyP50 | Should Be 0
        $s.AvgCompressionRatio | Should Be 0
    }
}

Describe 'Remove-AnsiEscapes' {
    It 'strips a CSI cursor-back sequence' {
        (Remove-AnsiEscapes "abc`e[3Dxyz") | Should Be 'abcxyz'
    }

    It 'strips an erase-to-EOL sequence' {
        (Remove-AnsiEscapes "abc`e[Kdef") | Should Be 'abcdef'
    }

    It 'strips SGR color codes' {
        (Remove-AnsiEscapes "`e[31mred`e[0m") | Should Be 'red'
    }

    It 'returns identical string when no escape codes are present' {
        (Remove-AnsiEscapes 'plain text') | Should Be 'plain text'
    }

    It 'returns empty string for empty input' {
        (Remove-AnsiEscapes '') | Should Be ''
    }

    It 'returns empty string for null input' {
        (Remove-AnsiEscapes $null) | Should Be ''
    }

    It 'strips the exact wrap sequence reported by ollama run' {
        # Reproduces the byte pattern that corrupted "ideia vaga" output:
        # `nív` + CSI cursor-back-19 + CSI erase-EOL + CRLF + `escolher?`.
        $dirty = "nív`e[19D`e[K`r`nescolher?"
        (Remove-AnsiEscapes $dirty) | Should Be "nív`r`nescolher?"
    }
}

Describe 'Get-RefinerOutput CSI sanitization' {
    It 'strips embedded CSI escape codes from a single-question payload' {
        $dirty = "<questions><q>abc`e[3Ddef?</q></questions>"
        $result = Get-RefinerOutput $dirty
        $result.Mode | Should Be 'questions'
        $result.Payload.Count | Should Be 1
        $result.Payload[0] | Should Be 'abcdef?'
    }

    It 'strips CSI codes from a passthrough payload' {
        $dirty = "<passthrough>fix`e[1Dbug now</passthrough>"
        $result = Get-RefinerOutput $dirty
        $result.Mode | Should Be 'passthrough'
        $result.Payload | Should Be 'fixbug now'
    }
}

Describe 'Get-PromptXml CSI sanitization' {
    It 'strips CSI codes that appear inside the XML body' {
        $dirty = "<task>do`e[1D the thing</task><context>here`e[2D</context><constraints>none</constraints>"
        $result = Get-PromptXml $dirty
        $result | Should Match '<task>'
        ($result -match "`e\[") | Should Be $false
    }
}

Describe 'Test-InputIsZeroSignal' {
    It 'returns $true for null input' {
        (Test-InputIsZeroSignal -Text $null) | Should Be $true
    }

    It 'returns $true for empty string' {
        (Test-InputIsZeroSignal -Text '') | Should Be $true
    }

    It 'returns $true for whitespace-only input' {
        (Test-InputIsZeroSignal -Text '   ') | Should Be $true
    }

    It 'returns $true for a single word' {
        (Test-InputIsZeroSignal -Text 'ajuda') | Should Be $true
    }

    It 'returns $true for two words' {
        (Test-InputIsZeroSignal -Text 'ideia vaga') | Should Be $true
    }

    It 'returns $true for three words' {
        (Test-InputIsZeroSignal -Text 'preciso de algo') | Should Be $true
    }

    It 'returns $false for exactly four words' {
        (Test-InputIsZeroSignal -Text 'cache lru em go') | Should Be $false
    }

    It 'returns $false for five or more words' {
        (Test-InputIsZeroSignal -Text 'implementa um servidor http em rust') | Should Be $false
    }

    It 'collapses multiple whitespace runs when counting' {
        (Test-InputIsZeroSignal -Text "ideia    vaga`tagora") | Should Be $true
    }

    It 'respects custom MinWords threshold' {
        (Test-InputIsZeroSignal -Text 'cache lru go' -MinWords 3) | Should Be $false
        (Test-InputIsZeroSignal -Text 'cache lru' -MinWords 3)    | Should Be $true
    }
}


