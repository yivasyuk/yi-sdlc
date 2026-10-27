<#
Tells an implement-feature session whether a gate driver is watching its panel, so it stops at a gate only
when something will clear and resume it.

The driver (gate-driver.ps1) keeps %TEMP%\yi-sdlc\gate-driver-<panel id>.pid while it watches and deletes it
when it exits. A driver that is killed (its tab closed, the Pane app restarted) can't delete it, and Windows
reuses process ids, so the file alone proves nothing: the process it names must be running, and it must be
gate-driver.ps1 for this panel. A marker that fails that is stale and is removed.

Exit code 0 and one line naming the driver when one watches; 1 and one line saying why not otherwise.
#>
param(
    [string] $Panel = $env:PANE_PANEL_ID
)

if (-not $Panel) { Write-Host 'No gate driver: this is not a Pane terminal (PANE_PANEL_ID is not set).'; exit 1 }

$marker = Join-Path $env:TEMP "yi-sdlc\gate-driver-$Panel.pid"
if (-not (Test-Path -LiteralPath $marker)) { Write-Host "No gate driver: $marker is missing."; exit 1 }

$driverPid = 0
[void][int]::TryParse(([IO.File]::ReadAllText($marker)).Trim(), [ref] $driverPid)
$process = if ($driverPid) { Get-CimInstance Win32_Process -Filter "ProcessId = $driverPid" -ErrorAction SilentlyContinue }
$command = "$($process.CommandLine)"
if ($command -match 'gate-driver\.ps1' -and $command -match [regex]::Escape($Panel)) {
    Write-Host "Gate driver $driverPid is watching panel $Panel."
    exit 0
}

$why = if (-not $driverPid) { 'it holds no process id' }
    elseif (-not $process) { "process $driverPid isn't running" }
    else { "process $driverPid isn't gate-driver.ps1 for this panel" }
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
Write-Host "No gate driver: $why; removed the stale $marker."
exit 1
