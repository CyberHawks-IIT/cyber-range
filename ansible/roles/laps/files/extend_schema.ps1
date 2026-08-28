$ErrorActionPreference = "Stop"

$adminPassword = $env:ADMIN_PASSWORD
if (-not $adminPassword) { throw "ADMIN_PASSWORD environment variable not set" }

# Runs via a one-shot scheduled task under real password auth -- see
# CLAUDE.md's documented WinRM/NTLM double-hop gotcha. Update-LapsADSchema
# makes its own internal LDAP write to the schema master; an NTLM-authenticated
# WinRM session can't delegate that.
$innerScript = @'
$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
Import-Module LAPS
$resultPath = "C:\Windows\Temp\laps_schema_result.txt"
try {
    $schemaNC = (Get-ADRootDSE).schemaNamingContext
    $existing = Get-ADObject -SearchBase $schemaNC -Filter "lDAPDisplayName -eq 'msLAPS-Password'" -ErrorAction SilentlyContinue
    if ($existing) {
        "AD schema already extended for Windows LAPS" | Out-File -FilePath $resultPath
    } else {
        Update-LapsADSchema -Confirm:$false
        "Extended AD schema for Windows LAPS" | Out-File -FilePath $resultPath
    }
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $resultPath -Append
}
'@

$taskName = "LapsSchemaExtend_$(Get-Random)"
$scriptPath = "C:\Windows\Temp\laps_schema_task_script.ps1"
$resultPath = "C:\Windows\Temp\laps_schema_result.txt"

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
    throw "Schema extension task reported an error (see output above)"
}
