#!/usr/bin/env pwsh
# Builds the HarmonyOS HAP with the DevEco Studio toolchain installed on this machine.
#
# Usage:
#   pwsh -File scripts/build.ps1                 # debug HAP
#   pwsh -File scripts/build.ps1 -Mode release   # release HAP (still unsigned without a signing config)
#
# Override any path with the matching environment variable before running.

param(
  [ValidateSet('debug', 'release')]
  [string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'

$devecoCandidates = @(
  $env:DEVECO_STUDIO_HOME,
  'D:\Programs\Huawei\DevEcoStudio',
  'C:\Program Files\Huawei\DevEco Studio',
  "$env:LOCALAPPDATA\Huawei\DevEco Studio"
) | Where-Object { $_ -and (Test-Path $_) }

if ($devecoCandidates.Count -eq 0) {
  throw 'DevEco Studio was not found. Set DEVECO_STUDIO_HOME to the installation directory.'
}
$deveco = [string]@($devecoCandidates)[0]

$env:DEVECO_SDK_HOME = if ($env:DEVECO_SDK_HOME) { $env:DEVECO_SDK_HOME } else { Join-Path $deveco 'sdk' }
$env:NODE_HOME = if ($env:NODE_HOME) { $env:NODE_HOME } else { Join-Path $deveco 'tools\node' }
if (-not $env:JAVA_HOME) {
  $jdk = Join-Path $deveco 'jbr'
  if (-not (Test-Path $jdk)) { $jdk = 'E:\tools\jdk-17' }
  $env:JAVA_HOME = $jdk
}
$env:PATH = "$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"

$projectRoot = Split-Path -Parent $PSScriptRoot
$hvigor = Join-Path $deveco 'tools\hvigor\bin\hvigorw.js'
if (-not (Test-Path $hvigor)) {
  throw "hvigor wrapper not found at $hvigor"
}

Write-Host "DevEco Studio : $deveco"
Write-Host "SDK           : $env:DEVECO_SDK_HOME"
Write-Host "Node          : $env:NODE_HOME"
Write-Host "JDK           : $env:JAVA_HOME"
Write-Host "Mode          : $Mode"

Push-Location $projectRoot
try {
  & $env:NODE_HOME\node.exe $hvigor --mode module -p product=default -p module=entry@default `
      -p buildMode=$Mode assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) { throw "hvigor failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

$output = Join-Path $projectRoot "entry\build\default\outputs\default"
Get-ChildItem $output -Filter '*.hap' | ForEach-Object {
  Write-Host ("HAP: {0} ({1:N0} bytes)" -f $_.FullName, $_.Length)
}
Write-Host 'Installing this HAP needs a signing configuration; see docs/BUILD.md.'
