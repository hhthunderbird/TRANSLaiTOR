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

