param(
    [string]$Tag,
    [string]$TargetCommitish,
    [switch]$BuildOnly,
    [switch]$Stable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Invoke-Tool {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}

if (-not $BuildOnly -and $Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$') {
    throw 'Pass a release tag such as -Tag v0.4.1, or use -BuildOnly.'
}
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$npmName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'npm.cmd' } else { 'npm' }
$npm = (Get-Command $npmName -ErrorAction Stop).Source

# Read data only; never execute .env as a script or print its token.
$token = $env:GITHUB_TOKEN
if (-not $token) { $token = $env:GH_TOKEN }
$envFile = Join-Path $repo '.env'
if (-not $BuildOnly -and -not $token -and (Test-Path -LiteralPath $envFile)) {
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^\s*(?:GITHUB_TOKEN|GH_TOKEN)\s*=\s*(.*?)\s*$') {
            $token = $Matches[1].Trim().Trim('"').Trim("'")
            if ($token) { break }
        }
    }
}
if (-not $BuildOnly -and -not $token) {
    throw 'Set GITHUB_TOKEN in the environment or .env before publishing.'
}

Push-Location $repo
try {
    Invoke-Tool $flutter @('clean')
    Push-Location (Join-Path $repo 'renderer')
    try {
        Invoke-Tool $npm @('ci')
        Invoke-Tool $npm @('run', 'bundle:app')
    } finally { Pop-Location }
    Invoke-Tool $flutter @('pub', 'get')
    Invoke-Tool $flutter @('analyze')
    Invoke-Tool $flutter @('build', 'apk', '--release')

    $apk = Join-Path $repo 'build/app/outputs/flutter-apk/app-release.apk'
    if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { throw 'Flutter did not produce the APK.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName })
        foreach ($required in @(
            'assets/flutter_assets/samples/bucegi/map.pmtiles',
            'assets/flutter_assets/samples/bucegi/terrain.pmtiles',
            'assets/flutter_assets/samples/bucegi/search.sqlite',
            'assets/flutter_assets/assets/renderer/assets/renderer.js'
        )) {
            if ($required -notin $names) { throw "APK is missing $required." }
        }
    } finally { $archive.Dispose() }

    $outputDir = Join-Path $repo 'build/release'
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $assetName = if ($Tag) { "ridgewalk-$Tag.apk" } else { 'ridgewalk.apk' }
    $asset = Join-Path $outputDir $assetName
    Copy-Item -LiteralPath $apk -Destination $asset -Force
    $hash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksums = Join-Path $outputDir 'SHA256SUMS.txt'
    [System.IO.File]::WriteAllText($checksums, "$hash  $assetName`n", [System.Text.Encoding]::ASCII)
    Write-Host "APK: $asset"
    Write-Host "SHA-256: $hash"
    if ($BuildOnly) { return }

    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'ridgewalk-local-release'
    }
    $body = @{
        tag_name = $Tag
        name = "Ridgewalk $Tag"
        body = 'Built locally from the working tree. The release tag points to the selected GitHub commit, which may differ from uncommitted local changes.'
        draft = $true
        prerelease = (-not $Stable)
    }
    if ($TargetCommitish) { $body.target_commitish = $TargetCommitish }
    $api = 'https://api.github.com/repos/broaks23/mobile-gps/releases'
    $json = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))
    $release = Invoke-RestMethod -Method Post -Uri $api -Headers $headers -ContentType 'application/json' -Body $json
    try {
        foreach ($file in @($asset, $checksums)) {
            $name = [Uri]::EscapeDataString([System.IO.Path]::GetFileName($file))
            $upload = "https://uploads.github.com/repos/broaks23/mobile-gps/releases/$($release.id)/assets?name=$name"
            Invoke-RestMethod -Method Post -Uri $upload -Headers $headers -ContentType 'application/octet-stream' -InFile $file | Out-Null
        }
        $publish = [System.Text.Encoding]::UTF8.GetBytes('{"draft":false}')
        $release = Invoke-RestMethod -Method Patch -Uri "$api/$($release.id)" -Headers $headers -ContentType 'application/json' -Body $publish
        Write-Host "Published: $($release.html_url)"
    } catch {
        Write-Warning "Upload or publication failed. The draft release remains at $($release.html_url)."
        throw
    }
} finally { Pop-Location }
