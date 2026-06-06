param(
  [string]$Token = "change-me-client-token",
  [string]$Device = "windows",
  [string]$BaseUrl = "https://wl.example.com"
)

$ErrorActionPreference = "Stop"
$Url = "$BaseUrl/pulse/$Token" + "?device=$Device&mode=fast"

curl.exe --noproxy "*" --connect-timeout 5 --max-time 10 $Url