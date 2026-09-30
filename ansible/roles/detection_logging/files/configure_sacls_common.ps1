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
    # so audit every local profile that actually exists on this host rather
    # than guessing which accounts have logged on.
    #
    # The SACL goes on the FILES, never the folders. Auditing the folders
    # (the original design) was wrong twice over: (1) DPAPI creates the
    # per-user Protect\<SID> subfolder with a protected security descriptor,
    # so an inheritable folder ACE never propagated to the masterkey files --
    # reading a masterkey produced no 4663 at all; and (2) the only events it
    # did produce were ListDirectory on the folders, which false-fired on any
    # enumeration of the profile (host inventory, Windows Search) with no
    # credential ever read. Auditing ReadData on each file means a folder
    # listing is silent and only an actual read of a file's DATA -- the dump --
    # is logged. Inheritance is blocked on these folders, so the rule is
    # applied to each existing file directly (recursively). A masterkey
    # rotated after this run isn't covered until the role runs again, which is
    # the deliberate trade for zero enumeration false positives on a
    # snapshot-based range.
    $fileAudit = New-Object System.Security.AccessControl.FileSystemAuditRule(
        $everyone, "ReadData", "None", "None", "Success")
    $sidType = [System.Security.Principal.SecurityIdentifier]
    Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in @("AppData\Roaming\Microsoft\Protect",
                           "AppData\Roaming\Microsoft\Credentials",
                           "AppData\Local\Microsoft\Credentials")) {
            $root = Join-Path $_.FullName $sub
            if (-not (Test-Path $root)) { continue }
            $items = @(Get-Item -LiteralPath $root -Force) +
                     @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue)
            $set = 0
            foreach ($it in $items) {
                try {
                    $acl = Get-Acl -LiteralPath $it.FullName -Audit
                    # Clear any audit ACE (inherited or explicit) so folders carry none.
                    $acl.SetAuditRuleProtection($true, $false)
                    foreach ($r in @($acl.GetAuditRules($true, $false, $sidType))) { [void]$acl.RemoveAuditRule($r) }
                    if (-not $it.PSIsContainer) { $acl.AddAuditRule($fileAudit); $set++ }
                    Set-Acl -LiteralPath $it.FullName -AclObject $acl
                } catch {
                    $lines += "WARNING: could not set SACL on $($it.FullName) : $($_.Exception.Message)"
                }
            }
            $lines += "SACL set on $set file(s) under $root"
        }
    }

    # SAM/SECURITY hive-FILE theft via VSS shadow copy. The live hive files
    # are locked, so attackers copy them out of a shadow copy
    # (\Device\HarddiskVolumeShadowCopyN\Windows\System32\config\SAM). The
    # shadow copy inherits the file's security descriptor, so a ReadData SACL
    # on the on-disk hive file makes that read emit a 4663 naming the shadow
    # path -- the same file-SACL technique NTDS.dit Extraction uses. This
    # covers the "shadow copy" method; the HKLM\SAM|SECURITY registry-key
    # SACLs above cover the direct-registry query/export methods. SYSTEM can
    # set a SACL on the locked hive files (SD write, not data access).
    foreach ($hiveFile in @("C:\Windows\System32\config\SAM",
                            "C:\Windows\System32\config\SECURITY")) {
        try {
            $acl = Get-Acl -LiteralPath $hiveFile -Audit
            $acl.AddAuditRule($fileAudit)
            Set-Acl -LiteralPath $hiveFile -AclObject $acl
            $lines += "SACL set on $hiveFile"
        } catch {
            $lines += "WARNING: could not set SACL on $hiveFile : $($_.Exception.Message)"
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
