param(
  [Parameter(Mandatory=$true)] [string]$Token,
  [Parameter(Mandatory=$true)] [string]$BaseUrl,
  [string]$Device = "windows",
  [string]$TaskName = "Dynamic Whitelist Refresh"
)

$ErrorActionPreference = "Stop"
$ScriptPath = Join-Path $PSScriptRoot "windows-task.ps1"
$Args = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Token `"$Token`" -BaseUrl `"$BaseUrl`" -Device `"$Device`""
$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $Args

$DailyTrigger = New-ScheduledTaskTrigger -Daily -At 09:17
$NetworkTrigger = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select>
  </Query>
</QueryList>
"@
$EventTrigger = New-ScheduledTaskTrigger -OnEvent -Subscription $NetworkTrigger

$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel LeastPrivilege

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger @($DailyTrigger, $EventTrigger) -Settings $Settings -Principal $Principal -Force | Out-Null
Write-Host "Installed task: $TaskName"
Write-Host "Triggers: NetworkProfile EventID 10000 + daily 09:17"