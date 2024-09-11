using module ./lib/PatternConfig.psm1
# Get current scripts location 
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Generate test reading from config.yaml
$configContent = Get-Content -Path "$scriptPath\test_config.yaml" -Raw
$config = ConvertFrom-Yaml $configContent

foreach ($PatternConfig in $config.templates) {

    $Metadata = $config.global.metadata
    $PatternConfig.Metadata = ($Metadata, $Metadata + $PatternConfig.Metadata)[$PatternConfig.ContainsKey("Metadata")]
    $pattern = [PatternConfig]::new($PatternConfig)
    if (-not $pattern.ValidateTemplate()) {
        Write-Output $pattern.Errors 
    }
    else {
        Write-Output "Pattern '$($pattern.Name)' is valid"
    }
    $content = Get-Content -Path "$scriptPath\test_input.txt" 
    foreach ($line in $content) {
        $match = $pattern.GetMatches($line)
        if ($match) {
            Write-Output "Match found for pattern '$($pattern.Name)' in line: $line"
        }
    }
    $match = $pattern.GetMatches($content)
}