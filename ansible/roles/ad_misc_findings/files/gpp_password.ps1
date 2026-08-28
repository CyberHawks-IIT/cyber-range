$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
Import-Module GroupPolicy

$gppPassword = $env:GPP_PASSWORD
if (-not $gppPassword) { throw "GPP_PASSWORD environment variable not set" }

function ConvertTo-GppCpassword {
    param([string]$Password)
    # The well-known, publicly-documented Microsoft GPP AES key -- this is
    # what makes GPP cpassword values trivially reversible by design.
    $key = [byte[]](0x4e, 0x99, 0x06, 0xe8, 0xfc, 0xb6, 0x6c, 0xc9, 0xfa, 0xf4, 0x93, 0x10, 0x62, 0x0f, 0xfe, 0xe8,
        0xf4, 0x96, 0xe8, 0x06, 0xcc, 0x05, 0x79, 0x90, 0x20, 0x9b, 0x09, 0xa4, 0x33, 0xb6, 0x6c, 0x1b)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key = $key
    $aes.IV = New-Object byte[] 16
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $encryptor = $aes.CreateEncryptor()
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($Password)
    $encrypted = $encryptor.TransformFinalBlock($bytes, 0, $bytes.Length)
    # GPP cpassword uses base64url, not standard base64: '+' -> '-', '/' -> '_', no padding.
    return [Convert]::ToBase64String($encrypted).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

# --- Move workstation into a dedicated OU so a GPO can actually be linked to it ---
$ouDN = "OU=Workstations,DC=cyberhawks,DC=lab"
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Workstations'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name "Workstations" -Path "DC=cyberhawks,DC=lab" -ProtectedFromAccidentalDeletion $false
    Write-Output "Created Workstations OU"
}
$wsComputer = Get-ADComputer "workstation"
if ($wsComputer.DistinguishedName -notlike "*$ouDN") {
    Move-ADObject -Identity $wsComputer.DistinguishedName -TargetPath $ouDN
    Write-Output "Moved workstation into Workstations OU"
}

# --- Create the GPO and write the GPP Local Users and Groups preference ---
$gpoName = "Workstation Local Admin Reset"
$gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $gpoName
    Write-Output "Created GPO $gpoName"
}
$gpoGuid = $gpo.Id.ToString("B").ToUpper()
$sysvolPath = "\\cyberhawks.lab\SYSVOL\cyberhawks.lab\Policies\$gpoGuid\Machine\Preferences\Groups"
if (-not (Test-Path $sysvolPath)) {
    New-Item -Path $sysvolPath -ItemType Directory -Force | Out-Null
}

$cpassword = ConvertTo-GppCpassword -Password $gppPassword
$changed = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$groupsXmlPath = "$sysvolPath\Groups.xml"

# Creating a brand-new local account (action="C") instead of updating the
# built-in Administrator avoids all well-known-RID-500 targeting ambiguity
# -- updating the built-in account via GPP repeatedly processed with no
# error ("Changes were detected", extension completed) but never actually
# changed the password on this Windows 11 build, for reasons not worth
# chasing further. A freshly-created local account demonstrates the exact
# same cpassword vulnerability just as validly.
$groupsXml = @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}"><User clsid="{DF5F1855-51E5-4d24-8B1A-D9BDE98BA1D1}" name="svc-helpdesk" image="2" changed="$changed" uid="{$([Guid]::NewGuid().ToString().ToUpper())}"><Properties action="C" newName="" fullName="Help Desk Service" description="Local account for help desk tooling" cpassword="$cpassword" changeLogon="0" noChange="0" neverExpires="1" acctDisabled="0" userName="svc-helpdesk"/></User></Groups>
"@
Set-Content -Path $groupsXmlPath -Value $groupsXml
Write-Output "Wrote GPP Groups.xml with encrypted cpassword"

# Register the GPP client-side extension so Group Policy actually processes
# Preferences (a GPO with no extensions declared gets ignored even if the
# XML files exist).
$gpoDN = "CN=$gpoGuid,CN=Policies,CN=System,DC=cyberhawks,DC=lab"
$extNames = "[{17D89FEC-5C44-4972-B12D-241CAEF74509}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]"
Set-ADObject -Identity $gpoDN -Replace @{ gPCMachineExtensionNames = $extNames }
Write-Output "Registered GPP client-side extension on the GPO"

# The client also gates on versionNumber (packed Machine/User version
# halves) matching gpt.ini's Version= -- both were left at 0 by New-GPO
# since we wrote SYSVOL content directly rather than through GPMC's own
# settings APIs, which is what actually makes gpresult treat this GPO as
# having no real content ("Filtering: Not Applied (Empty)"), independent
# of whether the extension GUID above is correct.
$newVersion = ([int](Get-ADObject -Identity $gpoDN -Properties versionNumber).versionNumber) + 1
Set-ADObject -Identity $gpoDN -Replace @{ versionNumber = $newVersion }
$gptIniPath = "\\cyberhawks.lab\SYSVOL\cyberhawks.lab\Policies\$gpoGuid\GPT.INI"
Set-Content -Path $gptIniPath -Value "[General]`r`nVersion=$newVersion"
Write-Output "Bumped GPO version so the client recognizes it has real content"

# --- Link the GPO to the Workstations OU ---
$existingLink = Get-GPInheritance -Target $ouDN
if (-not ($existingLink.GpoLinks | Where-Object { $_.DisplayName -eq $gpoName })) {
    New-GPLink -Name $gpoName -Target $ouDN | Out-Null
    Write-Output "Linked $gpoName to Workstations OU"
} else {
    Write-Output "$gpoName already linked to Workstations OU"
}

Write-Output "DONE"
