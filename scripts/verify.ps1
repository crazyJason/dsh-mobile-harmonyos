#!/usr/bin/env pwsh
# Repository verification gate. Exit code 0 means the tree is deliverable.
#
#   pwsh -File scripts/verify.ps1              # static checks + full HAP build
#   pwsh -File scripts/verify.ps1 -SkipBuild   # static checks only (seconds)
#
# Checks are deliberately mechanical: required files, config sanity, LF line endings, no signing
# material, no build artifacts in git, protocol guards from docs/adr, and resolvable doc links.

param(
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$script:failures = @()
$script:checks = 0

function Pass([string]$name) {
  $script:checks++
  Write-Host ("  ok    {0}" -f $name) -ForegroundColor DarkGreen
}

function Fail([string]$name, [string]$detail) {
  $script:checks++
  $script:failures += "$name -> $detail"
  Write-Host ("  FAIL  {0}: {1}" -f $name, $detail) -ForegroundColor Red
}

function Section([string]$title) {
  Write-Host ""
  Write-Host $title -ForegroundColor Cyan
}

# ---------------------------------------------------------------- required files
Section '1. Required files'
$required = @(
  'AppScope/app.json5',
  'AppScope/resources/base/element/string.json',
  'AppScope/resources/base/media/app_icon.png',
  'build-profile.json5',
  'hvigorfile.ts',
  'hvigor/hvigor-config.json5',
  'oh-package.json5',
  'entry/build-profile.json5',
  'entry/hvigorfile.ts',
  'entry/oh-package.json5',
  'entry/src/main/module.json5',
  'entry/src/main/resources/base/profile/main_pages.json',
  'entry/src/main/resources/base/element/string.json',
  'entry/src/main/resources/base/element/color.json',
  'entry/src/main/ets/entryability/EntryAbility.ets',
  'entry/src/main/ets/pages/Index.ets',
  'entry/src/main/ets/pages/BrowserView.ets',
  'entry/src/main/ets/protocol/Origin.ets',
  'entry/src/main/ets/protocol/PairingKey.ets',
  'entry/src/main/ets/protocol/CertPin.ets',
  'entry/src/main/ets/protocol/TlsHttp.ets',
  'entry/src/main/ets/protocol/GatewayHttp.ets',
  'entry/src/main/ets/protocol/Discovery.ets',
  'entry/src/main/ets/protocol/AuthFailure.ets',
  'entry/src/main/ets/model/DeviceRecord.ets',
  'entry/src/main/ets/model/DeviceStore.ets',
  'entry/src/main/ets/service/AppService.ets',
  'entry/src/main/ets/common/Log.ets',
  'entry/src/main/ets/common/Json.ets',
  'entry/src/main/ets/common/Theme.ets',
  'entry/src/main/ets/common/SelfCheck.ets',
  'entry/src/main/ets/common/Scanner.ets',
  'README.md',
  'AGENTS.md',
  'LICENSE',
  '.gitignore',
  '.gitattributes',
  'docs/BUILD.md',
  'docs/PROTOCOL.md',
  'docs/ARCHITECTURE.md',
  'docs/TESTING.md',
  'docs/adr/README.md',
  'scripts/build.ps1',
  'scripts/install.ps1',
  'scripts/verify.ps1'
)
foreach ($path in $required) {
  if (Test-Path $path) { Pass $path } else { Fail 'missing file' $path }
}

# ------------------------------------------------------------ config sanity
Section '2. Project configuration'
$appJson = Get-Content 'AppScope/app.json5' -Raw
if ($appJson -match '"bundleName"\s*:\s*"([A-Za-z0-9_.]+)"' -and $Matches[1] -eq 'io.github.crazyjason.dshmobile.hmos') {
  Pass 'bundleName matches the ADR-0004 namespace'
} else {
  Fail 'bundleName' 'AppScope/app.json5 must be io.github.crazyjason.dshmobile.hmos (see docs/adr/0004)'
}

$profile = Get-Content 'build-profile.json5' -Raw
if ($profile -match 'compatibleSdkVersion"\s*:\s*"5\.0\.0\(12\)"') {
  Pass 'compatibleSdkVersion stays at API 12'
} else {
  Fail 'compatibleSdkVersion' 'keep 5.0.0(12); raising it silently drops HarmonyOS 5.0 devices'
}

$module = Get-Content 'entry/src/main/module.json5' -Raw
foreach ($permission in @('ohos.permission.INTERNET', 'ohos.permission.GET_NETWORK_INFO')) {
  if ($module.Contains($permission)) { Pass "declares $permission" } else { Fail 'permission' $permission }
}
# ADR-0006: scanning is delegated to the system Scan Kit UI, which owns the camera preview in the
# system process. Declaring CAMERA would grant the app a capability it does not use, and it would
# also invite a home-grown viewfinder (which then needs the permission for real).
if ($module.Contains('ohos.permission.CAMERA')) {
  Fail 'permission' 'CAMERA must not be declared: the system Scan Kit UI scans in its own process (ADR-0006)'
} else {
  Pass 'no CAMERA permission declared (system Scan Kit scans in its own process)'
}

# brace/bracket balance of the JSON5 files we ship
foreach ($config in @('AppScope/app.json5', 'build-profile.json5', 'entry/build-profile.json5',
    'entry/src/main/module.json5', 'hvigor/hvigor-config.json5', 'oh-package.json5', 'entry/oh-package.json5')) {
  $text = Get-Content $config -Raw
  $depth = 0
  $inString = $false
  $escape = $false
  $balanced = $true
  foreach ($ch in $text.ToCharArray()) {
    if ($inString) {
      if ($escape) { $escape = $false }
      elseif ($ch -eq '\') { $escape = $true }
      elseif ($ch -eq '"') { $inString = $false }
      continue
    }
    if ($ch -eq '"') { $inString = $true; continue }
    if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
    elseif ($ch -eq '}' -or $ch -eq ']') { $depth--; if ($depth -lt 0) { $balanced = $false; break } }
  }
  if ($balanced -and $depth -eq 0 -and -not $inString) {
    Pass "$config is balanced"
  } else {
    Fail "$config" 'unbalanced braces or unterminated string'
  }
}

# ------------------------------------------------------------- line endings
Section '3. Text hygiene (UTF-8 + LF)'
$textFiles = Get-ChildItem -Recurse -File -Include *.ets, *.ts, *.json5, *.json, *.ps1, *.md |
  Where-Object { $_.FullName -notmatch '\\build\\|\\\.research\\|\\\.git\\|\\\.hvigor\\|\\oh_modules\\|\\node_modules\\|\\\.notes\\' }
$withCr = @()
$withBom = @()
foreach ($file in $textFiles) {
  $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $withBom += $file.FullName.Replace("$root\", '')
  }
  for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) { $withCr += $file.FullName.Replace("$root\", ''); break }
  }
}
if ($withCr.Count -eq 0) { Pass 'all text files use LF' } else { Fail 'CRLF line endings' ($withCr -join ', ') }
if ($withBom.Count -eq 0) { Pass 'no UTF-8 BOM' } else { Fail 'UTF-8 BOM present' ($withBom -join ', ') }

# ---------------------------------------------------------- secrets / hygiene
Section '4. Secrets and artifacts'
$signing = Get-ChildItem -Recurse -File -Include *.p12, *.p7b, *.keystore, *.jks, *.pfx, *.csr, *.pem, *.cer, *.key |
  Where-Object { $_.FullName -notmatch '\\\.git\\|\\\.research\\|\\build\\' }
if ($signing.Count -eq 0) { Pass 'no signing material in the tree' } else { Fail 'signing material present' ($signing.FullName -join ', ') }

# DevEco "automatically generate signature" rewrites build-profile.json5 with machine-local paths
# and IDE-encrypted passwords. That must stay local: revert the file before committing.
if ((Get-Content 'build-profile.json5' -Raw) -match 'signingConfigs') {
  Fail 'build-profile.json5 carries a signingConfig' 'run `git checkout -- build-profile.json5` (auto signing writes machine-local paths + passwords)'
} else {
  Pass 'build-profile.json5 carries no signing config'
}

$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
if ($gitAvailable) {
  $tracked = & git ls-files
  $badTracked = $tracked | Where-Object {
    $_ -match '(^|/)(build|\.hvigor|oh_modules|node_modules|\.research)/' -or $_ -match '\.hap$' -or $_ -match '\.(p12|p7b|pem|keystore)$'
  }
  if ($badTracked.Count -eq 0) { Pass 'git tracks no build output or secrets' } else { Fail 'tracked build/secret files' ($badTracked -join ', ') }
} else {
  Write-Host '  skip  git not available' -ForegroundColor Yellow
}

# ------------------------------------------------------------ protocol guards
Section '5. Protocol and security guards (docs/adr)'
$etsFiles = Get-ChildItem -Recurse -File -Path 'entry/src/main/ets' -Include *.ets
$httpImports = $etsFiles | Select-String -Pattern "from '@kit\.NetworkKit'.*http|@ohos\.net\.http|http\.createHttp" -List
if ($null -eq $httpImports) {
  Pass 'no @ohos.net.http usage (ADR-0001: custom CA needs TLSSocket)'
} else {
  Fail 'ADR-0001 violated' (($httpImports | ForEach-Object { $_.Path.Replace("$root\", '') }) -join ', ')
}

$anyUsage = $etsFiles | Select-String -Pattern ':\s*any\b|<any>|\bas any\b' -List
if ($null -eq $anyUsage) { Pass 'no TS any casts' } else { Fail 'arkts: any usage' (($anyUsage | ForEach-Object { $_.Path.Replace("$root\", '') }) -join ', ') }

$tls = Get-Content 'entry/src/main/ets/protocol/TlsHttp.ets' -Raw
if ($tls.Contains('INSTANCE_ID_PATTERN') -or $tls.Contains('skipRemoteValidation')) {
  Pass 'TLS transport still exposes pinned and bootstrap modes'
} else {
  Fail 'TlsHttp.ets' 'expected TrustMode handling'
}
$certPin = Get-Content 'entry/src/main/ets/protocol/CertPin.ets' -Raw
if ($certPin.Contains('fingerprint !== instanceId')) {
  Pass 'pairing CA is fingerprinted against instanceId (ADR-0002)'
} else {
  Fail 'ADR-0002 violated' 'CertPin.ets must compare the CA fingerprint with the pairing key instanceId'
}

$logSource = Get-Content 'entry/src/main/ets/common/Log.ets' -Raw
if ($logSource.Contains('sanitize')) {
  Pass 'Log sanitizes before writing'
} else {
  Fail 'Log.ets' 'logging must sanitize credentials before hilog'
}
$logCalls = $etsFiles | Select-String -Pattern 'Log\.(info|warn|error)\([^)]*deviceToken|Log\.(info|warn|error)\([^)]*sessionToken|Log\.(info|warn|error)\([^)]*csrfToken' -List
if ($null -eq $logCalls) { Pass 'no credential named in a log call' } else { Fail 'credential logged' (($logCalls | ForEach-Object { $_.Path.Replace("$root\", '') }) -join ', ') }

# hilog with domain 0x0000 is silently dropped on HarmonyOS 7 (verified on a real Mate 60 Pro+),
# so every call must go through Log.ets, which pins domain 0x0D5B.
$rawHilog = $etsFiles | Select-String -Pattern 'hilog\.(info|warn|error|debug)\(' | Where-Object { $_.Path -notmatch '\\common\\Log\.ets$' }
if ($rawHilog.Count -eq 0) {
  Pass 'hilog is only called from common/Log.ets (domain 0x0D5B)'
} else {
  Fail 'direct hilog call' (($rawHilog | ForEach-Object { "$($_.Path.Replace("$root\", '')):$($_.LineNumber)" }) -join ', ')
}

# ADR-0006: the scan channel has exactly one entry point. A page that imported Scan Kit directly
# could act on a scanned payload without `interpretPairingInput`, i.e. skip the protocol rules the
# payload is still subject to.
$scanKit = $etsFiles | Select-String -Pattern "@kit\.ScanKit" -List
if ($null -eq $scanKit) {
  Fail 'scan channel' 'nothing imports @kit.ScanKit: common/Scanner.ets is missing or unwired'
} else {
  $scanKitStrays = @($scanKit | Where-Object { $_.Path -notmatch '\\common\\Scanner\.ets$' })
  if ($scanKitStrays.Count -eq 0) {
    Pass 'Scan Kit is imported only by common/Scanner.ets (ADR-0006)'
  } else {
    Fail 'ADR-0006 violated' (($scanKitStrays | ForEach-Object { $_.Path.Replace("$root\", '') }) -join ', ')
  }
}

# --------------------------------------------------------------- documentation
Section '6. Documentation links'
$docFiles = @('README.md', 'AGENTS.md', 'CLAUDE.md') + (Get-ChildItem 'docs' -Recurse -File -Filter *.md | ForEach-Object { $_.FullName.Replace("$root\", '') })
$broken = @()
foreach ($doc in $docFiles) {
  $text = Get-Content $doc -Raw
  # Links are only real outside code: fenced blocks and inline spans may contain regex text that
  # looks like a markdown link.
  $text = [regex]::Replace($text, '(?s)```.*?```', '')
  $text = [regex]::Replace($text, '`[^`\n]*`', '')
  foreach ($match in [regex]::Matches($text, '\[[^\]]*\]\(([^)\s]+)\)')) {
    $target = $match.Groups[1].Value
    if ($target -match '^(https?:|mailto:|#)') { continue }
    $path = ($target -split '#')[0]
    if ($path.Length -eq 0) { continue }
    $baseDir = Split-Path $doc -Parent
    if ([string]::IsNullOrEmpty($baseDir)) { $baseDir = '.' }
    $resolved = Join-Path $baseDir $path
    if (-not (Test-Path $resolved)) { $broken += "$doc -> $target" }
  }
}
if ($broken.Count -eq 0) { Pass 'every relative markdown link resolves' } else { Fail 'broken links' ($broken -join '; ') }

# ---------------------------------------------------------------------- build
if ($SkipBuild) {
  Section '7. Build (skipped)'
  Write-Host '  skip  -SkipBuild requested' -ForegroundColor Yellow
} else {
  Section '7. Build'
  & (Join-Path $PSScriptRoot 'build.ps1') | Out-Host
  if ($LASTEXITCODE -eq 0) {
    Pass 'hvigor assembleHap'
  } else {
    Fail 'hvigor assembleHap' "exit code $LASTEXITCODE"
  }
  $hap = Join-Path $root 'entry/build/default/outputs/default/entry-default-unsigned.hap'
  if (Test-Path $hap) { Pass 'HAP artifact produced' } else { Fail 'HAP artifact' 'missing' }
}

# ---------------------------------------------------------------------- report
Write-Host ''
if ($script:failures.Count -eq 0) {
  Write-Host ("VERIFY PASSED ({0} checks)" -f $script:checks) -ForegroundColor Green
  exit 0
}
Write-Host ("VERIFY FAILED ({0} of {1} checks)" -f $script:failures.Count, $script:checks) -ForegroundColor Red
foreach ($failure in $script:failures) {
  Write-Host "  - $failure" -ForegroundColor Red
}
exit 1
