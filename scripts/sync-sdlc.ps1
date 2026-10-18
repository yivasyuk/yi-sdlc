<#
.SYNOPSIS
    Imports the upstream sdlc plugin (Kyrylo Genkov, MIT) into yi-sdlc under the yi-sdlc namespace.

    Copies <Source>\plugin\skills\* to skills\, <Source>\plugin\agents\*.md to agents\, <Source>\plugin\tests to
    tests\sdlc\, the plugin README to SDLC.md and the licence to LICENSE-sdlc, then rewrites the copies' own
    references so they resolve inside this plugin:
      sdlc:<name>    -> yi-sdlc:<name>     (agents and skills, e.g. subagent_type "sdlc:critic")
      /sdlc-<name>   -> /yi-sdlc:<name>    (the commands the handoffs and triggers name)
    The settings file name .claude/sdlc.local.md and the sdlc/plugin/... path comments stay as they are.
    The source is never written to.

    sdlc-upstream.json records what was imported (version, source commit, skill and agent names). A re-run
    replaces exactly those entries, so skills removed upstream disappear here, and yi-sdlc's own skills
    (impl-*, git-commit, notification-mode) are never touched: an upstream name that collides with one stops
    the sync.

.EXAMPLE
    .\scripts\sync-sdlc.ps1
    .\scripts\sync-sdlc.ps1 -Source D:\src\sdlc
#>
[CmdletBinding()]
param(
    # The sdlc repo folder (the one holding plugin\).
    [string]$Source = 'C:\Projects\Learning\agentic-engineering\agentic-engineering-course\sdlc'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$plugin = Join-Path $Source 'plugin'
if (-not (Test-Path (Join-Path $plugin 'plugin.json'))) { throw "No sdlc plugin at $plugin" }

$manifestPath = Join-Path $root 'sdlc-upstream.json'
$previous = if (Test-Path $manifestPath) { Get-Content $manifestPath -Raw | ConvertFrom-Json } else { $null }
$prevSkills = @(if ($previous) { $previous.skills })
$prevAgents = @(if ($previous) { $previous.agents })

$skills = @(Get-ChildItem (Join-Path $plugin 'skills') -Directory | ForEach-Object Name)
$agents = @(Get-ChildItem (Join-Path $plugin 'agents') -File -Filter '*.md' | ForEach-Object BaseName)

# Never overwrite yi-sdlc's own skills or agents.
foreach ($name in $skills) {
    if ((Test-Path (Join-Path $root "skills\$name")) -and $prevSkills -notcontains $name) {
        throw "Upstream skill '$name' collides with yi-sdlc's own skills\$name"
    }
}
foreach ($name in $agents) {
    if ((Test-Path (Join-Path $root "agents\$name.md")) -and $prevAgents -notcontains $name) {
        throw "Upstream agent '$name' collides with yi-sdlc's own agents\$name.md"
    }
}

# Drop the previous import, then copy the current one.
foreach ($name in $prevSkills) { $p = Join-Path $root "skills\$name"; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }
foreach ($name in $prevAgents) { $p = Join-Path $root "agents\$name.md"; if (Test-Path $p) { Remove-Item -Force $p } }
$testsTarget = Join-Path $root 'tests\sdlc'
if (Test-Path $testsTarget) { Remove-Item -Recurse -Force $testsTarget }

$copied = New-Object System.Collections.Generic.List[string]
function Copy-Tree([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force $to | Out-Null
    Copy-Item -Recurse -Force (Join-Path $from '*') $to
    Get-ChildItem $to -Recurse -File | ForEach-Object { $copied.Add($_.FullName) }
}
foreach ($name in $skills) { Copy-Tree (Join-Path $plugin "skills\$name") (Join-Path $root "skills\$name") }
New-Item -ItemType Directory -Force (Join-Path $root 'agents') | Out-Null
foreach ($name in $agents) {
    $target = Join-Path $root "agents\$name.md"
    Copy-Item -Force (Join-Path $plugin "agents\$name.md") $target
    $copied.Add($target)
}
if (Test-Path (Join-Path $plugin 'tests')) { Copy-Tree (Join-Path $plugin 'tests') $testsTarget }
Copy-Item -Force (Join-Path $plugin 'README.md') (Join-Path $root 'SDLC.md'); $copied.Add((Join-Path $root 'SDLC.md'))
Copy-Item -Force (Join-Path $Source 'LICENSE') (Join-Path $root 'LICENSE-sdlc')

# Rewrite the namespace in the copies.
$rules = @(
    @{ pattern = '(?<![\w/.-])sdlc:(?=[a-z<])'; replace = 'yi-sdlc:' }
    @{ pattern = '(?<![\w.-])/sdlc-'; replace = '/yi-sdlc:' }
)
$textExt = '.md', '.json', '.yaml', '.yml', '.sh', '.py', '.txt'
$rewrites = 0
foreach ($file in $copied) {
    if ($textExt -notcontains [IO.Path]::GetExtension($file).ToLowerInvariant()) { continue }
    $bytes = [IO.File]::ReadAllBytes($file)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [IO.File]::ReadAllText($file)
    $new = $text
    foreach ($rule in $rules) {
        $rewrites += [regex]::Matches($new, $rule.pattern).Count
        $new = [regex]::Replace($new, $rule.pattern, $rule.replace)
    }
    if ($new -ne $text) { [IO.File]::WriteAllText($file, $new, (New-Object Text.UTF8Encoding $bom)) }
}

$upstream = Get-Content (Join-Path $plugin 'plugin.json') -Raw | ConvertFrom-Json
$commit = (& git -C $Source log -1 --format=%H -- plugin 2>$null)
$dirty = [bool](& git -C $Source status --porcelain -- plugin 2>$null)
[ordered]@{
    source  = $Source
    version = $upstream.version
    commit  = $commit
    dirty   = $dirty
    skills  = $skills
    agents  = $agents
} | ConvertTo-Json | ForEach-Object { [IO.File]::WriteAllText($manifestPath, $_ + "`n", (New-Object Text.UTF8Encoding $false)) }

$removed = @($prevSkills | Where-Object { $skills -notcontains $_ }) + @($prevAgents | Where-Object { $agents -notcontains $_ })
[pscustomobject]@{
    version  = $upstream.version
    commit   = $commit
    dirty    = $dirty
    skills   = $skills.Count
    agents   = $agents.Count
    files    = $copied.Count
    rewrites = $rewrites
    removed  = $removed
} | ConvertTo-Json -Compress
