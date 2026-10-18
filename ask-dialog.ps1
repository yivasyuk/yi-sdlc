param([string]$Auto = '', [string]$Mode = '')

# Claude Code PreToolUse hook for AskUserQuestion: answer the questions in a desktop window.
#   Submit            - the selected answers; recommended ones are preselected (Enter)
#   Close             - no output, so Claude Code shows its normal terminal prompt instead
#   Close To Terminal - same as Close, and switches notification mode to terminal (Esc)
#   All As Recommended - ticked on Submit, the session's later questions get their recommended options
#                       without a window (marks in all-recommended\<session id>, swept after 7 days).
#   UA / GB flags     - translate the window in place (Ukrainian / English) via headless `claude -p`;
#                       answers are always sent with the original question and option texts.
#   Read-only texts   - selectable; releasing a selection copies it to the clipboard (Ctrl+A selects all).
#   Message field     - optional free text for Claude; Ctrl+V pastes clipboard images (saved as PNG,
#                       passed as [Image #n] file paths). Sent as additionalContext with Submit/Close.
#   References        - AC-/US- items, ADRs, doc paths and doc sections (PRD §5, sad.md §6.4) a question
#                       mentions are links under it; a click shows that section beside the window.
# Notification mode (desktop | terminal) is stored per user in notification-mode next to this script.
# -Mode desktop|terminal|toggle|status manages it from a shell (used by the /notification-mode skill).
# -Auto submit|close builds the window without showing it (for testing); env ASK_DIALOG_TRANSLATE=uk|en
# translates first, ASK_DIALOG_NOTE=<text> fills the message field, ASK_DIALOG_IMAGE=<file> attaches an
# image and ASK_DIALOG_SHOT=<png> saves a picture (with ASK_DIALOG_OPEN=<reference>, e.g. AC-03, also
# the reference window as <png>-ref.png).
# Keep this file UTF-8 with BOM: Windows PowerShell needs the BOM to read the Ukrainian strings.

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$modeFile = Join-Path $PSScriptRoot 'notification-mode'
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

$allRecommendedDir = Join-Path $PSScriptRoot 'all-recommended'
function Get-AllRecommendedMark([string]$sessionId) {
    if ($sessionId -notmatch '^[\w-]+$') { return $null }
    Join-Path $allRecommendedDir $sessionId
}
function Set-AllRecommendedMark([string]$sessionId) {
    $mark = Get-AllRecommendedMark $sessionId
    if (-not $mark) { return }
    [void](New-Item -ItemType Directory -Force -Path $allRecommendedDir)
    Get-ChildItem -LiteralPath $allRecommendedDir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force
    [IO.File]::WriteAllText($mark, (Get-Date).ToString('o'))
}

function Get-Recommended($q) {
    $opts = @($q.options)
    $rec = @($opts | Where-Object { $_.label -match '\(recommended\)' } | ForEach-Object { $_.label })
    if ($rec.Count -eq 0 -and $opts.Count -gt 0) { $rec = @($opts[0].label) }
    if (-not $q.multiSelect) { $rec = @($rec | Select-Object -First 1) }
    return ,$rec
}

function Write-Answers($toolInput, $answers, [string]$reason, [string]$context) {
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
    [Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 20 -Compress))
}

try {
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $toolInput = $payload.tool_input
    $questions = @($toolInput.questions)
    if ($questions.Count -eq 0) { exit 0 }

    # PS 5.1 otherwise serializes some arrays as {"value":[...],"Count":n}.
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

    # All As Recommended was ticked earlier in this session: answer without asking, in either mode.
    $mark = Get-AllRecommendedMark $payload.session_id
    if ($mark -and (Test-Path -LiteralPath $mark)) {
        $answers = [ordered]@{}
        foreach ($q in $questions) {
            $rec = Get-Recommended $q
            if ($rec.Count -gt 0) { $answers[$q.question] = $rec -join ', ' }
        }
        Write-Answers $toolInput $answers 'Answered with the recommended options (All As Recommended)' (
            'The user ticked All As Recommended earlier in this session, so these questions were not shown to them: ' +
            'each was answered with its recommended option (the first option when none is marked).')
        exit 0
    }

    if ((Get-NotificationMode) -eq 'terminal') { exit 0 }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -Name Native -Namespace ClaudeHook -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
'@
    # The wheel goes to the control under the pointer, and the read-only texts, radio buttons and group boxes
    # inside the question list swallow it; this filter scrolls the list instead, wherever the pointer is in it.
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace ClaudeHook {
    public sealed class WheelRouter : IMessageFilter {
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
        readonly ScrollableControl target;
        int pending;
        public WheelRouter(ScrollableControl target) { this.target = target; }
        public bool PreFilterMessage(ref Message m) {
            if (m.Msg != 0x020A) return false;  // WM_MOUSEWHEEL
            return ScrollAt(Control.MousePosition, (short)((long)m.WParam >> 16));
        }
        public bool ScrollAt(Point screen, int delta) {
            if (!target.Visible || !target.RectangleToScreen(target.ClientRectangle).Contains(screen)) return false;
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
}
'@
    [void][ClaudeHook.Native]::SetProcessDPIAware()
    [Windows.Forms.Application]::EnableVisualStyles()

    $ui = @{
        en = @{
            Title = 'Claude Code needs your answer'; Submit = 'Submit'; ToTerminal = 'Close To Terminal'; Close = 'Close'
            Other = 'Other:'; Project = 'PROJECT'; Branch = 'BRANCH'; Feature = 'FEATURE'
            Note = 'Additional information for Claude (optional; Ctrl+V pastes images; Ctrl+Enter submits):'
            ImageTip = 'Image #{0} - click to remove'
            Missing = 'Answer every question ({0} left)'; Translating = 'Translating...'; Failed = 'Translation failed'
            Copied = 'Copied to clipboard'
            References = 'References:'; OpenFile = 'Open the file'
            TerminalTip = 'Close and switch to terminal mode: this and the next questions are asked in the terminal. Switch back with /notification-mode desktop.'
            AllRecommended = 'All As Recommended'
            AllRecommendedTip = 'Ticked when you press Submit: every later question in this session is answered with its recommended option, without asking you.'
            LanguageName = 'English'
        }
        uk = @{
            Title = 'Claude Code чекає на вашу відповідь'; Submit = 'Надіслати'; ToTerminal = 'Закрити в термінал'; Close = 'Закрити'
            Other = 'Інше:'; Project = 'ПРОЄКТ'; Branch = 'ГІЛКА'; Feature = 'ФІЧА'
            Note = 'Додаткова інформація для Claude (необов''язково; Ctrl+V — вставити зображення; Ctrl+Enter — надіслати):'
            ImageTip = 'Зображення #{0} — клацніть, щоб прибрати'
            Missing = 'Дайте відповідь на всі питання (залишилось {0})'; Translating = 'Перекладаю...'; Failed = 'Не вдалося перекласти'
            Copied = 'Скопійовано в буфер обміну'
            References = 'Посилання:'; OpenFile = 'Відкрити файл'
            TerminalTip = 'Закрити й перейти в режим терміналу: це та наступні питання будуть у терміналі. Повернути вікно: /notification-mode desktop.'
            AllRecommended = 'Усі як рекомендовано'
            AllRecommendedTip = 'Якщо позначено під час «Надіслати»: усі наступні питання цієї сесії отримають рекомендовану відповідь, без запитань до вас.'
            LanguageName = 'Українська'
        }
    }
    $allText = ($questions | ForEach-Object { $_.question; $_.header; @($_.options) | ForEach-Object { $_.label; $_.description } }) -join ' '
    $origLang = if ($allText -match '[Ѐ-ӿ]') { 'uk' } else { 'en' }
    $script:lang = $origLang

    # Title context: project (git repo or cwd), branch, and SDLC feature (docs/features/<slug>
    # matching the branch, else the one with the most recently edited files).
    $context = [ordered]@{}
    if ($payload.cwd) {
        $root = $payload.cwd
        $branch = ''
        try {
            $ErrorActionPreference = 'Continue'  # git writes to stderr outside a repo
            $repoRoot = git -C $payload.cwd rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $repoRoot) {
                $root = $repoRoot
                $branch = git -C $payload.cwd rev-parse --abbrev-ref HEAD 2>$null
                if ($branch -eq 'HEAD') { $branch = 'detached ' + (git -C $payload.cwd rev-parse --short HEAD 2>$null) }
            }
        } catch {} finally { $ErrorActionPreference = 'Stop' }
        $context['Project'] = Split-Path -Leaf $root
        if ($branch) { $context['Branch'] = $branch }

        $featuresDir = Join-Path $root 'docs\features'
        if (Test-Path $featuresDir) {
            $slugs = @(Get-ChildItem -LiteralPath $featuresDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' })
            $feature = $slugs | Where-Object { $branch -and $branch -match "(^|[/_-])$([regex]::Escape($_.Name))($|[/_-])" } |
                Sort-Object { $_.Name.Length } -Descending | Select-Object -First 1
            if (-not $feature) {
                $feature = $slugs | Sort-Object {
                    Get-ChildItem -LiteralPath $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty LastWriteTime
                } -Descending | Select-Object -First 1
            }
            if ($feature) { $context['Feature'] = $feature.Name }
        }
    }
    if ($context.Count -eq 0) { $context['Project'] = '(unknown)' }

    $form = New-Object Windows.Forms.Form
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.StartPosition = 'CenterScreen'
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
            Show-Status $ui[$script:lang].Copied $false
        } catch {}
    }
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
        $t.add_MouseUp({ param($sender) Copy-Selection $sender })
        $t.add_KeyDown({
            param($sender, $e)
            if ($e.Control -and $e.KeyCode -eq 'A') { $sender.SelectAll(); $e.SuppressKeyPress = $true }
        })
        $t.add_KeyUp({ param($sender) Copy-Selection $sender })
        Resize-SelectableText $t
        $t
    }

    # Texts that get translated: control + original text (GroupBox titles need '&' doubled).
    $script:dyn = New-Object Collections.ArrayList
    function Add-Dyn($control, [string]$text, [switch]$Amp) {
        [void]$script:dyn.Add([pscustomobject]@{ Control = $control; Original = $text; Amp = [bool]$Amp })
        Set-DynText $control $text $Amp
    }
    function Set-DynText($control, [string]$text, [bool]$amp) {
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

    $main = New-Object Windows.Forms.FlowLayoutPanel
    $main.Dock = 'Fill'
    $main.FlowDirection = 'TopDown'
    $main.WrapContents = $false
    $main.AutoScroll = $true
    $main.Padding = New-Object Windows.Forms.Padding((& $px 12))
    $wheel = New-Object ClaudeHook.WheelRouter($main)
    [Windows.Forms.Application]::AddMessageFilter($wheel)

    # Header row: project, branch and feature on a dark band, language flags on the right.
    $headerColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $top = New-Object Windows.Forms.TableLayoutPanel
    $top.Dock = 'Top'
    $top.AutoSize = $true
    $top.ColumnCount = 2
    [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$top.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $top.BackColor = $headerColor
    $top.Padding = New-Object Windows.Forms.Padding((& $px 14), (& $px 10), (& $px 10), (& $px 10))

    $contextFlow = New-Object Windows.Forms.FlowLayoutPanel
    $contextFlow.AutoSize = $true
    $contextFlow.Dock = 'Fill'
    $contextFlow.Margin = New-Object Windows.Forms.Padding(0)
    $captionFont = New-Object Drawing.Font('Segoe UI', 8, [Drawing.FontStyle]::Bold)
    $valueFont = New-Object Drawing.Font('Segoe UI Semibold', 13)
    $valueColors = @{
        Project = [Drawing.Color]::White
        Branch  = [Drawing.Color]::FromArgb(125, 211, 252)
        Feature = [Drawing.Color]::FromArgb(134, 239, 172)
    }
    $captions = @{}
    foreach ($key in $context.Keys) {
        $cell = New-Object Windows.Forms.FlowLayoutPanel
        $cell.FlowDirection = 'TopDown'
        $cell.WrapContents = $false
        $cell.AutoSize = $true
        $cell.Margin = New-Object Windows.Forms.Padding(0, 0, (& $px 28), 0)
        $caption = New-Object Windows.Forms.Label
        $caption.Font = $captionFont
        $caption.ForeColor = [Drawing.Color]::FromArgb(148, 163, 184)
        $caption.AutoSize = $true
        $caption.Margin = New-Object Windows.Forms.Padding(0)
        $captions[$key] = $caption
        $value = New-SelectableText ($w - (& $px 100)) $valueFont $valueColors[$key] $headerColor
        $value.Text = $context[$key]
        $value.Margin = New-Object Windows.Forms.Padding(0)
        $cell.Controls.AddRange(@($caption, $value))
        $contextFlow.Controls.Add($cell)
    }
    $top.Controls.Add($contextFlow, 0, 0)

    function New-Flag([string]$lang) {
        $fw = & $px 30; $fh = & $px 20
        $bmp = New-Object Drawing.Bitmap($fw, $fh)
        $fg = [Drawing.Graphics]::FromImage($bmp)
        if ($lang -eq 'uk') {
            $fg.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(0, 87, 183))), 0, 0, $fw, [int]($fh / 2))
            $fg.FillRectangle((New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 215, 0))), 0, [int]($fh / 2), $fw, $fh - [int]($fh / 2))
        } else {
            $red = [Drawing.Color]::FromArgb(200, 16, 46)
            $fg.SmoothingMode = 'AntiAlias'
            $fg.Clear([Drawing.Color]::FromArgb(1, 33, 105))
            foreach ($pen in @((New-Object Drawing.Pen([Drawing.Color]::White, ($fh / 5))), (New-Object Drawing.Pen($red, ($fh / 14))))) {
                $fg.DrawLine($pen, 0, 0, $fw, $fh); $fg.DrawLine($pen, 0, $fh, $fw, 0)
            }
            $fg.SmoothingMode = 'None'
            $white = New-Object Drawing.SolidBrush([Drawing.Color]::White)
            $fg.FillRectangle($white, 0, [int]($fh * 0.34), $fw, [int]($fh * 0.32))
            $fg.FillRectangle($white, [int]($fw / 2 - $fh * 0.16), 0, [int]($fh * 0.32), $fh)
            $redBrush = New-Object Drawing.SolidBrush($red)
            $fg.FillRectangle($redBrush, 0, [int]($fh * 0.41), $fw, [int]($fh * 0.18))
            $fg.FillRectangle($redBrush, [int]($fw / 2 - $fh * 0.09), 0, [int]($fh * 0.18), $fh)
        }
        $fg.Dispose()
        $bmp
    }
    $flagPanel = New-Object Windows.Forms.FlowLayoutPanel
    $flagPanel.AutoSize = $true
    $flagPanel.WrapContents = $false
    $flagPanel.Anchor = 'Top, Right'
    $flagPanel.Margin = New-Object Windows.Forms.Padding(0)
    $flags = @{}
    foreach ($lang in 'uk', 'en') {
        $fb = New-Object Windows.Forms.Button
        $fb.Image = New-Flag $lang
        $fb.Tag = $lang
        $fb.FlatStyle = 'Flat'
        $fb.FlatAppearance.BorderSize = & $px 2
        $fb.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(51, 65, 85)
        $fb.BackColor = $headerColor
        $fb.Size = New-Object Drawing.Size((& $px 42), (& $px 32))
        $fb.Margin = New-Object Windows.Forms.Padding((& $px 4), 0, 0, 0)
        $fb.Cursor = [Windows.Forms.Cursors]::Hand
        $fb.TabStop = $false
        $tips.SetToolTip($fb, $ui[$lang].LanguageName)
        $fb.add_Click({ param($sender) Switch-Language $sender.Tag })
        $flagPanel.Controls.Add($fb)
        $flags[$lang] = $fb
    }
    $top.Controls.Add($flagPanel, 1, 0)

    # References the questions mention, resolved to a section of a file under the repo's docs/:
    # AC-03 / US-02 (heading in docs/features/<slug>/PRD.md or spec.md), ADR-0019 (whole file in docs/adr
    # or docs/features/*/adr), docs/.../x.md with §5 or #anchor, and PRD|SAD|spec|... §6.4. Features are
    # tried in order: the first one the question names (else the dialog), the title's feature, then the
    # most recently edited.
    $script:refRoot = if ($payload.cwd -and (Test-Path -LiteralPath (Join-Path $root 'docs'))) { $root } else { $null }
    $script:refCache = @{}
    $byEdit = @()
    if ($script:refRoot -and $slugs) {
        $edited = { param($dir) 'PRD.md', 'spec.md', 'sad.md' | ForEach-Object { Join-Path $dir $_ } |
            Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).LastWriteTime } |
            Sort-Object -Descending | Select-Object -First 1 }
        $byEdit = @($slugs | Sort-Object -Descending { & $edited $_.FullName } | ForEach-Object { $_.Name })
    }
    function Get-NamedFeature([string]$text) {
        $first = $null
        foreach ($slug in $byEdit) {
            $hit = [regex]::Match($text, "(?<![\w-])$([regex]::Escape($slug))(?![\w-])")
            if ($hit.Success -and (-not $first -or $hit.Index -lt $first.Index)) { $first = @{ Index = $hit.Index; Slug = $slug } }
        }
        if ($first) { $first.Slug } else { '' }
    }
    $dialogFeature = Get-NamedFeature $allText
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
        $path.LinkColor = $valueColors.Branch
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
        $tips.SetToolTip($v.Path, $ui[$script:lang].OpenFile)
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
    # opens it in the reference window, dragging still selects and copies. Formatting follows the text, so a
    # translated window links the same codes.
    $linkColor = [Drawing.Color]::FromArgb(66, 100, 145)      # beside the near-black question text
    $linkColorDim = [Drawing.Color]::FromArgb(96, 128, 168)   # beside the grey option descriptions
    $script:links = @{}
    function Set-Links($t, $color) {
        $script:links[$t] = @{ Order = @($script:featureOrder); Color = $color; Ranges = @(); Hover = $null }
    }
    function Format-Links($t) {
        $info = $script:links[$t]
        if (-not $info -or -not $script:refRoot) { return }
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

    $refCaptions = @()
    $entries = @()
    $otherLabels = @()
    for ($i = 0; $i -lt $questions.Count; $i++) {
        $q = $questions[$i]
        $rec = Get-Recommended $q

        $box = New-Object Windows.Forms.GroupBox
        Add-Dyn $box $(if ($q.header) { $q.header } else { "Question $($i + 1)" }) -Amp
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
        if ($script:refRoot) {
            $qText = @($q.question; @($q.options) | ForEach-Object { $_.label; $_.description; $_.preview }) -join "`n"
            $named = Get-NamedFeature $qText
            if (-not $named) { $named = $dialogFeature }
            $script:featureOrder = @(@($named, $context['Feature']) + $byEdit | Where-Object { $_ } | Select-Object -Unique)
        }

        $text = New-SelectableText ($w - (& $px 30)) $bold $form.ForeColor $form.BackColor -Linkable
        Set-Links $text $linkColor
        Add-Dyn $text $q.question
        $text.Margin = New-Object Windows.Forms.Padding(0, 0, 0, (& $px 6))
        $inner.Controls.Add($text)

        # The question and descriptions link their codes in place; codes only in option labels or previews,
        # which cannot hold links, get a row of their own.
        $refs = @()
        if ($script:refRoot) {
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
            $refCaptions += $refCaption
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
            Add-Dyn $c $o.label
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
                Set-Links $d $linkColorDim
                Add-Dyn $d $o.description
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
        $otherLabels += $otherLabel
        $other = New-Object Windows.Forms.TextBox
        $other.Width = $w - (& $px 110)
        $row.Controls.AddRange(@($otherLabel, $other))
        $inner.Controls.Add($row)

        $main.Controls.Add($box)
        $entries += [pscustomobject]@{ Question = $q; Choices = $choices; Other = $other }
    }

    # Free-text message for Claude, sent as additionalContext with whatever button closes the window.
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

    # Images: hooks can only pass text, so each image is a file whose path goes to Claude as [Image #n].
    $imageDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-ask-dialog\images'
    [void](New-Item -ItemType Directory -Force -Path $imageDir)
    Get-ChildItem -LiteralPath $imageDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
    $script:attachments = New-Object Collections.ArrayList
    $script:imageCount = 0
    function Add-Attachment([string]$path, [bool]$owned) {
        $script:imageCount++
        $n = $script:imageCount
        $pb = New-Object Windows.Forms.PictureBox
        $pb.Size = New-Object Drawing.Size((& $px 64), (& $px 64))
        $pb.SizeMode = 'Zoom'
        $pb.BorderStyle = 'FixedSingle'
        $pb.Cursor = [Windows.Forms.Cursors]::Hand
        try { $pb.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($path)))) }
        catch { $pb.BackColor = [Drawing.Color]::Gainsboro }
        $item = [pscustomobject]@{ Number = $n; Path = $path; Owned = $owned; Box = $pb }
        $pb.Tag = $item
        $tips.SetToolTip($pb, ($ui[$script:lang].ImageTip -f $n) + "`n" + $path)
        $pb.add_Click({ param($sender) Remove-Attachment $sender.Tag })
        [void]$script:attachments.Add($item)
        $attachPanel.Controls.Add($pb)
        $attachPanel.Visible = $true
        $note.SelectedText = "[Image #$n] "
        Update-FormHeight
    }
    function Remove-Attachment($item) {
        $script:attachments.Remove($item)
        $attachPanel.Controls.Remove($item.Box)
        if ($item.Box.Image) { $item.Box.Image.Dispose() }
        $item.Box.Dispose()
        if ($item.Owned) { Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue }
        $note.Text = $note.Text.Replace("[Image #$($item.Number)] ", '').Replace("[Image #$($item.Number)]", '')
        $attachPanel.Visible = $script:attachments.Count -gt 0
        Update-FormHeight
    }
    function Add-ClipboardImages {
        if ([Windows.Forms.Clipboard]::ContainsImage()) {
            $img = [Windows.Forms.Clipboard]::GetImage()
            $path = Join-Path $imageDir ('image-{0:yyyyMMdd-HHmmss-fff}.png' -f (Get-Date))
            $img.Save($path, [Drawing.Imaging.ImageFormat]::Png)
            $img.Dispose()
            Add-Attachment $path $true
            return $true
        }
        if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $files = @([Windows.Forms.Clipboard]::GetFileDropList() | Where-Object { $_ -match '\.(png|jpe?g|gif|bmp|webp)$' })
            foreach ($file in $files) { Add-Attachment $file $false }
            return $files.Count -gt 0
        }
        return $false
    }
    $note.add_KeyDown({
        param($sender, $e)
        if ($e.Control -and $e.KeyCode -eq 'Return') {
            $e.SuppressKeyPress = $true
            $submitBtn.PerformClick()
        } elseif (($e.Control -and $e.KeyCode -eq 'V') -or ($e.Shift -and $e.KeyCode -eq 'Insert')) {
            if (Add-ClipboardImages) { $e.SuppressKeyPress = $true }
        }
    })

    # The bottom row: All As Recommended on the left, the buttons (and the status) from the right.
    $bar = New-Object Windows.Forms.TableLayoutPanel
    $bar.Dock = 'Bottom'
    $bar.AutoSize = $true
    $bar.ColumnCount = 2
    $bar.RowCount = 1
    [void]$bar.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    [void]$bar.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$bar.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $bar.Padding = New-Object Windows.Forms.Padding((& $px 10))
    $allRecommended = New-Object Windows.Forms.CheckBox
    $allRecommended.AutoSize = $true
    $allRecommended.Anchor = 'Left'
    $allRecommended.Checked = [bool]$env:ASK_DIALOG_ALL
    $bar.Controls.Add($allRecommended, 0, 0)
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
    $terminalBtn = & $mkButton
    $submitBtn = & $mkButton
    $status = New-Object Windows.Forms.Label
    $status.AutoSize = $true
    $status.Margin = New-Object Windows.Forms.Padding(0, (& $px 8), (& $px 10), 0)
    $buttons.Controls.Add($status)
    function Show-Status([string]$text, [bool]$isError) {
        $status.ForeColor = if ($isError) { [Drawing.Color]::Firebrick } else { $gray }
        $status.Text = $text
    }

    $script:mode = 'close'
    $closeBtn.add_Click({ $form.Close() })
    $terminalBtn.add_Click({ Set-NotificationMode 'terminal'; $form.Close() })
    $submitBtn.add_Click({
        $missing = @($entries | Where-Object { -not ($_.Choices | Where-Object Checked) -and -not $_.Other.Text.Trim() })
        if ($missing.Count -gt 0) { Show-Status ($ui[$script:lang].Missing -f $missing.Count) $true; return }
        $script:mode = 'submit'
        $form.Close()
    })
    $form.AcceptButton = $submitBtn
    $form.CancelButton = $terminalBtn

    $form.Controls.Add($main)
    $form.Controls.Add($notePanel)
    $form.Controls.Add($bar)
    $form.Controls.Add($top)
    $clientWidth = $w + (& $px 50)
    function Update-FormHeight {
        $contentHeight = $main.GetPreferredSize((New-Object Drawing.Size(($w + (& $px 40)), 0))).Height +
            $top.GetPreferredSize((New-Object Drawing.Size($clientWidth, 0))).Height + $notePanel.PreferredSize.Height + $bar.PreferredSize.Height
        $maxHeight = [int]([Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height * 0.85)
        $form.ClientSize = New-Object Drawing.Size($clientWidth, [Math]::Min($contentHeight, $maxHeight))
    }

    # Language switching. Translations are cached; the original language needs no call.
    $script:translations = @{ $origLang = @($script:dyn | ForEach-Object { $_.Original }) }
    $script:job = $null
    function Set-Language([string]$lang) {
        $script:lang = $lang
        $t = $ui[$lang]
        $items = $script:translations[$lang]
        for ($k = 0; $k -lt $script:dyn.Count; $k++) {
            $item = $script:dyn[$k]
            Set-DynText $item.Control $items[$k] $item.Amp
        }
        $form.Text = $t.Title + ' - ' + ($context.Values -join ' | ')
        foreach ($key in $captions.Keys) { $captions[$key].Text = $t[$key] }
        foreach ($l in $otherLabels) { $l.Text = $t.Other }
        foreach ($l in $refCaptions) { $l.Text = $t.References }
        $noteLabel.Text = $t.Note
        $submitBtn.Text = $t.Submit
        $terminalBtn.Text = $t.ToTerminal
        $closeBtn.Text = $t.Close
        $tips.SetToolTip($terminalBtn, $t.TerminalTip)
        $allRecommended.Text = $t.AllRecommended
        $tips.SetToolTip($allRecommended, $t.AllRecommendedTip)
        foreach ($code in $flags.Keys) {
            $flags[$code].FlatAppearance.BorderColor = if ($code -eq $lang) { [Drawing.Color]::White } else { $headerColor }
        }
        Show-Status '' $false
        Update-FormHeight
    }

    $claudeExe = (Get-Command claude.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $claudeExe) { $claudeExe = Join-Path $HOME '.local\bin\claude.exe' }
    function Switch-Language([string]$lang) {
        if ($script:job -or $lang -eq $script:lang) { return }
        if ($script:translations.ContainsKey($lang)) { Set-Language $lang; return }

        $quote = { param($s) '"' + ($s -replace '"', '\"') + '"' }
        $schema = '{"type":"object","properties":{"items":{"type":"array","items":{"type":"string"}}},"required":["items"]}'
        $system = "You translate UI text of a question dialog. Input: a JSON array of strings. Translate every string to $(if ($lang -eq 'uk') { 'Ukrainian' } else { 'English' }). " +
            'Return them in the same order and count. Keep code, identifiers, file names, commands and product names unchanged.'
        $workDir = Join-Path ([IO.Path]::GetTempPath()) 'claude-ask-dialog'
        [void](New-Item -ItemType Directory -Force -Path $workDir)

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $claudeExe
        $psi.Arguments = '-p --model haiku --effort low --setting-sources project --strict-mcp-config --tools "" --no-session-persistence ' +
            "--disable-slash-commands --output-format json --json-schema $(& $quote $schema) --system-prompt $(& $quote $system)"
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
            $stdin.Write((ConvertTo-Json -InputObject @($script:translations[$origLang]) -Compress))
            $stdin.Close()
            $script:job = @{ Lang = $lang; Process = $proc; Output = $proc.StandardOutput.ReadToEndAsync(); Watch = [Diagnostics.Stopwatch]::StartNew() }
            foreach ($fb in $flags.Values) { $fb.Enabled = $false }
            Show-Status $ui[$lang].Translating $false
            $timer.Start()
        } catch {
            Show-Status $ui[$script:lang].Failed $true
        }
    }
    function Complete-Translation([string]$raw) {
        $timer.Stop()
        $lang = $script:job.Lang
        $script:job = $null
        foreach ($fb in $flags.Values) { $fb.Enabled = $true }
        try {
            $items = @(($raw | ConvertFrom-Json).structured_output.items)
            if ($items.Count -ne $script:dyn.Count) { throw 'count mismatch' }
            $script:translations[$lang] = $items
            Set-Language $lang
        } catch {
            Show-Status $ui[$script:lang].Failed $true
        }
    }
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 250
    $timer.add_Tick({
        $job = $script:job
        if (-not $job) { $timer.Stop(); return }
        if ($job.Output.IsCompleted) { Complete-Translation $job.Output.Result; return }
        if ($job.Watch.Elapsed.TotalSeconds -gt 90) { try { $job.Process.Kill() } catch {}; Complete-Translation '' }
    })
    $form.add_FormClosed({ if ($script:job) { try { $script:job.Process.Kill() } catch {} } })

    Set-Language $origLang
    $form.add_Shown({ $form.Activate(); $submitBtn.Focus() })

    if ($Auto) {
        if ($env:ASK_DIALOG_NOTE) { $note.Text = $env:ASK_DIALOG_NOTE + ' ' }
        if ($env:ASK_DIALOG_IMAGE) { $note.SelectionStart = $note.TextLength; Add-Attachment $env:ASK_DIALOG_IMAGE $false }
        if ($env:ASK_DIALOG_TRANSLATE) {
            Switch-Language $env:ASK_DIALOG_TRANSLATE
            while ($script:job) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        }
        [Console]::Error.WriteLine("title: $($form.Text) [$script:lang]")
        foreach ($key in $script:refCache.Keys) {
            $r = $script:refCache[$key]
            [Console]::Error.WriteLine("reference: $key -> $(if ($r) { "$($r.Path):$($r.Line) ($($r.Lines.Count) lines) $($r.Title)" } else { '(not found)' })")
        }
        if ($env:ASK_DIALOG_WHEEL) {
            # Wheel check: shown nearly transparent at the screen's corner (hit-testing needs a real window),
            # one notch down over each kind of control; the question list must scroll, the message box not.
            $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(0, 0); $form.Opacity = 0.01
            $form.Show(); [Windows.Forms.Application]::DoEvents()
            $firstInner = $entries[0].Choices[0].Parent
            $probes = [ordered]@{
                'question text' = $firstInner.Controls[0]
                'radio button'  = $entries[0].Choices[0]
                'description'   = @($firstInner.Controls | Where-Object { $_ -is [Windows.Forms.TextBoxBase] -and $_.Multiline })[1]
                'references'    = @($firstInner.Controls | Where-Object { $_ -is [Windows.Forms.FlowLayoutPanel] })[0]
                'other field'   = $entries[0].Other
                'group box'     = $firstInner.Parent
                'message box'   = $note
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
            foreach ($rich in @($script:links.Keys)) {
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
            $view = $main.RectangleToScreen($main.ClientRectangle)
            foreach ($rich in @($script:links.Keys)) {
                $on = $rich.RectangleToScreen($rich.ClientRectangle)
                if (-not $rich.Visible -or -not $view.Contains($on)) { continue }
                $on.Offset(-$form.Left, -$form.Top)
                [ClaudeHook.RichPrint]::Draw($rich, $sg, $on)
            }
            $sg.Dispose()
            $bmp.Save($env:ASK_DIALOG_SHOT)
            $shown = if ($env:ASK_DIALOG_OPEN) { @($script:refCache.Values) | Where-Object { $_ -and $_.Key -eq $env:ASK_DIALOG_OPEN } | Select-Object -First 1 }
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
        $script:mode = $Auto
    } else {
        [Media.SystemSounds]::Asterisk.Play()
        [void]$form.ShowDialog()
    }

    $noteText = $note.Text.Trim()
    $imageBlock = ''
    if ($script:attachments.Count) {
        $imageBlock = "`n`nAttached images (open each with the Read tool before replying):`n" +
            (($script:attachments | ForEach-Object { "[Image #$($_.Number)]: $($_.Path)" }) -join "`n")
    }
    $noteContext = if ($noteText -or $imageBlock) { "Additional message from the user, written in the question dialog:`n$noteText$imageBlock" } else { '' }

    if ($script:mode -eq 'close') {
        # Closed without answering: the terminal prompt follows, but the message still reaches Claude.
        if ($noteContext) {
            $result = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; additionalContext = $noteContext } }
            [Console]::Out.Write((ConvertTo-Json -InputObject $result -Depth 5 -Compress))
        }
        exit 0
    }

    # Answers always use the original question and option texts, whatever language is shown.
    $answers = [ordered]@{}
    foreach ($e in $entries) {
        $labels = @($e.Choices | Where-Object Checked | ForEach-Object { $_.Tag })
        $typed = $e.Other.Text.Trim()
        if ($typed) { $labels = if ($e.Question.multiSelect) { $labels + $typed } else { @($typed) } }
        if ($labels.Count -gt 0) { $answers[$e.Question.question] = $labels -join ', ' }
    }

    if ($allRecommended.Checked) {
        Set-AllRecommendedMark $payload.session_id
        $allNote = 'The user ticked All As Recommended: their later questions in this session are answered with the recommended options without being shown.'
        $noteContext = if ($noteContext) { "$noteContext`n`n$allNote" } else { $allNote }
    }
    Write-Answers $toolInput $answers 'Answered in the desktop dialog' $noteContext
} catch {
    # Any failure falls back to the normal terminal prompt.
    [Console]::Error.WriteLine("ask-dialog: $_")
    exit 0
}
exit 0
