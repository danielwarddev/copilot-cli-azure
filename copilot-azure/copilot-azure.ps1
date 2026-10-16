$ErrorActionPreference = "Stop"

$AZURE_FOUNDRY_RESOURCE_NAME = "your-azure-foundry-resource-name"
# Resource group name is only needed if you don't want to
# set COPILOT_PROVIDER_API_KEY. If that env var isn't set,# the script will use the Azure CLI to fetch the API key.
$AZURE_RESOURCE_GROUP_NAME = "your-azure-resource-group"

function Show-Usage {
    @"
Usage: copilot-azure [model-deployment-name] [copilot-args...]

Examples:
  copilot-azure
  copilot-azure gpt-5.6-terra
  copilot-azure gpt-5.6-terra --help
    copilot-azure gpt-5.6-luna --some-copilot-flag
"@ | Write-Output
}

if ($args[0] -in @("-h", "--help")) {
    Show-Usage
    exit 0
}

$pricingPath = Join-Path $HOME '.copilot\azure-pricing-status-line\foundry-model-pricing.csv'
if (-not (Test-Path $pricingPath)) {
    Write-Error "Pricing file not found at '$pricingPath'."
    exit 1
}

$models = @(Import-Csv $pricingPath | ForEach-Object { $_.model_key.Trim() } | Where-Object { $_ })
if ($models.Count -eq 0) {
    Write-Error "No models found in '$pricingPath'."
    exit 1
}

if ($args.Count -eq 0) {
    if ([Console]::IsInputRedirected) {
        Write-Error 'Model selection requires a terminal. Pass a model name directly instead.'
        exit 1
    }

    Write-Host 'Choose a model (Up/Down, Enter; Esc to cancel):'
    $current = 0
    for ($index = 0; $index -lt $models.Count; $index++) {
        $marker = if ($index -eq $current) { '>' } else { ' ' }
        Write-Host (' {0} {1}' -f $marker, $models[$index])
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
        else { continue }

        Write-Host -NoNewline ('{0}[{1}A' -f [char]27, $models.Count)
        for ($index = 0; $index -lt $models.Count; $index++) {
            $marker = if ($index -eq $current) { '>' } else { ' ' }
            Write-Host (' {0} {1}{2}[K' -f $marker, $models[$index], [char]27)
        }
    }
    $deploymentName = $models[$current]
    $copilotArgs = @()
}
else {
    $deploymentName = $args[0]
    $copilotArgs = @($args | Select-Object -Skip 1)
    if ($deploymentName -cnotin $models) {
        Write-Error "Model '$deploymentName' is not in '$pricingPath'."
        exit 1
    }
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

& copilot @copilotArgs
exit $LASTEXITCODE