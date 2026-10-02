$ErrorActionPreference = "Stop"

$adminPassword = $env:ADMIN_PASSWORD
if (-not $adminPassword) { throw "ADMIN_PASSWORD environment variable not set" }

# Grant 'user' read access to sql2's LAPS password.
#
# NOTE: do NOT use Set-LapsADReadPasswordPermission here. That cmdlet writes an
# ACE scoped to InheritanceType=Descendents (it is designed to be pointed at an
# OU/container so the right is inherited by the *computer objects inside it*).
# Pointed at a single leaf computer object (sql2), the ACE applies only to
# sql2's non-existent descendant computers, so it grants nothing effective on
# sql2 itself -- the ACE looks correct in a casual ACL dump but the account
# still cannot read the password. Instead we write a DIRECT ACE on sql2.
#
# msLAPS-Password is a CONFIDENTIAL attribute, so reading it requires both
# RIGHT_DS_READ_PROPERTY and RIGHT_DS_CONTROL_ACCESS (ReadProperty + ExtendedRight
# in the ActiveDirectoryRights enum) scoped to the attribute's schemaIDGUID.
#
# Same NTLM double-hop workaround as the rest of this role -- the directory
# write runs inside a one-shot scheduled task under real password auth.
$innerScript = @'
$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
$resultPath = "C:\Windows\Temp\laps_read_grant_result.txt"
try {
    $dn      = "AD:CN=SQL2,CN=Computers,DC=cyberhawks,DC=lab"
    $userSid = (Get-ADUser user).SID
    $gPw     = [guid]'8411e67d-c911-43a7-ae75-7598def09900'   # msLAPS-Password
    $gExp    = [guid]'dbd2d4b6-0edc-4cf4-bab7-52b94aa53893'   # msLAPS-PasswordExpirationTime
    $none    = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow

    $acl = Get-Acl $dn

    # Remove any prior user ACEs on the LAPS attributes (e.g. the dead
    # Descendents-scoped ones a previous Set-LapsADReadPasswordPermission left)
    # so re-runs converge on exactly the direct ACEs below.
    $lapsGuids = @(
        '8411e67d-c911-43a7-ae75-7598def09900',   # msLAPS-Password
        '814e73c3-569b-420f-8f27-d2b3e94dc5b5',   # msLAPS-EncryptedPassword
        'a1f5159f-0bb8-4e0c-85cb-7e9af84b6ba1',   # msLAPS-EncryptedPasswordHistory
        'dbd2d4b6-0edc-4cf4-bab7-52b94aa53893'    # msLAPS-PasswordExpirationTime
    )
    $stale = $acl.Access | Where-Object {
        $_.IdentityReference -like '*\user' -and $_.ObjectType.ToString() -in $lapsGuids
    }
    foreach ($ace in $stale) { [void]$acl.RemoveAccessRule($ace) }

    # Direct ACEs (This object only): read the confidential password attribute
    # plus its expiration-time metadata.
    $r1 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $userSid, [System.DirectoryServices.ActiveDirectoryRights]"ReadProperty,ExtendedRight", $allow, $gPw, $none)
    $r2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $userSid, [System.DirectoryServices.ActiveDirectoryRights]"ReadProperty", $allow, $gExp, $none)
    $acl.AddAccessRule($r1)
    $acl.AddAccessRule($r2)

    Set-Acl -Path $dn -AclObject $acl
    "Granted user direct LAPS password read on sql2 (removed $($stale.Count) stale ACE(s))" | Out-File -FilePath $resultPath
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
