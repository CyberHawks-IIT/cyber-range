$ErrorActionPreference = "Stop"

# Advanced Audit Policy subcategories needed to actually produce the Windows
# event IDs splunk-detections/detections/backlog.md depends on (see
# cyber-range's CLAUDE.md, "Monitoring rollout plan" step 2). None of these
# fire on their own -- Windows ships with most Object Access / DS Access /
# Account Logon subcategories disabled by default, so the detections that
# assume 4656/4662/4769/5136/etc. simply never see anything without this.
#
# HKLM\SYSTEM\CurrentControlSet\Control\Lsa denies write access to a merely-
# elevated Administrator token on these VMs (confirmed live -- New-Item there
# throws UnauthorizedAccessException even from an Administrator WinRM
# session), the same class of problem as HKLM\SAM/SECURITY in
# configure_sacls_common.ps1. Run the whole thing as SYSTEM via a one-shot
# scheduled task rather than chase down exactly which ACL is blocking it.
$innerScript = @'
$ErrorActionPreference = "Stop"
$resultPath = "C:\Windows\Temp\audit_policy_result.txt"
try {
    $subcategories = @(
        @{ Name = "Process Creation";                  Success = $true; Failure = $false }, # 4688
        @{ Name = "Logon";                              Success = $true; Failure = $true  }, # 4624/4625
        @{ Name = "Other Logon/Logoff Events";          Success = $true; Failure = $true  }, # anonymous logon detail
        @{ Name = "Kerberos Authentication Service";    Success = $true; Failure = $true  }, # 4768/4771
        @{ Name = "Kerberos Service Ticket Operations"; Success = $true; Failure = $true  }, # 4769 (Kerberoasting)
        @{ Name = "User Account Management";            Success = $true; Failure = $true  }, # 4720
        @{ Name = "Computer Account Management";        Success = $true; Failure = $true  }, # 4741
        @{ Name = "Security Group Management";          Success = $true; Failure = $true  }, # 4728/4732/4756
        @{ Name = "Directory Service Access";           Success = $true; Failure = $true  }, # 4662 (DCSync)
        @{ Name = "Directory Service Changes";          Success = $true; Failure = $true  }, # 5136/5137
        @{ Name = "File System";                        Success = $true; Failure = $true  }, # 4656/4663 file SACLs
        @{ Name = "Registry";                           Success = $true; Failure = $true  }, # 4656/4657/4663 registry SACLs
        @{ Name = "Other Object Access Events";         Success = $true; Failure = $true  }, # 4697/4698
        @{ Name = "Audit Policy Change";                Success = $true; Failure = $true  }  # policy-change coverage
    )

    $lines = @()

    # Advanced audit policy subcategory settings only stay authoritative once
    # legacy category-level settings are told not to override them. Nothing
    # in this range currently applies old-style audit settings via GPO, but
    # the Default Domain Policy GPO is directly writable by design (see the
    # ACL-abuse findings) -- this is cheap insurance against that silently
    # clobbering these subcategories later.
    # New-Item -Force on an EXISTING registry key does a delete-then-recreate
    # of the whole subtree, not an in-place update -- confirmed live and the
    # hard way (it wiped this exact key's Kerberos/MSV1_0/etc. subkeys and
    # values on two hosts before this guard was added). HKLM:\...\Control\Lsa
    # always exists on a running Windows install, so -Force here would only
    # ever hit the destructive path, never the "create new" one -- there's no
    # safe use of it against this key.
    if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa")) {
        New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "SCENoApplyLegacyAuditPolicy" -Value 1 -Type DWord
    $lines += "Set SCENoApplyLegacyAuditPolicy=1"

    foreach ($sub in $subcategories) {
        $successFlag = if ($sub.Success) { "enable" } else { "disable" }
        $failureFlag = if ($sub.Failure) { "enable" } else { "disable" }
        auditpol /set /subcategory:"$($sub.Name)" /success:$successFlag /failure:$failureFlag | Out-Null
        $lines += "Set audit subcategory '$($sub.Name)' (success:$successFlag failure:$failureFlag)"
    }

    $lines | Out-File -FilePath $resultPath
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $resultPath -Append
}
'@

$taskName = "AuditPolicy_$(Get-Random)"
$scriptPath = "C:\Windows\Temp\audit_policy_task_script.ps1"
$resultPath = "C:\Windows\Temp\audit_policy_result.txt"

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
    throw "Audit policy configuration task reported an error (see output above)"
}
