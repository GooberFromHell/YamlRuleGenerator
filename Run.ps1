# Import the PowerShell-Yaml module
if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
    Register-PSRepository -Name LocalPackages -SourceLocation $(Join-Path $(Get-Location) "packages") -InstallationPolicy Trusted
    Publish-Module -Path "$(Get-Location)\packages\powershell-yaml" -Repository LocalPackages
    Install-Module -Name powershell-yaml -Force -Scope CurrentUser -Repository LocalPackages
    Unregister-PSRepository -Name LocalPackages
}

Import-Module powershell-yaml

# Import required module for YAML parsing
Import-Module powershell-yaml

# Function to read YAML configuration
function Read-YamlConfig {
    param (
        [string]$configPath
    )
    $configContent = Get-Content -Path $configPath -Raw
    $config = ConvertFrom-Yaml $configContent
    return $config
}

# Function to generate a unique SID
function Get-UniqueSid {
    $script:currentSid++
    return $script:currentSid
}

# Function to return all matches in an array
function All-RegexMatches {
    [CmdletBinding()]
    param (
        [string[]]$Content,
        [string[]]$Regex
    )

    $found_matches = @()
    foreach ($line in $Content) {
        foreach ($regex in $Regex) {
            if ($line -match $regex) {
                $found_matches += $Matches -as [hashtable] | ForEach-Object {
                    $hash = @{}
                    $_.GetEnumerator() | Where-Object { $_.Name -as [int] -lt 0 -and $_.Value } | ForEach-Object {
                        $hash[$_.Name] = $_.Value
                    }
                    return $hash
                }
            }
        }
    }
    return $found_matches
}

# Function to generate rules from an array of matches
function Generate-Rules {
    [CmdletBinding()]
    param (
        [Object[]]$RegexMatches,
        [Object]$PatternConfig
    )

    $rules = @()
    $Required = (@(), $PatternConfig.Required)[$PatternConfig.Required.Keys.Count -eq 0]
    $Template = $PatternConfig.Template
    $Defaults = $PatternConfig.Defaults
    foreach ($match in $RegexMatches) {

        # Check if all required fields are present
        if ($Required) {
            $Missing = ($Required | ForEach-Object { $Match.Keys -contains $_ } | Where-Object { $_ -eq $false }) 
            if ($Missing -eq $false) { Continue }
        }

        # Copy Tempalte
        $NewRule = $Template
        
        # First replace parameters with rule defaults
        foreach ($key in $Defaults.Keys) {
            $NewRule = $NewRule -replace "\{$key\}", $Defaults.$key
        }

        # Next replace parameters with rule matched paramters
        foreach ($key in $match.Keys) {
            $NewRule = $NewRule -replace "\{$key\}", $match.$key
        }

        $rules += $NewRule
    }
    return $rules
}

# Function to handle generating rules
function To-Rules {
    param (
        [object[]]$RegexMatches,
        [hashtable]$PatternConfig,
        [string]$RuleDirectory,
        [string]$FileSerial
    )
    $outputFile = ""
    $NewRules = Generate-Rules -RegexMatches $RegexMatches -PatternConfig $PatternConfig

    if ( -not $NewRules) { Continue }

    $NewRules = $NewRules | Sort-Object -Unique

    # Add sid and rev to rules
    $NewRules | ForEach-Object {
        $sid = Get-UniqueSid
        $_ = $_ -replace "\{sid\}", $sid
        $_ = $_ -replace "\{rev\}", $PatternConfig.rev
    }

    if ($config.global.split_rules) {
        $outputFile = Join-Path $RuleDirectory "$($PatternConfig.Name)-$($FileSerial).rules"
        $NewRules | Out-File -FilePath $outputFile -Append
    }
    else {
        $outputFile = Join-Path $RuleDirectory "combined_rules-$($FileSerial).rules"
        $NewRules | Out-File -FilePath $outputFile -Append 
    }

    return $outputFile
}

function To-Lists {
    [CmdletBinding()]
    param (
        [Object]$RegexMatches,
        [string]$RuleDirectory,
        [string[]]$Lists,
        [string]$FileSerial
    )

    $AllValues = $RegexMatches | ForEach-Object {
        ($_.GetEnumerator() | Where-Object { $_.Name -as [int] -lt 0 -and $_.Value }).Value
    }

    $AllValues = $AllValues | Sort-Object -Unique
    foreach ($List in $Lists) {
        $outputFile = Join-Path $RuleDirectory "$($List)-$($FileSerial).txt"   
        $AllValues | Out-File -FilePath $outputFile -Append
        $outputFiles += $outputFile
    }

    return $outputFiles
}

# Function to process IoCs and generate rules
function Process-IoCs {
    param (
        [string]$iocDirectory,
        [string]$ruleDirectory,
        [hashtable]$config
    )

    $iocFiles = Get-ChildItem -Path $iocDirectory -File
    
    $FileSerial = $((Get-Date).ToString("ddMMMyy").ToUpper())
    $files = @()
    foreach ($iocFile in $iocFiles) {

        $iocs = Get-Content $iocFile.FullName
        foreach ($PatternConfig in $config.templates) {
            $Regex = $PatternConfig.regex -join "|"

            # Add function to return all matches in an array
            $RegexMatches = All-RegexMatches -Content $iocs -Regex $Regex

            # If there are no matches, continue to the next pattern
            if (-not $RegexMatches) { continue }

            # Add to detection lists if the pattern config has lists to add too
            if ($PatternConfig.lists) {
                $files += To-Lists -RegexMatches $RegexMatches -Lists $PatternConfig.lists -RuleDirectory $ruleDirectory -FileSerial $FileSerial
            }

            # Generate Rules if the pattern config has rule templates
            if ($PatternConfig.template) {
                $files += to-Rules -RegexMatches $RegexMatches -PatternConfig $PatternConfig -RuleDirectory $ruleDirectory -FileSerial $FileSerial
            }
        }
    }

    # Becasue im lazy and its late and didnt feel like making this integrate somewhere else... sue me...
    $files | Sort-Object -Unique | ForEach-Object { 
        $Content = Get-Content -Path $_ | Sort-Object -Unique
        $Content | Out-File -FilePath $_ -Force
        Write-Host "Generated file: $_"
    }
}


# Main script execution
$configPath = "config.yaml"
$config = Read-YamlConfig -configPath $configPath

$script:currentSid = $config.global.sid_start - 1

$iocDirectory = $config.global.ioc_directory
$ruleDirectory = $config.global.rules_directory


if (-not (Test-Path $iocDirectory)) {
    Write-Host "The IoC directory does not exist. Please check the configuration file."
    exit
}

if (-not (Test-Path $ruleDirectory)) {
    New-Item -ItemType Directory -Path $ruleDirectory | Out-Null
}

Process-IoCs -iocDirectory $iocDirectory -ruleDirectory $ruleDirectory -config $config

Write-Host "Suricata rules have been generated and saved in the $ruleDirectory directory."
