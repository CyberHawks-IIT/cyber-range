$ErrorActionPreference = "Stop"

$adminPassword = $env:ADMIN_PASSWORD
if (-not $adminPassword) { throw "ADMIN_PASSWORD environment variable not set" }

# Same NTLM double-hop workaround as the laps role -- Set-LapsADReadPasswordPermission
# makes its own internal LDAP write.
$innerScript = @'
$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
Import-Module LAPS
$resultPath = "C:\Windows\Temp\laps_read_grant_result.txt"
try {
    $sql2 = Get-ADComputer sql2
    $user1 = Get-ADUser user1
    Set-LapsADReadPasswordPermission -Identity $sql2 -AllowedPrincipals $user1.SID.Value
    "Granted user1 LAPS password read on sql2" | Out-File -FilePath $resultPath
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $resultPath -Append
}
'@

$taskName = "LapsGrantRead_$(Get-Random)"
$scriptPath = "C:\Windows\Temp\laps_read_grant_task_script.ps1"
$resultPath = "C:\Windows\Temp\laps_read_grant_result.txt"

Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
Set-Content -Path $scriptPath -Value $innerScript

schtasks /Create /TN $taskName /TR "powershell.exe -ExecutionPolicy Bypass -File $scriptPath" /SC ONCE /ST 00:00 /RU "CYBERHAWKS\Administrator" /RP $adminPassword /RL HIGHEST /F | Out-Null
schtasks /Run /TN $taskName | Out-Null

$maxWait = 90
$waited = 0
while (-not (Test-Path $resultPath) -and $waited -lt $maxWait) {
    Start-Sleep -Seconds 2
    $waited += 2
}

schtasks /Delete /TN $taskName /F | Out-Null
Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $resultPath)) {
    throw "Scheduled task did not complete within $maxWait seconds"
}

$output = Get-Content $resultPath
Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
$output | Write-Output
if ($output -match "^ERROR:") {
    throw "LAPS read-permission grant task reported an error (see output above)"
}
