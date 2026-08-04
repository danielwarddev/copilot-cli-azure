$ErrorActionPreference = "Stop"

$AZURE_FOUNDRY_RESOURCE_NAME = "your-azure-foundry-resource-name"
# Resource group name is only needed if you don't want to
# set COPILOT_PROVIDER_API_KEY. If that env var isn't set,# the script will use the Azure CLI to fetch the API key.
$AZURE_RESOURCE_GROUP_NAME = "your-azure-resource-group"

function Show-Usage {
    @"
Usage: copilot-azure <model-deployment-name> [copilot-args...]

Examples:
  copilot-azure gpt-5.6-terra
  copilot-azure gpt-5.6-terra --help
  copilot-azure my-other-model-deployment --some-copilot-flag
"@ | Write-Output
}

if ($args.Count -lt 1 -or $args[0] -in @("-h", "--help")) {
    Show-Usage
    exit 0
}

$deploymentName = $args[0]
$copilotArgs = @($args | Select-Object -Skip 1)

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
$env:COPILOT_MODEL = $deploymentName

& copilot @copilotArgs
exit $LASTEXITCODE