#Requires -RunAsAdministrator
# Builds the host-privilege-escalation findings on workstation for the
# low-priv domain "user" account. Idempotent - safe to re-run.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$DomainUser      = 'CYBERHAWKS\user'
$DomainUserSid   = (New-Object System.Security.Principal.NTAccount('CYBERHAWKS','user')).Translate([System.Security.Principal.SecurityIdentifier]).Value
$LocalAdminPw    = 'S@lcianaszkot23'
$CscExe          = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

function Write-Step($msg) { Write-Host "=== $msg ===" }

function Set-UserRight {
    param([string]$Right, [string]$Sid, [switch]$Remove)
    $cfgPath = "$env:WINDIR\Temp\secpol_privesc_$Right.cfg"
    secedit /export /cfg $cfgPath /areas USER_RIGHTS | Out-Null
    $cfg = Get-Content $cfgPath
    $lineIdx = ($cfg | Select-String "^$Right").LineNumber
    $hasSid = $lineIdx -and ($cfg[$lineIdx-1] -match [regex]::Escape($Sid))
    if ($Remove) {
        if ($hasSid) {
            $cfg[$lineIdx-1] = ($cfg[$lineIdx-1] -replace "(,\*$Sid|\*$Sid,)", '' -replace "\*$Sid$", '')
            $cfg | Set-Content $cfgPath
            secedit /configure /db "$env:WINDIR\security\local_privesc.sdb" /cfg $cfgPath /areas USER_RIGHTS | Out-Null
            Write-Host "$Right revoked from SID $Sid"
        } else {
            Write-Host "$Right already does not include SID $Sid"
        }
    } else {
        if ($hasSid) {
            Write-Host "$Right already granted to SID $Sid"
        } else {
            if ($lineIdx) {
                $cfg[$lineIdx-1] = $cfg[$lineIdx-1] + ",*$Sid"
            } else {
                $insertAt = ($cfg | Select-String '^\[Privilege Rights\]').LineNumber
                $cfg = $cfg[0..($insertAt-1)] + "$Right = *$Sid" + $cfg[$insertAt..($cfg.Count-1)]
            }
            $cfg | Set-Content $cfgPath
            secedit /configure /db "$env:WINDIR\security\local_privesc.sdb" /cfg $cfgPath /areas USER_RIGHTS | Out-Null
            Write-Host "$Right granted to SID $Sid"
        }
    }
    Remove-Item $cfgPath -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 1. RDP + WinRM access for the low-priv domain user (no local admin rights)
# ---------------------------------------------------------------------------
Write-Step "RDP enablement"

$tsKey = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
if ((Get-ItemProperty $tsKey -Name fDenyTSConnections).fDenyTSConnections -ne 0) {
    Set-ItemProperty $tsKey -Name fDenyTSConnections -Value 0
    Write-Host "fDenyTSConnections set to 0"
} else {
    Write-Host "RDP already enabled"
}

Set-Service -Name TermService -StartupType Automatic
if ((Get-Service TermService).Status -ne 'Running') { Start-Service TermService }

Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Enable-NetFirewallRule

$rdpMembers = Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction SilentlyContinue
if (-not ($rdpMembers | Where-Object { $_.SID -eq $DomainUserSid })) {
    Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $DomainUser
    Write-Host "Added $DomainUser to Remote Desktop Users"
} else {
    Write-Host "$DomainUser already in Remote Desktop Users"
}

Write-Step "WinRM access (non-admin) for the low-priv domain user"

$wrmMembers = Get-LocalGroupMember -Group 'Remote Management Users' -ErrorAction SilentlyContinue
if (-not ($wrmMembers | Where-Object { $_.SID -eq $DomainUserSid })) {
    Add-LocalGroupMember -Group 'Remote Management Users' -Member $DomainUser
    Write-Host "Added $DomainUser to Remote Management Users"
} else {
    Write-Host "$DomainUser already in Remote Management Users"
}

# Group membership alone isn't enough - the WinRM service's own RootSDDL
# (WSMan:\localhost\Service\RootSDDL) only grants BUILTIN\Administrators and
# Interactive Users by default, which blocks the raw/WinRS shell (though not
# PowerShell-remoting session config, which already allows Remote Management
# Users). Add an explicit ACE for the Remote Management Users SID (S-1-5-32-580).
$rmuSid = 'S-1-5-32-580'
$rootSddl = (Get-Item WSMan:\localhost\Service\RootSDDL).Value
if ($rootSddl -notmatch [regex]::Escape($rmuSid)) {
    $newRootSddl = $rootSddl -replace 'D:P', "D:P(A;;GA;;;$rmuSid)"
    Set-Item WSMan:\localhost\Service\RootSDDL $newRootSddl -Force
    Write-Host "Added Remote Management Users to WinRM RootSDDL"
} else {
    Write-Host "WinRM RootSDDL already grants Remote Management Users"
}

# Confirm not a local admin (should never be - this is the whole point)
$admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
if ($admins | Where-Object { $_.SID -eq $DomainUserSid }) {
    throw "$DomainUser is a local Administrator on workstation - this must NOT be the case, aborting"
}
Write-Host "Confirmed $DomainUser is NOT a local Administrator"

# ---------------------------------------------------------------------------
# 2. SeImpersonatePrivilege granted directly to the low-priv user
# ---------------------------------------------------------------------------
Write-Step "SeImpersonatePrivilege grant"
Set-UserRight -Right 'SeImpersonatePrivilege' -Sid $DomainUserSid

# ---------------------------------------------------------------------------
# 3. Force first logon for the domain user (materializes the profile /
#    NTUSER.DAT), then plant cleartext local-admin creds in PSReadLine
#    history and set the per-user AlwaysInstallElevated key.
# ---------------------------------------------------------------------------
Write-Step "Force profile creation for $DomainUser"

$profilePath = 'C:\Users\user'
if (-not (Test-Path $profilePath)) {
    # Domain users don't have "Log on as a batch job" by default on a
    # workstation - grant it temporarily just to bootstrap the profile,
    # then revoke it again so it isn't left as an extra, unintended right.
    Set-UserRight -Right 'SeBatchLogonRight' -Sid $DomainUserSid

    $taskName = 'CyberHawksTempProfileInit'
    $startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
    schtasks /Create /TN $taskName /TR "cmd.exe /c whoami" /SC ONCE /ST $startTime /RU $DomainUser /RP 'password' /RL LIMITED /F | Out-Null
    schtasks /Run /TN $taskName | Out-Null
    $waited = 0
    while (-not (Test-Path $profilePath) -and $waited -lt 90) {
        Start-Sleep -Seconds 3
        $waited += 3
    }
    schtasks /Delete /TN $taskName /F | Out-Null

    Set-UserRight -Right 'SeBatchLogonRight' -Sid $DomainUserSid -Remove

    if (-not (Test-Path $profilePath)) { throw "Profile for $DomainUser did not materialize in time" }
    Write-Host "Profile created at $profilePath after ${waited}s"
} else {
    Write-Host "Profile already exists at $profilePath"
}

Write-Step "PowerShell history with cleartext local admin creds"

$psrlDir = "$profilePath\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine"
if (-not (Test-Path $psrlDir)) { New-Item -Path $psrlDir -ItemType Directory -Force | Out-Null }
$histFile = "$psrlDir\ConsoleHost_history.txt"
$histMarker = 'net use \\workstation\C$'
$histLines = @(
    'whoami',
    'ipconfig /all',
    ('net use \\workstation\C$ /user:Administrator "' + $LocalAdminPw + '"'),
    'dir \\workstation\C$'
)
if (-not (Test-Path $histFile) -or -not (Select-String -Path $histFile -Pattern ([regex]::Escape($histMarker)) -Quiet)) {
    Add-Content -Path $histFile -Value $histLines
    Write-Host "Planted cleartext Administrator credential in $histFile"
} else {
    Write-Host "PowerShell history already contains the planted credential"
}

Write-Step "Per-user AlwaysInstallElevated (HKCU via offline hive load)"

$ntuserPath = "$profilePath\NTUSER.DAT"
$hiveKey = 'HKU\CyberHawksTempHive'
reg load $hiveKey $ntuserPath | Out-Null
try {
    $installerKey = "$hiveKey\SOFTWARE\Policies\Microsoft\Windows\Installer"
    reg add $installerKey /v AlwaysInstallElevated /t REG_DWORD /d 1 /f | Out-Null
} finally {
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 1
    reg unload $hiveKey | Out-Null
}
Write-Host "Per-user AlwaysInstallElevated set for $DomainUser"

# ---------------------------------------------------------------------------
# 4. Machine-wide AlwaysInstallElevated (both halves needed for exploitation)
# ---------------------------------------------------------------------------
Write-Step "Machine-wide AlwaysInstallElevated"

$machineInstallerKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
if (-not (Test-Path $machineInstallerKey)) { New-Item -Path $machineInstallerKey -Force | Out-Null }
Set-ItemProperty -Path $machineInstallerKey -Name AlwaysInstallElevated -Value 1 -Type DWord
Write-Host "HKLM AlwaysInstallElevated = 1"

# ---------------------------------------------------------------------------
# 5. Autologon creds for the local Administrator, readable by any user
# ---------------------------------------------------------------------------
Write-Step "Autologon credentials for local Administrator"

$winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogonKey -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty -Path $winlogonKey -Name DefaultUserName -Value 'Administrator' -Type String
Set-ItemProperty -Path $winlogonKey -Name DefaultPassword -Value $LocalAdminPw -Type String
Set-ItemProperty -Path $winlogonKey -Name DefaultDomainName -Value 'WORKSTATION' -Type String
Write-Host "Autologon set for WORKSTATION\Administrator"

Write-Host "=== Phase 1 (accounts/registry/history) complete ==="

# ---------------------------------------------------------------------------
# 6. Four custom services, each a distinct service-abuse primitive.
#    All share one tiny compiled C# ServiceBase binary; only the OnStart
#    body and file/service ACLs differ.
# ---------------------------------------------------------------------------
Write-Step "Custom services setup"

$csTemplate = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;

namespace CyberHawksSvc
{
    public class Svc : ServiceBase
    {
        public Svc() { ServiceName = "__SVCNAME__"; }

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        static extern IntPtr LoadLibrary(string lpFileName);

        protected override void OnStart(string[] args)
        {
            string log = @"__LOGPATH__";
            __EXTRACODE__
            File.AppendAllText(log, DateTime.Now + " - started" + Environment.NewLine);
        }

        protected override void OnStop()
        {
            string log = @"__LOGPATH__";
            File.AppendAllText(log, DateTime.Now + " - stopped" + Environment.NewLine);
        }

        static void Main() { ServiceBase.Run(new Svc()); }
    }
}
'@

function New-CyberHawksService {
    param(
        [string]$SvcName,
        [string]$DisplayName,
        [string]$Dir,
        [string]$ExeName,
        [string]$BinPath,
        [string]$ExtraCode = '',
        [string]$SddlRights,
        [switch]$GrantFileAcl,
        [switch]$GrantFolderAcl
    )

    if (-not (Test-Path $Dir)) { New-Item -Path $Dir -ItemType Directory -Force | Out-Null }
    $exePath = Join-Path $Dir $ExeName
    $csPath  = Join-Path $Dir ($ExeName -replace '\.exe$', '.cs')
    $logPath = Join-Path $Dir 'service.log'

    if (-not (Test-Path $exePath)) {
        $src = $csTemplate.Replace('__SVCNAME__', $SvcName).Replace('__LOGPATH__', $logPath).Replace('__EXTRACODE__', $ExtraCode)
        Set-Content -Path $csPath -Value $src
        & $CscExe /nologo /target:winexe /out:"$exePath" /reference:System.ServiceProcess.dll "$csPath" | Out-Null
        if (-not (Test-Path $exePath)) { throw "Failed to compile $exePath" }
        Write-Host "Compiled $exePath"
    } else {
        Write-Host "$exePath already compiled"
    }

    if (-not (Get-Service -Name $SvcName -ErrorAction SilentlyContinue)) {
        sc.exe create $SvcName binPath= "$BinPath" start= demand DisplayName= "$DisplayName" | Out-Null
        Write-Host "Created service $SvcName"
    } else {
        Write-Host "Service $SvcName already exists"
    }

    if ($GrantFileAcl) {
        $acl = icacls $exePath
        if ($acl -notmatch [regex]::Escape($DomainUser)) {
            icacls $exePath /grant "${DomainUser}:(M)" | Out-Null
            Write-Host "Granted Modify on $exePath to $DomainUser"
        }
    }
    if ($GrantFolderAcl) {
        $acl = icacls $Dir
        if ($acl -notmatch [regex]::Escape($DomainUser)) {
            icacls $Dir /grant "${DomainUser}:(OI)(CI)M" | Out-Null
            Write-Host "Granted Modify on $Dir to $DomainUser"
        }
    }

    $curSddl = sc.exe sdshow $SvcName
    $curSddl = ($curSddl -join '').Trim()
    # Strip any pre-existing ACE for this SID first, then re-add with the
    # requested rights - re-runnable even if the granted right set changes.
    $strippedSddl = $curSddl -replace "\(A;;[A-Z]+;;;$DomainUserSid\)", ''
    $desiredAce = "(A;;$SddlRights;;;$DomainUserSid)"
    if ($strippedSddl -notmatch [regex]::Escape($desiredAce)) {
        $newSddl = $strippedSddl -replace '^(D:)', "`$1$desiredAce"
        sc.exe sdset $SvcName $newSddl | Out-Null
        Write-Host "Granted service rights ($SddlRights) on $SvcName to $DomainUser"
    } else {
        Write-Host "Service $SvcName already grants rights ($SddlRights) to $DomainUser"
    }

    # Prove the service actually runs, then leave it stopped/demand-start so
    # the student is the one who restarts it after tampering.
    Start-Service -Name $SvcName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name $SvcName
    Write-Host "$SvcName status after test-start: $($svc.Status)"
    Stop-Service -Name $SvcName -ErrorAction SilentlyContinue
}

# 6a. Writable service BINARY - WorkstationHealthMonitor
#     RP (start) + WP (stop) at the SC level; write access on the exe file.
New-CyberHawksService -SvcName 'WorkstationHealthMonitor' -DisplayName 'Workstation Health Monitor' `
    -Dir 'C:\ProgramData\CyberHawks\HealthMonitor' -ExeName 'HealthMonitorSvc.exe' `
    -BinPath 'C:\ProgramData\CyberHawks\HealthMonitor\HealthMonitorSvc.exe' `
    -SddlRights 'RPWPLC' -GrantFileAcl

# 6b. Writable service CONFIG (sc config) - WorkstationBackupAgent
#     DC (change config) + RP + WP at the SC level; file itself stays admin-only.
New-CyberHawksService -SvcName 'WorkstationBackupAgent' -DisplayName 'Workstation Backup Agent' `
    -Dir 'C:\ProgramData\CyberHawks\BackupAgent' -ExeName 'BackupAgentSvc.exe' `
    -BinPath 'C:\ProgramData\CyberHawks\BackupAgent\BackupAgentSvc.exe' `
    -SddlRights 'DCRPWPLC'

# 6c. Unquoted service path with a writable intermediate folder - WorkstationDeploySvc
#     binPath (unquoted, contains spaces) resolves "C:\Program Files\Vulnerable
#     Service\Sub.exe" as an earlier candidate than the real exe; that folder
#     ("...\Vulnerable Service") is writable by the low-priv user.
$deploySvcDir = 'C:\Program Files\Vulnerable Service'
$deploySvcSub = Join-Path $deploySvcDir 'Sub Folder'
if (-not (Test-Path $deploySvcSub)) { New-Item -Path $deploySvcSub -ItemType Directory -Force | Out-Null }
New-CyberHawksService -SvcName 'WorkstationDeploySvc' -DisplayName 'Workstation Deploy Service' `
    -Dir $deploySvcSub -ExeName 'svc.exe' `
    -BinPath (Join-Path $deploySvcSub 'svc.exe') `
    -SddlRights 'RPWPLC'
# binPath is registered unquoted (sc.exe's own quoting is just for its CLI
# parser - the stored ImagePath has no quotes), so the vulnerable candidate
# "C:\Program Files\Vulnerable Service\Sub.exe" lands one level up, inside
# $deploySvcDir, which is the folder actually granted to the low-priv user.
if ((icacls $deploySvcDir) -notmatch [regex]::Escape($DomainUser)) {
    icacls $deploySvcDir /grant "${DomainUser}:(OI)(CI)M" | Out-Null
    Write-Host "Granted Modify on $deploySvcDir to $DomainUser (unquoted-path target folder)"
}

# 6d. DLL hijack - WorkstationReportSvc
#     Loads "wkstnutil.dll" by bare name (no path) from its own app directory,
#     which is writable by the low-priv user - classic search-order hijack.
New-CyberHawksService -SvcName 'WorkstationReportSvc' -DisplayName 'Workstation Report Service' `
    -Dir 'C:\Apps\ReportTool' -ExeName 'ReportTool.exe' `
    -BinPath 'C:\Apps\ReportTool\ReportTool.exe' `
    -ExtraCode 'try { IntPtr h = LoadLibrary("wkstnutil.dll"); File.AppendAllText(log, DateTime.Now + " - LoadLibrary(wkstnutil.dll) = " + h + Environment.NewLine); } catch {}' `
    -SddlRights 'RPWPLC' -GrantFolderAcl

Write-Host "=== Phase 2 (custom services) complete ==="

# ---------------------------------------------------------------------------
# 7. Writable SYSTEM scheduled task (script the low-priv user can edit)
# ---------------------------------------------------------------------------
Write-Step "Writable SYSTEM scheduled task"

$maintDir = 'C:\ProgramData\CyberHawks\Maintenance'
if (-not (Test-Path $maintDir)) { New-Item -Path $maintDir -ItemType Directory -Force | Out-Null }
$maintScript = Join-Path $maintDir 'cleanup.ps1'
if (-not (Test-Path $maintScript)) {
    Set-Content -Path $maintScript -Value '"$(Get-Date) - maintenance run" | Add-Content "C:\ProgramData\CyberHawks\Maintenance\cleanup.log"'
    Write-Host "Wrote $maintScript"
}
if ((icacls $maintScript) -notmatch [regex]::Escape($DomainUser)) {
    icacls $maintScript /grant "${DomainUser}:(M)" | Out-Null
    Write-Host "Granted Modify on $maintScript to $DomainUser"
}

$taskName = 'CyberHawksMaintenance'
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$maintScript`""
    $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Host "Registered scheduled task $taskName (runs as SYSTEM every 5 min)"
} else {
    Write-Host "Scheduled task $taskName already exists"
}
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
if (Test-Path (Join-Path $maintDir 'cleanup.log')) {
    Write-Host "Verified: $taskName ran and produced cleanup.log"
} else {
    Write-Host "WARNING: cleanup.log not found yet after triggering $taskName"
}

Write-Host "=== Phase 3 (scheduled task) complete ==="
Write-Host "=== ALL PHASES COMPLETE ==="
