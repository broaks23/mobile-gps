param(
    [string]$Tag,
    [string]$TargetCommitish,
    [switch]$BuildOnly,
    [switch]$Stable,
    [string]$ExpectedSignerSha256 = 'dd2701d37ff47e856d5c09c97412dc215e3b7455b1835f8b14bd917c1d0d43a9'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Invoke-Tool {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE." }
}

if (-not $BuildOnly -and $Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') {
    throw 'Pass a release tag such as -Tag v0.4.1, or use -BuildOnly.'
}
if (-not $BuildOnly) {
    $versionLine = Get-Content -LiteralPath (Join-Path $repo 'pubspec.yaml') | Where-Object { $_ -match '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$' } | Select-Object -First 1
    if (-not $versionLine -or $versionLine -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
        throw 'Set pubspec.yaml version to a stable version with an explicit Android build number, for example 0.5.0+2.'
    }
    if ($Tag -ne "v$($Matches[1])") { throw 'Release tag must match the pubspec.yaml version.' }
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

    # Pin the new release key so later updates retain the same certificate.
    $sdk = $env:ANDROID_HOME
    if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
    if (-not $sdk) {
        $localProperties = Join-Path $repo 'android/local.properties'
        if (Test-Path -LiteralPath $localProperties) {
            $sdkLine = Get-Content -LiteralPath $localProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
            if ($sdkLine) { $sdk = ($sdkLine -replace '^sdk\.dir=', '').Replace('\:', ':').Replace('\\', '\') }
        }
    }
    if (-not $sdk) { throw 'Android SDK path is needed to verify the APK signing certificate.' }
    $signerTool = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
        Sort-Object { [version]($_.Name -replace '[^0-9.]', '') } -Descending |
        ForEach-Object { Join-Path $_.FullName 'apksigner.bat' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $signerTool) { throw 'Could not find apksigner.bat in the Android SDK.' }
    $signerOutput = & $signerTool verify --print-certs $asset 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $signerOutput -notmatch 'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})') {
        throw 'Could not verify the APK signing certificate.'
    }
    $actualSigner = $Matches[1].ToLowerInvariant()
    if ($actualSigner -ne $ExpectedSignerSha256.ToLowerInvariant()) {
        throw "APK signing key differs from the installed release. Expected $ExpectedSignerSha256, got $actualSigner. Recover the prior keystore before publishing an update."
    }

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
        prerelease = $false
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
