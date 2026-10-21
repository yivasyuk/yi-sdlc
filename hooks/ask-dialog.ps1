param([string]$Auto = '', [string]$Mode = '', [string]$DataDir = '', [switch]$Serve, [string]$Pipe = '')

# Claude Code PreToolUse hook for AskUserQuestion: answer the questions in a desktop window.
#   One window        - every session's questions share one window, a tab per question call titled
#                       project and feature (else the branch), each cut at its width; a tab not opened yet
#                       has an amber line on top. Its buttons and captions speak its questions' language.
#                       The hook hands its call over a named pipe to the window process (-Serve, started on
#                       demand outside the hook's process tree, gone 5 minutes after its last tab) and waits.
#   Submit            - the selected answers; recommended ones are preselected, else a single choice's
#                       first option (a multiple choice starts empty) (Enter)
#   Close             - no output, so Claude Code shows its normal terminal prompt instead (Esc). Only the
#                       shown tab; the window's own close button closes every tab.
#   Keep Recommended  - ticked on Submit, the session's later questions get their recommended options
#                       without a window (marks in keep-recommended\<session id>, swept after 7 days).
#   Read-only texts   - selectable; releasing a selection copies it to the clipboard (Ctrl+A selects all).
#                       Double-click a word and keep the button down: its Ukrainian translation (headless
#                       `claude -p`, Haiku) shows beside the pointer.
#   Message field     - optional free text for Claude; Ctrl+V pastes clipboard images (saved as PNG,
#                       passed as [Image #n] file paths). Sent as additionalContext with Submit/Close.
#   References        - AC-/US- items, ADRs, doc paths and doc sections (PRD §5, sad.md §6.4) a question
#                       mentions are links under it; a click shows that section beside the window.
# State (notification-mode, keep-recommended\) lives in the plugin's data dir: -DataDir, else $env:CLAUDE_PLUGIN_DATA
# (set for plugin hooks), else next to this script. It survives plugin updates; the script's folder does not.
# -Mode desktop|terminal|toggle|status manages the notification mode from a shell (scripts\notification-mode.cmd).
# -Auto submit|close builds the window in this process without showing it (for testing); env
# ASK_DIALOG_NOTE=<text> fills the message field, ASK_DIALOG_IMAGE=<file> attaches an image,
# ASK_DIALOG_WORD=<word> translates that word of the first question as if held after a double-click, ASK_DIALOG_MORE=<payload.json>;... adds more tabs (not opened)
# and ASK_DIALOG_SHOT=<png> saves a picture (with ASK_DIALOG_OPEN=<reference>, e.g. AC-03, also the
# reference window as <png>-ref.png). The window process logs its failures to ask-dialog.log in the data dir.
# Keep this file UTF-8 with BOM: Windows PowerShell needs the BOM to read the Ukrainian strings.

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$dataDir = if ($DataDir) { $DataDir } elseif ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { $PSScriptRoot }
[void](New-Item -ItemType Directory -Force -Path $dataDir)
$modeFile = Join-Path $dataDir 'notification-mode'
function Get-NotificationMode {
    $value = if (Test-Path $modeFile) { (Get-Content -LiteralPath $modeFile -Raw).Trim() } else { '' }
    if ($value -eq 'terminal') { 'terminal' } else { 'desktop' }
}
function Set-NotificationMode([string]$value) {
    [IO.File]::WriteAllText($modeFile, $value)
}

if ($Mode) {
    switch ($Mode.ToLower()) {
        'desktop'  { Set-NotificationMode 'desktop' }
        'terminal' { Set-NotificationMode 'terminal' }
        'toggle'   { Set-NotificationMode $(if ((Get-NotificationMode) -eq 'desktop') { 'terminal' } else { 'desktop' }) }
        'status'   { }
        default    { Write-Output "Unknown value '$Mode'. Use desktop, terminal, toggle or status."; exit 1 }
    }
    $state = if ((Get-NotificationMode) -eq 'terminal') { 'terminal - questions are asked in the terminal' } else { 'desktop - questions open the desktop window' }
    Write-Output "Notification mode: $state"
    exit 0
}

$keepRecommendedDir = Join-Path $dataDir 'keep-recommended'
function Get-KeepRecommendedMark([string]$sessionId) {
    if ($sessionId -notmatch '^[\w-]+$') { return $null }
    Join-Path $keepRecommendedDir $sessionId
}
function Set-KeepRecommendedMark([string]$sessionId) {
    $mark = Get-KeepRecommendedMark $sessionId
    if (-not $mark) { return }
    [void](New-Item -ItemType Directory -Force -Path $keepRecommendedDir)
    Get-ChildItem -LiteralPath $keepRecommendedDir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force
    [IO.File]::WriteAllText($mark, (Get-Date).ToString('o'))
}

function Get-Recommended($q) {
    $opts = @($q.options)
    $rec = @($opts | Where-Object { $_.label -match '\(recommended\)' } | ForEach-Object { $_.label })
    # Nothing marked: a single choice falls back to the first option, a multiple choice starts empty.
    if ($q.multiSelect) { return ,$rec }
    if ($rec.Count -eq 0 -and $opts.Count -gt 0) { $rec = @($opts[0].label) }
    $rec = @($rec | Select-Object -First 1)
    return ,$rec
}

function Get-AnswersOutput($toolInput, $answers, [string]$reason, [string]$context) {
    $toolInput | Add-Member -NotePropertyName answers -NotePropertyValue ([pscustomobject]$answers) -Force
    $result = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'allow'
            permissionDecisionReason = $reason
            updatedInput             = $toolInput
        }
    }
    if ($context) { $result.hookSpecificOutput.additionalContext = $context }
    ConvertTo-Json -InputObject $result -Depth 20 -Compress
}

function Write-Log([string]$text) {
    try { Add-Content -LiteralPath (Join-Path $dataDir 'ask-dialog.log') -Value ('{0:s} {1}' -f (Get-Date), $text) -Encoding UTF8 } catch {}
}

# The window process's pipe (and its lock) are per user and per version of this script, so an updated
# plugin never hands its questions to an older window.
$scriptId = "$PSCommandPath|$((Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.Ticks)"
$sha = [Security.Cryptography.SHA1]::Create()
$pipeName = 'yi-sdlc-ask-dialog-' + $env:USERNAME + '-' +
    (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scriptId)) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') }))
if ($Pipe) { $pipeName = $Pipe }

function Start-Window {
    $dir = $dataDir.TrimEnd('\')
    $arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File ""$PSCommandPath"" -Serve -Pipe $pipeName -DataDir ""$dir"""
    # Through WMI, so the window is no child of this hook: Claude Code may end the hook's process tree
    # (or job) when its question is cancelled, and the window holds other sessions' questions too.
    # Hidden, so its console never flashes (Windows applies that to the dialog's first showing too;
    # Add-RequestTab shows it again). Detached, powershell.exe does not start at all.
    try {
        $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
            CommandLine = "powershell.exe $arguments"; ProcessStartupInformation = $startup }
        if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
    } catch {
        Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden
    }
}

# Sends the hook's payload to the window (starting it when there is none) and returns the hook output
# for its tab: one base64 line each way, the reply as "OK <base64>". A window that drops the call
# (closing for idleness, or failed) gets the call again from a new window, twice at most.
function Send-ToWindow([string]$payloadJson) {
    $request = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $started = $false
    $tries = 0
    $deadline = (Get-Date).AddSeconds(60)
    while ($tries -lt 3 -and (Get-Date) -lt $deadline) {
        $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
        try {
            try { $pipe.Connect(250) } catch {
                if (-not $started) { Start-Window; $started = $true }
                continue
            }
            $tries++
            $writer = New-Object IO.StreamWriter($pipe, [Text.Encoding]::ASCII)
            $writer.WriteLine($request)
            $writer.Flush()
            $reply = (New-Object IO.StreamReader($pipe, [Text.Encoding]::ASCII)).ReadLine()
            if ($reply -and $reply.StartsWith('OK ')) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($reply.Substring(3))) }
            $started = $false
        } finally { $pipe.Dispose() }
    }
    ''
}

# PS 5.1 otherwise serializes some arrays as {"value":[...],"Count":n}.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

# The hook: answer from Keep Recommended, leave it to the terminal, or hand it to the window.
if (-not $Serve) {
    try {
        $rawPayload = [Console]::In.ReadToEnd()
        $payload = $rawPayload | ConvertFrom-Json
        $toolInput = $payload.tool_input
        $questions = @($toolInput.questions)
        if ($questions.Count -eq 0) { exit 0 }

        # Keep Recommended was ticked earlier in this session: answer without asking, in either mode.
        $mark = Get-KeepRecommendedMark $payload.session_id
        if ($mark -and (Test-Path -LiteralPath $mark)) {
            $answers = [ordered]@{}
            foreach ($q in $questions) {
                $rec = Get-Recommended $q
                if ($rec.Count -gt 0) { $answers[$q.question] = $rec -join ', ' }
            }
            [Console]::Out.Write((Get-AnswersOutput $toolInput $answers 'Answered with the recommended options (Keep Recommended)' (
                'The user ticked Keep Recommended earlier in this session, so these questions were not shown to them: ' +
                'each was answered with its recommended option (the first option when none is marked; ' +
                'a multi-select question with none marked is left unanswered).')))
            exit 0
        }

        if ((Get-NotificationMode) -eq 'terminal') { exit 0 }
        if (-not $Auto) {
            [Console]::Out.Write((Send-ToWindow $rawPayload))
            exit 0
        }
    } catch {
        # Any failure falls back to the normal terminal prompt.
        [Console]::Error.WriteLine("ask-dialog: $_")
        exit 0
    }
}

# The window: the window process (-Serve), or with -Auto this process with the one tab.
try {
    if ($Serve) {
        # One window process: a second one waits for a closing one to go, or leaves the calls to it.
        $lock = New-Object Threading.Mutex($false, "Local\$pipeName")
        try { if (-not $lock.WaitOne(5000)) { exit 0 } } catch [Threading.AbandonedMutexException] {}
    }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -Name Native -Namespace ClaudeHook -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
'@
    # The wheel goes to the control under the pointer, and the read-only texts, radio buttons and group boxes
    # inside the question list swallow it; this filter scrolls the shown tab's list instead, wherever the
    # pointer is in it.
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Core -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
namespace ClaudeHook {
    public sealed class WheelRouter : IMessageFilter {
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
        public ScrollableControl Target;
        int pending;
        public bool PreFilterMessage(ref Message m) {
            if (m.Msg != 0x020A) return false;  // WM_MOUSEWHEEL
            return ScrollAt(Control.MousePosition, (short)((long)m.WParam >> 16));
        }
        public bool ScrollAt(Point screen, int delta) {
            ScrollableControl target = Target;
            if (target == null || !target.Visible || !target.RectangleToScreen(target.ClientRectangle).Contains(screen)) return false;
            Control c = Control.FromChildHandle(WindowFromPoint(screen));
            while (c != null && c != target) c = c.Parent;
            if (c == null) return false;
            pending += delta;
            int notches = pending / 120;
            if (notches == 0) return true;  // a touchpad's small steps add up
            pending -= notches * 120;
            int lines = SystemInformation.MouseWheelScrollLines;
            int step = lines < 0 ? target.ClientSize.Height : Math.Max(1, lines) * target.Font.Height;
            int y = Math.Max(0, -target.AutoScrollPosition.Y - notches * step);
            target.AutoScrollPosition = new Point(-target.AutoScrollPosition.X, y);
            return true;
        }
    }
    // Test pictures only: DrawToBitmap leaves a RichTextBox blank, EM_FORMATRANGE draws its text in.
    public static class RichPrint {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct FORMATRANGE { public IntPtr hdc, hdcTarget; public RECT rc, rcPage; public int cpMin, cpMax; }
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, ref FORMATRANGE l);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
        public static void Draw(RichTextBox box, Graphics g, Rectangle r) {
            using (var back = new SolidBrush(box.BackColor)) g.FillRectangle(back, r);
            float x = 1440f / g.DpiX, y = 1440f / g.DpiY;
            IntPtr hdc = g.GetHdc();
            try {
                var fr = new FORMATRANGE { hdc = hdc, hdcTarget = hdc, cpMin = 0, cpMax = -1 };
                fr.rc = new RECT { Left = (int)(r.Left * x), Top = (int)(r.Top * y), Right = (int)(r.Right * x), Bottom = (int)(r.Bottom * y) };
                fr.rcPage = fr.rc;
                SendMessage(box.Handle, 0x0439, (IntPtr)1, ref fr);  // EM_FORMATRANGE
                SendMessage(box.Handle, 0x0439, IntPtr.Zero, IntPtr.Zero);
            } finally { g.ReleaseHdc(hdc); }
        }
    }
    // One hook call: its payload, and the open pipe its hook waits on. Gone turns true when the hook
    // goes away (its question was cancelled); the pipe is overlapped, so Reply writes while Serve waits.
    public sealed class AskRequest {
        readonly NamedPipeServerStream pipe;
        int done;
        public string Payload;
        public volatile bool Gone;
        internal AskRequest(NamedPipeServerStream pipe) { this.pipe = pipe; }
        public void Reply(string output) {
            if (Interlocked.Exchange(ref done, 1) == 1) return;
            try {
                byte[] line = Encoding.ASCII.GetBytes("OK " + Convert.ToBase64String(Encoding.UTF8.GetBytes(output ?? "")) + "\n");
                pipe.Write(line, 0, line.Length);
                pipe.Flush();
                pipe.WaitForPipeDrain();
            } catch { } finally { pipe.Dispose(); }
        }
        // No answer: the hook asks again, of a new window.
        internal void Drop() {
            if (Interlocked.Exchange(ref done, 1) == 0) pipe.Dispose();
        }
        internal void Serve(AskServer server) {
            try {
                var reader = new StreamReader(pipe, Encoding.ASCII);
                string line = reader.ReadLine();
                if (line != null) {
                    Payload = Encoding.UTF8.GetString(Convert.FromBase64String(line.Trim()));
                    if (!server.Enqueue(this)) { Drop(); return; }
                    while (reader.Read() >= 0) { }
                }
            } catch { }
            Gone = true;
            Drop();
        }
    }
    // The window's end of the pipe: accepts hook calls and queues them for the UI thread to take.
    public sealed class AskServer {
        readonly string name;
        readonly object gate = new object();
        bool stopped;
        public readonly ConcurrentQueue<AskRequest> Incoming = new ConcurrentQueue<AskRequest>();
        public AskServer(string name) { this.name = name; }
        public void Start() { new Thread(Listen) { IsBackground = true }.Start(); }
        void Listen() {
            while (true) {
                NamedPipeServerStream pipe = null;
                try {
                    pipe = new NamedPipeServerStream(name, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    pipe.WaitForConnection();
                } catch {
                    if (pipe != null) pipe.Dispose();
                    lock (gate) { if (stopped) return; }
                    Thread.Sleep(250);
                    continue;
                }
                lock (gate) { if (stopped) { pipe.Dispose(); return; } }
                var request = new AskRequest(pipe);
                ThreadPool.QueueUserWorkItem(_ => request.Serve(this));
            }
        }
        internal bool Enqueue(AskRequest request) {
            lock (gate) {
                if (stopped) return false;
                Incoming.Enqueue(request);
                return true;
            }
        }
        // Takes no more calls; the ones not taken yet are dropped, so their hooks start a new window.
        public void Stop() {
            lock (gate) { stopped = true; }
            AskRequest request;
            while (Incoming.TryDequeue(out request)) request.Drop();
            try { using (var wake = new NamedPipeClientStream(".", name, PipeDirection.InOut)) wake.Connect(500); } catch { }
        }
    }
}
'@
    [void][ClaudeHook.Native]::SetProcessDPIAware()
    [Windows.Forms.Application]::EnableVisualStyles()

    $ui = @{
        en = @{
            Title = 'Claude Code needs your answer'; Submit = 'Submit'; Close = 'Close'
            Other = 'Other:'; Project = 'Project'; Branch = 'Branch'; Feature = 'Feature'
            Note = 'Additional information for Claude (optional; Ctrl+V pastes images; Ctrl+Enter submits):'
            ImageTip = 'Image #{0} - click to remove'
            Missing = 'Answer every question ({0} left)'
            Copied = 'Copied to clipboard'
            References = 'References:'; OpenFile = 'Open the file'
            KeepRecommended = 'Keep Recommended'
            KeepRecommendedTip = 'Ticked when you press Submit: every later question in this session is answered with its recommended option, without asking you.'
        }
        uk = @{
            Title = 'Claude Code чекає на вашу відповідь'; Submit = 'Надіслати'; Close = 'Закрити'
            Other = 'Інше:'; Project = 'Проєкт'; Branch = 'Гілка'; Feature = 'Фіча'
            Note = 'Додаткова інформація для Claude (необов''язково; Ctrl+V — вставити зображення; Ctrl+Enter — надіслати):'
            ImageTip = 'Зображення #{0} — клацніть, щоб прибрати'
            Missing = 'Дайте відповідь на всі питання (залишилось {0})'
            Copied = 'Скопійовано в буфер обміну'
            References = 'Посилання:'; OpenFile = 'Відкрити файл'
            KeepRecommended = 'Залишати рекомендовані'
            KeepRecommendedTip = 'Якщо позначено під час «Надіслати»: усі наступні питання цієї сесії отримають рекомендовану відповідь, без запитань до вас.'
        }
    }
    # A call's context: project (the repo's name, also from a worktree; else the cwd), branch, and the SDLC
    # feature (docs/features/<slug>) the branch names, else the one it changes: uncommitted changes first,
    # then its commits since the default branch, newest first. No such feature, or a fix/ or change/
    # branch, no Feature field. Also the repo root and its features, for the references.
    function Get-QuestionContext([string]$cwd) {
        $context = [ordered]@{}
        $root = $null
        $slugs = @()
        if ($cwd) {
            $root = $cwd
            $project = Split-Path -Leaf $root
            $branch = ''
            $changed = @()
            try {
                $ErrorActionPreference = 'Continue'  # git writes to stderr outside a repo
                $repoRoot = git -C $cwd rev-parse --show-toplevel 2>$null
                if ($LASTEXITCODE -eq 0 -and $repoRoot) {
                    $root = $repoRoot
                    $project = Split-Path -Leaf $root
                    # A worktree's folder is named after its branch; the shared .git sits in the main checkout.
                    $commonDir = git -C $root rev-parse --path-format=absolute --git-common-dir 2>$null
                    if ($LASTEXITCODE -eq 0 -and $commonDir -and (Split-Path -Leaf $commonDir) -eq '.git') {
                        $project = Split-Path -Leaf (Split-Path -Parent $commonDir)
                    }
                    $branch = git -C $root rev-parse --abbrev-ref HEAD 2>$null
                    if ($branch -eq 'HEAD') { $branch = 'detached ' + (git -C $root rev-parse --short HEAD 2>$null) }

                    $changed += @(git -C $root -c core.quotepath=off status --porcelain --untracked-files=all -- docs/features 2>$null |
                        ForEach-Object { $_.Substring(3) -replace '^.* -> ', '' })
                    $default = git -C $root rev-parse --abbrev-ref origin/HEAD 2>$null
                    if ($LASTEXITCODE -ne 0 -or -not $default) { $default = 'main' }
                    $base = git -C $root merge-base HEAD $default 2>$null
                    if ($LASTEXITCODE -eq 0 -and $base) {
                        $changed += @(git -C $root -c core.quotepath=off log --format= --name-only "$base..HEAD" -- docs/features 2>$null)
                    }
                }
            } catch {} finally { $ErrorActionPreference = 'Stop' }
            $context['Project'] = $project
            if ($branch) { $context['Branch'] = $branch }

            $featuresDir = Join-Path $root 'docs\features'
            if (Test-Path $featuresDir) {
                $slugs = @(Get-ChildItem -LiteralPath $featuresDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' })
                $slugNames = @($slugs | ForEach-Object { $_.Name })
                # A fix or a change branch works on a ticket, not on a feature.
                if ($branch -notmatch '^(fix|change)/') {
                    $feature = $slugNames | Where-Object { $branch -and $branch -match "(^|[/_-])$([regex]::Escape($_))($|[/_-])" } |
                        Sort-Object { $_.Length } -Descending | Select-Object -First 1
                    if (-not $feature) {
                        $feature = $changed | Where-Object { $_ -match '^"?docs/features/([^/]+)/' } |
                            ForEach-Object { $Matches[1] } | Where-Object { $slugNames -contains $_ } | Select-Object -First 1
                    }
                    if ($feature) { $context['Feature'] = $feature }
                }
            }
        }
        if ($context.Count -eq 0) { $context['Project'] = '(unknown)' }
        @{ Context = $context; Root = $root; Slugs = $slugs }
    }

    $form = New-Object Windows.Forms.Form
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.StartPosition = 'Manual'  # Add-RequestTab places it
    $form.TopMost = $true
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false
    $form.ShowIcon = $false

    $g = $form.CreateGraphics(); $scale = $g.DpiX / 96; $g.Dispose()
    $px = { param($n) [int]($n * $scale) }
    $w = & $px 640
    $bold = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
    $gray = [Drawing.Color]::DimGray
    $tips = New-Object Windows.Forms.ToolTip
    $tips.AutoPopDelay = 30000

    # Read-only text the user can select: a borderless TextBox that looks like a label, sized to its
    # wrapped text (Tag holds the wrap width). Releasing a selection copies it, as in a terminal.
    $textFlags = [Windows.Forms.TextFormatFlags]'WordBreak, TextBoxControl, NoPrefix'
    function Resize-SelectableText($t) {
        $pad = & $px 4
        if ($t -is [Windows.Forms.RichTextBox]) {
            # Rich text sizes itself: full width, height from its own layout (ContentsResized).
            $t.Width = $t.Tag
            [void][ClaudeHook.Native]::SendMessage($t.Handle, 0x0441, [IntPtr]::Zero, [IntPtr]::Zero)  # EM_REQUESTRESIZE
            return
        }
        $size = [Windows.Forms.TextRenderer]::MeasureText($t.Text, $t.Font, (New-Object Drawing.Size(($t.Tag - $pad), [int]::MaxValue)), $textFlags)
        $t.Size = New-Object Drawing.Size(($size.Width + $pad), ($size.Height + (& $px 2)))
    }
    function Copy-Selection($t) {
        if ($t.SelectionLength -eq 0) { return }
        try {
            [Windows.Forms.Clipboard]::SetText((Get-Copied $t.SelectedText))
            Show-Status $ui[$script:current.Lang].Copied $false
        } catch {}
    }

    # Double-click a word and keep the button down: its Ukrainian translation shows beside the pointer, from
    # a headless `claude -p` given the text around it (cached per word and text). Released sooner, the
    # double-click only selects and copies, as before.
    $claudeExe = (Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $claudeExe) { $claudeExe = Join-Path $HOME '.local\bin\claude.exe' }
    $wordTip = New-Object Windows.Forms.ToolTip
    $script:hold = $null
    $script:wordCache = @{}
    $script:wordJobs = New-Object Collections.ArrayList
    $holdTimer = New-Object Windows.Forms.Timer
    $holdTimer.Interval = 400
    $holdTimer.add_Tick({
        $holdTimer.Stop()
        $h = $script:hold
        if ($h -and ([Windows.Forms.Control]::MouseButtons -band [Windows.Forms.MouseButtons]::Left)) { Show-WordTranslation $h }
    })
    function Start-WordHold($box, $e) {
        if ($e.Button -ne 'Left' -or $e.Clicks -lt 2) { return }
        $script:hold = @{ Box = $box; Fired = $false }
        $holdTimer.Stop()
        $holdTimer.Start()
    }
    # True when the hold showed a translation, so the release does not also copy.
    function Stop-WordHold {
        $holdTimer.Stop()
        $fired = $script:hold -and $script:hold.Fired
        $script:hold = $null
        $fired
    }
    function Show-WordTranslation($h) {
        $box = $h.Box
        $word = (Get-Copied $box.SelectedText).Trim()
        if (-not $word -or $word.Length -gt 80 -or $word -notmatch '[A-Za-z]') { return }
        $h.Fired = $true
        $at = $box.PointToClient([Windows.Forms.Control]::MousePosition)
        $at.Offset(0, (& $px 22))
        $key = "$word|$(Get-Copied $box.Text)"
        if ($script:wordCache.ContainsKey($key)) { $wordTip.Show("$word → $($script:wordCache[$key])", $box, $at, 15000); return }
        $wordTip.Show("$word → …", $box, $at, 60000)

        $quote = { param($s) '"' + ($s -replace '"', '\"') + '"' }
        $system = 'You translate one English word or short phrase into Ukrainian, as it is meant in the given text. ' +
            'Reply with the translation only: a word or a few, plus one alternative after a comma only when the meaning is unclear.'
        $workDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-ask-dialog'
        [void](New-Item -ItemType Directory -Force -Path $workDir)
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $claudeExe
        $psi.Arguments = '-p --model haiku --effort low --setting-sources project --strict-mcp-config --tools "" --no-session-persistence ' +
            "--disable-slash-commands --output-format text --system-prompt $(& $quote $system)"
        $psi.WorkingDirectory = $workDir
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $psi.EnvironmentVariables.Remove('CLAUDECODE')
        $psi.EnvironmentVariables['MAX_THINKING_TOKENS'] = '0'  # thinking makes it 4 s -> 20-40 s
        try {
            $proc = [Diagnostics.Process]::Start($psi)
            $stdin = New-Object IO.StreamWriter($proc.StandardInput.BaseStream, [Text.UTF8Encoding]::new($false))
            $stdin.Write("Word: $word`nText: $(Get-Copied $box.Text)")
            $stdin.Close()
            [void]$script:wordJobs.Add(@{ Word = $word; Key = $key; Box = $box; At = $at; Process = $proc
                Output = $proc.StandardOutput.ReadToEndAsync(); Watch = [Diagnostics.Stopwatch]::StartNew() })
            $wordTimer.Start()
        } catch {
            $wordTip.Show("$word → ?", $box, $at, 5000)
        }
    }
    $wordTimer = New-Object Windows.Forms.Timer
    $wordTimer.Interval = 200
    $wordTimer.add_Tick({
        foreach ($job in @($script:wordJobs)) {
            $done = $job.Output.IsCompleted
            if (-not $done -and $job.Watch.Elapsed.TotalSeconds -lt 60) { continue }
            $script:wordJobs.Remove($job)
            if (-not $done) { try { $job.Process.Kill() } catch {} }
            $text = if ($done) { "$($job.Output.Result)".Trim() } else { '' }
            if ($text) { $script:wordCache[$job.Key] = $text } else { $text = '?' }
            if (-not $job.Box.IsDisposed) { $wordTip.Show("$($job.Word) → $text", $job.Box, $job.At, 15000) }
        }
        if ($script:wordJobs.Count -eq 0) { $wordTimer.Stop() }
    })
    # -Linkable: rich text whose specification codes (AC-03, ADR-0019, PRD §5...) are links; see Set-Links.
    function New-SelectableText([int]$maxWidth, $font, $foreColor, $backColor, [switch]$Linkable) {
        $t = if ($Linkable) { New-Object Windows.Forms.RichTextBox } else { New-Object Windows.Forms.TextBox }
        $t.ReadOnly = $true
        $t.Multiline = $true
        $t.WordWrap = $true
        $t.AutoSize = $false
        $t.BorderStyle = 'None'
        $t.TabStop = $false
        $t.Font = $font
        $t.BackColor = $backColor  # also makes a read-only TextBox honour ForeColor
        $t.ForeColor = $foreColor
        $t.Tag = $maxWidth
        $t.add_HandleCreated({ param($sender) [void][ClaudeHook.Native]::SendMessage($sender.Handle, 0xD3, [IntPtr]3, [IntPtr]::Zero) })  # EM_SETMARGINS: none
        if ($Linkable) {
            $t.DetectUrls = $false
            $t.ScrollBars = 'None'
            $t.Cursor = [Windows.Forms.Cursors]::IBeam
            $t.Width = $maxWidth
            $t.Height = $font.Height + (& $px 2)
            $t.add_ContentsResized({
                param($sender, $e)
                $height = $e.NewRectangle.Height + (& $px 2)
                if ($sender.Height -ne $height) { $sender.Height = $height }
            })
            $t.add_MouseMove({ param($sender, $e) Update-LinkHover $sender $e })
            $t.add_MouseUp({ param($sender, $e) if ($e.Button -eq 'Left' -and $sender.SelectionLength -eq 0) { Open-LinkAt $sender $e.Location } })
            [void]$t.Handle  # lay out now, so the window's height is right before it shows
        }
        $t.add_TextChanged({ param($sender) Resize-SelectableText $sender; if ($sender -is [Windows.Forms.RichTextBox]) { Format-Links $sender } })
        $t.add_FontChanged({ param($sender) Resize-SelectableText $sender })
        $t.add_MouseDown({ param($sender, $e) Start-WordHold $sender $e })
        $t.add_MouseUp({ param($sender) if (-not (Stop-WordHold)) { Copy-Selection $sender } })
        $t.add_KeyDown({
            param($sender, $e)
            if ($e.Control -and $e.KeyCode -eq 'A') { $sender.SelectAll(); $e.SuppressKeyPress = $true }
        })
        $t.add_KeyUp({ param($sender) Copy-Selection $sender })
        Resize-SelectableText $t
        $t
    }

    # A question's text on a control (GroupBox titles need '&' doubled).
    function Set-QuestionText($control, [string]$text, [switch]$Amp) {
        if ($control -is [Windows.Forms.RichTextBox]) { $text = Protect-Codes $text }
        $control.Text = if ($amp) { $text -replace '&', '&&' } else { $text }
    }
    # Codes keep to one line: inside each, a non-breaking hyphen and space, and a narrow no-break space after §.
    # Get-Plain turns the hyphen and space back (same length, so matched positions hold; the § patterns
    # allow the joiner); Get-Copied also drops the joiner, for the clipboard.
    $nbHyphen = [char]0x2011
    $nbSpace = [char]0x00A0
    $joiner = [char]0x202F  # narrow no-break space: "§ 6", never wrapped
    function Get-Plain([string]$s) { $s.Replace($nbHyphen, '-').Replace($nbSpace, ' ') }
    function Get-Copied([string]$s) { (Get-Plain $s).Replace([string]$joiner, '') }
    function Protect-Codes([string]$text) {
        if (-not $script:refRoot -or -not $text) { return $text }
        $out = New-Object Text.StringBuilder
        $pos = 0
        foreach ($m in (Get-Mentions $text)) {
            [void]$out.Append($text.Substring($pos, $m.Start - $pos))
            foreach ($ch in $text.Substring($m.Start, $m.End - $m.Start).ToCharArray()) {
                switch ($ch) {
                    '-' { [void]$out.Append($nbHyphen) }
                    ' ' { [void]$out.Append($nbSpace) }
                    '§' { [void]$out.Append($ch).Append($joiner) }
                    default { [void]$out.Append($ch) }
                }
            }
            $pos = $m.End
        }
        $out.Append($text.Substring($pos)).ToString()
    }

    $wheel = New-Object ClaudeHook.WheelRouter
    [Windows.Forms.Application]::AddMessageFilter($wheel)

    # The tab strip on a dark band, a tab per question call; under it the shown tab's page.
    $headerColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $valueFont = New-Object Drawing.Font('Segoe UI Semibold', 13)
    $pathColor = [Drawing.Color]::FromArgb(125, 211, 252)
    $strip = New-Object Windows.Forms.FlowLayoutPanel
    $strip.Dock = 'Top'
    $strip.AutoSize = $true
    $strip.WrapContents = $true
    $strip.BackColor = [Drawing.Color]::FromArgb(8, 11, 20)
    $strip.Padding = New-Object Windows.Forms.Padding((& $px 8), (& $px 6), (& $px 8), 0)
    $pages = New-Object Windows.Forms.Panel
    $pages.Dock = 'Fill'

    # A tab's head: the project, then the feature (else the branch), each in its own colour and cut with
    # an ellipsis past its width (the tooltip has them whole). On a near-black band: the shown tab lighter,
    # with a blue line along its bottom; one not opened yet has an amber line along its top.
    $tabFont = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $tabWidths = @{ Project = (& $px 140); Feature = (& $px 200); Branch = (& $px 200) }
    function Get-Trimmed([string]$text, $font, [int]$max) {
        $fits = { param($s) [Windows.Forms.TextRenderer]::MeasureText($s, $font).Width -le $max }
        if (& $fits $text) { return $text }
        $n = $text.Length
        while ($n -gt 1 -and -not (& $fits ($text.Substring(0, $n) + '…'))) { $n-- }
        $text.Substring(0, $n).TrimEnd(' ', '-', '_', '/') + '…'
    }
    $titleColors = @{
        Project = [Drawing.Color]::White
        Branch  = [Drawing.Color]::FromArgb(125, 211, 252)
        Feature = [Drawing.Color]::FromArgb(134, 239, 172)
    }
    $tabBack = @{ Current = [Drawing.Color]::FromArgb(51, 65, 85); Other = $headerColor }
    $unvisitedLine = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(251, 191, 36))
    $currentLine = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(56, 189, 248))
    function New-TabHead($tab) {
        $head = New-Object Windows.Forms.FlowLayoutPanel
        $head.AutoSize = $true
        $head.WrapContents = $false
        $head.Margin = New-Object Windows.Forms.Padding(0, (& $px 2), (& $px 4), 0)
        $head.Padding = New-Object Windows.Forms.Padding((& $px 12), (& $px 8), (& $px 12), (& $px 7))
        $head.Cursor = [Windows.Forms.Cursors]::Hand
        $head.Tag = $tab
        $head.add_Click({ param($sender) Select-Tab (Get-OwnerTab $sender) })
        $head.add_Paint({
            param($sender, $e)
            if (-not $sender.Tag.Visited) { $e.Graphics.FillRectangle($unvisitedLine, 0, 0, $sender.Width, (& $px 3)) }
            if ($sender.Tag -eq $script:current) { $e.Graphics.FillRectangle($currentLine, 0, $sender.Height - (& $px 3), $sender.Width, (& $px 3)) }
        })
        $tab.TitleLabels = @()
        $rows = [ordered]@{ Project = $tab.Context['Project'] }
        if ($tab.Context['Feature']) { $rows.Feature = $tab.Context['Feature'] } elseif ($tab.Context['Branch']) { $rows.Branch = $tab.Context['Branch'] }
        foreach ($key in $rows.Keys) {
            $label = New-Object Windows.Forms.Label
            $label.AutoSize = $true
            $label.UseMnemonic = $false
            $label.Font = $tabFont
            $label.ForeColor = $titleColors[$key]
            $label.Text = Get-Trimmed $rows[$key] $tabFont $tabWidths[$key]
            $label.Margin = New-Object Windows.Forms.Padding(0, 0, (& $px 2), 0)
            $label.add_Click({ param($sender) Select-Tab (Get-OwnerTab $sender) })
            $head.Controls.Add($label)
            $tab.TitleLabels += $label
        }
        $head
    }
    function Update-TabHead($tab) {
        $tab.Head.BackColor = if ($tab -eq $script:current) { $tabBack.Current } else { $tabBack.Other }
        $tab.Head.Invalidate()
    }

    # References the questions mention, resolved to a section of a file under the repo's docs/:
    # AC-03 / US-02 (heading in docs/features/<slug>/PRD.md or spec.md), ADR-0019 (whole file in docs/adr
    # or docs/features/*/adr), docs/.../x.md with §5 or #anchor, and PRD|SAD|spec|... §6.4. Features are
    # tried in order: the first one the question names (else the tab's questions), the title's feature,
    # then the most recently edited. Each tab resolves against its own repo (Use-Tab).
    function Get-NamedFeature([string]$text, [string[]]$slugs) {
        $first = $null
        foreach ($slug in $slugs) {
            $hit = [regex]::Match($text, "(?<![\w-])$([regex]::Escape($slug))(?![\w-])")
            if ($hit.Success -and (-not $first -or $hit.Index -lt $first.Index)) { $first = @{ Index = $hit.Index; Slug = $slug } }
        }
        if ($first) { $first.Slug } else { '' }
    }
    $docNames = @{ prd = 'PRD.md'; sad = 'sad.md'; spec = 'spec.md'; 'data-model' = 'data-model.md'; 'test-plan' = 'test-plan.md'
        'idea-brief' = 'idea-brief.md'; 'design-spec' = 'design-spec.md' }
    # Order matters: a path wins over a PRD § or an AC inside it.
    $refPatterns = @(
        @{ Kind = 'file'; Re = [regex]'(?<![\w/.\\-])((?:docs|src|web|tests|scripts|\.claude)/[\w./-]*\w\.(?:md|cs|tsx?|json|ya?ml|sql|ps1))(?:\s*§[\s⁠]*(\d+(?:\.\d+)*)|#([\w-]+))?' }
        @{ Kind = 'doc'; Re = [regex]'(?i)\b(PRD|SAD|spec|data-model|test-plan|idea-brief|design-spec)(?:\.md)?\s*§[\s⁠]*(\d+(?:\.\d+)*)' }
        @{ Kind = 'adr'; Re = [regex]'(?i)\bADR[-\s]?(\d{1,4})\b' }
        @{ Kind = 'item'; Re = [regex]'\b(AC|US)-(\d{1,3})([a-z]?)\b' }
    )
    $headingRe = [regex]'^(#{1,6})\s+(.*?)\s*#*\s*$'
    $fenceRe = [regex]'^\s*(```|~~~)'

    function Get-Mentions([string]$text) {
        $found = New-Object Collections.ArrayList
        foreach ($p in $refPatterns) {
            foreach ($x in $p.Re.Matches($text)) {
                if ($found | Where-Object { $x.Index -lt $_.End -and $_.Start -lt ($x.Index + $x.Length) }) { continue }
                $g = $x.Groups
                $m = switch ($p.Kind) {
                    'file' {
                        $name = $g[1].Value.Substring($g[1].Value.LastIndexOf('/') + 1)
                        $key = if ($g[2].Success) { "$name §$($g[2].Value)" } elseif ($g[3].Success) { "$name#$($g[3].Value)" } else { $name }
                        @{ Path = $g[1].Value; Section = $g[2].Value; Anchor = $g[3].Value; Key = $key }
                    }
                    'doc' { $doc = $docNames[$g[1].Value.ToLower()]; @{ Doc = $doc; Section = $g[2].Value; Key = "$doc §$($g[2].Value)" } }
                    'adr' { $n = [int]$g[1].Value; @{ Num = $n; Key = 'ADR-{0:D4}' -f $n } }
                    'item' { $n = [int]$g[2].Value; @{ Prefix = $g[1].Value; Num = $n; Suffix = $g[3].Value; Key = '{0}-{1:D2}{2}' -f $g[1].Value, $n, $g[3].Value } }
                }
                $m.Kind = $p.Kind; $m.Start = $x.Index; $m.End = $x.Index + $x.Length
                [void]$found.Add($m)
            }
        }
        $seen = @{}
        @($found | Sort-Object { $_.Start } | Where-Object { if ($seen.ContainsKey($_.Key)) { $false } else { $seen[$_.Key] = $true; $true } })
    }

    function Read-DocLines([string]$rel) {
        $abs = Join-Path $script:refRoot $rel
        if (-not (Test-Path -LiteralPath $abs -PathType Leaf)) { return $null }
        , [IO.File]::ReadAllLines($abs, [Text.Encoding]::UTF8)
    }

    # The first heading whose text passes $test, and the lines up to the next heading of its level or above.
    function Find-Section([string[]]$lines, [scriptblock]$test) {
        $fence = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($fenceRe.IsMatch($lines[$i])) { $fence = -not $fence; continue }
            if ($fence) { continue }
            $h = $headingRe.Match($lines[$i])
            if (-not $h.Success -or -not (& $test $h.Groups[2].Value)) { continue }
            $level = $h.Groups[1].Value.Length
            $inner = $false
            for ($end = $i + 1; $end -lt $lines.Count; $end++) {
                if ($fenceRe.IsMatch($lines[$end])) { $inner = -not $inner; continue }
                if ($inner) { continue }
                $next = $headingRe.Match($lines[$end])
                if ($next.Success -and $next.Groups[1].Value.Length -le $level) { break }
            }
            return @{ Start = $i; End = $end; Title = $h.Groups[2].Value }
        }
        $null
    }
    function Get-NumberedTest([string]$section) {
        $re = [regex]('^§?\s*' + [regex]::Escape($section) + '(?:\.|\s|$)')
        { param($t) $re.IsMatch($t) }.GetNewClosure()
    }

    function New-Ref([string]$key, [string]$rel, [string[]]$lines, $section, [string]$feature) {
        if ($section) {
            $body = $lines[$section.Start..($section.End - 1)]; $line = $section.Start + 1; $title = $section.Title
        } else {
            $body = $lines; $line = 1
            $title = @($lines | Where-Object { $headingRe.IsMatch($_) } | Select-Object -First 1) -replace '^#+\s*', ''
            if (-not $title) { $title = $rel.Substring($rel.LastIndexOf('/') + 1) }
        }
        [pscustomobject]@{ Key = $key; Feature = $feature; Path = $rel; Abs = (Join-Path $script:refRoot $rel); Line = $line; Title = "$title"; Lines = @($body) }
    }

    function Resolve-Reference($m) {
        switch ($m.Kind) {
            'item' {
                $re = [regex]"^$($m.Prefix)-0*$($m.Num)$($m.Suffix)(?!\w)"
                $test = { param($t) $re.IsMatch($t) }.GetNewClosure()
                foreach ($slug in $script:featureOrder) {
                    foreach ($doc in 'PRD.md', 'spec.md') {
                        $rel = "docs/features/$slug/$doc"
                        $lines = Read-DocLines $rel
                        $s = if ($lines) { Find-Section $lines $test }
                        if ($s) { return New-Ref $m.Key $rel $lines $s $slug }
                    }
                }
            }
            'adr' {
                $prefix = '{0:D4}-' -f $m.Num
                foreach ($dir in @('docs/adr') + @($script:featureOrder | ForEach-Object { "docs/features/$_/adr" })) {
                    $abs = Join-Path $script:refRoot $dir
                    if (-not (Test-Path -LiteralPath $abs)) { continue }
                    $file = Get-ChildItem -LiteralPath $abs -File -Filter "$prefix*.md" | Select-Object -First 1
                    if ($file) { $rel = "$dir/$($file.Name)"; return New-Ref $m.Key $rel (Read-DocLines $rel) $null '' }
                }
            }
            'file' {
                $lines = Read-DocLines $m.Path
                if ($lines) {
                    $anchor = $m.Anchor.ToLower()
                    $s = if ($m.Section) { Find-Section $lines (Get-NumberedTest $m.Section) }
                         elseif ($anchor) {
                             # GitHub's heading anchor; a closure sees no script functions, so it is inline.
                             Find-Section $lines { param($t) (($t.ToLower() -replace '[^\p{L}\p{N}\s_-]', '').Trim() -replace '\s', '-') -eq $anchor }.GetNewClosure()
                         }
                    return New-Ref $m.Key $m.Path $lines $s ''
                }
            }
            'doc' {
                $test = Get-NumberedTest $m.Section
                foreach ($slug in $script:featureOrder) {
                    $rel = "docs/features/$slug/$($m.Doc)"
                    $lines = Read-DocLines $rel
                    $s = if ($lines) { Find-Section $lines $test }
                    if ($s) { return New-Ref $m.Key $rel $lines $s $slug }
                }
            }
        }
        $null
    }
    # Cached per feature order, since AC-03 is a different AC in each feature.
    $script:featureOrder = @()
    function Get-Reference($m) {
        $cacheKey = "$($script:featureOrder -join ',')|$($m.Key)"
        if (-not $script:refCache.ContainsKey($cacheKey)) {
            $r = $null
            try { $r = Resolve-Reference $m } catch { [Console]::Error.WriteLine("ask-dialog: reference $($m.Key): $_") }
            $script:refCache[$cacheKey] = $r
        }
        $script:refCache[$cacheKey]
    }

    # The reference window: one, beside the dialog, showing the clicked section; a second click on the
    # same link, Esc or its close button hides it.
    $script:viewer = $null
    $script:shownRef = $null
    function New-ReferenceViewer {
        $f = New-Object Windows.Forms.Form
        $f.Font = $form.Font
        $f.ShowIcon = $false
        $f.MinimizeBox = $false
        $f.ShowInTaskbar = $false
        $f.TopMost = $true
        $f.KeyPreview = $true
        $f.StartPosition = 'Manual'
        $f.ClientSize = New-Object Drawing.Size((& $px 620), (& $px 480))

        $head = New-Object Windows.Forms.FlowLayoutPanel
        $head.Dock = 'Top'
        $head.AutoSize = $true
        $head.FlowDirection = 'TopDown'
        $head.WrapContents = $false
        $head.BackColor = $headerColor
        $head.Padding = New-Object Windows.Forms.Padding((& $px 14), (& $px 10), (& $px 14), (& $px 10))
        $title = New-SelectableText (& $px 590) $valueFont ([Drawing.Color]::White) $headerColor
        $title.Margin = New-Object Windows.Forms.Padding(0)
        $path = New-Object Windows.Forms.LinkLabel
        $path.AutoSize = $true
        $path.Margin = New-Object Windows.Forms.Padding(0, (& $px 4), 0, 0)
        $path.LinkColor = $pathColor
        $path.ActiveLinkColor = [Drawing.Color]::White
        $path.LinkBehavior = 'HoverUnderline'
        $path.add_LinkClicked({
            if ($script:shownRef) { try { Start-Process -FilePath $script:shownRef.Abs } catch { Show-Status "$_" $true } }
        })
        $head.Controls.AddRange(@($title, $path))

        # The body is HTML in the WebBrowser control (IE11 engine): a .md section rendered, any other file as code.
        $body = New-Object Windows.Forms.WebBrowser
        $body.Dock = 'Fill'
        $body.ScriptErrorsSuppressed = $true
        $body.AllowWebBrowserDrop = $false
        # Links leave the window: a page anchor scrolls, anything else opens in its own app.
        $body.add_Navigating({
            param($sender, $e)
            $url = $e.Url
            if ($url.Scheme -eq 'about' -and -not $url.Fragment) { return }
            $e.Cancel = $true
            if ($url.Fragment -and ($url.Scheme -eq 'about' -or $url.AbsolutePath.EndsWith('/'))) {
                $target = $sender.Document.GetElementById($url.Fragment.TrimStart('#'))
                if ($target) { $target.ScrollIntoView($true) }
                return
            }
            $where = if ($url.IsFile) { $url.LocalPath } else { $url.AbsoluteUri }
            try { Start-Process -FilePath $where } catch { Show-Status "$_" $true }
        })
        $body.add_PreviewKeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { $sender.FindForm().Close() } })

        $f.Controls.Add($body)
        $f.Controls.Add($head)
        $f.add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq 'Escape') { $sender.Close() } })
        $f.add_FormClosed({ $script:shownRef = $null; Update-ReferenceLinks })
        @{ Form = $f; Title = $title; Path = $path; Body = $body }
    }

    # Markdown to HTML, enough for the docs: headings, paragraphs, nested lists and task lists, tables,
    # fenced code, quotes, rules, frontmatter; inline code, links, bold, italic, strikethrough.
    $encode = { param($s) [Net.WebUtility]::HtmlEncode($s) }
    function ConvertTo-InlineHtml([string]$s) {
        $codes = New-Object Collections.ArrayList
        $s = [regex]::Replace($s, '(`+)(.+?)\1', [Text.RegularExpressions.MatchEvaluator] {
            param($m) [void]$codes.Add($m.Groups[2].Value.Trim()); "%%CODE$($codes.Count - 1)%%" })
        $s = & $encode $s
        $s = $s -replace '!\[([^\]]*)\]\(([^)\s]+)[^)]*\)', '<em>[$1]</em>'
        $s = $s -replace '\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)', '<a href="$2">$1</a>'
        $s = $s -replace '&lt;(https?://[^\s&]+)&gt;', '<a href="$1">$1</a>'
        $s = $s -replace '\*\*(.+?)\*\*', '<strong>$1</strong>' -replace '(?<!\w)__(.+?)__(?!\w)', '<strong>$1</strong>'
        $s = $s -replace '(?<![\w*])\*(?![\s*])(.+?)(?<![\s*])\*(?![\w*])', '<em>$1</em>' -replace '(?<![\w])_(?![\s_])(.+?)(?<![\s_])_(?!\w)', '<em>$1</em>'
        $s = $s -replace '~~(.+?)~~', '<del>$1</del>'
        [regex]::Replace($s, '%%CODE(\d+)%%', [Text.RegularExpressions.MatchEvaluator] {
            param($m) '<code>' + (& $encode $codes[[int]$m.Groups[1].Value]) + '</code>' })
    }
    function Split-TableRow([string]$line) {
        $cells = ($line.Trim() -replace '^\|', '' -replace '(?<!\\)\|$', '') -split '(?<!\\)\|'
        @($cells | ForEach-Object { $_.Trim() -replace '\\\|', '|' })
    }
    function ConvertTo-MarkdownHtml([string[]]$lines) {
        $out = New-Object Text.StringBuilder
        $para = New-Object Collections.ArrayList
        $lists = New-Object Collections.ArrayList  # open lists, innermost last: @{ Indent; Tag }
        $listItemRe = [regex]'^(\s*)([-*+]|\d+[.)])\s+(.*)$'
        $tableSepRe = [regex]'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$'
        $flush = {
            if ($para.Count) { [void]$out.Append('<p>' + (ConvertTo-InlineHtml ($para -join ' ')) + "</p>`n"); $para.Clear() }
        }
        $closeLists = {
            param($deeperThan)
            while ($lists.Count -and $lists[$lists.Count - 1].Indent -gt $deeperThan) {
                [void]$out.Append("</li></$($lists[$lists.Count - 1].Tag)>`n"); $lists.RemoveAt($lists.Count - 1)
            }
        }
        $i = 0
        # Frontmatter at the top of a file: shown as a small key/value block.
        if ($lines.Count -gt 1 -and $lines[0].Trim() -eq '---') {
            $end = [Array]::FindIndex($lines, 1, [Predicate[string]] { param($l) $l.Trim() -eq '---' })
            if ($end -gt 1) {
                [void]$out.Append('<pre class="front">' + (& $encode (($lines[1..($end - 1)]) -join "`n")) + "</pre>`n")
                $i = $end + 1
            }
        }
        $wasBlank = $false
        for (; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if (-not $line.Trim()) { & $flush; $wasBlank = $true; continue }
            $item = $listItemRe.Match($line)
            $indent = $line.Length - $line.TrimStart().Length
            # A list ends at a blank line followed by text that is neither an item nor indented under one.
            if ($lists.Count -and $wasBlank -and -not $item.Success -and $indent -lt 2) { & $closeLists -1 }
            $wasBlank = $false

            if ($fenceRe.IsMatch($line)) {
                & $flush; & $closeLists -1
                $fenceMark = $line.Trim().Substring(0, 3)
                $lang = $line.Trim().Substring(3).Trim()
                $code = New-Object Collections.ArrayList
                for ($i++; $i -lt $lines.Count -and -not $lines[$i].Trim().StartsWith($fenceMark); $i++) { [void]$code.Add($lines[$i]) }
                $class = if ($lang) { " class=""lang-$(& $encode $lang)""" } else { '' }
                [void]$out.Append("<pre$class><code>" + (& $encode ($code -join "`n")) + "</code></pre>`n")
                continue
            }
            $h = $headingRe.Match($line)
            if ($h.Success) {
                & $flush; & $closeLists -1
                $n = $h.Groups[1].Value.Length
                $text = $h.Groups[2].Value
                $id = (($text.ToLower() -replace '[^\p{L}\p{N}\s_-]', '').Trim() -replace '\s', '-')
                [void]$out.Append("<h$n id=""$(& $encode $id)"">" + (ConvertTo-InlineHtml $text) + "</h$n>`n")
                continue
            }
            if ($line -match '^\s*([-*_])(\s*\1){2,}\s*$') { & $flush; & $closeLists -1; [void]$out.Append("<hr>`n"); continue }
            if ($line.TrimStart().StartsWith('<!--')) {
                for (; $i -lt $lines.Count -and -not $lines[$i].Contains('-->'); $i++) {}
                continue
            }
            if ($line.TrimStart().StartsWith('>')) {
                & $flush; & $closeLists -1
                $quote = New-Object Collections.ArrayList
                for (; $i -lt $lines.Count -and $lines[$i].TrimStart().StartsWith('>'); $i++) { [void]$quote.Add(($lines[$i].TrimStart() -replace '^>\s?', '')) }
                $i--
                [void]$out.Append('<blockquote>' + (ConvertTo-MarkdownHtml $quote) + "</blockquote>`n")
                continue
            }
            if ($line.TrimStart().StartsWith('|') -and $i + 1 -lt $lines.Count -and $tableSepRe.IsMatch($lines[$i + 1])) {
                & $flush; & $closeLists -1
                $aligns = @(Split-TableRow $lines[$i + 1] | ForEach-Object {
                    if ($_ -match '^:-+:$') { ' style="text-align:center"' } elseif ($_ -match '-:$') { ' style="text-align:right"' } else { '' } })
                $cell = { param($tag, $cells) $k = 0; ($cells | ForEach-Object { "<$tag$($aligns[$k])>" + (ConvertTo-InlineHtml $_) + "</$tag>"; $k++ }) -join '' }
                [void]$out.Append('<table><thead><tr>' + (& $cell 'th' (Split-TableRow $line)) + '</tr></thead><tbody>')
                for ($i += 2; $i -lt $lines.Count -and $lines[$i].TrimStart().StartsWith('|'); $i++) {
                    [void]$out.Append('<tr>' + (& $cell 'td' (Split-TableRow $lines[$i])) + '</tr>')
                }
                $i--
                [void]$out.Append("</tbody></table>`n")
                continue
            }
            if ($item.Success) {
                & $flush
                $tag = if ($item.Groups[2].Value -match '\d') { 'ol' } else { 'ul' }
                & $closeLists $indent
                $top = if ($lists.Count) { $lists[$lists.Count - 1] } else { $null }
                if ($top -and $top.Indent -eq $indent -and $top.Tag -ne $tag) { & $closeLists ($indent - 1); $top = $null }
                if ($top -and $top.Indent -eq $indent) {
                    [void]$out.Append("</li>`n<li>")
                } else {
                    [void]$out.Append("<$tag><li>")
                    [void]$lists.Add(@{ Indent = $indent; Tag = $tag })
                }
                $text = $item.Groups[3].Value
                $task = [regex]::Match($text, '^\[([ xX])\]\s+')
                if ($task.Success) {
                    $mark = if ($task.Groups[1].Value -eq ' ') { '&#9744;' } else { '&#9745;' }
                    $text = $text.Substring($task.Length)
                    [void]$out.Append("<span class=""task"">$mark</span> ")
                }
                [void]$out.Append((ConvertTo-InlineHtml $text))
                continue
            }
            if ($lists.Count) { [void]$out.Append(' ' + (ConvertTo-InlineHtml $line.Trim())); continue }
            [void]$para.Add($line.Trim())
        }
        & $flush; & $closeLists -1
        $out.ToString()
    }

    # The section without its own heading (the window's title already says it), as a page.
    function Set-ReferenceBody($browser, $ref) {
        $lines = @($ref.Lines)
        $isMarkdown = $ref.Path -match '\.md$'
        if ($isMarkdown) {
            $own = [Array]::FindIndex([string[]]$lines, [Predicate[string]] {
                param($l) $m = $headingRe.Match($l); $m.Success -and $m.Groups[2].Value -eq $ref.Title })
            if ($own -ge 0) { $lines = @($lines | Select-Object -First $own) + @($lines | Select-Object -Skip ($own + 1)) }
            $content = ConvertTo-MarkdownHtml $lines
        } else {
            $content = '<pre><code>' + (& $encode ($lines -join "`n")) + '</code></pre>'
        }
        $base = 'file:///' + ((Split-Path -Parent $ref.Abs) -replace '\\', '/') + '/'
        $font = [int](14 * $scale)
        $browser.DocumentText = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="X-UA-Compatible" content="IE=edge">
<base href="$(& $encode $base)">
<style>
body { font-family: 'Segoe UI', sans-serif; font-size: ${font}px; line-height: 1.5; color: #1f2328; margin: 0; padding: 0.8em 1.2em 1.5em; }
h1, h2 { border-bottom: 1px solid #d1d9e0; padding-bottom: .25em; } h1 { font-size: 1.6em; } h2 { font-size: 1.35em; }
h3 { font-size: 1.15em; } h4, h5, h6 { font-size: 1em; } h1, h2, h3, h4, h5, h6 { margin: 1.1em 0 .5em; font-weight: 600; }
p, ul, ol, table, pre, blockquote { margin: 0 0 .8em; } ul, ol { padding-left: 1.8em; } li { margin: .15em 0; }
a { color: #0969da; text-decoration: none; } a:hover { text-decoration: underline; }
code { font-family: Consolas, monospace; font-size: .9em; background: #eff1f3; padding: .1em .35em; border-radius: 4px; }
pre { background: #f6f8fa; padding: .8em 1em; border-radius: 6px; overflow: auto; }
pre code { background: none; padding: 0; font-size: .88em; line-height: 1.35; }
pre.front { font-family: Consolas, monospace; font-size: .85em; color: #59636e; border: 1px solid #d1d9e0; background: #fafbfc; }
blockquote { color: #59636e; border-left: .25em solid #d1d9e0; margin-left: 0; padding: 0 1em; }
table { border-collapse: collapse; } th, td { border: 1px solid #d1d9e0; padding: .35em .75em; vertical-align: top; }
th { background: #f6f8fa; font-weight: 600; } tr:nth-child(even) td { background: #fbfcfd; }
hr { border: 0; border-top: 1px solid #d1d9e0; margin: 1.2em 0; } .task { font-size: 1.1em; }
</style></head><body>
$content
</body></html>
"@
    }

    $script:refLinks = New-Object Collections.ArrayList
    function Update-ReferenceLinks {
        foreach ($l in $script:refLinks) {
            $l.LinkBehavior = if ($l.Tag -eq $script:shownRef) { 'AlwaysUnderline' } else { 'HoverUnderline' }
        }
    }
    function Show-Reference($ref) {
        $v = $script:viewer
        $isOpen = $v -and -not $v.Form.IsDisposed -and $v.Form.Visible
        if ($isOpen -and $script:shownRef -eq $ref) { $v.Form.Close(); return }
        if (-not $v -or $v.Form.IsDisposed) { $v = New-ReferenceViewer; $script:viewer = $v }
        $script:shownRef = $ref
        $v.Form.Text = $ref.Key + $(if ($ref.Feature) { " · $($ref.Feature)" })
        $v.Title.Text = $ref.Title
        $v.Path.Text = "$($ref.Path):$($ref.Line)"
        $tips.SetToolTip($v.Path, $ui[$script:current.Lang].OpenFile)
        Set-ReferenceBody $v.Body $ref
        Update-ReferenceLinks
        $v.Form.ActiveControl = $v.Path  # no caret blinking in the text
        if ($isOpen) { $v.Form.Activate(); return }
        $area = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $gap = & $px 8
        $v.Form.Height = [Math]::Min([Math]::Max($form.Height, (& $px 360)), $area.Height)
        $x = $form.Right + $gap
        if ($x + $v.Form.Width -gt $area.Right) { $x = $form.Left - $v.Form.Width - $gap }
        if ($x -lt $area.Left) { $x = $area.Right - $v.Form.Width }
        $y = [Math]::Min([Math]::Max($area.Top, $form.Top), $area.Bottom - $v.Form.Height)
        $v.Form.Location = New-Object Drawing.Point($x, $y)
        $v.Form.Show($form)
    }

    # Codes inside the question and option texts: a resolvable one keeps the text's font and is only tinted,
    # a muted blue a little lighter than the text around it; hovering shows a hand and where it leads, a click
    # opens it in the reference window, dragging still selects and copies.
    $linkColor = [Drawing.Color]::FromArgb(66, 100, 145)      # beside the near-black question text
    $linkColorDim = [Drawing.Color]::FromArgb(96, 128, 168)   # beside the grey option descriptions
    $script:links = @{}
    function Set-Links($tab, $t, $color) {
        $script:links[$t] = @{ Tab = $tab; Order = @($script:featureOrder); Color = $color; Ranges = @(); Hover = $null }
    }
    function Format-Links($t) {
        $info = $script:links[$t]
        if (-not $info) { return }
        Use-Tab $info.Tab
        if (-not $script:refRoot) { return }
        $script:featureOrder = $info.Order
        $info.Ranges = @(Get-Mentions (Get-Plain $t.Text) | ForEach-Object {
            $ref = Get-Reference $_
            if ($ref) { @{ Start = $_.Start; Length = $_.End - $_.Start; Ref = $ref } } })
        $info.Hover = $null
        # New text takes on the formatting at its start, which may be a link's: reset it all first.
        $t.SelectAll()
        $t.SelectionFont = $t.Font
        $t.SelectionColor = $t.ForeColor
        $t.SelectionBackColor = $t.BackColor
        foreach ($r in $info.Ranges) {
            $t.Select($r.Start, $r.Length)
            $t.SelectionColor = $info.Color
        }
        $t.Select(0, 0)
        [void][ClaudeHook.Native]::SendMessage($t.Handle, 0x0441, [IntPtr]::Zero, [IntPtr]::Zero)  # EM_REQUESTRESIZE
    }
    # The link under a point: the character there must really be under the pointer, not just the nearest.
    function Get-LinkAt($t, [Drawing.Point]$point) {
        $info = $script:links[$t]
        if (-not $info -or $info.Ranges.Count -eq 0) { return $null }
        $i = $t.GetCharIndexFromPosition($point)
        $at = $t.GetPositionFromCharIndex($i)
        $next = if ($i + 1 -lt $t.TextLength) { $t.GetPositionFromCharIndex($i + 1) } else { $null }
        $right = if ($next -and $next.Y -eq $at.Y -and $next.X -gt $at.X) { $next.X } else { $at.X + $t.Font.Height }
        $lineHeight = $t.Font.Height + (& $px 3)
        if ($point.X -lt $at.X - 1 -or $point.X -gt $right -or $point.Y -lt $at.Y -or $point.Y -gt $at.Y + $lineHeight) { return $null }
        foreach ($r in $info.Ranges) { if ($i -ge $r.Start -and $i -lt $r.Start + $r.Length) { return $r } }
        $null
    }
    function Update-LinkHover($t, $e) {
        $info = $script:links[$t]
        if (-not $info) { return }
        $r = if ($e.Button -eq 'None') { Get-LinkAt $t $e.Location } else { $null }
        if ($r -eq $info.Hover) { return }
        $info.Hover = $r
        $t.Cursor = if ($r) { [Windows.Forms.Cursors]::Hand } else { [Windows.Forms.Cursors]::IBeam }
        $tip = if ($r) {
            $from = if ($r.Ref.Feature) { " · $($r.Ref.Feature)" } else { '' }
            "$($r.Ref.Key)$from — $($r.Ref.Title)`n$($r.Ref.Path):$($r.Ref.Line)"
        } else { $null }
        $tips.SetToolTip($t, $tip)
    }
    function Open-LinkAt($t, [Drawing.Point]$point) {
        $r = Get-LinkAt $t $point
        if ($r) { Show-Reference $r.Ref }
    }

    # Images: hooks can only pass text, so each image is a file whose path goes to Claude as [Image #n].
    $imageDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-ask-dialog\images'
    [void](New-Item -ItemType Directory -Force -Path $imageDir)
    Get-ChildItem -LiteralPath $imageDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

    # Tabs: one per question call, each a hashtable (IsTab) on its page's and its head's Tag. Event handlers
    # run long after Add-QuestionTab returns, so they find their tab from the control (Get-OwnerTab).
    $script:tabs = New-Object Collections.ArrayList
    $script:current = $null
    function Get-OwnerTab($control) {
        for ($c = $control; $c; $c = $c.Parent) { if ($c.Tag -is [hashtable] -and $c.Tag.IsTab) { return $c.Tag } }
        $null
    }
    # Reference lookups go to the tab's repo.
    function Use-Tab($tab) {
        $script:refRoot = $tab.RefRoot
        $script:refCache = $tab.RefCache
    }

    function Add-QuestionTab($payload, $request) {
        $questions = @($payload.tool_input.questions)
        $found = Get-QuestionContext $payload.cwd
        $context = $found.Context
        $allText = ($questions | ForEach-Object { $_.question; $_.header; @($_.options) | ForEach-Object { $_.label; $_.description } }) -join ' '
        $second = if ($context['Feature']) { $context['Feature'] } else { $context['Branch'] }
        # The tab's own texts (buttons, captions) speak the questions' language.
        $tab = @{
            IsTab = $true; Payload = $payload; Request = $request; Context = $context
            Title = $context['Project'] + $(if ($second) { " · $second" })
            Lang = $(if ($allText -match '[Ѐ-ӿ]') { 'uk' } else { 'en' })
            Visited = $false; RefCache = @{}; Entries = @(); OtherLabels = @(); RefCaptions = @()
            Attachments = [Collections.ArrayList]::new(); ImageCount = 0
        }
        $root = $found.Root
        $tab.RefRoot = if ($root -and (Test-Path -LiteralPath (Join-Path $root 'docs'))) { $root } else { $null }
        $byEdit = @()
        if ($tab.RefRoot -and $found.Slugs) {
            $edited = { param($dir) 'PRD.md', 'spec.md', 'sad.md' | ForEach-Object { Join-Path $dir $_ } |
                Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
                Sort-Object -Descending | Select-Object -First 1 }
            $byEdit = @($found.Slugs | Sort-Object -Descending { & $edited $_.FullName } | ForEach-Object { $_.Name })
        }
        Use-Tab $tab
        $tabFeature = Get-NamedFeature $allText $byEdit

        $page = New-Object Windows.Forms.Panel
        $page.Dock = 'Fill'
        $page.Visible = $false
        $page.Tag = $tab
        $tab.Page = $page
        $main = New-Object Windows.Forms.FlowLayoutPanel
        $main.Dock = 'Fill'
        $main.FlowDirection = 'TopDown'
        $main.WrapContents = $false
        $main.AutoScroll = $true
        $main.Padding = New-Object Windows.Forms.Padding((& $px 12))
        $tab.Main = $main

        for ($i = 0; $i -lt $questions.Count; $i++) {
            $q = $questions[$i]
            $rec = Get-Recommended $q

            $box = New-Object Windows.Forms.GroupBox
            Set-QuestionText $box $(if ($q.header) { $q.header } else { "Question $($i + 1)" }) -Amp
            $box.AutoSize = $true
            $box.AutoSizeMode = 'GrowAndShrink'
            $box.MinimumSize = New-Object Drawing.Size($w, 0)
            $box.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (& $px 10))

            $inner = New-Object Windows.Forms.FlowLayoutPanel
            $inner.FlowDirection = 'TopDown'
            $inner.WrapContents = $false
            $inner.AutoSize = $true
            $inner.AutoSizeMode = 'GrowAndShrink'
            $inner.Location = New-Object Drawing.Point((& $px 10), (& $px 24))
            $box.Controls.Add($inner)

            # This question's features, in the order its references are looked up.
            $named = ''
            if ($tab.RefRoot) {
                $qText = @($q.question; @($q.options) | ForEach-Object { $_.label; $_.description; $_.preview }) -join "`n"
                $named = Get-NamedFeature $qText $byEdit
                if (-not $named) { $named = $tabFeature }
                $script:featureOrder = @(@($named, $context['Feature']) + $byEdit | Where-Object { $_ } | Select-Object -Unique)
            }

            $text = New-SelectableText ($w - (& $px 30)) $bold $form.ForeColor $form.BackColor -Linkable
            Set-Links $tab $text $linkColor
            Set-QuestionText $text $q.question
            $text.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (& $px 6))
            $inner.Controls.Add($text)

            # The question and descriptions link their codes in place; codes only in option labels or previews,
            # which cannot hold links, get a row of their own.
            $refs = @()
            if ($tab.RefRoot) {
                $inText = @(@($q.question) + @(@($q.options) | ForEach-Object { $_.description }) | Where-Object { $_ } |
                    ForEach-Object { Get-Mentions $_ } | ForEach-Object { Get-Reference $_ } | Where-Object { $_ })
                $seen = @{}
                $refs = @(@(@($q.options) | ForEach-Object { $_.label; $_.preview }) | Where-Object { $_ } |
                    ForEach-Object { Get-Mentions $_ } | ForEach-Object { Get-Reference $_ } |
                    Where-Object { $_ -and $inText -notcontains $_ -and -not $seen.ContainsKey($_.Key) } | ForEach-Object { $seen[$_.Key] = $true; $_ })
            }
            if ($refs.Count -gt 0) {
                $refRow = New-Object Windows.Forms.FlowLayoutPanel
                $refRow.AutoSize = $true
                $refRow.WrapContents = $true
                $refRow.MaximumSize = New-Object Drawing.Size(($w - (& $px 30)), 0)
                $refRow.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (& $px 6))
                $refCaption = New-Object Windows.Forms.Label
                $refCaption.AutoSize = $true
                $refCaption.ForeColor = $gray
                $refCaption.Margin = New-Object Windows.Forms.Padding(0, 0, (& $px 4), 0)
                $tab.RefCaptions += $refCaption
                $refRow.Controls.Add($refCaption)
                foreach ($ref in $refs) {
                    $link = New-Object Windows.Forms.LinkLabel
                    $link.AutoSize = $true
                    $link.UseMnemonic = $false
                    # Say which feature an AC or a § came from when the questions did not name it.
                    $link.Text = if ($ref.Feature -and $ref.Feature -ne $named) { "$($ref.Key) · $($ref.Feature)" } else { $ref.Key }
                    $link.Tag = $ref
                    $link.LinkBehavior = 'HoverUnderline'
                    $link.LinkColor = $linkColorDim
                    $link.ActiveLinkColor = $linkColor
                    $link.VisitedLinkColor = $linkColorDim
                    $link.Margin = New-Object Windows.Forms.Padding(0, 0, (& $px 10), 0)
                    $tips.SetToolTip($link, "$($ref.Title)`n$($ref.Path):$($ref.Line)")
                    $link.add_LinkClicked({ param($sender) Show-Reference $sender.Tag })
                    [void]$script:refLinks.Add($link)
                    $refRow.Controls.Add($link)
                }
                $inner.Controls.Add($refRow)
            }

            $choices = @()
            foreach ($o in @($q.options)) {
                $c = if ($q.multiSelect) { New-Object Windows.Forms.CheckBox } else { New-Object Windows.Forms.RadioButton }
                Set-QuestionText $c $o.label
                $c.Tag = $o.label
                $c.UseMnemonic = $false
                $c.AutoSize = $true
                $c.Margin = New-Object Windows.Forms.Padding((& $px 3), (& $px 2), 0, 0)
                if ($rec -contains $o.label) { $c.Font = $bold; $c.Checked = $true }
                if ($o.preview) { $tips.SetToolTip($c, $o.preview) }
                $inner.Controls.Add($c)
                $choices += $c

                if ($o.description) {
                    $d = New-SelectableText ($w - (& $px 60)) $form.Font $gray $form.BackColor -Linkable
                    Set-Links $tab $d $linkColorDim
                    Set-QuestionText $d $o.description
                    $d.Margin = New-Object Windows.Forms.Padding((& $px 22), 0, 0, (& $px 4))
                    $inner.Controls.Add($d)
                }
            }

            $row = New-Object Windows.Forms.FlowLayoutPanel
            $row.AutoSize = $true
            $row.WrapContents = $false
            $row.Margin = New-Object Windows.Forms.Padding(0, (& $px 6), 0, 0)
            $otherLabel = New-Object Windows.Forms.Label
            $otherLabel.AutoSize = $true
            $otherLabel.Margin = New-Object Windows.Forms.Padding(0, (& $px 5), (& $px 4), 0)
            $tab.OtherLabels += $otherLabel
            $other = New-Object Windows.Forms.TextBox
            $other.Width = $w - (& $px 110)
            $row.Controls.AddRange(@($otherLabel, $other))
            $inner.Controls.Add($row)

            $main.Controls.Add($box)
            $tab.Entries += [pscustomobject]@{ Question = $q; Choices = $choices; Other = $other }
        }

        # Free-text message for Claude, sent as additionalContext with whatever button closes the tab.
        $notePanel = New-Object Windows.Forms.FlowLayoutPanel
        $notePanel.Dock = 'Bottom'
        $notePanel.AutoSize = $true
        $notePanel.FlowDirection = 'TopDown'
        $notePanel.WrapContents = $false
        $notePanel.Padding = New-Object Windows.Forms.Padding((& $px 12), (& $px 8), (& $px 12), 0)
        $noteLabel = New-Object Windows.Forms.Label
        $noteLabel.AutoSize = $true
        $noteLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (& $px 3))
        $note = New-Object Windows.Forms.TextBox
        $note.Multiline = $true
        $note.AcceptsReturn = $true
        $note.ScrollBars = 'Vertical'
        $note.MaxLength = 9000
        $note.Size = New-Object Drawing.Size(($w + (& $px 14)), (& $px 64))
        $note.Margin = New-Object Windows.Forms.Padding(0)
        $attachPanel = New-Object Windows.Forms.FlowLayoutPanel
        $attachPanel.AutoSize = $true
        $attachPanel.Visible = $false
        $attachPanel.Margin = New-Object Windows.Forms.Padding(0, (& $px 4), 0, 0)
        $notePanel.Controls.AddRange(@($noteLabel, $note, $attachPanel))
        $note.add_KeyDown({
            param($sender, $e)
            if ($e.Control -and $e.KeyCode -eq 'Return') {
                $e.SuppressKeyPress = $true
                (Get-OwnerTab $sender).Submit.PerformClick()
            } elseif (($e.Control -and $e.KeyCode -eq 'V') -or ($e.Shift -and $e.KeyCode -eq 'Insert')) {
                if (Add-ClipboardImages (Get-OwnerTab $sender)) { $e.SuppressKeyPress = $true }
            }
        })
        $tab.NotePanel = $notePanel; $tab.NoteLabel = $noteLabel; $tab.Note = $note; $tab.AttachPanel = $attachPanel

        # The bottom row: Keep Recommended on the left, the buttons (and the status) from the right.
        $bar = New-Object Windows.Forms.TableLayoutPanel
        $bar.Dock = 'Bottom'
        $bar.AutoSize = $true
        $bar.ColumnCount = 2
        $bar.RowCount = 1
        [void]$bar.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
        [void]$bar.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
        [void]$bar.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
        $bar.Padding = New-Object Windows.Forms.Padding((& $px 10))
        $keepRecommended = New-Object Windows.Forms.CheckBox
        $keepRecommended.AutoSize = $true
        $keepRecommended.Anchor = 'Left'
        $keepRecommended.Checked = [bool]$env:ASK_DIALOG_KEEP
        $bar.Controls.Add($keepRecommended, 0, 0)
        $buttons = New-Object Windows.Forms.FlowLayoutPanel
        $buttons.FlowDirection = 'RightToLeft'
        $buttons.AutoSize = $true
        $buttons.Dock = 'Fill'
        $buttons.Margin = New-Object Windows.Forms.Padding(0)
        $bar.Controls.Add($buttons, 1, 0)
        $mkButton = {
            $b = New-Object Windows.Forms.Button
            $b.AutoSize = $true
            $b.MinimumSize = New-Object Drawing.Size((& $px 100), (& $px 32))
            $buttons.Controls.Add($b)
            $b
        }
        $closeBtn = & $mkButton
        $submitBtn = & $mkButton
        $status = New-Object Windows.Forms.Label
        $status.AutoSize = $true
        $status.Margin = New-Object Windows.Forms.Padding(0, (& $px 8), (& $px 10), 0)
        $buttons.Controls.Add($status)
        $closeBtn.add_Click({ param($sender) Complete-Tab (Get-OwnerTab $sender) 'close' })
        $submitBtn.add_Click({
            param($sender)
            $owner = Get-OwnerTab $sender
            $missing = @($owner.Entries | Where-Object { -not ($_.Choices | Where-Object Checked) -and -not $_.Other.Text.Trim() })
            if ($missing.Count -gt 0) { Show-Status ($ui[$owner.Lang].Missing -f $missing.Count) $true $owner; return }
            Complete-Tab $owner 'submit'
        })
        $tab.Bar = $bar; $tab.Keep = $keepRecommended; $tab.Submit = $submitBtn; $tab.Close = $closeBtn; $tab.Status = $status

        $page.Controls.Add($main)
        $page.Controls.Add($notePanel)
        $page.Controls.Add($bar)
        $pages.Controls.Add($page)
        $tab.Head = New-TabHead $tab
        $strip.Controls.Add($tab.Head)
        [void]$script:tabs.Add($tab)
        Set-TabTexts $tab
        if ($script:current) { Update-WindowTitle } else { Select-Tab $tab }
    }

    function Select-Tab($tab) {
        if (-not $tab -or $script:current -eq $tab) { return }
        Close-Reference
        $old = $script:current
        $script:current = $tab
        $tab.Visited = $true
        $tab.Page.Visible = $true
        if ($old) { $old.Page.Visible = $false; Update-TabHead $old }
        Update-TabHead $tab
        $wheel.Target = $tab.Main
        $form.AcceptButton = $tab.Submit
        $form.CancelButton = $tab.Close
        Update-WindowTitle
        if ($form.Visible) { [void]$tab.Submit.Focus() }
    }

    function Update-WindowTitle {
        $tab = $script:current
        if (-not $tab) { return }
        $count = if ($script:tabs.Count -gt 1) { " ($($script:tabs.Count))" } else { '' }
        $form.Text = $ui[$tab.Lang].Title + $count + ' - ' + ($tab.Context.Values -join ' | ')
    }

    function Close-Reference {
        $v = $script:viewer
        if ($v -and -not $v.Form.IsDisposed -and $v.Form.Visible) { $v.Form.Close() }
    }

    # A tab is done: its answers (or nothing, for the terminal prompt) go to its hook, and the tab goes.
    function Complete-Tab($tab, [string]$mode) {
        $output = Get-TabOutput $tab $mode
        if ($tab.Request) { $tab.Request.Reply($output) } else { [Console]::Out.Write($output) }
        Remove-Tab $tab
    }

    function Remove-Tab($tab) {
        $index = $script:tabs.IndexOf($tab)
        if ($index -lt 0) { return }
        $script:tabs.RemoveAt($index)
        foreach ($key in @($script:links.Keys)) { if ($script:links[$key].Tab -eq $tab) { $script:links.Remove($key) } }
        foreach ($l in @($script:refLinks)) { if ((Get-OwnerTab $l) -eq $tab) { $script:refLinks.Remove($l) } }
        if ($script:current -eq $tab) {
            Close-Reference
            $script:current = $null
            if ($script:tabs.Count) { Select-Tab $script:tabs[[Math]::Min($index, $script:tabs.Count - 1)] }
        }
        $strip.Controls.Remove($tab.Head)
        $pages.Controls.Remove($tab.Page)
        $tab.Head.Dispose()
        $tab.Page.Dispose()
        if ($script:tabs.Count -eq 0) {
            $wheel.Target = $null
            $form.Hide()
            $script:idleSince = Get-Date
        } else {
            Update-WindowTitle
            Update-FormHeight
        }
    }

    function Get-TabOutput($tab, [string]$mode) {
        $noteText = $tab.Note.Text.Trim()
        $imageBlock = ''
        if ($tab.Attachments.Count) {
            $imageBlock = "`n`nAttached images (open each with the Read tool before replying):`n" +
                (($tab.Attachments | ForEach-Object { "[Image #$($_.Number)]: $($_.Path)" }) -join "`n")
        }
        $noteContext = if ($noteText -or $imageBlock) { "Additional message from the user, written in the question dialog:`n$noteText$imageBlock" } else { '' }

        if ($mode -eq 'close') {
            # Closed without answering: the terminal prompt follows, but the message still reaches Claude.
            if (-not $noteContext) { return '' }
            $result = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $noteContext } }
            return (ConvertTo-Json -InputObject $result -Depth 5 -Compress)
        }

        # Answers always use the original question and option texts, whatever language is shown.
        $answers = [ordered]@{}
        foreach ($entry in $tab.Entries) {
            $labels = @($entry.Choices | Where-Object Checked | ForEach-Object { $_.Tag })
            $typed = $entry.Other.Text.Trim()
            if ($typed) { $labels = if ($entry.Question.multiSelect) { $labels + $typed } else { @($typed) } }
            if ($labels.Count -gt 0) { $answers[$entry.Question.question] = $labels -join ', ' }
        }

        if ($tab.Keep.Checked) {
            Set-KeepRecommendedMark $tab.Payload.session_id
            $keepNote = 'The user ticked Keep Recommended: their later questions in this session are answered with the recommended options without being shown.'
            $noteContext = if ($noteContext) { "$noteContext`n`n$keepNote" } else { $keepNote }
        }
        Get-AnswersOutput $tab.Payload.tool_input $answers 'Answered in the desktop dialog' $noteContext
    }

    function Add-Attachment($tab, [string]$path, [bool]$owned) {
        $tab.ImageCount++
        $n = $tab.ImageCount
        $pb = New-Object Windows.Forms.PictureBox
        $pb.Size = New-Object Drawing.Size((& $px 64), (& $px 64))
        $pb.SizeMode = 'Zoom'
        $pb.BorderStyle = 'FixedSingle'
        $pb.Cursor = [Windows.Forms.Cursors]::Hand
        try { $pb.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($path)))) }
        catch { $pb.BackColor = [Drawing.Color]::Gainsboro }
        $item = [pscustomobject]@{ Number = $n; Path = $path; Owned = $owned; Box = $pb }
        $pb.Tag = $item
        $tips.SetToolTip($pb, ($ui[$tab.Lang].ImageTip -f $n) + "`n" + $path)
        $pb.add_Click({ param($sender) Remove-Attachment (Get-OwnerTab $sender) $sender.Tag })
        [void]$tab.Attachments.Add($item)
        $tab.AttachPanel.Controls.Add($pb)
        $tab.AttachPanel.Visible = $true
        $tab.Note.SelectedText = "[Image #$n] "
        Update-FormHeight
    }
    function Remove-Attachment($tab, $item) {
        $tab.Attachments.Remove($item)
        $tab.AttachPanel.Controls.Remove($item.Box)
        if ($item.Box.Image) { $item.Box.Image.Dispose() }
        $item.Box.Dispose()
        if ($item.Owned) { Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue }
        $note = $tab.Note
        $note.Text = $note.Text.Replace("[Image #$($item.Number)] ", '').Replace("[Image #$($item.Number)]", '')
        $tab.AttachPanel.Visible = $tab.Attachments.Count -gt 0
        Update-FormHeight
    }
    function Add-ClipboardImages($tab) {
        if ([Windows.Forms.Clipboard]::ContainsImage()) {
            $img = [Windows.Forms.Clipboard]::GetImage()
            $path = Join-Path $imageDir ('image-{0:yyyyMMdd-HHmmss-fff}.png' -f (Get-Date))
            $img.Save($path, [Drawing.Imaging.ImageFormat]::Png)
            $img.Dispose()
            Add-Attachment $tab $path $true
            return $true
        }
        if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $files = @([Windows.Forms.Clipboard]::GetFileDropList() | Where-Object { $_ -match '\.(png|jpe?g|gif|bmp|webp)$' })
            foreach ($file in $files) { Add-Attachment $tab $file $false }
            return $files.Count -gt 0
        }
        return $false
    }

    function Show-Status([string]$text, [bool]$isError, $tab = $script:current) {
        if (-not $tab) { return }
        $tab.Status.ForeColor = if ($isError) { [Drawing.Color]::Firebrick } else { $gray }
        $tab.Status.Text = $text
    }

    $form.Controls.Add($pages)
    $form.Controls.Add($strip)
    $clientWidth = $w + (& $px 50)
    # As tall as the tallest tab, so switching tabs keeps the window still.
    function Update-FormHeight {
        $pageHeight = 0
        foreach ($tab in $script:tabs) {
            $height = $tab.Main.GetPreferredSize((New-Object Drawing.Size(($w + (& $px 40)), 0))).Height +
                $tab.NotePanel.PreferredSize.Height + $tab.Bar.PreferredSize.Height
            $pageHeight = [Math]::Max($pageHeight, $height)
        }
        $contentHeight = $pageHeight + $strip.GetPreferredSize((New-Object Drawing.Size($clientWidth, 0))).Height
        $maxHeight = [int]([Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height * 0.85)
        $form.ClientSize = New-Object Drawing.Size($clientWidth, [Math]::Min($contentHeight, $maxHeight))
    }

    # The tab's own texts, in its questions' language.
    function Set-TabTexts($tab) {
        $t = $ui[$tab.Lang]
        foreach ($l in $tab.OtherLabels) { $l.Text = $t.Other }
        foreach ($l in $tab.RefCaptions) { $l.Text = $t.References }
        $tab.NoteLabel.Text = $t.Note
        $tab.Submit.Text = $t.Submit
        $tab.Close.Text = $t.Close
        $tab.Keep.Text = $t.KeepRecommended
        $tips.SetToolTip($tab.Keep, $t.KeepRecommendedTip)
        $whole = ($tab.Context.Keys | ForEach-Object { "$($t[$_]): $($tab.Context[$_])" }) -join "`n"
        foreach ($c in @($tab.Head) + $tab.TitleLabels) { $tips.SetToolTip($c, $whole) }
        Update-TabHead $tab
        Update-FormHeight
    }

    # The window's close button closes every tab; Esc and Close only the shown one.
    $form.add_FormClosing({
        param($sender, $e)
        if ($e.CloseReason -ne 'UserClosing') { return }
        $e.Cancel = $true
        foreach ($tab in @($script:tabs)) { Complete-Tab $tab 'close' }
    })
    $form.add_Shown({ $form.Activate(); if ($script:current) { [void]$script:current.Submit.Focus() } })

    if ($Auto) {
        [void](Add-QuestionTab $payload $null)
        $tab = $script:tabs[0]
        foreach ($more in @("$env:ASK_DIALOG_MORE" -split ';' | Where-Object { $_ })) {
            [void](Add-QuestionTab ([IO.File]::ReadAllText($more) | ConvertFrom-Json) $null)
        }
        if ($env:ASK_DIALOG_NOTE) { $tab.Note.Text = $env:ASK_DIALOG_NOTE + ' ' }
        if ($env:ASK_DIALOG_IMAGE) { $tab.Note.SelectionStart = $tab.Note.TextLength; Add-Attachment $tab $env:ASK_DIALOG_IMAGE $false }
        if ($env:ASK_DIALOG_WORD) {
            # As if held after a double-click on that word in the first question.
            $box = $tab.Entries[0].Choices[0].Parent.Controls[0]
            $box.Select($box.Text.IndexOf($env:ASK_DIALOG_WORD), $env:ASK_DIALOG_WORD.Length)
            Show-WordTranslation @{ Box = $box; Fired = $false }
            while ($script:wordJobs.Count) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
            $key = "$($env:ASK_DIALOG_WORD)|$(Get-Copied $box.Text)"
            [Console]::Error.WriteLine("word: $($env:ASK_DIALOG_WORD) -> $(if ($script:wordCache.ContainsKey($key)) { $script:wordCache[$key] } else { '(failed)' })")
        }
        [Console]::Error.WriteLine("title: $($form.Text) [$($tab.Lang)]")
        foreach ($t in $script:tabs) {
            [Console]::Error.WriteLine("tab: $($t.Title) [$($t.Lang)]$(if ($t -eq $tab) { ' (shown)' } elseif (-not $t.Visited) { ' (not opened)' })")
        }
        foreach ($key in $tab.RefCache.Keys) {
            $r = $tab.RefCache[$key]
            [Console]::Error.WriteLine("reference: $key -> $(if ($r) { "$($r.Path):$($r.Line) ($($r.Lines.Count) lines) $($r.Title)" } else { '(not found)' })")
        }
        if ($env:ASK_DIALOG_WHEEL) {
            # Wheel check: shown nearly transparent at the screen's corner (hit-testing needs a real window),
            # one notch down over each kind of control; the question list must scroll, the message box not.
            $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(0, 0); $form.Opacity = 0.01
            $form.Show(); [Windows.Forms.Application]::DoEvents()
            $main = $tab.Main
            $firstInner = $tab.Entries[0].Choices[0].Parent
            $probes = [ordered]@{
                'question text' = $firstInner.Controls[0]
                'radio button'  = $tab.Entries[0].Choices[0]
                'description'   = @($firstInner.Controls | Where-Object { $_ -is [Windows.Forms.TextBoxBase] -and $_.Multiline })[1]
                'references'    = @($firstInner.Controls | Where-Object { $_ -is [Windows.Forms.FlowLayoutPanel] })[0]
                'other field'   = $tab.Entries[0].Other
                'group box'     = $firstInner.Parent
                'message box'   = $tab.Note
            }
            foreach ($name in $probes.Keys) {
                $c = $probes[$name]
                if (-not $c) { [Console]::Error.WriteLine("wheel: $name -> (not in this dialog)"); continue }
                $main.AutoScrollPosition = New-Object Drawing.Point(0, 0); [Windows.Forms.Application]::DoEvents()
                $r = $c.RectangleToScreen($c.ClientRectangle)
                $point = New-Object Drawing.Point(($r.Left + 3), ($r.Top + [int]($r.Height / 2)))
                $taken = $wheel.ScrollAt($point, -120)
                [Console]::Error.WriteLine("wheel: $name -> taken=$taken, list scrolled to $(-$main.AutoScrollPosition.Y)")
            }
            # Link hit-testing: the middle of each code finds it; the space after a line's end finds nothing.
            foreach ($rich in @($script:links.Keys | Where-Object { $script:links[$_].Tab -eq $tab })) {
                foreach ($r in $script:links[$rich].Ranges) {
                    $at = $rich.GetPositionFromCharIndex($r.Start + [int]($r.Length / 2))
                    $hit = Get-LinkAt $rich (New-Object Drawing.Point(($at.X + 2), ($at.Y + 4)))
                    [Console]::Error.WriteLine("link: $($r.Ref.Key) -> $(if ($hit) { $hit.Ref.Key } else { '(missed)' })")
                }
                $hit = Get-LinkAt $rich (New-Object Drawing.Point(($rich.Width - 2), 4))
                [Console]::Error.WriteLine("link: past the first line's end -> $(if ($hit) { $hit.Ref.Key } else { 'nothing' })")
            }
            $form.Hide(); $form.Opacity = 1
        }
        if ($env:ASK_DIALOG_SHOT) {
            $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-5000, -5000)
            $form.Show(); [Windows.Forms.Application]::DoEvents()
            $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.SetResolution((96 * $scale), (96 * $scale))
            $sg = [Drawing.Graphics]::FromImage($bmp)
            $view = $tab.Main.RectangleToScreen($tab.Main.ClientRectangle)
            foreach ($rich in @($script:links.Keys)) {
                $on = $rich.RectangleToScreen($rich.ClientRectangle)
                if (-not $rich.Visible -or -not $view.Contains($on)) { continue }
                $on.Offset(-$form.Left, -$form.Top)
                [ClaudeHook.RichPrint]::Draw($rich, $sg, $on)
            }
            $sg.Dispose()
            $bmp.Save($env:ASK_DIALOG_SHOT)
            $shown = if ($env:ASK_DIALOG_OPEN) { @($tab.RefCache.Values) | Where-Object { $_ -and $_.Key -eq $env:ASK_DIALOG_OPEN } | Select-Object -First 1 }
            if ($shown) {
                # A RichTextBox draws nothing under DrawToBitmap; PrintWindow renders it.
                Show-Reference $shown
                $vf = $script:viewer.Form
                $vf.Location = New-Object Drawing.Point(-5000, -5000)
                $wait = [Diagnostics.Stopwatch]::StartNew()
                do { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
                while ($script:viewer.Body.ReadyState -ne 'Complete' -and $wait.Elapsed.TotalSeconds -lt 10)
                Start-Sleep -Milliseconds 200; [Windows.Forms.Application]::DoEvents()
                $page = $script:viewer.Body
                [Console]::Error.WriteLine("reference window: $($page.ReadyState), $($page.Document.Body.InnerText.Length) characters of text")
                [IO.File]::WriteAllText((($env:ASK_DIALOG_SHOT -replace '\.png$', '') + '-ref.html'), $page.DocumentText)
                $vbmp = New-Object Drawing.Bitmap($vf.Width, $vf.Height)
                $vg = [Drawing.Graphics]::FromImage($vbmp); $hdc = $vg.GetHdc()
                [void][ClaudeHook.Native]::PrintWindow($vf.Handle, $hdc, 2)
                $vg.ReleaseHdc($hdc); $vg.Dispose()
                # Offscreen, PrintWindow leaves the page blank; the WebBrowser draws itself in.
                $at = $page.PointToScreen([Drawing.Point]::Empty)
                $page.DrawToBitmap($vbmp, (New-Object Drawing.Rectangle(($at.X - $vf.Left), ($at.Y - $vf.Top), $page.Width, $page.Height)))
                $vbmp.Save(($env:ASK_DIALOG_SHOT -replace '\.png$', '') + '-ref.png')
                $vf.Close()
            }
            $form.Hide()
        }
        Complete-Tab $tab $Auto
        exit 0
    }

    # The window process: takes hook calls from the pipe as tabs, drops the ones whose hook went away,
    # and ends 5 minutes after its last tab.
    function Add-RequestTab($request) {
        try {
            [void](Add-QuestionTab ($request.Payload | ConvertFrom-Json) $request)
        } catch {
            Write-Log "ask-dialog: tab failed: $_"
            foreach ($broken in @($script:tabs | Where-Object { $_.Request -eq $request })) { Remove-Tab $broken }
            $request.Reply('')
            return
        }
        if (-not $form.Visible) {
            # Each showing: at the right of the main screen, 100 px in from its edge, centred top to bottom.
            $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $form.Location = New-Object Drawing.Point(($area.Right - (& $px 100) - $form.Width),
                ($area.Top + [Math]::Max(0, [int](($area.Height - $form.Height) / 2))))
            $form.Show()
            # Started hidden, the process's first showing is a hiding; this one shows.
            [void][ClaudeHook.Native]::ShowWindow($form.Handle, 5)  # SW_SHOW
            $form.Activate()
            [void]$script:current.Submit.Focus()
        }
        [Media.SystemSounds]::Asterisk.Play()
    }
    $server = New-Object ClaudeHook.AskServer($pipeName)
    $server.Start()
    $script:idleSince = Get-Date
    $app = New-Object Windows.Forms.ApplicationContext
    $poll = New-Object Windows.Forms.Timer
    $poll.Interval = 200
    $poll.add_Tick({
        $request = $null
        while ($server.Incoming.TryDequeue([ref]$request)) { Add-RequestTab $request }
        foreach ($tab in @($script:tabs)) { if ($tab.Request.Gone) { Remove-Tab $tab } }
        if ($script:tabs.Count -eq 0 -and ((Get-Date) - $script:idleSince).TotalMinutes -ge 5) {
            $poll.Stop()
            $server.Stop()
            $app.ExitThread()
        }
    })
    $poll.Start()
    [Windows.Forms.Application]::Run($app)
    $lock.ReleaseMutex()
} catch {
    # Any failure falls back to the normal terminal prompt.
    [Console]::Error.WriteLine("ask-dialog: $_")
    if ($Serve) { Write-Log "ask-dialog: $_`n$($_.ScriptStackTrace)" }
    exit 0
}
exit 0
