#!/usr/bin/env pwsh
# Installs a signed HAP on a HarmonyOS device over hdc.
#
# Usage:
#   pwsh -File scripts/install.ps1 -Hap entry\build\default\outputs\default\entry-default-signed.hap
#   pwsh -File scripts/install.ps1 -Uninstall
#
# A HAP must be signed by a certificate the phone trusts (DevEco automatic signing, or a debug
# certificate issued for this device). The unsigned build artifact cannot be installed: on a
# HarmonyOS 7.0.0 phone it fails with "code:9568320 error: no signature file".

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

# hdc 3.2.0f reports install/uninstall failures on stdout but still exits 0, so the exit code
# alone cannot be trusted. Treat any error/fail wording in the output as a failure and print it.
function Invoke-Hdc([string]$Label, [string[]]$HdcArgs) {
  $output = @(& $hdc @targetArgs @HdcArgs 2>&1 | ForEach-Object { "$_" })
  $output | ForEach-Object { Write-Host $_ }
  $text = $output -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "$Label failed: hdc exited with code $LASTEXITCODE"
  }
  if ($text -match '(?i)\berror\b|\bfail(ed|ure)?\b') {
    throw "$Label failed (hdc exit code was 0, so the message above is the real verdict)"
  }
  Write-Host "$Label ok"
}

if ($Uninstall) {
  Invoke-Hdc 'uninstall' @('uninstall', 'io.github.crazyjason.dshmobile.hmos')
  exit 0
}

if (-not $Hap) { throw 'Pass -Hap with the path to a signed HAP, or -Uninstall.' }
if (-not (Test-Path $Hap)) { throw "HAP not found: $Hap" }

Write-Host "hdc   : $hdc"
Invoke-Hdc 'install' @('install', '-r', $Hap)
exit 0
