Set-StrictMode -Version Latest

function New-CpaStackBundledHost {
    param([Parameter(Mandatory = $true)][string]$ScriptsRoot)

    $root = [System.IO.Path]::GetFullPath($ScriptsRoot).TrimEnd('\')
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $invoke = {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [string[]]$Arguments = @()
        )

        if ([System.IO.Path]::GetFileName($Name) -cne $Name -or [System.IO.Path]::GetExtension($Name) -cne '.ps1') {
            throw "Bundled script name is invalid: $Name"
        }
        $script = Join-Path $root $Name
        if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
            throw "Bundled script is missing: $script"
        }
        $previousModulePath = $env:PSModulePath
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $commonModulePath = & {
                $paths = @($env:PSModulePath -split [System.IO.Path]::PathSeparator | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    -not $_.StartsWith((Join-Path $HOME 'Documents\PowerShell'), [System.StringComparison]::OrdinalIgnoreCase) -and
                    -not $_.StartsWith((Join-Path $HOME 'Documents\WindowsPowerShell'), [System.StringComparison]::OrdinalIgnoreCase)
                })
                return ($paths -join [System.IO.Path]::PathSeparator)
            }
            $env:PSModulePath = $commonModulePath
            # A bundled script's nonzero result is data for the transaction module to classify.
            # Windows PowerShell surfaces redirected native stderr as an ErrorRecord, so keep it
            # non-terminating here and parse the script's JSON result below.
            $ErrorActionPreference = 'Continue'
            $output = @(& $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $env:PSModulePath = $previousModulePath
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $lines = @($output | ForEach-Object { [string]$_ })
        $combined = $lines -join [Environment]::NewLine
        $documents = New-Object System.Collections.Generic.List[object]
        try {
            $document = $combined | ConvertFrom-Json
            if ($null -ne $document -and $document -isnot [array] -and $document -isnot [string] -and $document -isnot [ValueType]) {
                $documents.Add($document)
            }
        } catch {}
        if ($documents.Count -eq 0) {
            foreach ($line in $lines) {
                $candidate = $line.Trim()
                if (-not ($candidate.StartsWith('{') -and $candidate.EndsWith('}'))) { continue }
                try {
                    $document = $candidate | ConvertFrom-Json
                    if ($null -ne $document -and $document -isnot [array] -and $document -isnot [string] -and $document -isnot [ValueType]) {
                        $documents.Add($document)
                    }
                } catch {}
            }
        }
        $json = if ($documents.Count -eq 1) { $documents[0] } else { $null }
        $protocolError = if ($documents.Count -eq 0) {
            [pscustomobject]@{ code = 'NoJsonDocument'; message = 'Bundled script returned no valid JSON object document.' }
        } elseif ($documents.Count -gt 1) {
            [pscustomobject]@{ code = 'MultipleJsonDocuments'; message = 'Bundled script returned more than one JSON object document.' }
        } else {
            $null
        }
        return [pscustomobject]@{
            ExitCode = [int]$exitCode
            Json = $json
            ProtocolError = $protocolError
            Output = $lines
            Text = $combined
        }
    }.GetNewClosure()

    return [pscustomobject]@{ Invoke = $invoke }
}

function Invoke-CpaStackBundled {
    param(
        [Parameter(Mandatory = $true)]$HostAdapter,
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Arguments = @()
    )

    if ($null -eq $HostAdapter.PSObject.Properties['Invoke'] -or $HostAdapter.Invoke -isnot [scriptblock]) {
        throw 'Host adapter does not expose an Invoke scriptblock.'
    }
    return & $HostAdapter.Invoke $Name $Arguments
}

Export-ModuleMember -Function New-CpaStackBundledHost, Invoke-CpaStackBundled
