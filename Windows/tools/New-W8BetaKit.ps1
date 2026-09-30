param(
    [Parameter(Mandatory = $true)]
    [string]$PackagePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [int]$Build,

    [Parameter(Mandatory = $true)]
    [string]$SourceRevision,

    [ValidateSet("unsigned-internal", "code-signed-beta")]
    [string]$TrustState = "unsigned-internal",

    [bool]$ActivationConfigured = $false,

    [bool]$UpdatesConfigured = $false
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Version must be a semantic version safe for an artifact filename."
}
if ($Build -le 0) {
    throw "Build must be a positive integer."
}
if ($SourceRevision -notmatch '^[0-9a-fA-F]{40}$') {
    throw "SourceRevision must be a full 40-character Git commit."
}
if (-not (Test-Path -LiteralPath $PackagePath -PathType Container)) {
    throw "Package directory does not exist: $PackagePath"
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "Output path already exists: $OutputPath"
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$packageRoot = (Resolve-Path -LiteralPath $PackagePath).Path
$setups = @(Get-ChildItem -LiteralPath $packageRoot -File -Filter "*Setup.exe")
if ($setups.Count -ne 1) {
    throw "Expected exactly one Velopack Setup.exe; found $($setups.Count)."
}
if ($TrustState -ceq "code-signed-beta") {
    $signature = Get-AuthenticodeSignature -LiteralPath $setups[0].FullName
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "A code-signed-beta kit requires a valid Authenticode Setup signature."
    }
    if (-not $ActivationConfigured -or -not $UpdatesConfigured) {
        throw "A code-signed-beta kit requires the isolated activation and update configurations."
    }
}

$documents = [ordered]@{
    "RELEASE_NOTES.md" = "Windows\RELEASE_NOTES_W8_BETA.md"
    "KNOWN_ISSUES.md" = "Windows\KNOWN_ISSUES.md"
    "TESTER_GUIDE.md" = "Windows\TESTER_GUIDE.md"
    "QA_CHECKLIST.md" = "Windows\QA_CHECKLIST.md"
    "BUG_REPORT_TEMPLATE.md" = "Windows\BUG_REPORT_TEMPLATE.md"
    "WINDOWS_BETA_PRIVACY.md" = "Windows\LEGAL\WINDOWS_BETA_PRIVACY.md"
    "WINDOWS_BETA_TERMS.md" = "Windows\LEGAL\WINDOWS_BETA_TERMS.md"
}
foreach ($relativePath in $documents.Values) {
    $source = Join-Path $repositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required kit document is missing: $relativePath"
    }
}
if ($TrustState -ceq "code-signed-beta") {
    foreach ($legalPath in @(
        (Join-Path $repositoryRoot "Windows\LEGAL\WINDOWS_BETA_PRIVACY.md"),
        (Join-Path $repositoryRoot "Windows\LEGAL\WINDOWS_BETA_TERMS.md")
    )) {
        if ((Get-Content -LiteralPath $legalPath -Raw) -match '(?i)\[insert\s') {
            throw "A code-signed-beta kit cannot contain unresolved legal placeholders: $legalPath"
        }
    }
}

New-Item -ItemType Directory -Path $OutputPath | Out-Null
$installerName = "Witness-Windows-Beta-$Version-x64-Setup.exe"
Copy-Item -LiteralPath $setups[0].FullName -Destination (Join-Path $OutputPath $installerName)
foreach ($entry in $documents.GetEnumerator()) {
    Copy-Item -LiteralPath (Join-Path $repositoryRoot $entry.Value) -Destination (Join-Path $OutputPath $entry.Key)
}

$assetsPath = Join-Path $repositoryRoot "Windows\src\Witness.App\obj\project.assets.json"
if (-not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) {
    throw "Restore assets are required to bind notices to the shipped .NET runtime."
}
$assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json
$framework = $assets.project.frameworks.PSObject.Properties.Value | Select-Object -First 1
$runtimeDependency = $framework.downloadDependencies |
    Where-Object { $_.name -ceq "Microsoft.NETCore.App.Runtime.win-x64" } |
    Select-Object -First 1
$desktopDependency = $framework.downloadDependencies |
    Where-Object { $_.name -ceq "Microsoft.WindowsDesktop.App.Runtime.win-x64" } |
    Select-Object -First 1
if ($null -eq $runtimeDependency -or $null -eq $desktopDependency) {
    throw "The restored app does not identify both required Windows x64 runtime packs."
}

function Exact-Version([string]$Range) {
    if ($Range -notmatch '^\[([^,]+),\s*\1\]$') {
        throw "Expected an exact runtime-pack version, got '$Range'."
    }
    return $Matches[1]
}

$runtimeVersion = Exact-Version $runtimeDependency.version
$desktopVersion = Exact-Version $desktopDependency.version
$nugetRoot = $assets.packageFolders.PSObject.Properties.Name | Select-Object -First 1
$runtimeDirectory = Join-Path $nugetRoot "microsoft.netcore.app.runtime.win-x64\$runtimeVersion"
$desktopDirectory = Join-Path $nugetRoot "microsoft.windowsdesktop.app.runtime.win-x64\$desktopVersion"
$runtimeLicense = Join-Path $runtimeDirectory "LICENSE.TXT"
$runtimeNotices = Join-Path $runtimeDirectory "THIRD-PARTY-NOTICES.TXT"
$desktopLicense = Join-Path $desktopDirectory "LICENSE"
foreach ($noticePath in @($runtimeLicense, $runtimeNotices, $desktopLicense)) {
    if (-not (Test-Path -LiteralPath $noticePath -PathType Leaf)) {
        throw "The exact restored Windows runtime-pack notice is missing: $noticePath"
    }
}

$engineeringNotices = Get-Content -LiteralPath (Join-Path $repositoryRoot "Windows\THIRD_PARTY_NOTICES.md") -Raw
$productMetadata = Get-Content -LiteralPath (Join-Path $repositoryRoot "Windows\config\build-metadata.json") -Raw | ConvertFrom-Json
$noticeParts = @(
    "Witness for Windows beta — third-party licenses and notices`r`n",
    "Generated for app version $Version, build $Build, source $($SourceRevision.ToLowerInvariant()).`r`n",
    $engineeringNotices,
    "`r`n---`r`n`r`n# Microsoft.NETCore.App.Runtime.win-x64 $runtimeVersion license`r`n",
    (Get-Content -LiteralPath $runtimeLicense -Raw),
    "`r`n# Microsoft.NETCore.App.Runtime.win-x64 $runtimeVersion THIRD-PARTY-NOTICES.TXT`r`n",
    (Get-Content -LiteralPath $runtimeNotices -Raw),
    "`r`n# Microsoft.WindowsDesktop.App.Runtime.win-x64 $desktopVersion license`r`n",
    (Get-Content -LiteralPath $desktopLicense -Raw)
)
$noticeParts -join "`r`n" | Set-Content -LiteralPath (Join-Path $OutputPath "THIRD_PARTY_NOTICES.txt") -Encoding utf8

$buildInfo = [ordered]@{
    schema = 1
    product = "Witness for Windows closed beta"
    version = $Version
    build = $Build
    sourceRevision = $SourceRevision.ToLowerInvariant()
    channel = $productMetadata.channel
    architecture = $productMetadata.architecture
    minimumOs = $productMetadata.minimumOs
    installer = $installerName
    trustState = $TrustState
    activationConfigured = $ActivationConfigured
    updatesConfigured = $UpdatesConfigured
    nativeBackend = "cpu"
    acceleratedBackendIncluded = $false
    speechModel = [ordered]@{
        id = $productMetadata.model.id
        artifact = $productMetadata.model.artifact
        revision = $productMetadata.model.revision
        sizeBytes = $productMetadata.model.sizeBytes
        sha256 = $productMetadata.model.sha256
    }
}
$buildInfo | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputPath "BUILD_INFO.json") -Encoding utf8

Get-ChildItem -LiteralPath $OutputPath -File |
    Sort-Object Name |
    ForEach-Object { "$(($_ | Get-FileHash -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)" } |
    Set-Content -LiteralPath (Join-Path $OutputPath "SHA256SUMS.txt") -Encoding ascii

Write-Host "Assembled W8 beta kit at $OutputPath with trust state '$TrustState'."
