<#
.SYNOPSIS
    Creates (or reuses) a git worktree for a branch, copies local/gitignored files and Claude memory,
    and opens the solution in Rider. It does not start any Claude session.

    With -Branch: uses that branch (existing local, else existing on origin - checked with ls-remote and
    checked out tracking it - else new from -BaseBranch).
    Without -Branch: uses the CURRENT branch of the main clone.
    The main clone is switched to master only if it is currently on the worktree branch; in every other
    case the main clone's branch is left untouched. Nothing is committed. By default (-WithChanges:$false)
    the branch is just opened; with -WithChanges:$true any uncommitted changes of the main clone
    (incl. untracked) are stashed first and then popped into the worktree.

.EXAMPLE
    .\worktree.ps1
    .\worktree.ps1 test/br1
    .\worktree.ps1 feat/EF-9000-my-new-thing -BaseBranch master
    .\worktree.ps1 test/br1 -ReplaceWindow:$true    # close the current Rider window first
    .\worktree.ps1 -WithChanges:$true               # move the main clone's uncommitted changes into the worktree
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Branch,

    # Main clone (the one that holds the .git folder).
    [string]$RepoPath = 'C:\Work\Repo\EvenFlow-Backend',

    # Folder where worktrees are created (outside the repo on purpose).
    # Default: sibling of the main clone named "<main clone folder name>-WT".
    [string]$WorktreeRoot,

    # Used when the branch does not exist yet, and as the branch checked out in the main clone.
    [string]$BaseBranch = 'master',

    [string]$SolutionName = 'EvenFlow.sln',

    # Full path to rider64.exe; auto-detected when omitted.
    [string]$RiderPath,

    [switch]$SkipMemory,

    # Default $false: keep the current Rider window and open the worktree in a new (maximized) one.
    # Pass -ReplaceWindow:$true to close the current Rider window of this solution first.
    [bool]$ReplaceWindow = $false,

    # Default $false: just open the branch; uncommitted changes of the main clone are left where they are.
    # Pass -WithChanges:$true to stash the main clone's changes (incl. untracked) and pop them into the worktree.
    [bool]$WithChanges = $false,

    # Internal: run only the "maximize Rider window for this path" step (used by the detached helper process).
    [string]$MaximizeOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param([string[]]$GitArgs, [switch]$AllowFail)
    & git -C $RepoPath @GitArgs
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "git $($GitArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Test-GitRef([string]$Ref) {
    & git -C $RepoPath show-ref --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

function Get-WorktreeForBranch([string]$Name) {
    $current = $null
    foreach ($line in (& git -C $RepoPath worktree list --porcelain)) {
        if ($line -like 'worktree *') { $current = $line.Substring(9) }
        elseif ($line -eq "branch refs/heads/$Name") { return $current }
    }
    return $null
}

function Get-ClaudeProjectKey([string]$Path) {
    # Claude Code stores per-project data under ~\.claude\projects\<path with non-alphanumerics as '-'>
    return ($Path.TrimEnd('\') -replace '[^a-zA-Z0-9]', '-')
}

function Find-Rider {
    if ($RiderPath) { return $RiderPath }
    $cmd = Get-Command rider64.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $toolbox = Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\apps'
    $candidates = @()
    if (Test-Path $toolbox) {
        $candidates += Get-ChildItem $toolbox -Recurse -Filter rider64.exe -ErrorAction SilentlyContinue
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        $jb = Join-Path $root 'JetBrains'
        if (Test-Path $jb) {
            $candidates += Get-ChildItem $jb -Recurse -Filter rider64.exe -ErrorAction SilentlyContinue
        }
    }
    $best = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($best) { return $best.FullName }
    throw 'rider64.exe not found. Pass -RiderPath "C:\...\bin\rider64.exe".'
}

function Initialize-WtWin32 {
    if (-not ('WtWin32' -as [type])) {
        Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WtWin32 {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    public static List<IntPtr> Find(HashSet<uint> pids, string text, bool exact) {
        var res = new List<IntPtr>();
        EnumWindows((h, l) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (!pids.Contains(pid) || !IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
            var title = sb.ToString();
            var hit = exact
                ? title.Equals(text, StringComparison.OrdinalIgnoreCase)
                : title.IndexOf(text, StringComparison.OrdinalIgnoreCase) >= 0;
            if (hit) res.Add(h);
            return true;
        }, IntPtr.Zero);
        return res;
    }
    public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
    public static void Maximize(IntPtr h) { ShowWindow(h, 3); SetForegroundWindow(h); }
    public static void Activate(IntPtr h) { if (IsIconic(h)) ShowWindow(h, 9); SetForegroundWindow(h); }
}
'@
    }
}

function Get-RiderPids {
    $pids = [System.Collections.Generic.HashSet[uint32]]::new()
    foreach ($p in (Get-Process -Name rider64 -ErrorAction SilentlyContinue)) { [void]$pids.Add([uint32]$p.Id) }
    return ,$pids
}

function Maximize-RiderWindow([string]$PathFragment, [int]$TimeoutSeconds = 90) {
    # Waits for the worktree's Rider window (title contains the worktree path) and maximizes it.
    Initialize-WtWin32
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $pids = Get-RiderPids
        if ($pids.Count -gt 0) {
            $wins = @([WtWin32]::Find($pids, $PathFragment, $false))
            if ($wins.Count -ge 1) {
                [WtWin32]::Maximize($wins[0])
                # Rider may restore its saved window bounds once the project finishes loading; maximize again.
                Start-Sleep -Seconds 3
                $wins = @([WtWin32]::Find((Get-RiderPids), $PathFragment, $false))
                if ($wins.Count -ge 1) { [WtWin32]::Maximize($wins[0]) }
                Write-Host 'Maximized Rider window.' -ForegroundColor Cyan
                return
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning "Rider window for '$PathFragment' did not appear within $TimeoutSeconds s; not maximized."
}

function Update-RiderWindow([string]$Title) {
    # Rider re-syncs the VFS and the Commit / Changes panel when its frame gets activated, so briefly bringing
    # the main clone's window (exact title "<solution>") to the foreground refreshes it after git changed
    # files behind its back. Best effort: no Rider window / ambiguous match / foreground lock => silently skipped.
    Initialize-WtWin32
    $pids = Get-RiderPids
    if ($pids.Count -eq 0) { return }
    $wins = @([WtWin32]::Find($pids, $Title, $true))
    if ($wins.Count -eq 1) {
        Write-Host "Refreshing Rider Commit/Changes panel of the main clone..." -ForegroundColor Cyan
        [WtWin32]::Activate($wins[0])
        Start-Sleep -Seconds 2
    }
}

function Close-RiderWindow([string]$TitlePrefix) {
    # Rider runs all windows in one process, so windows are found by title. The main clone's window is titled
    # exactly "<solution>"; worktree windows get a " [<path>]" suffix, so an exact match is the current window.
    # Closes only when exactly one window matches; otherwise it is ambiguous and nothing is closed.
    Initialize-WtWin32
    $pids = Get-RiderPids
    if ($pids.Count -eq 0) { return }

    $wins = @([WtWin32]::Find($pids, $TitlePrefix, $true))
    if ($wins.Count -eq 1) {
        Write-Host "Closing current Rider window ('$TitlePrefix...')." -ForegroundColor Cyan
        [WtWin32]::Close($wins[0])
        Start-Sleep -Seconds 4
    } elseif ($wins.Count -gt 1) {
        Write-Warning "$($wins.Count) Rider windows match '$TitlePrefix'; not closing any (ambiguous)."
    }
}

if ($MaximizeOnly) {
    Maximize-RiderWindow $MaximizeOnly
    return
}

# --- 0. Sanity -------------------------------------------------------------------------------------
if (-not (Test-Path (Join-Path $RepoPath '.git'))) { throw "Not a git repo: $RepoPath" }
$RepoPath = (Resolve-Path $RepoPath).Path
if (-not $WorktreeRoot) {
    $WorktreeRoot = Join-Path (Split-Path $RepoPath -Parent) ((Split-Path $RepoPath -Leaf) + '-WT')
}

# --- 1. Resolve branch; in "current branch" mode commit everything and free the branch ------------
$stashed = $false
$current = (& git -C $RepoPath branch --show-current)
if ($current) { $current = $current.Trim() }

if (-not $Branch) {
    if (-not $current) { throw 'Main clone is on a detached HEAD and no branch name was given.' }
    if ($current -eq $BaseBranch) { throw "Main clone is already on '$BaseBranch'; pass a branch name." }
    $Branch = $current
    Write-Host "No branch given - using current branch '$Branch'." -ForegroundColor Cyan

}

# Only when the main clone sits on the worktree branch does it have to be freed; otherwise leave it alone.
if ($WithChanges) {
    if (& git -C $RepoPath status --porcelain) {
        Write-Host "Stashing uncommitted changes (incl. untracked) of the main clone..." -ForegroundColor Cyan
        Invoke-Git @('stash', 'push', '--include-untracked', '-m', "worktree: $Branch")
        $stashed = $true
    } else {
        Write-Warning "-WithChanges was requested but the main clone has no uncommitted changes; nothing to move."
    }
}

if ($current -eq $Branch) {
    Write-Host "Checking out '$BaseBranch' in the main clone..." -ForegroundColor Cyan
    Invoke-Git @('checkout', $BaseBranch)
}

Write-Host "Fetching origin..." -ForegroundColor Cyan
Invoke-Git @('fetch', 'origin', '--prune') -AllowFail

# --- 2. Create / reuse worktree --------------------------------------------------------------------
# Drop registrations of worktree folders that no longer exist (deleted/moved by hand).
Invoke-Git @('worktree', 'prune')

$wtPath = Get-WorktreeForBranch $Branch
if ($wtPath) {
    $wtPath = $wtPath.Replace('/', '\')
    Write-Host "Branch '$Branch' is already checked out at $wtPath - reusing." -ForegroundColor Yellow
} else {
    $wtPath = Join-Path $WorktreeRoot ($Branch -replace '[\\/:*?"<>|]', '-')
    if (Test-Path $wtPath) { throw "Folder already exists but is not a worktree of '$Branch': $wtPath" }
    New-Item -ItemType Directory -Force -Path $WorktreeRoot | Out-Null

    $isLocal = Test-GitRef "refs/heads/$Branch"
    if (-not $isLocal -and -not (Test-GitRef "refs/remotes/origin/$Branch")) {
        # Not a local branch and not known remotely from the fetch above: ask the remote directly before
        # treating it as new (the general fetch is best effort and may have failed or been partial).
        $onRemote = & git -C $RepoPath ls-remote --heads origin "refs/heads/$Branch"
        if ($LASTEXITCODE -eq 0 -and $onRemote) {
            Write-Host "Branch '$Branch' exists on origin - fetching it." -ForegroundColor Cyan
            Invoke-Git @('fetch', 'origin', "+refs/heads/${Branch}:refs/remotes/origin/$Branch") -AllowFail
        }
    }

    if ($isLocal) {
        Write-Host "Using existing local branch '$Branch'." -ForegroundColor Cyan
        Invoke-Git @('worktree', 'add', $wtPath, $Branch)
    } elseif (Test-GitRef "refs/remotes/origin/$Branch") {
        Write-Host "Using remote branch 'origin/$Branch'." -ForegroundColor Cyan
        Invoke-Git @('worktree', 'add', '--track', '-b', $Branch, $wtPath, "origin/$Branch")
    } else {
        $base = if (Test-GitRef "refs/remotes/origin/$BaseBranch") { "origin/$BaseBranch" } else { $BaseBranch }
        Write-Host "Creating new branch '$Branch' from '$base'." -ForegroundColor Cyan
        Invoke-Git @('worktree', 'add', '--no-track', '-b', $Branch, $wtPath, $base)
    }
}
$wtPath = (Resolve-Path $wtPath).Path

# Restore the stashed changes into the worktree (the stash is shared by all worktrees of the repo).
if ($stashed) {
    Write-Host "Applying stashed changes in the worktree..." -ForegroundColor Cyan
    & git -C $wtPath stash pop
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "git stash pop failed (conflicts?); changes remain in the stash - resolve in the worktree."
    } elseif (& git -C $RepoPath status --porcelain) {
        # The changes now live in the worktree; make sure nothing is left behind in the main clone.
        Write-Host "Undoing leftover changes in the main clone..." -ForegroundColor Cyan
        Invoke-Git @('reset', '--hard')
        Invoke-Git @('clean', '-fd')
    }
    # Changes are gone from the main clone: make Rider's Commit panel notice it.
    Update-RiderWindow ([IO.Path]::GetFileNameWithoutExtension($SolutionName))
}

# --- 3. Copy gitignored / local files --------------------------------------------------------------
Write-Host "Copying gitignored files (appsettings overrides, .claude local settings, ...)" -ForegroundColor Cyan
$skip = '(^|/)(bin|obj|node_modules|\.vs|\.idea|TestResults|packages|\.git)/'
$ignored = & git -c core.quotepath=off -C $RepoPath ls-files --others --ignored --exclude-standard
$copied = 0
foreach ($rel in $ignored) {
    if (-not $rel -or $rel -match $skip) { continue }
    $src = Join-Path $RepoPath $rel
    $dst = Join-Path $wtPath $rel
    if ((Test-Path -LiteralPath $src -PathType Leaf) -and -not (Test-Path -LiteralPath $dst)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst
        $copied++
    }
}
Write-Host "  copied $copied file(s)."

# --- 4. Copy Claude project memory (keyed by directory path) ---------------------------------------
if (-not $SkipMemory) {
    $projects = Join-Path $env:USERPROFILE '.claude\projects'
    $srcMem = Join-Path $projects (Join-Path (Get-ClaudeProjectKey $RepoPath) 'memory')
    $dstMem = Join-Path $projects (Join-Path (Get-ClaudeProjectKey $wtPath) 'memory')
    if ((Test-Path $srcMem) -and -not (Test-Path $dstMem)) {
        New-Item -ItemType Directory -Force -Path $dstMem | Out-Null
        Copy-Item (Join-Path $srcMem '*') $dstMem -Recurse
        Write-Host "Copied Claude memory -> $dstMem"
    }
}

# --- 5. Open Rider ---------------------------------------------------------------------------------
# The Rider CLI has no "reuse window" flag: whether the solution replaces the current window or opens a
# new one is decided by Rider (Settings > Appearance & Behavior > System Settings > Project > Open project in).
$sln = Join-Path $wtPath $SolutionName
if (-not (Test-Path $sln)) { throw "Solution not found: $sln" }
$rider = Find-Rider
if ($ReplaceWindow) { Close-RiderWindow ([IO.Path]::GetFileNameWithoutExtension($SolutionName)) }
Write-Host "Opening Rider: $sln" -ForegroundColor Cyan
Start-Process -FilePath $rider -ArgumentList "`"$sln`""
# Maximize in a detached hidden process so this script returns immediately (callers like Claude Code
# would otherwise wait up to 90 s for the Rider window).
Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-MaximizeOnly', "`"$wtPath`"")

Write-Host "Done. Worktree: $wtPath (branch $Branch)" -ForegroundColor Green
