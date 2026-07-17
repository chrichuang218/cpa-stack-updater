Set-StrictMode -Version Latest

function Get-CpaStackValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        foreach ($key in @($Object.Keys)) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Set-CpaStackValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) {
            if ([string]$key -ieq $Name) {
                $Object[$key] = $Value
                return
            }
        }
        $Object[$Name] = $Value
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $property.Value = $Value
        return
    }
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function Get-CpaStackSafeErrorIdentifier {
    param(
        $Value,
        [string]$Default,
        [switch]$AllowNull
    )

    $candidate = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $candidate.Trim()
        if ($candidate -match '^[A-Za-z][A-Za-z0-9_.-]{0,127}$') {
            return $candidate
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Default)) {
        $fallback = $Default.Trim()
        if ($fallback -match '^[A-Za-z][A-Za-z0-9_.-]{0,127}$') {
            return $fallback
        }
    }
    if ($AllowNull) { return $null }
    return 'OperationFailed'
}

function Get-CpaStackSafeErrorMessage {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$Default
    )

    foreach ($candidateValue in @($Value, $Default, 'Operation failed.')) {
        if ($null -eq $candidateValue) { continue }
        $candidate = [string]$candidateValue
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $candidate = $candidate.Trim()
        if ($candidate.Length -gt 512 -or $candidate -match '[\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') { continue }
        if ($candidate -match '(?i)(?:authorization|proxy-authorization)\s*["'']?\s*[:=]|bearer\s+\S+|(?:api[-_ ]?key|token|password|secret|credential|cookie)\s*["'']?\s*[:=]') { continue }
        return $candidate
    }
    return 'Operation failed.'
}

function ConvertTo-CpaStackError {
    param(
        $InputObject = $null,
        $Run = $null,
        [Parameter(Mandatory = $true)][string]$DefaultCode,
        [Parameter(Mandatory = $true)][string]$DefaultMessage,
        [string]$DefaultType,
        [string]$DefaultPhase,
        $ExitCode = $null
    )

    $source = $InputObject
    if ($null -ne $Run) {
        $protocolError = Get-CpaStackValue -Object $Run -Name 'ProtocolError'
        if ($null -ne $protocolError) { $source = $protocolError }
        if (-not $PSBoundParameters.ContainsKey('ExitCode')) {
            $ExitCode = Get-CpaStackValue -Object $Run -Name 'ExitCode'
        }
    }

    $code = $null
    $message = $null
    $type = $null
    $phase = $null
    if ($source -is [System.Management.Automation.ErrorRecord]) {
        $message = $source.Exception.Message
        $type = $source.Exception.GetType().FullName
    } elseif ($source -is [System.Exception]) {
        $message = $source.Message
        $type = $source.GetType().FullName
    } elseif ($source -is [string]) {
        $message = $source
    } elseif ($null -ne $source) {
        $code = Get-CpaStackValue -Object $source -Name 'code'
        $message = Get-CpaStackValue -Object $source -Name 'message'
        $type = Get-CpaStackValue -Object $source -Name 'type'
        $phase = Get-CpaStackValue -Object $source -Name 'phase'

        if ([string]::IsNullOrWhiteSpace([string]$message)) {
            $nested = Get-CpaStackValue -Object $source -Name 'error'
            if ($nested -is [System.Management.Automation.ErrorRecord]) {
                $message = $nested.Exception.Message
                $type = $nested.Exception.GetType().FullName
            } elseif ($nested -is [System.Exception]) {
                $message = $nested.Message
                $type = $nested.GetType().FullName
            } elseif ($nested -is [string]) {
                $message = $nested
            } elseif ($null -ne $nested) {
                $nestedCode = Get-CpaStackValue -Object $nested -Name 'code'
                $nestedMessage = Get-CpaStackValue -Object $nested -Name 'message'
                $nestedType = Get-CpaStackValue -Object $nested -Name 'type'
                $nestedPhase = Get-CpaStackValue -Object $nested -Name 'phase'
                if ($null -ne $nestedCode) { $code = $nestedCode }
                if ($null -ne $nestedMessage) { $message = $nestedMessage }
                if ($null -ne $nestedType) { $type = $nestedType }
                if ($null -ne $nestedPhase) { $phase = $nestedPhase }
            }
        }
    }

    $safeMessage = Get-CpaStackSafeErrorMessage -Value $message -Default $DefaultMessage
    $parsedExitCode = 0
    if ($null -ne $ExitCode -and [int]::TryParse([string]$ExitCode, [ref]$parsedExitCode) -and $parsedExitCode -ne 0) {
        $exitPattern = '(?i)\bExitCode\s*=\s*' + [regex]::Escape([string]$parsedExitCode) + '\b'
        if ($safeMessage -notmatch $exitPattern) {
            $safeMessage += " ExitCode=$parsedExitCode."
        }
    }

    return [ordered]@{
        code = Get-CpaStackSafeErrorIdentifier -Value $code -Default $DefaultCode
        message = $safeMessage
        type = Get-CpaStackSafeErrorIdentifier -Value $type -Default $DefaultType -AllowNull
        phase = Get-CpaStackSafeErrorIdentifier -Value $phase -Default $DefaultPhase -AllowNull
    }
}

function New-CpaStackError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Type,
        [string]$Phase
    )

    return ConvertTo-CpaStackError -InputObject ([pscustomobject]@{
        code = $Code
        message = $Message
        type = $Type
        phase = $Phase
    }) -DefaultCode $Code -DefaultMessage 'Operation failed.' -DefaultType $Type -DefaultPhase $Phase
}

function ConvertTo-CpaStackList {
    param($Value)

    if ($null -eq $Value) { return }
    if ($Value -is [pscustomobject]) {
        $hasProperty = $false
        foreach ($property in $Value.PSObject.Properties) {
            $hasProperty = $true
            break
        }
        if (-not $hasProperty) { return }
    }
    if ($Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace($Value)) { Write-Output $Value }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { if ($null -ne $item) { Write-Output $item } }
        return
    }
    Write-Output $Value
}

function New-CpaStackResult {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Healthy', 'NoChange', 'Changed', 'RolledBack', 'Blocked', 'RecoveryRequired', 'ManualRecoveryRequired')]
        [string]$Outcome,
        [Parameter(Mandatory = $true)][bool]$Changed,
        [Parameter(Mandatory = $true)][string]$Root,
        [bool]$RolledBack = $false,
        [bool]$Recovered = $false,
        $Before = $null,
        $After = $null,
        [object[]]$Warnings = @(),
        $Error = $null,
        [System.Collections.IDictionary]$Extensions
    )

    $normalizedError = $null
    if ($null -ne $Error -or -not $Success) {
        $normalizedError = ConvertTo-CpaStackError -InputObject $Error -DefaultCode 'OperationFailed' `
            -DefaultMessage "The $Operation operation failed." -DefaultPhase $Operation
    }

    $result = [ordered]@{
        schemaVersion = 2
        operation = $Operation
        success = $Success
        outcome = $Outcome
        changed = $Changed
        rolledBack = $RolledBack
        recovered = $Recovered
        root = $Root
        before = $Before
        after = $After
        warnings = @($Warnings | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
        error = $normalizedError
    }
    if ($Extensions) {
        foreach ($entry in $Extensions.GetEnumerator()) {
            if ($result.Contains($entry.Key)) {
                throw "Result extension conflicts with the v2 envelope: $($entry.Key)"
            }
            $result[$entry.Key] = $entry.Value
        }
    }
    return $result
}

Export-ModuleMember -Function Get-CpaStackValue, Set-CpaStackValue, ConvertTo-CpaStackList, ConvertTo-CpaStackError, New-CpaStackError, New-CpaStackResult
