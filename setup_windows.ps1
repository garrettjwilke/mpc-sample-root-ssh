# Host-side preparation with Windows PowerShell + OpenSSH Client.
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Autorun = Join-Path $Root 'autorun'
$ClientKey = if ($env:MPC_CLIENT_KEY) { $env:MPC_CLIENT_KEY } else { Join-Path $HOME '.ssh\mpc_sample_client_ed25519' }
$HostKey = Join-Path $Autorun 'ssh_host_ed25519_key'
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    throw 'ssh-keygen is required. Enable the Windows OpenSSH Client optional feature first.'
}
[byte[]]$Payload = [IO.File]::ReadAllBytes((Join-Path $Autorun 'autorun.json')) +
    [IO.File]::ReadAllBytes((Join-Path $Autorun 'autorun.sh')) +
    [Text.Encoding]::ASCII.GetBytes('f7bed1c9-7e90-4731-9194-c996666b4331')
$Hasher = [Security.Cryptography.SHA256]::Create()
try { $Actual = ([BitConverter]::ToString($Hasher.ComputeHash($Payload))).Replace('-', '').ToLowerInvariant() }
finally { $Hasher.Dispose() }
$Expected = [IO.File]::ReadAllText((Join-Path $Autorun 'autorun.check'))
if ($Expected.Length -ne 64 -or $Actual -cne $Expected) { throw 'autorun.check mismatch; use a clean download.' }
Write-Host 'AUTORUN_CHECK_VERIFIED'
foreach ($Path in @($ClientKey, "$ClientKey.pub", (Join-Path $Autorun 'authorized_keys'), $HostKey, "$HostKey.pub")) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite $Path. Use a clean extraction and a new MPC_CLIENT_KEY path if needed." }
}
[IO.Directory]::CreateDirectory((Split-Path -Parent $ClientKey)) | Out-Null
Write-Host 'Creating your CLIENT key. Choose a passphrase when prompted.'
& ssh-keygen -t ed25519 -a 64 -f $ClientKey -C 'mpc-sample-client'
if ($LASTEXITCODE -ne 0) { throw 'Client key generation failed.' }
[IO.File]::Copy("$ClientKey.pub", (Join-Path $Autorun 'authorized_keys'))
Write-Host 'Creating the separate SERVER HOST key. Leave its passphrase EMPTY: press Enter twice.'
& ssh-keygen -t ed25519 -f $HostKey -C 'mpc-sample-host'
if ($LASTEXITCODE -ne 0) { throw 'Host key generation failed.' }
Write-Host 'PERSONAL_AUTORUN_PREPARED'
Write-Host 'Expected MPC host fingerprint (compare on first connection):'
& ssh-keygen -lf "$HostKey.pub"
if ($LASTEXITCODE -ne 0) { throw 'Could not read host fingerprint.' }
Write-Host 'Copy the complete autorun/ directory to the ROOT of an exFAT SD card.'
Write-Host 'Keep the client private key on this computer. Do not publish the prepared folder.'
Write-Host "Connect: ssh -p 2222 -i `"$ClientKey`" root@192.168.155.1"
