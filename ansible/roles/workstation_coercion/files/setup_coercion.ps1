$ErrorActionPreference = "Stop"

# WebClient (WebDAV Redirector) -- normally only starts on-demand when a
# WebDAV UNC path is referenced. Setting it to Automatic makes it always
# running, which is the actual "trigger" this finding needs (a coercion
# technique like PetitPotam/WebClient-based coercion needs the service
# listening, not just installable on demand).
Set-Service -Name WebClient -StartupType Automatic
Start-Service -Name WebClient -ErrorAction SilentlyContinue
Write-Output "WebClient set to Automatic and started"

# Standard weakenings documented for local NTLM reflection PoCs. Flagged
# best-effort in the plan -- genuine reflection-to-SYSTEM is patch-level
# sensitive and not independently re-verified with a live exploit here.
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "DisableLoopbackCheck" -PropertyType DWord -Value 1 -Force | Out-Null
Write-Output "Disabled loopback check (allows NTLM auth to reflect back to this machine)"

New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RequireSecuritySignature" -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "RequireSecuritySignature" -PropertyType DWord -Value 0 -Force | Out-Null
Write-Output "Disabled SMB signing requirement (client and server)"

Write-Output "DONE"
