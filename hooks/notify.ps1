param([string]$Event = 'Stop')

# Claude Code hook: show a Windows toast. Reads the hook payload (JSON) from stdin.
$payload = $null
try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) { $payload = $raw | ConvertFrom-Json }
} catch {}

$project = ''
if ($payload -and $payload.cwd) { $project = Split-Path -Leaf $payload.cwd }

if ($Event -eq 'Notification') {
    $title = 'Claude Code needs your input'
    $body = if ($payload -and $payload.message) { $payload.message } else { 'Claude is waiting for you.' }
} elseif ($Event -eq 'StopFailure') {
    $title = 'Claude Code stopped with an error'
    $body = if ($payload -and $payload.last_assistant_message) { $payload.last_assistant_message } elseif ($payload -and $payload.error) { $payload.error } else { 'The run failed.' }
} else {
    $title = 'Claude Code finished'
    $body = 'The run is complete.'
}
if ($project) { $title = "$title - $project" }

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

$esc = [System.Security.SecurityElement]
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml(@"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$($esc::Escape($title))</text>
      <text>$($esc::Escape($body))</text>
    </binding>
  </visual>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@)

# PowerShell's registered AppUserModelID, so the toast shows without registering a custom app.
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
    [Windows.UI.Notifications.ToastNotification]::new($xml))
