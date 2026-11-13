<#
.SYNOPSIS
Builds the Windows release: both MSIX packages, ready to upload to the Microsoft Store.

.DESCRIPTION
Takes the version from project.yml, as the Mac release does: MARKETING_VERSION 1.5 and
CURRENT_PROJECT_VERSION 7 make the package version 1.5.7.0 (the Store needs the last part to be 0).
Writes it into windows/Readme.App/Package.appxmanifest, runs the Core tests, builds the x64 and
ARM64 packages and puts them in windows/dist with a .sha256 beside each.

With -Store it refuses to build while the package identity is still the placeholder: copy the
Identity Name and Publisher from Partner Center into Package.appxmanifest first (see
docs/releasing.md, "Windows").

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\windows-release.ps1
powershell -ExecutionPolicy Bypass -File scripts\windows-release.ps1 -Store
#>
param([switch]$Store)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'project.yml'
$manifest = Join-Path $root 'windows\Readme.App\Package.appxmanifest'
$app = Join-Path $root 'windows\Readme.App'
$dist = Join-Path $root 'windows\dist'

function Setting([string]$name) {
    $line = Select-String -Path $project -Pattern "^\s*${name}:\s*`"?([0-9.]+)`"?" | Select-Object -First 1
    if (-not $line) { throw "No $name in project.yml" }
    $line.Matches[0].Groups[1].Value
}

$marketing = Setting 'MARKETING_VERSION'
$build = Setting 'CURRENT_PROJECT_VERSION'
$parts = $marketing.Split('.')
if ($parts.Count -gt 2) { throw "MARKETING_VERSION $marketing has more than two parts; the package version needs room for the build number" }
$version = "$($parts[0]).$(if ($parts.Count -gt 1) { $parts[1] } else { 0 }).$build.0"
"Version $version (from MARKETING_VERSION $marketing, build $build)"

$xml = [System.IO.File]::ReadAllText($manifest)
if ($Store -and $xml -match 'Publisher="CN=Readme Development"') {
    throw 'The package identity is still the placeholder. Copy Identity Name and Publisher from Partner Center into Package.appxmanifest first.'
}
$updated = [regex]::Replace($xml, '(<Identity [^>]*Version=")[^"]+(")', "`${1}$version`${2}")
if ($updated -ne $xml) {
    [System.IO.File]::WriteAllText($manifest, $updated, (New-Object System.Text.UTF8Encoding $false))
    "Package.appxmanifest now says $version"
}

"Running the Core tests"
& dotnet test (Join-Path $root 'windows\Readme.Core.Tests\Readme.Core.Tests.csproj') --nologo
if ($LASTEXITCODE -ne 0) { throw 'The Core tests failed' }

New-Item -ItemType Directory -Force $dist | Out-Null
Remove-Item -Recurse -Force (Join-Path $app 'bin\Packages') -ErrorAction SilentlyContinue
foreach ($target in @(@{ Platform = 'x64'; Runtime = 'win-x64'; Arch = 'x64' }, @{ Platform = 'ARM64'; Runtime = 'win-arm64'; Arch = 'arm64' })) {
    "Building the $($target.Arch) package"
    Push-Location $app
    try {
        & dotnet build -c Release "-p:Platform=$($target.Platform)" -r $target.Runtime -p:ReadmePackage=true --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw "The $($target.Arch) package didn't build" }
    }
    finally { Pop-Location }
    $built = Get-ChildItem (Join-Path $app 'bin\Packages') -Recurse -Filter "*_$($target.Arch).msix" | Select-Object -First 1
    if (-not $built) { throw "No $($target.Arch) package was made" }
    $out = Join-Path $dist "Readme-$version-$($target.Arch).msix"
    Copy-Item $built.FullName $out -Force
    $hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$out.sha256", "$hash  $(Split-Path -Leaf $out)`n")
    "  $out"
}
"Done. Upload both packages to the submission's Packages page in Partner Center."
