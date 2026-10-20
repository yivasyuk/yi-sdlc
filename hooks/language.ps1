# Claude Code SessionStart hook: tells Claude which language the yi-sdlc skills write in.
# Reads "- Language: <name>" from the Language section of the repo's .claude/yi-sdlc/project.md (the main clone's
# when run from a worktree); without one, English. The imported sdlc skills hard-code Ukrainian, and the
# sync overwrites them, so the setting is applied here instead. Reads the hook payload (JSON) from stdin.
$payload = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) { $payload = $raw | ConvertFrom-Json }
} catch {}

$cwd = if ($payload -and $payload.cwd) { $payload.cwd } else { (Get-Location).Path }

# The checkout first, then the main clone (a worktree's git common dir is <main>\.git).
$roots = New-Object System.Collections.Generic.List[string]
$top = & git -C $cwd rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $top) { $roots.Add($top) } else { $roots.Add($cwd) }
$common = & git -C $cwd rev-parse --path-format=absolute --git-common-dir 2>$null
if ($LASTEXITCODE -eq 0 -and $common) { $roots.Add((Split-Path $common -Parent)) }

$language = $null
$source = 'the default'
foreach ($root in $roots) {
    $file = Join-Path $root '.claude/yi-sdlc/project.md'
    if (-not (Test-Path $file)) { continue }
    $text = Get-Content $file -Raw -Encoding UTF8
    $section = [regex]::Match($text, '(?ms)^##[ \t]+Language[ \t]*\r?\n(.*?)(?=^##[ \t]|\z)')
    if (-not $section.Success) { continue }
    $line = [regex]::Match($section.Groups[1].Value, '(?m)^[ \t]*-[ \t]*Language:[ \t]*(.+?)[ \t]*\r?$')
    if ($line.Success -and $line.Groups[1].Value -notmatch '^<') {
        $language = $line.Groups[1].Value.Trim('`', ' ')
        $source = '.claude/yi-sdlc/project.md, section Language'
        break
    }
}
if (-not $language) { $language = 'English' }

$context = "yi-sdlc language: $language (from $source). Everything the yi-sdlc skills produce is written in " +
    "${language}: AskUserQuestion questions and options, the documents (idea brief, PRD, CONTEXT, SAD, ADRs, " +
    "data model, contracts, tasks, reviews, changelogs, user docs), tracker comments, PR titles and bodies. " +
    "This overrides any yi-sdlc skill, agent or shared reference that names another language (such as " +
    "'Ukrainian throughout' in skills/_shared/ask-style.md); wording in their examples shows the shape, not " +
    "the language. When dispatching a yi-sdlc agent, tell it to write in $language. Code, identifiers, " +
    "commands, file names and quoted text stay as they are. A document that already exists keeps its " +
    "language unless the user asks to translate it."

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
@{ hookSpecificOutput = @{ hookEventName = 'SessionStart'; additionalContext = $context } } |
    ConvertTo-Json -Compress
