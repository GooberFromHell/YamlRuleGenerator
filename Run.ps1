#Requires -Version 5.1
<#
.SYNOPSIS
    Generates Suricata rules and detection lists from IoC files using a YAML configuration.
.DESCRIPTION
    Reads config.yaml, scans every file in the configured IoC directory with the regex
    patterns of each template, and renders the matched named capture groups into the
    template's Suricata rule string. Matched values can also be written to plain lists.
.PARAMETER ConfigPath
    Path to the YAML configuration. Defaults to config.yaml next to this script.
#>
[CmdletBinding()]
param (
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Module bootstrap
# ---------------------------------------------------------------------------

function Import-YamlModule {
    param ([string]$PackageRoot)

    if (Get-Module -Name powershell-yaml) { return }

    if (Get-Module -Name powershell-yaml -ListAvailable) {
        Import-Module powershell-yaml
        return
    }

    # Fall back to the copy vendored under packages\ so the script works offline
    # and without installing anything into the user's module path.
    $manifest = Get-ChildItem -Path (Join-Path $PackageRoot 'powershell-yaml') -Filter 'powershell-yaml.psd1' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1

    if (-not $manifest) {
        throw "powershell-yaml is not installed and no vendored copy was found under '$PackageRoot'."
    }

    # DLLs that arrived with the repo carry a mark-of-the-web zone identifier,
    # which makes Assembly::LoadFrom fail with HRESULT 0x80131515.
    Get-ChildItem -Path $manifest.Directory.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    Import-Module $manifest.FullName
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

function Read-YamlConfig {
    param ([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }
    return ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw)
}

function Resolve-ConfiguredPath {
    param (
        [string]$Path,
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $BaseDirectory $Path
}

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

# Returns one hashtable per matching line, keyed by the regex named capture groups.
function Get-NamedMatch {
    [CmdletBinding()]
    param (
        [string[]]$Content,
        [string]$Pattern
    )

    $regex = [regex]::new($Pattern)
    $groupNames = $regex.GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' }
    $results = @()

    foreach ($line in $Content) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Trimmed so anchored patterns survive trailing whitespace in IoC files.
        $match = $regex.Match($line.Trim())
        if (-not $match.Success) { continue }

        $captured = @{}
        foreach ($name in $groupNames) {
            $group = $match.Groups[$name]
            if ($group.Success -and -not [string]::IsNullOrEmpty($group.Value)) {
                $captured[$name] = $group.Value
            }
        }

        if ($captured.Count -gt 0) { $results += ,$captured }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Rule rendering
# ---------------------------------------------------------------------------

function Expand-Token {
    param (
        [string]$Text,
        [string]$Name,
        [string]$Value
    )
    # Plain ordinal replace: IoC values may contain regex/substitution metacharacters.
    return $Text.Replace("{$Name}", $Value)
}

function New-Rule {
    [CmdletBinding()]
    param (
        [object[]]$NamedMatches,
        [hashtable]$Template
    )

    $ruleTemplate = [string]$Template.template
    $defaults = $Template.defaults
    $required = @($Template.required | Where-Object { $_ })

    $rules = @()
    foreach ($match in $NamedMatches) {

        # Required groups must come from the regex, never from defaults.
        $missing = $required | Where-Object { -not $match.ContainsKey($_) }
        if ($missing) { continue }

        $rule = $ruleTemplate

        # Defaults first; their values may themselves reference capture groups.
        if ($defaults) {
            foreach ($key in $defaults.Keys) {
                $rule = Expand-Token -Text $rule -Name $key -Value ([string]$defaults[$key])
            }
        }

        # Captured values win over defaults.
        foreach ($key in $match.Keys) {
            $rule = Expand-Token -Text $rule -Name $key -Value ([string]$match[$key])
        }

        $rules += $rule
    }

    return $rules
}

# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

function Get-MetadataOption {
    [CmdletBinding()]
    param (
        [hashtable]$Config,
        [hashtable]$Template
    )

    $options = @{}
    if ($Config.global -and $Config.global.metadata) {
        foreach ($key in $Config.global.metadata.Keys) { $options[$key] = $Config.global.metadata[$key] }
    }
    # Template metadata overrides the global block.
    if ($Template.metadata) {
        foreach ($key in $Template.metadata.Keys) { $options[$key] = $Template.metadata[$key] }
    }
    return $options
}

function Get-MetadataPair {
    [CmdletBinding()]
    param (
        [hashtable]$Options,
        [string]$SourceFile
    )

    $pairs = [ordered]@{}
    foreach ($key in $Options.Keys) {
        switch ($key) {
            # rule_reference is the canonical name; the other two are accepted
            # for compatibility with older configs.
            { $_ -in 'rule_reference', 'add_rule_reference', 'add_reference' } {
                if ($Options[$key]) {
                    $pairs['source'] = ConvertTo-MetadataValue -Value ([System.IO.Path]::GetFileName($SourceFile))
                }
            }
            default {
                if ($Options[$key] -isnot [bool]) {
                    $pairs[(ConvertTo-MetadataValue -Value $key)] = ConvertTo-MetadataValue -Value ([string]$Options[$key])
                }
            }
        }
    }
    return $pairs
}

function ConvertTo-MetadataValue {
    param ([string]$Value)
    # Suricata metadata values cannot contain commas, semicolons or whitespace.
    return ($Value -replace '[^\w.\-]', '_')
}

function Add-Metadata {
    [CmdletBinding()]
    param (
        [string]$Rule,
        [System.Collections.Specialized.OrderedDictionary]$Pairs
    )

    $metadata = ''
    if ($Pairs.Count -gt 0) {
        $rendered = ($Pairs.Keys | ForEach-Object { "$_ $($Pairs[$_])" }) -join ', '
        $metadata = "metadata:$rendered;"
    }

    if ($Rule.Contains('{metadata}')) {
        return ($Rule.Replace('{metadata}', $metadata) -replace '\s+\)', ')')
    }

    if (-not $metadata) { return $Rule }

    # Insert before the closing parenthesis of the rule options block.
    $close = $Rule.LastIndexOf(')')
    if ($close -lt 0) { return "$Rule $metadata" }

    $head = $Rule.Substring(0, $close).TrimEnd()
    $tail = $Rule.Substring($close)
    return "$head $metadata$tail"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-OutputFile {
    param (
        [string]$Path,
        [string[]]$Lines
    )
    # BOM-less UTF-8: Out-File/Set-Content in PS 5.1 emit a BOM, which Suricata
    # treats as part of the first rule.
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Main processing
# ---------------------------------------------------------------------------

function Invoke-IocProcessing {
    [CmdletBinding()]
    param (
        [string]$IocDirectory,
        [string]$RuleDirectory,
        [hashtable]$Config
    )

    $iocFiles = @(Get-ChildItem -Path $IocDirectory -File)
    if (-not $iocFiles) {
        Write-Warning "No IoC files found in '$IocDirectory'."
        return
    }

    $fileSerial = (Get-Date).ToString('ddMMMyy').ToUpper()
    $combinedName = "combined_rules-$fileSerial.rules"
    $splitRules = [bool]$Config.global.split_rules

    # Rules are collected with the {sid} token intact so they can be deduplicated
    # before serial numbers are handed out. Key = output file, value = rule list.
    $ruleBuckets = [ordered]@{}
    $listBuckets = [ordered]@{}

    foreach ($template in $Config.templates) {
        $name = [string]$template.name
        $pattern = (@($template.regex) -join '|')
        if (-not $pattern) {
            Write-Warning "Template '$name' has no regex patterns; skipping."
            continue
        }

        $metadataOptions = Get-MetadataOption -Config $Config -Template $template
        $outputFile = if ($splitRules) { "$name-$fileSerial.rules" } else { $combinedName }
        $templateRules = @()

        foreach ($iocFile in $iocFiles) {
            $content = Get-Content -LiteralPath $iocFile.FullName
            $matched = Get-NamedMatch -Content $content -Pattern $pattern
            if (-not $matched) { continue }

            if ($template.lists) {
                $values = $matched | ForEach-Object { $_.Values }
                foreach ($list in @($template.lists)) {
                    $listFile = "$list-$fileSerial.txt"
                    if (-not $listBuckets.Contains($listFile)) { $listBuckets[$listFile] = @() }
                    $listBuckets[$listFile] += $values
                }
            }

            if (-not $template.template) { continue }

            $rules = New-Rule -NamedMatches $matched -Template $template
            if (-not $rules) { continue }

            $pairs = Get-MetadataPair -Options $metadataOptions -SourceFile $iocFile.Name
            $templateRules += $rules | ForEach-Object { Add-Metadata -Rule $_ -Pairs $pairs }
        }

        if (-not $templateRules) { continue }

        # Deduplicate before SIDs are handed out, otherwise the same IoC seen in two
        # files produces two rules that differ only by serial number.
        $templateRules = @($templateRules | Sort-Object -Unique)

        if ($template.sid_start) { $script:currentSid = [int]$template.sid_start - 1 }
        $revision = if ($null -ne $template.revision) { $template.revision } else { $Config.global.revision }

        $templateRules = @($templateRules | ForEach-Object {
            $script:currentSid++
            $_.Replace('{sid}', [string]$script:currentSid).Replace('{rev}', [string]$revision)
        })

        if (-not $ruleBuckets.Contains($outputFile)) { $ruleBuckets[$outputFile] = @() }
        $ruleBuckets[$outputFile] += $templateRules
    }

    $written = @()

    foreach ($file in $ruleBuckets.Keys) {
        # Already deduplicated per template; keep template order in the file.
        $lines = @($ruleBuckets[$file])
        if (-not $lines) { continue }
        $path = Join-Path $RuleDirectory $file
        Write-OutputFile -Path $path -Lines $lines
        $written += [pscustomobject]@{ Path = $path; Count = $lines.Count }
    }

    foreach ($file in $listBuckets.Keys) {
        $lines = @($listBuckets[$file] | Where-Object { $_ } | Sort-Object -Unique)
        if (-not $lines) { continue }
        $path = Join-Path $RuleDirectory $file
        Write-OutputFile -Path $path -Lines $lines
        $written += [pscustomobject]@{ Path = $path; Count = $lines.Count }
    }

    foreach ($item in $written) {
        Write-Host "Generated file: $($item.Path) ($($item.Count) lines)"
    }

    # Surface templates whose placeholders were never satisfied.
    $unresolved = $ruleBuckets.Keys | ForEach-Object { $ruleBuckets[$_] } | Where-Object { $_ -match '\{\w+\}' } | Select-Object -First 1
    if ($unresolved) {
        Write-Warning "At least one rule still contains unresolved placeholders, e.g.: $unresolved"
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot 'config.yaml' }

Import-YamlModule -PackageRoot (Join-Path $scriptRoot 'packages')

$config = Read-YamlConfig -Path $ConfigPath

if (-not $config.global) { throw "Configuration is missing the 'global' section." }
if (-not $config.templates) { throw "Configuration is missing the 'templates' section." }

$script:currentSid = [int]$config.global.sid_start - 1

$iocDirectory = Resolve-ConfiguredPath -Path ([string]$config.global.ioc_directory) -BaseDirectory $scriptRoot
$ruleDirectory = Resolve-ConfiguredPath -Path ([string]$config.global.rules_directory) -BaseDirectory $scriptRoot

if (-not (Test-Path -LiteralPath $iocDirectory)) {
    throw "The IoC directory '$iocDirectory' does not exist. Please check the configuration file."
}

if (-not (Test-Path -LiteralPath $ruleDirectory)) {
    New-Item -ItemType Directory -Path $ruleDirectory | Out-Null
}

Invoke-IocProcessing -IocDirectory $iocDirectory -RuleDirectory $ruleDirectory -Config $config

Write-Host "Suricata rules have been generated and saved in the $ruleDirectory directory."
