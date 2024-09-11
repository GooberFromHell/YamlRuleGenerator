# Define the PatternConfig class
class PatternConfig {
    [Parameter(Mandatory = $true)]
    [string]$Name
    [Parameter(Mandatory = $true)]
    [string[]]$Regex
    [string]$Template
    [string[]]$Required
    [string[]]$Lists
    [hashtable]$Defaults
    [hashtable]$Metadata
    [string]$SourceFile = $null
    static [string]$Errors = $null
    static [string[]]$Signatures = @()
    
    # Constructor to handle required and optional properties
    PatternConfig(
        [string]$name,
        [string[]]$regex,
        [string]$template = $null,
        [string[]]$required = @(),
        [string[]]$lists = @(),
        [hashtable]$metadata = @{},
        [hashtable]$defaults = @{
            sip   = 'any'
            sport = 'any'
            dip   = 'any'
            dport = 'any'
            msg   = '""'
        },
        [string]$sourceFile = $null
    ) {
        $this.Name = $name
        $this.Required = $required
        $this.Metadata = $metadata
        $this.Regex = $regex
        $this.Template = $template
        $this.Defaults = $defaults
        $this.Lists = $lists
        $this.Metadata = $metadata
        $this.SourceFile = $sourceFile
    }

    PatternConfig(
        [hashtable]$PatternConfig
    ) {
        foreach ($key in $this.PSObject.Properties.Name) {
            $this.$key = ($this.$key, $PatternConfig.$Key)[$PatternConfig.ContainsKey($Key)]   
        }
    }

    # Validate that if a template is provided, it contains all the required fields
    [bool] ValidateTemplate() {
        if ($this.Required.Count -le 0) {
            return $true
        }
        $match = [regex]::Matches($this.Template, '\{(\w+)\}')
        $fields = $match | ForEach-Object { $_.Groups[1].Value }
        $missing = $this.Required | Where-Object { $fields -notcontains $_ }
        if ($missing) {
            $this.Errors = [string]::Format("Pattern configuration for '{0}' has a template missing required fields: {1}\nPattern required: {2}\nTemplate is missing: {1}" -f $this.Name, $this.Required -join '\n - ', $missing -join '\n - ')
            return $false
        }
        return $true
    }

    [System.Array] GetMatches([string]$line) {
        $found_matches = @()
        foreach ($regex in $this.Regex) {
            $found_match = [regex]::Matches($line, $regex)
            if ($found_match.Groups) {
                $hash = @{}
                $capture_matches = $found_match | Select-Object -ExpandProperty Groups | Where-Object { $_.Name -as [int] -lt 0 -and $_.Value }
                foreach ($match in $capture_matches) { 
                    $hash[$match.Name] = $match.Value 
                }
                $found_matches += $hash
            }
            
        }
        if ($found_matches.Count -le 0) { return $null }
        if ($this.Template) { $this.GenerateSignatures($found_matches) }
        return $found_matches
    }

    [string] GenerateMetaData() {
        if ($this.Metadata.Keys -le 0) { return "" }
        $md = @()
        foreach ($key in $this.Metadata.Keys) {
            $md += "{0} {1}" -f $key, $this.Metadata[$key]
        }
        return "metadata: {0};" -f "$($md -join ', ')"
    }

    [string] GenerateOptions() {
        if ($this.Options.Keys -le 0) { return "" }
        $ops = @()
        foreach ($key in $this.Options.Keys) {
            switch ($key) {
                "reference" {
                    if ($this.SourceFile) {
                        $ops += "{0}:file,'{1}';" -f $key, $this.SourceFile
                    }
                }
                default {
                    $ops += "{0}:{1};" -f $key, $this.Options[$key]
                }
            }
        }
        
        return "options: {0}" -f "$($ops -join ' ')"
    }

    GenerateSignatures([System.Array]$found_matches) {
        foreach ($match in $found_matches) {
            $signature = $this.Template

            # First replace parameters with rule defaults
            foreach ($key in $this.Defaults) {
                $signature = $signature -replace "\{$key\}", $this.Defaults.$key
            }

            # Next replace parameters with rule matched paramters
            foreach ($key in $match.Keys) {
                $signature = $signature -replace "\{$key\}", $match.$key
            }
            
            # Replace Options with the generated options
            $signature = $signature -replace "\{sid\}", "{0} {sid}" -f $this.GenerateOptions()

            # Repalce metadata with the generated metadata
            $signature = $signature -replace "\{sid\}", "{0} {sid}" -f $this.GenerateMetaData()
            
            $this.Signatures += $signature
        }
    }
}

