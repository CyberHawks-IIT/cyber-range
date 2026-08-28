$ErrorActionPreference = "Stop"

$adminPassword = $env:ADMIN_PASSWORD
if (-not $adminPassword) { throw "ADMIN_PASSWORD environment variable not set" }

# certutil -CATemplates / -SetCATemplates talk live to the running CertSvc
# process via RPC (ICertAdmin2), unlike -setreg which just writes the
# registry directly. That RPC call fails under an NTLM-authenticated WinRM
# session with ERROR_NOT_AUTHENTICATED (0x800704dc) -- the earlier version
# of this script swallowed that error (piped to Out-Null) and reported
# success regardless, so none of the 8 templates were actually published.
# Same double-hop workaround as elsewhere in this build: run via a
# scheduled task under real password auth.
$innerScript = @'
$ErrorActionPreference = "Stop"
$templates = @("ESC1Template", "ESC2Template", "ESC3Template", "ESC4Template", "ESC9Template", "ESC13Template", "ESC15Template", "ESC17Template")
$resultPath = "C:\Windows\Temp\adcs_publish_result.txt"
try {
    $currentRaw = certutil -CATemplates
    if ($LASTEXITCODE -ne 0) { throw "certutil -CATemplates failed with exit code $LASTEXITCODE : $currentRaw" }
    $current = ($currentRaw | Where-Object { $_ -match ':' } | ForEach-Object { ($_ -split ':')[0].Trim() })
    $out = @()
    foreach ($t in $templates) {
        if ($current -contains $t) {
            $out += "$t already published"
        } else {
            certutil -SetCATemplates "+$t" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "certutil -SetCATemplates +$t failed with exit code $LASTEXITCODE" }
            $out += "Published $t"
        }
    }
    $out | Out-File -FilePath $resultPath
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $resultPath
}
'@

$taskName = "AdcsPublish_$(Get-Random)"
$scriptPath = "C:\Windows\Temp\adcs_publish_task_script.ps1"
$resultPath = "C:\Windows\Temp\adcs_publish_result.txt"

Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
Set-Content -Path $scriptPath -Value $innerScript

schtasks /Create /TN $taskName /TR "powershell.exe -ExecutionPolicy Bypass -File $scriptPath" /SC ONCE /ST 00:00 /RU "CYBERHAWKS\Administrator" /RP $adminPassword /RL HIGHEST /F | Out-Null
schtasks /Run /TN $taskName | Out-Null

$maxWait = 60
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
    throw "Template publish task reported an error (see output above)"
}
