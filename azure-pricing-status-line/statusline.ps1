$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) {
        return $null
    }
    try {
        return Get-Content -Raw $path | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-JsonFile([string]$path, $value, [int]$depth) {
    $value | ConvertTo-Json -Depth $depth | Set-Content -Path $path -Encoding utf8
}

function Get-TokenValue($usage, [string]$name) {
    if ($null -eq $usage) {
        return 0.0
    }

    $property = $usage.PSObject.Properties[$name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return 0.0
    }

    return [double]$property.Value
}

function New-UsageSnapshot($usage) {
    [pscustomobject]@{
        input_tokens = Get-TokenValue $usage 'input_tokens'
        output_tokens = Get-TokenValue $usage 'output_tokens'
        cache_creation_input_tokens = Get-TokenValue $usage 'cache_creation_input_tokens'
        cache_read_input_tokens = Get-TokenValue $usage 'cache_read_input_tokens'
    }
}

function Get-UsageDelta($current, $previous) {
    [pscustomobject]@{
        input_tokens = [Math]::Max(0.0, $current.input_tokens - $previous.input_tokens)
        output_tokens = [Math]::Max(0.0, $current.output_tokens - $previous.output_tokens)
        cache_creation_input_tokens = [Math]::Max(0.0, $current.cache_creation_input_tokens - $previous.cache_creation_input_tokens)
        cache_read_input_tokens = [Math]::Max(0.0, $current.cache_read_input_tokens - $previous.cache_read_input_tokens)
    }
}

function Test-UsageEqual($left, $right) {
    $left.input_tokens -eq $right.input_tokens -and
        $left.output_tokens -eq $right.output_tokens -and
        $left.cache_creation_input_tokens -eq $right.cache_creation_input_tokens -and
        $left.cache_read_input_tokens -eq $right.cache_read_input_tokens
}

function Test-UsageHasTokens($usage) {
    $usage.input_tokens -gt 0 -or
        $usage.output_tokens -gt 0 -or
        $usage.cache_creation_input_tokens -gt 0 -or
        $usage.cache_read_input_tokens -gt 0
}

function Get-PriceValue($pricing, $name) {
    # Columns may be absent (older pricing files) or empty; treat both as no charge.
    $property = $pricing.PSObject.Properties[$name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return 0.0
    }

    return [double]$property.Value
}

function Get-Cost($usage, $pricing) {
    $inputTokens = [double]$usage.input_tokens
    $outputTokens = [double]$usage.output_tokens
    $cacheReadInputTokens = [double]$usage.cache_read_input_tokens
    $cacheWriteInputTokens = [double]$usage.cache_creation_input_tokens
    $nonCachedInputTokens = $inputTokens - $cacheReadInputTokens

    if ($nonCachedInputTokens -lt 0) {
        throw 'cache_read_input_tokens cannot exceed input_tokens.'
    }

    # Not all models charge for cache writes, so check if that column has a value > 0
    $cacheWriteRate = Get-PriceValue $pricing 'cache_write_per_1m'
    $billedCacheWriteTokens = 0.0
    if ($cacheWriteRate -gt 0) {
        $billedCacheWriteTokens = [Math]::Min($cacheWriteInputTokens, $nonCachedInputTokens)
        $nonCachedInputTokens = $nonCachedInputTokens - $billedCacheWriteTokens
    }

    $inputCost = $nonCachedInputTokens / 1000000.0 * (Get-PriceValue $pricing 'input_per_1m')
    $cachedInputCost = $cacheReadInputTokens / 1000000.0 * (Get-PriceValue $pricing 'cached_input_per_1m')
    $cacheWriteCost = $billedCacheWriteTokens / 1000000.0 * $cacheWriteRate
    $outputCost = $outputTokens / 1000000.0 * (Get-PriceValue $pricing 'output_per_1m')

    return $inputCost + $cachedInputCost + $cacheWriteCost + $outputCost
}

function Get-Pricing($modelId, $modelDisplayName) {
    $pricingPath = Join-Path $PSScriptRoot 'foundry-model-pricing.csv'
    if (-not (Test-Path $pricingPath)) {
        return $null
    }

    $searchText = "$modelId $modelDisplayName".ToLowerInvariant()
    foreach ($row in Import-Csv $pricingPath) {
        # Match against model_key plus any pipe-separated aliases. Aliases may be empty.
        $candidates = @($row.model_key) + ($row.aliases -split '\|')
        foreach ($candidate in $candidates) {
            $normalizedCandidate = $candidate.Trim().ToLowerInvariant()
            if ($normalizedCandidate.Length -gt 0 -and $searchText.Contains($normalizedCandidate)) {
                return $row
            }
        }
    }

    return $null
}

function Get-TranscriptEventsPath([string]$transcriptPath) {
    # Copilot passes the session-state directory as transcript_path; its events.jsonl holds the event log.
    if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
        return $null
    }

    $eventsPath = if (Test-Path -LiteralPath $transcriptPath -PathType Container) { Join-Path $transcriptPath 'events.jsonl' } else { $transcriptPath }
    if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
        return $eventsPath
    }

    return $null
}

function Find-NewUserPrompt([string]$eventsPath, [long]$offset) {
    # Scan only the bytes appended since the last refresh, stopping at the last complete line.
    $stream = [System.IO.File]::Open($eventsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        if ($offset -lt 0 -or $offset -gt $stream.Length) {
            $offset = 0
        }

        $remaining = [int]($stream.Length - $offset)
        $buffer = [byte[]]::new($remaining)
        [void]$stream.Seek($offset, [System.IO.SeekOrigin]::Begin)
        $read = 0
        while ($read -lt $remaining) {
            $count = $stream.Read($buffer, $read, $remaining - $read)
            if ($count -le 0) {
                break
            }
            $read += $count
        }
    }
    finally {
        $stream.Dispose()
    }

    if ($read -eq 0) {
        return [pscustomobject]@{ has_new_prompt = $false; offset = $offset }
    }

    $lastNewline = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
    if ($lastNewline -lt 0) {
        return [pscustomobject]@{ has_new_prompt = $false; offset = $offset }
    }

    $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $lastNewline + 1)
    return [pscustomobject]@{
        has_new_prompt = $text -match '(?m)^\{"type":"user\.message"'
        offset = $offset + $lastNewline + 1
    }
}

function Update-SessionUsage($sessionId, $currentUsage, $transcriptPath) {
    $safeSessionId = if ([string]::IsNullOrWhiteSpace($sessionId)) { 'unknown' } else { $sessionId -replace '[^A-Za-z0-9_.-]', '_' }
    $stateDir = Join-Path $PSScriptRoot 'cost-state'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $statePath = Join-Path $stateDir "statusline-cost-state-$safeSessionId.json"
    $previousState = Read-JsonFile $statePath
    if ($null -ne $previousState -and $previousState.session_id -ne $sessionId) {
        $previousState = $null
    }

    $emptyUsage = New-UsageSnapshot $null
    $previousUsage = if ($null -ne $previousState -and $null -ne $previousState.last_cumulative_usage) { New-UsageSnapshot $previousState.last_cumulative_usage } else { $null }
    $refreshUsage = if ($null -ne $previousUsage) { Get-UsageDelta $currentUsage $previousUsage } else { $currentUsage }
    $promptStartUsage = $null
    $transcriptOffset = $null

    $eventsPath = Get-TranscriptEventsPath $transcriptPath
    if ($null -ne $eventsPath) {
        # A single prompt can trigger many model calls (and statusline refreshes), so prompt
        # boundaries come from user.message events in the transcript, not from usage changes.
        $previousOffset = if ($null -ne $previousState -and $null -ne $previousState.transcript_offset) { [long]$previousState.transcript_offset } else { 0 }
        $scan = Find-NewUserPrompt $eventsPath $previousOffset
        $transcriptOffset = $scan.offset

        if ($scan.has_new_prompt) {
            $promptStartUsage = if ($null -ne $previousUsage) { $previousUsage } else { $emptyUsage }
        }
        elseif ($null -ne $previousState -and $null -ne $previousState.prompt_start_usage) {
            $promptStartUsage = New-UsageSnapshot $previousState.prompt_start_usage
        }
        else {
            $promptStartUsage = if ($null -ne $previousUsage) { $previousUsage } else { $emptyUsage }
        }

        $promptUsage = Get-UsageDelta $currentUsage $promptStartUsage
    }
    elseif ($null -ne $previousUsage -and (Test-UsageEqual $currentUsage $previousUsage)) {
        # Without a transcript, fall back to treating each usage change as a prompt.
        $promptUsage = $previousState.last_prompt_usage
    }
    else {
        $promptUsage = $refreshUsage
    }

    $state = [pscustomobject]@{
        session_id = $sessionId
        last_cumulative_usage = $currentUsage
        last_prompt_usage = $promptUsage
        prompt_start_usage = $promptStartUsage
        transcript_offset = $transcriptOffset
        updated_at = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-JsonFile $statePath $state 5

    return [pscustomobject]@{
        prompt_usage = $promptUsage
        refresh_usage = $refreshUsage
    }
}

function Format-PricingText([double]$previousCost, [double]$sessionCost, [double]$todayCost) {
    $esc = [char]27
    return "$esc[36m$('(Azure) Last prompt: ${0:N2} | Session: ${1:N2} | Today: ${2:N2}' -f $previousCost, $sessionCost, $todayCost)$esc[0m"
}

function Get-DailyCost([double]$additionalCost, [bool]$shouldIncrement) {
    $dailyDir = Join-Path $PSScriptRoot 'daily-cost'
    New-Item -ItemType Directory -Path $dailyDir -Force | Out-Null

    $today = Get-Date -Format 'yyyy-MM-dd'
    $dailyPath = Join-Path $dailyDir "$today.json"
    $dailyTotal = 0.0

    $dailyState = Read-JsonFile $dailyPath
    if ($null -ne $dailyState -and $null -ne $dailyState.estimated_total_usd) {
        $dailyTotal = [double]$dailyState.estimated_total_usd
    }

    if ($shouldIncrement) {
        $dailyTotal += $additionalCost
        $state = [pscustomobject]@{
            date = $today
            estimated_total_usd = $dailyTotal
            updated_at = [DateTimeOffset]::Now.ToString('o')
        }
        Write-JsonFile $dailyPath $state 3
    }

    return $dailyTotal
}

function Invoke-StatusLine {
    $jsonText = [Console]::In.ReadToEnd()

    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        exit 0
    }

    $status = $jsonText | ConvertFrom-Json

    if (-not [string]::Equals($env:COPILOT_PROVIDER_TYPE, 'azure', [System.StringComparison]::OrdinalIgnoreCase)) {
        exit 0
    }

    $usage = $status.context_window.current_usage
    if ($null -eq $usage) {
        Format-PricingText 0.0 0.0 (Get-DailyCost 0.0 $false)
        exit 0
    }

    $pricing = Get-Pricing $status.model.id $status.model.display_name

    if ($null -eq $pricing) {
        exit 0
    }

    $sessionUsage = New-UsageSnapshot $usage
    $usageUpdate = Update-SessionUsage $status.session_id $sessionUsage $status.transcript_path
    $lastPromptCost = if ($null -ne $usageUpdate.prompt_usage) { Get-Cost $usageUpdate.prompt_usage $pricing } else { 0.0 }
    $sessionCost = Get-Cost $sessionUsage $pricing
    $refreshCost = Get-Cost $usageUpdate.refresh_usage $pricing
    $todayCost = Get-DailyCost $refreshCost (Test-UsageHasTokens $usageUpdate.refresh_usage)
    Format-PricingText $lastPromptCost $sessionCost $todayCost
}

try {
    Invoke-StatusLine
}
catch {
    "statusline error: $($_.Exception.Message)"
    exit 0
}