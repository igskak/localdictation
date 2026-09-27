param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Artifact path does not exist: $Path"
}

$forbiddenExtensions = @(".wav", ".m4a", ".mp3", ".flac", ".ogg", ".pcm", ".dmp")
$forbiddenNames = @("transcript", "clipboard", "vocabulary", "recording", "utterance", "crashdump")
$violations = [System.Collections.Generic.List[string]]::new()

function Test-EntryName([string]$EntryName) {
    $leaf = [System.IO.Path]::GetFileName($EntryName)
    $extension = [System.IO.Path]::GetExtension($leaf).ToLowerInvariant()
    if ($forbiddenExtensions -contains $extension) {
        $violations.Add($EntryName)
    }

    $lower = $leaf.ToLowerInvariant()
    foreach ($fragment in $forbiddenNames) {
        if ($lower.Contains($fragment)) {
            $violations.Add($EntryName)
            break
        }
    }
}

Get-ChildItem -LiteralPath $Path -Recurse -File | ForEach-Object {
    Test-EntryName $_.FullName

    if ($_.Extension -in @(".nupkg", ".zip")) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
        try {
            foreach ($entry in $archive.Entries) {
                Test-EntryName "$($_.FullName)!$($entry.FullName)"
            }
        }
        finally {
            $archive.Dispose()
        }
    }
}

if ($violations.Count -gt 0) {
    $details = $violations | Sort-Object -Unique | Out-String
    throw "Forbidden content-like artifact entries were found:`n$details"
}

Write-Host "Artifact privacy filename scan passed for $Path."
