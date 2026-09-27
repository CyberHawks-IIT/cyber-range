$ErrorActionPreference = "Stop"

# HKLM\SECURITY denies read/write-DAC to Administrators by default (only
# SYSTEM has access at all), and setting a SACL on HKLM\SAM needs
# SeSecurityPrivilege enabled, not just held. Rather than fight ownership and
# privilege-enabling gymnastics from a merely-elevated Administrator token
# (the same double-hop-style problem documented elsewhere in this repo for
# domain operations), run the actual SACL-setting logic as SYSTEM via a
# one-shot scheduled task -- SYSTEM already has unrestricted access to both
# hives, no privilege juggling required.
$innerScript = @'
$ErrorActionPreference = "Stop"
$resultPath = "C:\Windows\Temp\sacl_common_result.txt"
try {
    $everyone = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $lines = @()

    # Per-item try/catch, not one wrapping the whole script: Defender's own
    # Tamper Protection hardens WinDefend/WdNisSvc's registry ACLs on Server
    # 2019+/Windows 11 (absent on the older Server 2016 boxes in this range)
    # and refuses SACL changes even to SYSTEM -- confirmed live. One
    # protected key shouldn't abort SAM/SECURITY/DPAPI work that would
    # otherwise succeed on the same host.
    function Add-RegAudit {
        param([string]$SubKey)
        try {
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                $SubKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]"ChangePermissions,ReadKey")
            if (-not $key) { return "WARNING: HKLM\$SubKey not found" }
            $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Audit)
            $rule = New-Object System.Security.AccessControl.RegistryAuditRule(
                $everyone,
                [System.Security.AccessControl.RegistryRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit",
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AuditFlags]"Success,Failure")
            $acl.AddAuditRule($rule)
            $key.SetAccessControl($acl)
            $key.Close()
            return "SACL set on HKLM\$SubKey"
        } catch {
            return "WARNING: could not set SACL on HKLM\$SubKey (likely Tamper Protection or similar OS hardening): $($_.Exception.Message)"
        }
    }

    # SAM/SECURITY hive dumping detection.
    $lines += Add-RegAudit -SubKey "SAM"
    $lines += Add-RegAudit -SubKey "SECURITY"

    # Security-software-tampering detection (7040 covers the service
    # start-type change itself; this SACL is what generates the matching
    # 4657 for a direct registry edit of these services).
    foreach ($svc in @("WinDefend", "WdNisSvc", "Sense")) {
        $svcPath = "SYSTEM\CurrentControlSet\Services\$svc"
        if (Get-Item "HKLM:\$svcPath" -ErrorAction SilentlyContinue) {
            $lines += Add-RegAudit -SubKey $svcPath
        } else {
            $lines += "WARNING: HKLM\$svcPath not found (service not installed here)"
        }
    }

    # DPAPI masterkey/credential-file theft detection -- lives per profile,
    # so audit both folders for every local profile that actually exists on
    # this host rather than guessing which accounts have logged on.
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in @("AppData\Roaming\Microsoft\Protect", "AppData\Roaming\Microsoft\Credentials")) {
            $path = Join-Path $_.FullName $sub
            if (Test-Path $path) {
                try {
                    $acl = Get-Acl -Path $path -Audit
                    $rule = New-Object System.Security.AccessControl.FileSystemAuditRule(
                        $everyone, "FullControl", "ContainerInherit,ObjectInherit", "None", "Success,Failure")
                    $acl.AddAuditRule($rule)
                    Set-Acl -Path $path -AclObject $acl
                    $lines += "SACL set on $path"
                } catch {
                    $lines += "WARNING: could not set SACL on $path : $($_.Exception.Message)"
                }
            }
        }
    }

    $lines | Out-File -FilePath $resultPath
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $resultPath -Append
}
'@

$taskName = "SaclCommon_$(Get-Random)"
$scriptPath = "C:\Windows\Temp\sacl_common_task_script.ps1"
$resultPath = "C:\Windows\Temp\sacl_common_result.txt"

Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
Set-Content -Path $scriptPath -Value $innerScript

schtasks /Create /TN $taskName /TR "powershell.exe -ExecutionPolicy Bypass -File $scriptPath" /SC ONCE /ST 00:00 /RU "SYSTEM" /RL HIGHEST /F | Out-Null
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
    throw "Common SACL configuration task reported an error (see output above)"
}
