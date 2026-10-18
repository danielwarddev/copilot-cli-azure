$ErrorActionPreference = "Stop"

$AZURE_FOUNDRY_RESOURCE_NAME = "your-azure-foundry-resource-name"
# Resource group name is only needed if you don't want to
# set COPILOT_PROVIDER_API_KEY. If that env var isn't set,# the script will use the Azure CLI to fetch the API key.
$AZURE_RESOURCE_GROUP_NAME = "your-azure-resource-group"

function Show-Usage {
    @"
Usage: caz [model-deployment-name] [copilot-args...]

Examples:
    caz
    caz gpt-5.6-terra
    caz gpt-5.6-terra --help
        caz gpt-5.6-luna --some-copilot-flag
"@ | Write-Output
}

Write-Host
Write-Host '=== Copilot CLI (BYOK) with Azure Foundry models ==='

if ($args[0] -in @("-h", "--help")) {
    Show-Usage
    exit 0
}

$pricingPath = Join-Path $HOME '.copilot\azure-pricing-status-line\foundry-model-pricing.csv'
if (-not (Test-Path $pricingPath)) {
    Write-Error "Pricing file not found at '$pricingPath'."
    exit 1
}

$modelRows = @(Import-Csv $pricingPath | Where-Object { $_.model_key -and $_.model_key.Trim() })
$models = @($modelRows | ForEach-Object { $_.model_key.Trim() })
if ($models.Count -eq 0) {
    Write-Error "No models found in '$pricingPath'."
    exit 1
}

$effortOptions = @($modelRows | ForEach-Object {
    $levels = @()
    if ($_.reasoning_efforts) {
        $levels = @($_.reasoning_efforts -split '\|')
        foreach ($level in $levels) {
            if ($level -cnotin @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max')) {
                throw "Invalid reasoning effort '$level' for '$($_.model_key)'."
            }
        }
    }
    $startingEffort = if ($_.default_reasoning_effort) { $_.default_reasoning_effort } else { 'medium' }
    $effortIndex = [Array]::IndexOf($levels, $startingEffort)
    if ($_.default_reasoning_effort -and $effortIndex -lt 0) {
        throw "Invalid default reasoning effort '$startingEffort' for '$($_.model_key)'."
    }
    [pscustomobject]@{ Levels = $levels; Index = [Math]::Max(0, $effortIndex) }
})
$modelLabels = @($models)
for ($index = 0; $index -lt $models.Count; $index++) {
    $option = $effortOptions[$index]
    $effort = if ($option.Levels.Count) { $option.Levels[$option.Index] } else { 'N/A' }
    $modelLabels[$index] += " [$effort]"
}

if ($args.Count -eq 0) {
    if ([Console]::IsInputRedirected) {
        Write-Error 'Model selection requires a terminal. Pass a model name directly instead.'
        exit 1
    }

    $priceRows = @($modelRows | ForEach-Object {
        if ($_.input_per_1m -and $_.cached_input_per_1m -and $_.cache_write_per_1m -and $_.output_per_1m) {
            $rates = @($_.input_per_1m, $_.output_per_1m, $_.cached_input_per_1m, $_.cache_write_per_1m) |
                ForEach-Object { '$' + ($_ -replace '\.00$', '') }
        }
        else { $rates = @('', '', '', '') }
        [pscustomobject]@{ Input = $rates[0]; Output = $rates[1]; CacheRead = $rates[2]; CacheWrite = $rates[3] }
    })
    $allLabels = @($modelLabels)
    for ($index = 0; $index -lt $models.Count; $index++) {
        foreach ($level in $effortOptions[$index].Levels) { $allLabels += "$($models[$index]) [$level]" }
    }
    $nameWidth = [Math]::Max(14, ($allLabels | Measure-Object -Property Length -Maximum).Maximum)
    $inputWidth = [Math]::Max(2, ($priceRows | ForEach-Object { $_.Input.Length } | Measure-Object -Maximum).Maximum)
    $outputWidth = [Math]::Max(3, ($priceRows | ForEach-Object { $_.Output.Length } | Measure-Object -Maximum).Maximum)
    $cacheReadWidth = [Math]::Max(10, ($priceRows | ForEach-Object { $_.CacheRead.Length } | Measure-Object -Maximum).Maximum)
    $cacheWriteWidth = [Math]::Max(11, ($priceRows | ForEach-Object { $_.CacheWrite.Length } | Measure-Object -Maximum).Maximum)
    $hasPrices = ($priceRows | Where-Object { $_.Input } | Measure-Object).Count -gt 0
    $showPrices = $hasPrices -and (3 + $nameWidth + $inputWidth + $outputWidth + $cacheReadWidth + $cacheWriteWidth + 12) -lt $Host.UI.RawUI.WindowSize.Width
    Write-Host
    Write-Host 'Choose a model (Up/Down; Left/Right effort; Enter; Esc to cancel):'
    Write-Host
    if ($showPrices) {
        Write-Host 'Costs are in USD and per 1M tokens'
        Write-Host ('   {0}   {1}   {2}   {3}   {4}' -f 'model [effort]'.PadRight($nameWidth), 'in'.PadRight($inputWidth), 'out'.PadRight($outputWidth), 'cache read'.PadRight($cacheReadWidth), 'cache write')
        Write-Host ('   ' + ('-' * ($nameWidth + $inputWidth + $outputWidth + $cacheReadWidth + $cacheWriteWidth + 12)))
    }
    $current = 0
    for ($index = 0; $index -lt $models.Count; $index++) {
        $marker = if ($index -eq $current) { '>' } else { ' ' }
        $label = if ($showPrices) {
            $rate = $priceRows[$index]
            '{0}   {1}   {2}   {3}   {4}' -f $modelLabels[$index].PadRight($nameWidth), $rate.Input.PadRight($inputWidth), $rate.Output.PadRight($outputWidth), $rate.CacheRead.PadRight($cacheReadWidth), $rate.CacheWrite
        } else { $modelLabels[$index] }
        Write-Host (' {0} {1}' -f $marker, $label)
    }

    while ($true) {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        if ($key.VirtualKeyCode -eq 13) { break }
        if ($key.VirtualKeyCode -eq 27) {
            Write-Error 'No model selected.'
            exit 1
        }
        if ($key.VirtualKeyCode -eq 38 -and $current -gt 0) {
            $current--
        }
        elseif ($key.VirtualKeyCode -eq 40 -and $current -lt $models.Count - 1) {
            $current++
        }
        elseif ($key.VirtualKeyCode -in @(37, 39)) {
            $option = $effortOptions[$current]
            if ($option.Levels.Count -le 1) { continue }
            $direction = if ($key.VirtualKeyCode -eq 39) { 1 } else { -1 }
            $option.Index = ($option.Index + $direction + $option.Levels.Count) % $option.Levels.Count
            $modelLabels[$current] = '{0} [{1}]' -f $models[$current], $option.Levels[$option.Index]
        }
        else { continue }

        Write-Host -NoNewline ('{0}[{1}A' -f [char]27, $models.Count)
        for ($index = 0; $index -lt $models.Count; $index++) {
            $marker = if ($index -eq $current) { '>' } else { ' ' }
            $label = if ($showPrices) {
                $rate = $priceRows[$index]
                '{0}   {1}   {2}   {3}   {4}' -f $modelLabels[$index].PadRight($nameWidth), $rate.Input.PadRight($inputWidth), $rate.Output.PadRight($outputWidth), $rate.CacheRead.PadRight($cacheReadWidth), $rate.CacheWrite
            } else { $modelLabels[$index] }
            Write-Host (' {0} {1}{2}[K' -f $marker, $label, [char]27)
        }
    }
    $deploymentName = $models[$current]
    $copilotArgs = @()
    $option = $effortOptions[$current]
    if ($option.Levels.Count) { $copilotArgs = @('--reasoning-effort', $option.Levels[$option.Index]) }
    $selectedIndex = $current
    Write-Host 'Launching Copilot CLI...'
}
else {
    $deploymentName = $args[0]
    $copilotArgs = @($args | Select-Object -Skip 1)
    if ($deploymentName -cnotin $models) {
        Write-Error "Model '$deploymentName' is not in '$pricingPath'."
        exit 1
    }
    $selectedIndex = [Array]::IndexOf($models, $deploymentName)
}

if ([string]::IsNullOrWhiteSpace($env:COPILOT_PROVIDER_API_KEY)) {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Error "Azure CLI ('az') not found. Install it, or set COPILOT_PROVIDER_API_KEY."
        exit 1
    }

    $apiKey = & az cognitiveservices account keys list `
        --name $AZURE_FOUNDRY_RESOURCE_NAME `
        --resource-group $AZURE_RESOURCE_GROUP_NAME `
        --query key1 -o tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Error "Could not fetch a key for '$AZURE_FOUNDRY_RESOURCE_NAME' in '$AZURE_RESOURCE_GROUP_NAME'. Run 'az login', or set COPILOT_PROVIDER_API_KEY."
        exit 1
    }

    $env:COPILOT_PROVIDER_API_KEY = $apiKey.Trim()
}

$env:COPILOT_PROVIDER_TYPE = "azure"
    $env:COPILOT_PROVIDER_BASE_URL = "https://$AZURE_FOUNDRY_RESOURCE_NAME.openai.azure.com/openai/deployments/$deploymentName"
$env:COPILOT_PROVIDER_WIRE_API = "responses"
$env:COPILOT_MODEL = $deploymentName
$baseModel = $modelRows[$selectedIndex].base_model
$env:COPILOT_PROVIDER_MODEL_ID = if ($baseModel) { $baseModel.Trim() } else { $deploymentName }
$env:COPILOT_PROVIDER_WIRE_MODEL = $deploymentName

& copilot @copilotArgs
exit $LASTEXITCODE