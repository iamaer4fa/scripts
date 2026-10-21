<#
.SYNOPSIS
    Calculates monthly Windows server uptime/downtime from System events,
    exports CSV reports, and optionally pushes results to NocoBase.

.NOTES
    Event IDs:
      6005 = Event Log service started
      6006 = Event Log service stopped normally
      6008 = Previous shutdown was unexpected

    Downtime is estimated from matched 6006 -> 6005 events.
    Event 6008 alone does not establish the actual outage duration.
#>

[CmdletBinding()]
param (
    [ValidateRange(1970, 9998)]
    [int]$Year = (Get-Date).Year,

    [string]$OutputPath = "C:\Temp\Server_Uptime_Report_$Year.csv",

    [string]$ServerName = $env:COMPUTERNAME,

    [switch]$SkipNocoBase
)

# ---------- Configuration ----------
$EnvFile = Join-Path $PSScriptRoot '.env'
if (Test-Path -LiteralPath $EnvFile) {
    foreach ($Line in Get-Content -LiteralPath $EnvFile) {
        if ($Line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            $Name = $Matches[1]
            $Value = $Matches[2]
            if ($Value.Length -ge 2 -and
                (($Value.StartsWith('"') -and $Value.EndsWith('"')) -or
                 ($Value.StartsWith("'") -and $Value.EndsWith("'")))) {
                $Value = $Value.Substring(1, $Value.Length - 2)
            }
            $ExistingValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
            if (-not [string]::IsNullOrWhiteSpace($Value) -or
                [string]::IsNullOrWhiteSpace($ExistingValue)) {
                [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
            }
        }
    }
}

$NocoBaseUrl = $env:NOCOBASE_URL
$NocoBaseToken = $env:NOCOBASE_TOKEN



# ---------- Validate configuration ----------
if (-not $SkipNocoBase -and
    ([string]::IsNullOrWhiteSpace($NocoBaseUrl) -or
     [string]::IsNullOrWhiteSpace($NocoBaseToken))) {
    throw "Set NOCOBASE_URL and NOCOBASE_TOKEN in .env, or use -SkipNocoBase."
}

$ServerShort = ($ServerName -split '\.')[0]

if ([string]::IsNullOrWhiteSpace($ServerShort)) {
    throw "ServerName cannot be empty."
}

# ---------- Prepare output paths ----------
$OutputDir = Split-Path -Path $OutputPath -Parent

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = (Get-Location).Path
    $OutputPath = Join-Path $OutputDir $OutputPath
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force |
        Out-Null
}

$DetailsPath = Join-Path $OutputDir (
    [IO.Path]::GetFileNameWithoutExtension($OutputPath) + "_Details.csv"
)

# ---------- NocoBase headers ----------
$Headers = @{
    Authorization = "Bearer $NocoBaseToken"
    "Content-Type" = "application/json"
}

# ---------- NocoBase: lookup device UUID ----------
function Get-DeviceUuid {
    param(
        [Parameter(Mandatory)]
        [string]$Hostname
    )

    $filter = @{
        name = @{
            '$iLike' = $Hostname
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $encoded = [uri]::EscapeDataString($filter)
    $url = "$NocoBaseUrl/api/devices:list?filter=$encoded&pageSize=1"

    try {
        $response = Invoke-RestMethod `
            -Uri $url `
            -Headers $Headers `
            -Method Get `
            -ErrorAction Stop

        $device = @($response.data) |
            Where-Object { $null -ne $_.id } |
            Select-Object -First 1

        if ($device) {
            return [string]$device.id
        }

        Write-Warning "No NocoBase device found for '$Hostname'."
        return $null
    }
    catch {
        Write-Warning "Device lookup failed: $($_.Exception.Message)"
        return $null
    }
}

# ---------- NocoBase: create one KPI record ----------
function Push-ToNocoBase {
    param(
        [Parameter(Mandatory)]
        [string]$Month,

        [Parameter(Mandatory)]
        [string]$ServerReference,

        [Parameter(Mandatory)]
        [bool]$UseUuid,

        [AllowNull()]
        [object]$UptimePercent,

        [AllowNull()]
        [object]$DowntimePercent,

        [AllowNull()]
        [object]$Reboots,

        [Parameter(Mandatory)]
        [string]$DataSource,

        [Parameter(Mandatory)]
        [bool]$KpiMet,

        [Parameter(Mandatory)]
        [string]$Notes
    )

    $body = @{
        month       = $Month
        os_type     = "Windows"
        data_source = $DataSource
        kpi_met     = $KpiMet
        notes       = $Notes
    }

    if ($UseUuid) {
        # Confirm that server_name is a relation field accepting a device ID.
        $body.server_name = $ServerReference
    }
    else {
        $body.hostname = $ServerReference
    }

    if ($null -ne $UptimePercent) {
        $body.uptime_percent = [double]$UptimePercent
    }

    if ($null -ne $DowntimePercent) {
        $body.downtime_percent = [double]$DowntimePercent
    }

    if ($null -ne $Reboots) {
        $body.reboots = [int]$Reboots
    }

    $json = $body | ConvertTo-Json -Depth 5 -Compress

    try {
        $response = Invoke-RestMethod `
            -Uri "$NocoBaseUrl/api/kpi_server_uptime:create" `
            -Method Post `
            -Headers $Headers `
            -Body $json `
            -ErrorAction Stop

        Write-Host "  OK [$Month] NocoBase record created." `
            -ForegroundColor Green

        return $true
    }
    catch {
        $message = $_.ErrorDetails.Message

        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = $_.Exception.Message
        }

        Write-Host "  FAILED [$Month]: $message" `
            -ForegroundColor Red

        return $false
    }
}

# ---------- Resolve device ----------
$UseUuid = $false
$ServerRef = $ServerShort

if (-not $SkipNocoBase) {
    Write-Host "`nResolving device: $ServerShort" -ForegroundColor Cyan

    $DeviceUuid = Get-DeviceUuid -Hostname $ServerShort

    if ($DeviceUuid) {
        $UseUuid = $true
        $ServerRef = $DeviceUuid

        Write-Host "Device ID: $DeviceUuid" -ForegroundColor Green
    }
    else {
        Write-Warning "Using hostname fallback."
    }
}

# ---------- Define reporting period ----------
$Now = Get-Date
$StartTime = [datetime]::new($Year, 1, 1)
$EndTime = [datetime]::new($Year + 1, 1, 1)

# Do not include events that have not occurred yet.
$EffectiveEnd = if ($EndTime -lt $Now) {
    $EndTime
}
else {
    $Now
}

Write-Host "`nReading System events for $Year..." -ForegroundColor Cyan

# Retrieve relevant events. Include historical events before the reporting
# year so a shutdown immediately before January 1 can be matched to startup.
try {
    $AllEvents = @(
        Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id      = 6005, 6006, 6008
            StartTime = $StartTime.AddDays(-2)
            EndTime   = $EffectiveEnd
        } -ErrorAction Stop |
        Sort-Object TimeCreated
    )
}
catch {
    if ($_.FullyQualifiedErrorId -like '*NoMatchingEventsFound*') {
        $AllEvents = @()
    }
    else {
        throw "Unable to read System event log. Run PowerShell with appropriate permissions. $($_.Exception.Message)"
    }
}

$YearEvents = @(
    $AllEvents | Where-Object {
        $_.TimeCreated -ge $StartTime -and
        $_.TimeCreated -lt $EffectiveEnd
    }
)

Write-Host "Relevant events in reporting period: $($YearEvents.Count)"

if ($AllEvents.Count -gt 0) {
    Write-Host "Earliest retrieved event: $($AllEvents[0].TimeCreated)"
    Write-Host "Latest retrieved event: $($AllEvents[-1].TimeCreated)"
}
else {
    Write-Warning "No matching events were found in the reporting period."
}

# ---------- Build downtime records ----------
$DowntimeRecords = [System.Collections.Generic.List[object]]::new()
$PendingShutdown = $null

foreach ($Event in $AllEvents) {
    if ($Event.Id -eq 6006) {
        $PendingShutdown = $Event.TimeCreated
        continue
    }

    if ($Event.Id -eq 6005) {
        if ($null -ne $PendingShutdown -and
            $Event.TimeCreated -gt $PendingShutdown) {

            $Duration = New-TimeSpan `
                -Start $PendingShutdown `
                -End $Event.TimeCreated

            # Keep intervals overlapping the reporting year.
            if ($Event.TimeCreated -gt $StartTime -and
                $PendingShutdown -lt $EndTime) {

                $DowntimeRecords.Add([PSCustomObject]@{
                    Month         = $Event.TimeCreated.ToString('yyyy-MM')
                    DowntimeStart = $PendingShutdown
                    DowntimeEnd   = $Event.TimeCreated
                    DowntimeMins  = [math]::Round(
                        $Duration.TotalMinutes, 2
                    )
                    Type          = 'Planned/Graceful'
                })
            }

            $PendingShutdown = $null
        }
    }
}

# ---------- Monthly summary and push ----------
$MonthlySummary = [System.Collections.Generic.List[object]]::new()

Write-Host "`n=== Monthly Summary ===" -ForegroundColor Cyan

for ($Month = 1; $Month -le 12; $Month++) {
    $MonthStart = [datetime]::new($Year, $Month, 1)
    $MonthEnd = $MonthStart.AddMonths(1)
    $MonthKey = $MonthStart.ToString('yyyy-MM')

    # Do not publish measured results for future months.
    if ($MonthStart -ge $Now -or $MonthStart -ge $EffectiveEnd) {
        $MonthlySummary.Add([PSCustomObject]@{
            Month          = $MonthKey
            TotalMinutes   = 0
            DowntimeMins   = $null
            DowntimePct    = $null
            UptimePct      = $null
            Reboots        = $null
            TargetMet_1pct = 'NOT MEASURED'
        })

        if (-not $SkipNocoBase) {
            $null = Push-ToNocoBase `
                -Month $MonthKey `
                -ServerReference $ServerRef `
                -UseUuid $UseUuid `
                -UptimePercent $null `
                -DowntimePercent $null `
                -Reboots $null `
                -DataSource 'none' `
                -KpiMet $false `
                -Notes 'Future month or month not yet started'
        }

        continue
    }

    $ObservedEnd = if ($MonthEnd -lt $Now) {
        $MonthEnd
    }
    else {
        $Now
    }

    $TotalMinutes = ($ObservedEnd - $MonthStart).TotalMinutes

    $MonthDowntimeRecords = @(
        $DowntimeRecords | Where-Object {
            $_.DowntimeEnd -gt $MonthStart -and
            $_.DowntimeStart -lt $ObservedEnd
        }
    )

    # Calculate overlap with the actual reporting month.
    $MonthDowntime = 0.0

    foreach ($Record in $MonthDowntimeRecords) {
        $OverlapStart = if ($Record.DowntimeStart -lt $MonthStart) {
            $MonthStart
        }
        else {
            $Record.DowntimeStart
        }

        $OverlapEnd = if ($Record.DowntimeEnd -gt $ObservedEnd) {
            $ObservedEnd
        }
        else {
            $Record.DowntimeEnd
        }

        if ($OverlapEnd -gt $OverlapStart) {
            $MonthDowntime += (
                $OverlapEnd - $OverlapStart
            ).TotalMinutes
        }
    }

    $MonthDowntime = [math]::Round($MonthDowntime, 2)

    # Count Event Log service starts as a reboot proxy, not a guaranteed
    # one-to-one count of physical/OS reboots.
    $Reboots = @(
        $YearEvents | Where-Object {
            $_.Id -eq 6005 -and
            $_.TimeCreated -ge $MonthStart -and
            $_.TimeCreated -lt $ObservedEnd
        }
    ).Count

    $UnexpectedShutdowns = @(
        $YearEvents | Where-Object {
            $_.Id -eq 6008 -and
            $_.TimeCreated -ge $MonthStart -and
            $_.TimeCreated -lt $ObservedEnd
        }
    ).Count

    $UptimePct = [math]::Round(
        [math]::Max(0, 100 * (1 - $MonthDowntime / $TotalMinutes)),
        4
    )

    $DowntimePct = [math]::Round(
        100 * $MonthDowntime / $TotalMinutes,
        4
    )

    # A result based on incomplete events is an estimate, not proof of
    # full uptime. Unexpected shutdowns are explicitly flagged.
    $Notes = "Estimated from matched 6006/6005 events; unexpected shutdown reports: $UnexpectedShutdowns"

    $KpiMet = ($DowntimePct -le 1 -and $UnexpectedShutdowns -eq 0)

    $MonthlySummary.Add([PSCustomObject]@{
        Month          = $MonthKey
        TotalMinutes   = [math]::Round($TotalMinutes, 2)
        DowntimeMins   = $MonthDowntime
        DowntimePct    = "$DowntimePct%"
        UptimePct      = "$UptimePct%"
        Reboots        = $Reboots
        TargetMet_1pct = if ($KpiMet) { 'YES*' } else { 'NO/REVIEW' }
    })

    Write-Host (
        "{0}: downtime={1} min, uptime={2}%, starts={3}, unexpected={4}" -f
        $MonthKey, $MonthDowntime, $UptimePct, $Reboots, $UnexpectedShutdowns
    )

    if (-not $SkipNocoBase) {
        $null = Push-ToNocoBase `
            -Month $MonthKey `
            -ServerReference $ServerRef `
            -UseUuid $UseUuid `
            -UptimePercent $UptimePct `
            -DowntimePercent $DowntimePct `
            -Reboots $Reboots `
            -DataSource 'EventLog' `
            -KpiMet $KpiMet `
            -Notes $Notes
    }
}

# ---------- Export CSV ----------
$DowntimeRecords |
    Export-Csv -LiteralPath $DetailsPath -NoTypeInformation -Encoding UTF8

$MonthlySummary |
    Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "`nReport generated." -ForegroundColor Green
Write-Host "Summary: $OutputPath"
Write-Host "Details: $DetailsPath"

$MonthlySummary | Format-Table -AutoSize
