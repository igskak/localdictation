param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Kit directory does not exist: $Path"
}

$requiredNames = @(
    "BUG_REPORT_TEMPLATE.md",
    "BUILD_INFO.json",
    "KNOWN_ISSUES.md",
    "QA_CHECKLIST.md",
    "RELEASE_NOTES.md",
    "SHA256SUMS.txt",
    "TESTER_GUIDE.md",
    "THIRD_PARTY_NOTICES.txt",
    "WINDOWS_BETA_PRIVACY.md",
    "WINDOWS_BETA_TERMS.md"
)
foreach ($name in $requiredNames) {
    if (-not (Test-Path -LiteralPath (Join-Path $Path $name) -PathType Leaf)) {
        throw "Required W8 kit file is missing: $name"
    }
}

$setups = @(Get-ChildItem -LiteralPath $Path -File -Filter "Witness-Windows-Beta-*-x64-Setup.exe")
if ($setups.Count -ne 1) {
    throw "Expected exactly one canonical W8 installer; found $($setups.Count)."
}

$buildInfo = Get-Content -LiteralPath (Join-Path $Path "BUILD_INFO.json") -Raw | ConvertFrom-Json
if ($buildInfo.installer -cne $setups[0].Name -or
    $buildInfo.architecture -cne "x64" -or
    $buildInfo.channel -cne "beta" -or
    $buildInfo.minimumOs -cne "10.0.26100.0" -or
    $buildInfo.sourceRevision -notmatch '^[0-9a-f]{40}$') {
    throw "BUILD_INFO.json is incomplete or does not match the installer."
}
if ($buildInfo.trustState -notin @("unsigned-internal", "code-signed-beta")) {
    throw "BUILD_INFO.json has an unknown trust state."
}
if ($buildInfo.nativeBackend -cne "cpu" -or
    $buildInfo.acceleratedBackendIncluded -ne $false -or
    $buildInfo.speechModel.sha256 -notmatch '^[0-9a-f]{64}$' -or
    [long]$buildInfo.speechModel.sizeBytes -le 0) {
    throw "BUILD_INFO.json does not accurately describe the current CPU-only package and model."
}
if ($buildInfo.trustState -ceq "code-signed-beta") {
    if ($buildInfo.activationConfigured -ne $true -or $buildInfo.updatesConfigured -ne $true) {
        throw "A code-signed-beta kit requires isolated activation and update configuration."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $setups[0].FullName
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "The code-signed-beta installer does not have a valid Authenticode signature."
    }
    foreach ($legalName in @("WINDOWS_BETA_PRIVACY.md", "WINDOWS_BETA_TERMS.md")) {
        if ((Get-Content -LiteralPath (Join-Path $Path $legalName) -Raw) -match '(?i)\[insert\s') {
            throw "A code-signed-beta kit contains unresolved legal placeholders: $legalName"
        }
    }
}

$checksumPath = Join-Path $Path "SHA256SUMS.txt"
$checksumLines = @(Get-Content -LiteralPath $checksumPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$filesToCheck = @(Get-ChildItem -LiteralPath $Path -File | Where-Object Name -ne "SHA256SUMS.txt")
if ($checksumLines.Count -ne $filesToCheck.Count) {
    throw "SHA256SUMS.txt must cover every kit file except itself exactly once."
}
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($line in $checksumLines) {
    if ($line -notmatch '^([0-9a-f]{64})  ([^\\/]+)$') {
        throw "Invalid SHA256SUMS.txt line: $line"
    }
    $expected = $Matches[1]
    $name = $Matches[2]
    if (-not $seen.Add($name)) {
        throw "Duplicate checksum entry: $name"
    }
    $file = Join-Path $Path $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Checksum references a missing kit file: $name"
    }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $expected) {
        throw "SHA-256 mismatch for $name"
    }
}

$notices = Get-Content -LiteralPath (Join-Path $Path "THIRD_PARTY_NOTICES.txt") -Raw
foreach ($marker in @(
    "# NSec.Cryptography 26.4.0",
    "# Velopack 1.2.158",
    "# whisper.cpp v1.9.4",
    "# OpenAI Whisper model",
    "# Microsoft.NETCore.App.Runtime.win-x64",
    "THIRD-PARTY-NOTICES"
)) {
    if (-not $notices.Contains($marker, [System.StringComparison]::Ordinal)) {
        throw "Third-party notice bundle is missing marker: $marker"
    }
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
& (Join-Path $repositoryRoot "Windows\tools\assert-artifact-privacy.ps1") -Path $Path

Write-Host "W8 beta kit validation passed for $Path. Trust state: $($buildInfo.trustState)."
