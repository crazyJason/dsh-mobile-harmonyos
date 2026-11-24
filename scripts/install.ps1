#!/usr/bin/env pwsh
# Installs a signed HAP on a HarmonyOS device over hdc.
#
# Usage:
#   pwsh -File scripts/install.ps1 -Hap entry\build\default\outputs\default\entry-default-signed.hap
#   pwsh -File scripts/install.ps1 -Uninstall
#
# A HAP must be signed by a certificate the phone trusts (DevEco automatic signing, or a debug
# certificate issued for this device). The unsigned build artifact cannot be installed.

param(
  [string]$Hap,
  [string]$Device = '',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$devecoCandidates = @(
  $env:DEVECO_STUDIO_HOME,
  'D:\Programs\Huawei\DevEcoStudio',
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ -and (Test-Path $_) }

if ($devecoCandidates.Count -eq 0) {
  throw 'DevEco Studio was not found. Set DEVECO_STUDIO_HOME to the installation directory.'
}
$deveco = [string]@($devecoCandidates)[0]
$hdc = Get-ChildItem -Path (Join-Path $deveco 'sdk') -Filter 'hdc.exe' -Recurse -ErrorAction SilentlyContinue |
  Select-Object -First 1 -ExpandProperty FullName
if (-not $hdc) { throw 'hdc.exe not found in the DevEco SDK.' }

$targetArgs = @()
if ($Device) { $targetArgs = @('-t', $Device) }

if ($Uninstall) {
  & $hdc @targetArgs uninstall 'io.github.crazyjason.dshmobile.hmos'
  exit $LASTEXITCODE
}

if (-not $Hap) { throw 'Pass -Hap with the path to a signed HAP, or -Uninstall.' }
if (-not (Test-Path $Hap)) { throw "HAP not found: $Hap" }

Write-Host "hdc   : $hdc"
& $hdc @targetArgs install -r $Hap
exit $LASTEXITCODE
