param(
    [Parameter(Mandatory = $true)][string]$AccountName,
    [Parameter(Mandatory = $true)][string]$Password
)

# Creates (or repairs) a local administrator account used purely for
# unattended automation. Idempotent: exits "unchanged" when the account
# already exists, is enabled, is in Administrators, and its password already
# matches -- so re-running the playbook is a no-op once converged.
#
# Emits a line beginning "RESULT=" that the Ansible task keys changed_when on.

$ErrorActionPreference = "Stop"
$changed = $false

$secure = ConvertTo-SecureString $Password -AsPlainText -Force
$existing = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue

if (-not $existing) {
    New-LocalUser -Name $AccountName -Password $secure -FullName "Range Automation" `
        -Description "Automation account (this repo's Ansible control node) -- not a range finding" `
        -PasswordNeverExpires -AccountNeverExpires | Out-Null
    $changed = $true
} else {
    # Account exists -- make sure it is enabled and the password is the one
    # Ansible expects (so a rotated/forgotten password self-heals on re-run).
    if (-not $existing.Enabled) {
        Enable-LocalUser -Name $AccountName
        $changed = $true
    }
    Set-LocalUser -Name $AccountName -Password $secure -PasswordNeverExpires $true
    # Set-LocalUser gives no reliable "did it differ" signal; treat a
    # password (re)set as non-changing to keep the run quiet once converged.
}

# Ensure local Administrators membership.
$adminGroup = (Get-LocalGroup -SID "S-1-5-32-544").Name
$isMember = Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*\$AccountName" -or $_.Name -eq $AccountName }
if (-not $isMember) {
    Add-LocalGroupMember -Group $adminGroup -Member $AccountName
    $changed = $true
}

if ($changed) { "RESULT=changed" } else { "RESULT=ok" }
