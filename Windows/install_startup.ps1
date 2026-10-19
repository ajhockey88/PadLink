# Registers the PadLink receiver to start hidden at every login. Run once:
#   powershell -ExecutionPolicy Bypass -File install_startup.ps1
$script = Join-Path $PSScriptRoot "padlink_receiver.py"
$pyw = (Get-Command pythonw.exe -ErrorAction Stop).Source
$action = New-ScheduledTaskAction -Execute $pyw -Argument "`"$script`"" -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "PadLinkReceiver" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName "PadLinkReceiver"
Write-Host "PadLink receiver installed and started. Remove with: Unregister-ScheduledTask PadLinkReceiver"
