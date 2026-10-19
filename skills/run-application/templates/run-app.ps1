<#
.SYNOPSIS
  Starts this repo's application from one checkout (the main clone or any of its git worktrees), so several
  checkouts run side by side, and prints the links to try it. The interface: the yi-sdlc plugin's
  skills/run-application/run-script.md. Change what starts in $Parts below; the rest is generic.

.EXAMPLE
  run-app.ps1 up                          # the checkout this script is in
  run-app.ps1 up -Path ..\<repo>-WT\yv-5  # another checkout of the same repo
  run-app.ps1 status
  run-app.ps1 restart                     # after changes that don't hot-reload
  run-app.ps1 down
  run-app.ps1 list                        # every checkout of the repo and what runs there

.NOTES
  Runs under Windows PowerShell 5.1 and pwsh 7. Prints JSON on success.
  The main clone runs on each part's usual Port. A worktree gets free ports, kept in its state file, so its
  links stay the same across restarts. State and logs live outside every checkout, in
  %LOCALAPPDATA%\yi-sdlc\run\<repo>-<hash>\<checkout>-<hash>.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('up', 'status', 'restart', 'down', 'list')]
  [string]$Action = 'status',

  # The checkout to run (any folder inside it). Default: the checkout this script is in.
  [string]$Path
)

$ErrorActionPreference = 'Stop'

# ---- What starts: the only repo-specific part -------------------------------------------------------------
# One entry per part, started in this order and stopped in reverse.
#   Name     unique id, used in {port:<Name>} and in the log names
#   Dir      working directory, relative to the checkout (default '.')
#   Build    optional: a cmd.exe command line run to completion before Run
#   Run      a cmd.exe command line; the long-running process, which must listen on {port}
#   Port     the main clone's port; a worktree gets a free one
#   Env      optional hashtable of environment variables for Build and Run
#   Ready    'http://...' (any answer below 500 counts) or 'tcp://localhost:{port}' (default)
#   Timeout  seconds to wait for Ready (default 120)
#   Links    ordered name -> URL, shown to the user once the part is up
#   HotReload $true when the running part picks up code changes itself (Vite, `dotnet watch`), so it is never
#            reported stale
#   Watch    optional paths (relative to the checkout) whose changes make the part stale; default Dir
#   Stop     optional: a cmd.exe command line `down` runs after stopping the part (remove a per-checkout
#            container); `restart` doesn't run it
#   Shared   $true: one instance serves every checkout (e.g. a database container). Run is then a one-shot
#            command (`docker compose up -d db`), run only when Ready fails; Port is the same everywhere,
#            and down never stops it
#   Worktree optional hashtable of fields that replace the part's own outside the main clone (its Env is
#            merged key by key), e.g. a worktree's own database name, or a Build that first copies it
# Placeholders in Build, Run, Stop, Env, Ready and Links: {port}, {port:<Name>}, {checkout}, {state} (this
# checkout's state folder, outside every checkout: build output, generated config), {slug} (the checkout's
# folder name in lower case, other characters as `_`: safe in database and container names).
# Each command's output goes to <state>\<Name>[.build|.stop].out/err.log; a redirect of its own would be
# overridden, so write files from a command with a tool's own option (`-o`, `--out`), not `>`.
# A frontend must reach its own checkout's backend: pass {port:<backend>} through Env or Run (proxy target),
# never a hard-coded port.
$Parts = @(
  @{
    Name  = 'web'
    Dir   = '.'
    Run   = 'npm run dev -- --port {port} --strictPort'
    Port  = 5173
    Ready = 'http://localhost:{port}/'
    Links = [ordered]@{ 'Web' = 'http://localhost:{port}/' }
  }
)
# ------------------------------------------------------------------------------------------------------------

# The parts as they apply to one checkout: outside the main clone, each part's Worktree fields win.
function Get-Parts($co) {
  foreach ($part in $Parts) {
    if ($co.IsMain -or -not $part.Worktree) { $part; continue }
    $merged = @{} + $part
    foreach ($key in $part.Worktree.Keys) {
      if ($key -eq 'Env') {
        $vars = @{}
        if ($part.Env) { $vars += $part.Env }
        foreach ($name in $part.Worktree.Env.Keys) { $vars[$name] = $part.Worktree.Env[$name] }
        $merged.Env = $vars
      } else { $merged[$key] = $part.Worktree[$key] }
    }
    $merged
  }
}

function Invoke-Git([string]$dir, [string[]]$gitArgs) {
  # In 5.1, a native command's stderr under 'Stop' throws even when redirected.
  $ErrorActionPreference = 'Continue'
  $out = & git -C $dir @gitArgs 2>$null
  if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed in $dir" }
  return $out
}

function ConvertTo-Hashtable($object) {
  $table = @{}
  if ($object) { foreach ($p in $object.PSObject.Properties) { $table[$p.Name] = $p.Value } }
  return $table
}

function Get-PathHash([string]$path) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant()))[0..3] |
    ForEach-Object { $_.ToString('x2') })
}

function Get-Checkout([string]$dir) {
  $top = ((Invoke-Git $dir @('rev-parse', '--show-toplevel')) | Select-Object -First 1) -replace '/', '\'
  $common = ((Invoke-Git $top @('rev-parse', '--path-format=absolute', '--git-common-dir')) |
    Select-Object -First 1) -replace '/', '\'
  $main = Split-Path $common -Parent
  $branch = (Invoke-Git $top @('branch', '--show-current')) | Select-Object -First 1
  if (-not $branch) { $branch = 'detached at ' + ((Invoke-Git $top @('rev-parse', '--short', 'HEAD')) | Select-Object -First 1) }

  # <repo>-<hash>\<checkout>-<hash>: unique per path, still readable by name.
  $repoKey = '{0}-{1}' -f (Split-Path $main -Leaf), (Get-PathHash $main)
  $stateDir = Join-Path $env:LOCALAPPDATA ("yi-sdlc\run\{0}\{1}-{2}" -f $repoKey, (Split-Path $top -Leaf), (Get-PathHash $top))

  [pscustomobject]@{
    Path      = $top
    Main      = $main
    IsMain    = ($top -ieq $main)
    Slug      = ((Split-Path $top -Leaf).ToLowerInvariant() -replace '[^a-z0-9]', '_')
    Branch    = $branch
    StateDir  = $stateDir
    StateFile = (Join-Path $stateDir 'state.json')
  }
}

function Read-State($co) {
  $state = @{ checkout = $co.Path; ports = @{}; pids = @{}; started = @{}; commits = @{} }
  if (Test-Path $co.StateFile) {
    $saved = Get-Content -Raw $co.StateFile | ConvertFrom-Json
    $state.ports = ConvertTo-Hashtable $saved.ports
    $state.pids = ConvertTo-Hashtable $saved.pids
    $state.started = ConvertTo-Hashtable $saved.started
    $state.commits = ConvertTo-Hashtable $saved.commits
  }
  return $state
}

function Save-State($co, $state) {
  New-Item -ItemType Directory -Force $co.StateDir | Out-Null
  $state | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $co.StateFile
}

function Test-Listening([int]$port) {
  return [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

function Get-FreePort([int[]]$taken) {
  while ($true) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    if ($taken -notcontains $port -and -not (Test-Listening $port)) { return $port }
  }
}

# A PID alone can be reused by an unrelated process, so the start time recorded with it must match too. It is
# kept as ticks: pwsh 7's ConvertFrom-Json turns a date string into a DateTime, which then never compares equal.
function Test-Ours($state, [string]$name) {
  $processId = [int]$state.pids[$name]
  if ($processId -le 0) { return $false }
  $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
  if (-not $process) { return $false }
  try { return $process.StartTime.ToUniversalTime().Ticks -eq [long]$state.started[$name] } catch { return $true }
}

function Stop-Tree([int]$processId) {
  if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { & taskkill.exe /PID $processId /T /F 2>&1 | Out-Null }
}

function Expand-Text([string]$text, [string]$name, $ports, $co) {
  if (-not $text) { return $text }
  $text = $text.Replace('{checkout}', $co.Path).Replace('{state}', $co.StateDir).Replace('{slug}', $co.Slug)
  foreach ($other in $ports.Keys) { $text = $text.Replace("{port:$other}", [string]$ports[$other]) }
  return $text.Replace('{port}', [string]$ports[$name])
}

function Get-ReadyUrl($part, $ports, $co) {
  $ready = if ($part.Ready) { $part.Ready } else { 'tcp://localhost:{port}' }
  return Expand-Text $ready $part.Name $ports $co
}

# The HTTP status a URL answers with, or 0 when nothing answers.
function Get-HttpStatus([string]$url) {
  try {
    return [int](Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 5).StatusCode
  } catch {
    # A 4xx/5xx throws (WebException in 5.1, HttpResponseException in 7), but the server did answer.
    $response = $_.Exception.Response
    if ($response) { return [int]$response.StatusCode }
    return 0
  }
}

# Ready: a tcp:// URL listens, or an http(s) one answers below 500 (a 404 still means the server is up).
function Test-Url([string]$url) {
  if ($url -match '^tcp://[^:]+:(\d+)') { return Test-Listening ([int]$Matches[1]) }
  $status = Get-HttpStatus $url
  return $status -gt 0 -and $status -lt 500
}

function Get-LogTail($co, [string]$name) {
  $lines = foreach ($kind in 'err', 'out') {
    $log = Join-Path $co.StateDir "$name.$kind.log"
    if (Test-Path $log) { Get-Content $log -Tail 20 }
  }
  return ($lines -join "`n")
}

function Start-Cmd($part, [string]$commandLine, [string]$logName, $ports, $co, [switch]$Wait) {
  $dir = Join-Path $co.Path $(if ($part.Dir) { $part.Dir } else { '.' })
  New-Item -ItemType Directory -Force $co.StateDir | Out-Null
  # Start-Process in 5.1 has no -Environment: set, start (the child inherits), restore.
  $saved = @{}
  if ($part.Env) {
    foreach ($key in $part.Env.Keys) {
      $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
      [Environment]::SetEnvironmentVariable($key, (Expand-Text $part.Env[$key] $part.Name $ports $co), 'Process')
    }
  }
  # cmd.exe redirects into the logs itself. Start-Process -RedirectStandard* would hand the child every
  # inheritable handle, this script's stdout included, so whoever reads that output through a pipe would wait
  # until the servers exit. Without it, Start-Process goes through ShellExecute, which passes no handles.
  $out = Join-Path $co.StateDir "$logName.out.log"
  $err = Join-Path $co.StateDir "$logName.err.log"
  $line = '"' + (Expand-Text $commandLine $part.Name $ports $co) + " 1>`"$out`" 2>`"$err`"" + '"'
  try {
    $process = Start-Process cmd.exe -PassThru -WindowStyle Hidden -WorkingDirectory $dir `
      -ArgumentList '/d', '/s', '/c', $line -Wait:$Wait
  } finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
  }
  if ($Wait -and $process.ExitCode -ne 0) {
    throw "$($part.Name): '$commandLine' exited with $($process.ExitCode)`n$(Get-LogTail $co $logName)"
  }
  return $process
}

function Wait-Ready($part, $state, $ports, $co) {
  $url = Get-ReadyUrl $part $ports $co
  $seconds = if ($part.Timeout) { $part.Timeout } else { 120 }
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Url $url) { return }
    if (-not $part.Shared -and -not (Test-Ours $state $part.Name)) {
      throw "$($part.Name) exited before $url answered`n$(Get-LogTail $co $part.Name)"
    }
    Start-Sleep -Seconds 1
  }
  throw "$($part.Name): $url did not answer within $seconds s`n$(Get-LogTail $co $part.Name)"
}

function Resolve-Ports($state, $co) {
  $ports = @{}
  foreach ($part in (Get-Parts $co)) {
    $kept = [int]$state.ports[$part.Name]
    if ($co.IsMain -or $part.Shared) { $ports[$part.Name] = $part.Port }
    elseif ($kept -gt 0 -and ((Test-Ours $state $part.Name) -or -not (Test-Listening $kept))) { $ports[$part.Name] = $kept }
    else { $ports[$part.Name] = Get-FreePort @($ports.Values) }
  }
  return $ports
}

function Stop-Parts($state, $co, [switch]$Down) {
  $reversed = @(Get-Parts $co)
  [array]::Reverse($reversed)
  foreach ($part in $reversed) {
    if ($part.Shared) { continue }
    if (Test-Ours $state $part.Name) { Stop-Tree ([int]$state.pids[$part.Name]) }
    $state.pids.Remove($part.Name)
    $state.started.Remove($part.Name)
    $state.commits.Remove($part.Name)
    if ($Down -and $part.Stop) { Start-Cmd $part $part.Stop "$($part.Name).stop" $state.ports $co -Wait | Out-Null }
  }
  Save-State $co $state
}

function Start-Parts($state, $co) {
  $ports = Resolve-Ports $state $co
  $state.ports = $ports
  Save-State $co $state
  foreach ($part in (Get-Parts $co)) {
    if ($part.Shared) {
      if (-not (Test-Url (Get-ReadyUrl $part $ports $co))) {
        Start-Cmd $part $part.Run $part.Name $ports $co -Wait | Out-Null
        Wait-Ready $part $state $ports $co
      }
      continue
    }
    if (Test-Ours $state $part.Name) { Wait-Ready $part $state $ports $co; continue }
    # The main clone's usual port already answers: the operator's own run. Leave it alone.
    if (Test-Listening $ports[$part.Name]) {
      if ($co.IsMain) { continue }
      throw "$($part.Name): port $($ports[$part.Name]) is taken"
    }
    if ($part.Build) { Start-Cmd $part $part.Build "$($part.Name).build" $ports $co -Wait | Out-Null }
    $process = Start-Cmd $part $part.Run $part.Name $ports $co
    $state.pids[$part.Name] = $process.Id
    $state.started[$part.Name] = $process.StartTime.ToUniversalTime().Ticks
    $state.commits[$part.Name] = Get-Head $co
    Save-State $co $state
    Wait-Ready $part $state $ports $co
  }
}

function Get-Head($co) {
  return (Invoke-Git $co.Path @('rev-parse', '--short', 'HEAD')) | Select-Object -First 1
}

# Stale: the part runs older code than the checkout has, because HEAD moved since it started or a file it
# watches changed after that. A link that answers says nothing about which code answers.
function Test-Stale($part, $state, $co) {
  if ($part.HotReload -or $part.Shared) { return $false }
  $commit = $state.commits[$part.Name]
  if (-not $commit) { return $null }
  $watch = @(if ($part.Watch) { $part.Watch } elseif ($part.Dir) { $part.Dir } else { '.' })
  if ($commit -ne (Get-Head $co) -and (Invoke-Git $co.Path (@('diff', '--name-only', $commit, 'HEAD', '--') + $watch))) {
    return $true
  }
  $since = [datetime]::new([long]$state.started[$part.Name], [DateTimeKind]::Utc)
  foreach ($line in (Invoke-Git $co.Path (@('status', '--porcelain', '--') + $watch))) {
    $file = Join-Path $co.Path ($line.Substring(3).Trim('"') -replace '^.* -> ', '')
    if ((Test-Path $file) -and (Get-Item $file).LastWriteTimeUtc -gt $since) { return $true }
  }
  return $false
}

function Get-Report($co) {
  $state = Read-State $co
  $ports = @{}
  foreach ($part in (Get-Parts $co)) {
    $ports[$part.Name] = if ($co.IsMain -or $part.Shared) { $part.Port } else { [int]$state.ports[$part.Name] }
  }
  $rows = @(); $links = @()
  foreach ($part in (Get-Parts $co)) {
    $port = $ports[$part.Name]
    $ours = Test-Ours $state $part.Name
    $up = ($port -gt 0) -and (Test-Url (Get-ReadyUrl $part $ports $co))
    $how = if ($part.Shared) { 'shared' } elseif ($ours) { 'run-app' } elseif ($up) { 'external' } else { $null }
    $rows += [ordered]@{
      name    = $part.Name
      port    = $(if ($port -gt 0) { $port } else { $null })
      running = $up
      by      = $how
      pid     = $(if ($ours) { [int]$state.pids[$part.Name] } else { $null })
      commit  = $(if ($ours) { $state.commits[$part.Name] } else { $null })
      stale   = $(if ($ours) { Test-Stale $part $state $co } else { $null })
      log     = $(if ($ours) { Join-Path $co.StateDir "$($part.Name).out.log" } else { $null })
    }
    if ($up -and $part.Links) {
      foreach ($name in $part.Links.Keys) {
        $url = Expand-Text $part.Links[$name] $part.Name $ports $co
        $status = Get-HttpStatus $url
        $links += [ordered]@{ name = $name; url = $url; status = $status; ok = ($status -ge 200 -and $status -lt 400) }
      }
    }
  }
  [ordered]@{
    checkout = $co.Path
    branch   = $co.Branch
    head     = (Get-Head $co)
    main     = $co.IsMain
    running  = (@($rows | Where-Object { $_.running -and $_.by -ne 'shared' }).Count -gt 0)
    links    = $links
    parts    = $rows
    state    = $co.StateDir
  }
}

# Failures go to stderr as one message (with the part's log tail) and exit 1, so a caller never takes them for
# a report.
try {
  $scriptCheckout = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
  $co = Get-Checkout $(if ($Path) { (Resolve-Path $Path).Path } else { $scriptCheckout })

  switch ($Action) {
    'up' { Start-Parts (Read-State $co) $co; Get-Report $co | ConvertTo-Json -Depth 6 }
    'status' { Get-Report $co | ConvertTo-Json -Depth 6 }
    'restart' { $state = Read-State $co; Stop-Parts $state $co; Start-Parts $state $co; Get-Report $co | ConvertTo-Json -Depth 6 }
    'down' { Stop-Parts (Read-State $co) $co -Down; Get-Report $co | ConvertTo-Json -Depth 6 }
    'list' {
      $paths = (Invoke-Git $co.Main @('worktree', 'list', '--porcelain')) |
        Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring('worktree '.Length) }
      $reports = @(foreach ($p in $paths) { if (Test-Path $p) { Get-Report (Get-Checkout $p) } })
      ConvertTo-Json -InputObject $reports -Depth 6
    }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
