<#
.SYNOPSIS
    Writes (or removes) the Rider run configuration that opens a ticket's own terminal tab in its worktree.

    The impl-* skills use it to run a ticket in parallel with others: the configuration is a Shell Script
    with "Execute in the terminal", so Rider opens a real, interactive terminal tab named <Title> in
    <Worktree>, sets the variables the tab session reads, runs the profile's launcher setup commands and starts
    Claude with <Prompt>. Rider's MCP terminal tool can't do this: it runs commands with piped, captured I/O,
    so the tab keeps the MCP client's name and Claude can't start interactively there.

    A running process keeps its folder in use on Windows, so the tab session can't remove its own worktree.
    When Claude exits, the tab steps out to <Main> and, if the worktree's HEAD is detached (the tab session
    detaches it once the ticket is finished), runs `<EnvScript> down -Issue <Id>`, which removes it.

    The file goes to <Main>\.run\yi-sdlc-<Id>.run.xml and is kept out of git through .git\info\exclude, so
    the operator's checkout shows no change. Rider loads it only once it reads the file (an MCP read_file).
    The worktree also gets the main clone's git-ignored Claude files (.claude\settings.local.json and
    .claude\*.local.md), so the tab session has the operator's permissions, MCP approvals and stage settings.

.EXAMPLE
    .\rider-tab.ps1 -Main C:\Projects\Pet\yavias -Id yv-12 -Worktree C:\Projects\Pet\yavias-WT\yv-12 `
        -EnvScript C:\Projects\Pet\yavias\.claude\yi-sdlc\ticket-env.ps1 -Title fix/yv-12-fill-gaps-error `
        -Branch fix/yv-12-fill-gaps-error -Prompt '/yi-sdlc:impl-fix yv-12'
    .\rider-tab.ps1 -Main C:\Projects\Pet\yavias -Id yv-12 -Remove
#>
[CmdletBinding()]
param(
    # The main clone: the project Rider has open.
    [Parameter(Mandatory)] [string]$Main,
    [Parameter(Mandatory)] [string]$Id,
    # The ticket's worktree (the `worktree` that `ticket-env.ps1 up` prints): where the tab and Claude start.
    [string]$Worktree,
    # Absolute path of the environment script in the main clone, for the cleanup after Claude exits.
    [string]$EnvScript,
    # Tab and run configuration name.
    [string]$Title,
    # Exported as YI_SDLC_BRANCH, so the tab session uses the branch the launcher chose.
    [string]$Branch,
    # What Claude starts with, e.g. '/yi-sdlc:impl-fix yv-12'.
    [string]$Prompt,
    # PowerShell run in the tab before Claude starts (profile § Launcher).
    [string]$Setup,
    # Extra arguments for claude, passed as written (profile § Launcher), e.g. '--permission-mode auto'.
    [string]$ClaudeArgs,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$Main = (Resolve-Path $Main).Path.TrimEnd('\')
$safeId = $Id -replace '[^A-Za-z0-9_.-]', '-'
$file = Join-Path $Main ".run\yi-sdlc-$safeId.run.xml"

if ($Remove) {
    if (Test-Path $file) { Remove-Item $file -Force }
    [pscustomobject]@{ removed = $file } | ConvertTo-Json -Compress
    return
}

foreach ($name in 'Worktree', 'EnvScript', 'Title', 'Branch', 'Prompt') {
    if (-not (Get-Variable $name -ValueOnly)) { throw "-$name is required unless -Remove is given." }
}
$Worktree = (Resolve-Path $Worktree).Path.TrimEnd('\')
$EnvScript = (Resolve-Path $EnvScript).Path

# The main clone's git-ignored Claude files, which a fresh worktree lacks.
$claudeDir = Join-Path $Main '.claude'
$copied = @()
if (Test-Path $claudeDir) {
    $sources = @(Get-ChildItem $claudeDir -File -Filter '*.local.*' |
        Where-Object { $_.Name -eq 'settings.local.json' -or $_.Extension -eq '.md' })
    foreach ($source in $sources) {
        $target = Join-Path $Worktree ".claude\$($source.Name)"
        if (-not (Test-Path $target)) {
            New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
            Copy-Item $source.FullName $target
            $copied += $source.Name
        }
    }
}

function Quote([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# Typed into the tab's shell, which must be PowerShell (Rider's Terminal "Shell path").
$parts = @(
    "`$env:YI_SDLC_TAB = $(Quote $Id)"
    "`$env:YI_SDLC_BRANCH = $(Quote $Branch)"
    "`$env:YI_SDLC_MAIN = $(Quote $Main)"
    "`$Host.UI.RawUI.WindowTitle = $(Quote $Title)"
)
if ($Setup) { $parts += $Setup }
$claude = 'claude'
if ($ClaudeArgs) { $claude += " $ClaudeArgs" }
$parts += "$claude -n $(Quote $Title) $(Quote $Prompt)"
# After Claude exits: leave the worktree (both locations, or Windows keeps the folder in use) and remove it
# once the ticket is finished.
$parts += "Set-Location $(Quote $Main)"
$parts += "[Environment]::CurrentDirectory = $(Quote $Main)"
$parts += "if (-not (git -C $(Quote $Worktree) branch --show-current)) { & $(Quote $EnvScript) down -Issue $(Quote $Id) }"
$scriptText = $parts -join '; '

$esc = [System.Security.SecurityElement]
$xml = @"
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="$($esc::Escape($Title))" type="ShConfigurationType" activateToolWindowBeforeRun="true">
    <option name="SCRIPT_TEXT" value="$($esc::Escape($scriptText))" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="SCRIPT_PATH" value="" />
    <option name="SCRIPT_OPTIONS" value="" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$($esc::Escape($Worktree.Replace('\', '/')))" />
    <option name="INDEPENDENT_INTERPRETER_PATH" value="true" />
    <option name="INTERPRETER_PATH" value="" />
    <option name="INTERPRETER_OPTIONS" value="" />
    <option name="EXECUTE_IN_TERMINAL" value="true" />
    <option name="EXECUTE_SCRIPT_FILE" value="false" />
    <envs />
    <method v="2" />
  </configuration>
</component>
"@

New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
[IO.File]::WriteAllText($file, $xml, (New-Object Text.UTF8Encoding $false))

# Keep the generated configurations out of the operator's git status.
$exclude = (& git -C $Main rev-parse --path-format=absolute --git-path info/exclude).Trim()
$pattern = '/.run/yi-sdlc-*.run.xml'
$lines = if (Test-Path $exclude) { Get-Content $exclude } else { @() }
if ($lines -notcontains $pattern) {
    New-Item -ItemType Directory -Force (Split-Path $exclude) | Out-Null
    Add-Content -Path $exclude -Value $pattern
}

[pscustomobject]@{ name = $Title; file = $file; copied = $copied } | ConvertTo-Json -Compress
