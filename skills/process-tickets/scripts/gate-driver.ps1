<#
Clears and resumes a /yi-sdlc:implement-feature session after each approved gate.

Runs as a plain tab in the feature's Pane, started by /yi-sdlc:process-tickets. The feature session runs with
--stop-at-gates: once a gate is approved it reports `gate-approved` (runpane report) and ends its turn.
This script then sends /clear and the session's starting prompt again, so the next stage starts with a
fresh context and implement-feature resumes from the Feature pipeline comment. It never answers a gate:
the operator does that in the feature's tab.

Exits after gate 3, or when the feature's agent panel or its Pane goes away.
#>
param(
    [Parameter(Mandatory)] [string] $Pane,
    [Parameter(Mandatory)] [string] $Panel,
    [Parameter(Mandatory)] [string] $Prompt
)

$lastGate = 3
$runpane = 'runpane'
if (Test-Path "$env:USERPROFILE\.pane\bin\runpane.cmd") { $runpane = "$env:USERPROFILE\.pane\bin\runpane.cmd" }
if ($env:PANE_RUNPANE_BIN) { $runpane = $env:PANE_RUNPANE_BIN }

# The command's JSON. `watch` prints one object per line (a `_reset` line can come before the event), so
# when the whole output isn't one document, the last line that parses wins.
function Invoke-Runpane {
    $out = @(& $runpane @args 2>$null)
    if (-not $out) { return $null }
    try { return ($out -join "`n") | ConvertFrom-Json } catch { }
    [array]::Reverse($out)
    foreach ($line in $out) { try { return $line | ConvertFrom-Json } catch { } }
    return $null
}

# The agent's status (working, ready, blocked, idle, exited) and its latest `runpane report`, or $null
# when Pane can't say.
function Get-PanelReport {
    $status = Invoke-Runpane agents status --panel $Panel --limit 1 --json
    if (-not $status -or $status.ok -eq $false) { return $null }
    $report = $status.report
    if (-not $report) {
        $panels = Invoke-Runpane panels list --pane $Pane --json
        $report = @($panels.panels) + @($panels.items) | Where-Object { $_.panelId -eq $Panel -or $_.id -eq $Panel } |
            ForEach-Object { $_.report } | Select-Object -First 1
    }
    return @{ Status = $status.status; Report = $report }
}

# The gate-approved summary implement-feature writes, or $null for any other report.
function Get-GateApproval($report) {
    if (-not $report) { return $null }
    $data = $report.data
    if (-not $data -and $report.summary) { try { $data = $report.summary | ConvertFrom-Json } catch { } }
    if ($data.skill -eq 'implement-feature' -and $data.event -eq 'gate-approved') { return $data }
    return $null
}

# Waits, up to an hour, until the agent's turn is over. `panels wait --for ready` doesn't tell: Claude's
# input box stays on screen while it works.
function Wait-Ready {
    for ($i = 0; $i -lt 720; $i++) {
        $status = (Invoke-Runpane agents status --panel $Panel --limit 1 --json).status
        if ($status -eq 'ready' -or $status -eq 'idle') { return $true }
        if ($status -eq 'exited') { return $false }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Send-ToAgent([string[]] $inputArgs) {
    $result = Invoke-Runpane panels submit --panel $Panel @inputArgs --no-expect-report --yes --json
    $state = $result.delivery.state
    if ($state -eq 'in-composer') {
        Invoke-Runpane panels submit-composer --panel $Panel --strategy auto --yes --json | Out-Null
    }
    Write-Host "  sent $($inputArgs -join ' '): $state"
}

if (-not (Test-Path $Prompt)) { Write-Host "The starting prompt $Prompt is missing; nothing to resume with."; exit 1 }

$start = Get-PanelReport
if (-not $start) { Write-Host "Pane has no panel $Panel."; exit 1 }
$seen = $start.Report.reportedAt
$handled = @{}
$misses = 0
Write-Host "Watching panel $Panel for approved gates. Leave this tab open; it closes itself after gate $lastGate."

while ($true) {
    $event = Invoke-Runpane watch --pane $Pane --as "gates-$Panel" --until-event --json `
        --kinds 'agent.report,panel.exited,pane.gone'
    if (-not $event -or "$($event.kind)".StartsWith('_')) { Start-Sleep -Seconds 10; continue }
    if ($event.kind -eq 'pane.gone') { Write-Host 'The Pane is gone.'; break }

    $current = Get-PanelReport
    if (-not $current) {
        if (++$misses -ge 3) { Write-Host "Pane can't find panel $Panel any more."; break }
        continue
    }
    $misses = 0
    if ($current.Status -eq 'exited') { Write-Host 'The feature session has exited.'; break }

    $report = $current.Report
    if (-not $report -or $report.reportedAt -eq $seen) { continue }
    $seen = $report.reportedAt
    $gate = Get-GateApproval $report
    if (-not $gate -or $handled["$($gate.gate)"]) { continue }
    $handled["$($gate.gate)"] = $true

    Write-Host "Gate $($gate.gate) approved for $($gate.ticket); next: $($gate.next). Clearing the session."
    if (-not (Wait-Ready)) { Write-Host 'The session never came back to its prompt; stopping.'; break }
    Send-ToAgent @('--text', '/clear')
    Start-Sleep -Seconds 3
    if (-not (Wait-Ready)) { Write-Host 'The session never came back after /clear; stopping.'; break }
    Send-ToAgent @('--input-file', $Prompt)

    if ([int]$gate.gate -ge $lastGate) { Write-Host "Gate $lastGate done; nothing left to clear."; break }
}
