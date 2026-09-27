[CmdletBinding()]
param(
    [string]$ConfigPath = "C:\Windows\Temp\sysmon_config.xml"
)
$ErrorActionPreference = "Stop"

$svc = Get-Service -Name "Sysmon64", "Sysmon" -ErrorAction SilentlyContinue
if ($svc) {
    & "$env:SystemRoot\Sysmon64.exe" -c $ConfigPath | Out-Null
    Write-Output "Sysmon already installed -- config updated"
} else {
    # Server 2016's .NET defaults to SSL3/TLS1.0, which
    # download.sysinternals.com's TLS1.2-only endpoint rejects outright.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zipPath = "C:\Windows\Temp\Sysmon.zip"
    $extractPath = "C:\Windows\Temp\SysmonExtract"
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    & "$extractPath\Sysmon64.exe" -accepteula -i $ConfigPath | Out-Null
    Remove-Item -Path $zipPath, $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "Sysmon installed"
}

Write-Output "DONE"
