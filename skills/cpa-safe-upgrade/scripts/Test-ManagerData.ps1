[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DatabasePath,

    [string]$BaselineJsonPath,

    [string]$PythonExe,

    [ValidateSet('wal', 'delete', 'truncate', 'persist', 'memory', 'off')]
    [string]$ExpectedJournalMode = 'wal'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Resolve-PythonCommand {
    param([string]$RequestedCommand)

    if (-not [string]::IsNullOrWhiteSpace($RequestedCommand)) {
        $command = Get-Command -Name $RequestedCommand -ErrorAction Stop
        return [pscustomobject]@{
            Path = if ($command.Path) { $command.Path } else { $command.Source }
            PrefixArguments = @()
        }
    }

    $python = Get-Command -Name 'python' -ErrorAction SilentlyContinue
    if ($python) {
        return [pscustomobject]@{
            Path = if ($python.Path) { $python.Path } else { $python.Source }
            PrefixArguments = @()
        }
    }

    $launcher = Get-Command -Name 'py' -ErrorAction SilentlyContinue
    if ($launcher) {
        return [pscustomobject]@{
            Path = if ($launcher.Path) { $launcher.Path } else { $launcher.Source }
            PrefixArguments = @('-3')
        }
    }

    throw 'Python 3 was not found. Install Python or pass -PythonExe with its executable path.'
}

function Test-CountNotDecreased {
    param($Expected, $Actual)

    if ($null -eq $Expected -or $null -eq $Actual) { return $false }
    try {
        return ([long]$Actual -ge [long]$Expected)
    } catch {
        return $false
    }
}

function Test-WatermarkNotDecreased {
    param($Expected, $Actual)

    if ($null -eq $Expected) { return $true }
    if ($null -eq $Actual) { return $false }
    try {
        return ([long]$Actual -ge [long]$Expected)
    } catch {
        return $false
    }
}

function Read-BaselineUsageEvents {
    param([string]$Path)

    $resolved = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    $text = [System.IO.File]::ReadAllText($resolved)
    $baseline = $text | ConvertFrom-Json
    if ($null -eq $baseline.snapshot -or $null -eq $baseline.snapshot.usage_events) {
        throw 'Baseline JSON does not contain snapshot.usage_events from backup_sqlite.py.'
    }
    return $baseline.snapshot.usage_events
}

$result = $null
$exitCode = 2

try {
    $database = Get-Item -LiteralPath $DatabasePath -ErrorAction Stop
    if ($database.PSIsContainer) {
        throw "DatabasePath must be a file: $DatabasePath"
    }

    $pythonCommand = Resolve-PythonCommand -RequestedCommand $PythonExe
    $pythonCode = @'
import json
import pathlib
import sqlite3
import sys

db_path = pathlib.Path(sys.argv[1]).resolve()
uri = db_path.as_uri() + "?mode=ro"
connection = None
try:
    connection = sqlite3.connect(uri, uri=True, timeout=30.0)
    connection.execute("PRAGMA query_only = ON")
    quick_messages = [str(row[0]) for row in connection.execute("PRAGMA quick_check")]
    tables = [
        str(row[0])
        for row in connection.execute(
            "SELECT name FROM sqlite_schema "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
    ]
    columns = {}
    for table in ("usage_events", "model_prices", "usage_dashboard_hourly_rollups"):
        columns[table] = [
            str(row[1])
            for row in connection.execute("PRAGMA table_info(%s)" % table)
        ]

    usage_exists = "usage_events" in tables
    if usage_exists:
        count, max_id, max_timestamp_ms = connection.execute(
            "SELECT count(*), max(id), max(timestamp_ms) FROM usage_events"
        ).fetchone()
    else:
        count, max_id, max_timestamp_ms = 0, None, None

    critical_names = (
        "settings",
        "model_prices",
        "usage_account_model_rollups",
        "usage_rollup_checkpoints",
        "usage_dashboard_hourly_rollups",
    )
    table_counts = {}
    for name in critical_names:
        if name not in tables:
            table_counts[name] = None
            continue
        quoted = name.replace('"', '""')
        table_counts[name] = int(
            connection.execute('SELECT count(*) FROM "%s"' % quoted).fetchone()[0]
        )

    result = {
        "success": True,
        "database": {
            "path": str(db_path),
            "size_bytes": db_path.stat().st_size,
            "quick_check": {
                "ok": len(quick_messages) == 1 and quick_messages[0].lower() == "ok",
                "message_count": len(quick_messages),
                "messages": quick_messages[:20],
                "truncated": len(quick_messages) > 20,
            },
            "journal_mode": str(
                connection.execute("PRAGMA journal_mode").fetchone()[0]
            ).lower(),
            "usage_events": {
                "exists": usage_exists,
                "count": int(count),
                "max_id": int(max_id) if max_id is not None else None,
                "max_timestamp_ms": (
                    int(max_timestamp_ms) if max_timestamp_ms is not None else None
                ),
            },
            "critical_table_counts": table_counts,
        },
        "schema": {
            "tables": tables,
            "columns": columns,
        },
    }
except Exception as error:
    result = {
        "success": False,
        "error": {
            "type": type(error).__name__,
            "message": str(error),
        },
    }
finally:
    if connection is not None:
        connection.close()

print(json.dumps(result, ensure_ascii=True, sort_keys=True))
sys.exit(0 if result.get("success") else 2)
'@

    $invokeArguments = @()
    $invokeArguments += $pythonCommand.PrefixArguments
    $invokeArguments += '-'
    $invokeArguments += $database.FullName

    $pythonOutputLines = @($pythonCode | & $pythonCommand.Path @invokeArguments 2>&1)
    $pythonExitCode = $LASTEXITCODE
    $pythonOutput = $pythonOutputLines -join [Environment]::NewLine
    if ($pythonExitCode -ne 0) {
        throw "Python SQLite inspection failed: $pythonOutput"
    }
    $inspection = $pythonOutput | ConvertFrom-Json

    $requiredTables = @(
        'usage_account_model_rollups',
        'usage_rollup_checkpoints',
        'usage_dashboard_hourly_rollups'
    )
    $requiredColumns = [ordered]@{
        usage_events = @(
            'request_service_tier',
            'response_service_tier',
            'cache_input_mode',
            'normalized_uncached_input_tokens',
            'normalized_total_input_tokens',
            'normalized_cache_read_tokens',
            'normalized_cache_creation_tokens'
        )
        model_prices = @(
            'prompt_configured',
            'completion_configured',
            'cache_read_configured',
            'cache_creation_configured'
        )
    }

    $presentTables = @($inspection.schema.tables)
    $missingTables = @($requiredTables | Where-Object { $presentTables -notcontains $_ })
    $missingColumns = [ordered]@{}
    foreach ($table in $requiredColumns.Keys) {
        $property = $inspection.schema.columns.PSObject.Properties[$table]
        $presentColumns = if ($null -eq $property) { @() } else { @($property.Value) }
        $missingColumns[$table] = @(
            $requiredColumns[$table] | Where-Object { $presentColumns -notcontains $_ }
        )
    }

    $schemaOk = ($missingTables.Count -eq 0)
    foreach ($table in $missingColumns.Keys) {
        if ($missingColumns[$table].Count -ne 0) {
            $schemaOk = $false
        }
    }

    $history = [ordered]@{
        checked = $false
        ok = $true
        expected = $null
        actual = $inspection.database.usage_events
        fields = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($BaselineJsonPath)) {
        $expected = Read-BaselineUsageEvents -Path $BaselineJsonPath
        $baselineDocument = [System.IO.File]::ReadAllText($BaselineJsonPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
        $fieldChecks = [ordered]@{
            count = Test-CountNotDecreased -Expected $expected.count -Actual $inspection.database.usage_events.count
            max_id = Test-WatermarkNotDecreased -Expected $expected.max_id -Actual $inspection.database.usage_events.max_id
            max_timestamp_ms = Test-WatermarkNotDecreased -Expected $expected.max_timestamp_ms -Actual $inspection.database.usage_events.max_timestamp_ms
        }
        $history.checked = $true
        $history.ok = ($fieldChecks.count -and $fieldChecks.max_id -and $fieldChecks.max_timestamp_ms)
        $history.expected = $expected
        $history.fields = $fieldChecks
        $tableChecks = [ordered]@{}
        $tableDetails = [ordered]@{}
        foreach ($table in @('settings', 'model_prices')) {
            $expectedProperty = $baselineDocument.snapshot.critical_table_counts.PSObject.Properties[$table]
            if ($null -eq $expectedProperty -or $null -eq $expectedProperty.Value) {
                continue
            }
            $actualProperty = $inspection.database.critical_table_counts.PSObject.Properties[$table]
            $actualValue = if ($null -eq $actualProperty) { $null } else { $actualProperty.Value }
            $ok = Test-CountNotDecreased -Expected $expectedProperty.Value -Actual $actualValue
            $tableChecks[$table] = $ok
            $tableDetails[$table] = [ordered]@{
                policy = 'not_decreased'
                expected_minimum = $expectedProperty.Value
                actual = $actualValue
                ok = $ok
            }
        }
        foreach ($table in @('usage_account_model_rollups', 'usage_rollup_checkpoints', 'usage_dashboard_hourly_rollups')) {
            $expectedProperty = $baselineDocument.snapshot.critical_table_counts.PSObject.Properties[$table]
            $actualProperty = $inspection.database.critical_table_counts.PSObject.Properties[$table]
            $tableDetails[$table] = [ordered]@{
                policy = 'rebuildable_rollup_not_authoritative'
                expected = if ($null -eq $expectedProperty) { $null } else { $expectedProperty.Value }
                actual = if ($null -eq $actualProperty) { $null } else { $actualProperty.Value }
                ok = $true
            }
        }
        $history['critical_table_counts'] = $tableChecks
        $history['critical_table_count_details'] = $tableDetails
        foreach ($table in $tableChecks.Keys) {
            if (-not $tableChecks[$table]) { $history.ok = $false }
        }
    }

    $quickCheckOk = [bool]$inspection.database.quick_check.ok
    $success = ($quickCheckOk -and $schemaOk -and [bool]$history.ok)

    $result = [ordered]@{
        format_version = 1
        success = $success
        operation = 'manager_v1_11_data_compatibility_check'
        database = $inspection.database
        checks = [ordered]@{
            quick_check = [ordered]@{
                ok = $quickCheckOk
                details = $inspection.database.quick_check
            }
            journal_mode = [ordered]@{
                ok = $true
                policy = 'observed_only'
                actual = $inspection.database.journal_mode
            }
            schema = [ordered]@{
                ok = $schemaOk
                missing_tables = $missingTables
                missing_columns = $missingColumns
            }
            history = $history
        }
    }
    $exitCode = if ($success) { 0 } else { 1 }
}
catch {
    $result = [ordered]@{
        format_version = 1
        success = $false
        operation = 'manager_v1_11_data_compatibility_check'
        error = [ordered]@{
            type = $_.Exception.GetType().FullName
            message = $_.Exception.Message
        }
    }
    $exitCode = 2
}

$result | ConvertTo-Json -Depth 10
exit $exitCode
