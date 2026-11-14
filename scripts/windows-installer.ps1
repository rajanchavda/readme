<#
.SYNOPSIS
Builds the Windows installers for a GitHub release: Readme-Setup-<version>-x64.exe and -arm64.exe.

.DESCRIPTION
Takes the version from project.yml, as the Mac release does: MARKETING_VERSION names the files
(Readme-Setup-1.5-x64.exe, beside Readme-1.5.dmg) and, with CURRENT_PROJECT_VERSION, makes the file
version (1.5.7.0). Publishes Readme.App self-contained for each architecture, so the PC needs nothing
installed first (WebView2 comes with Windows 11), then wraps each in an Inno Setup installer from
windows/installer/Readme.iss. Writes them, each with a .sha256, to windows/dist.

Needs Inno Setup 6 (https://jrsoftware.org/isinfo.php, or: winget install JRSoftware.InnoSetup).
GitHub's Windows runners have it already.

The installers aren't signed, so Windows SmartScreen asks once before running them: "More info",
then "Run anyway". docs/install-windows.md walks through it.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\windows-installer.ps1
powershell -ExecutionPolicy Bypass -File scripts\windows-installer.ps1 -Arch x64
#>
param([ValidateSet('x64', 'arm64', 'both')][string]$Arch = 'both')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'project.yml'
$app = Join-Path $root 'windows\Readme.App'
$script = Join-Path $root 'windows\installer\Readme.iss'
$dist = Join-Path $root 'windows\dist'

function Setting([string]$name) {
    $line = Select-String -Path $project -Pattern "^\s*${name}:\s*`"?([0-9.]+)`"?" | Select-Object -First 1
    if (-not $line) { throw "No $name in project.yml" }
    $line.Matches[0].Groups[1].Value
}

function Find-Iscc {
    $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($folder in @("${env:ProgramFiles(x86)}\Inno Setup 6", "$env:ProgramFiles\Inno Setup 6", "$env:LOCALAPPDATA\Programs\Inno Setup 6")) {
        $candidate = Join-Path $folder 'ISCC.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    throw 'Inno Setup 6 is needed: winget install JRSoftware.InnoSetup'
}

$version = Setting 'MARKETING_VERSION'
$build = Setting 'CURRENT_PROJECT_VERSION'
$parts = @($version.Split('.')) + @('0', '0')
$fileVersion = "$($parts[0]).$($parts[1]).$build.0"
$iscc = Find-Iscc
"Readme $version (file version $fileVersion), Inno Setup at $iscc"

New-Item -ItemType Directory -Force $dist | Out-Null
$targets = @(@{ Arch = 'x64'; Platform = 'x64'; Runtime = 'win-x64' }, @{ Arch = 'arm64'; Platform = 'ARM64'; Runtime = 'win-arm64' }) |
    Where-Object { $Arch -eq 'both' -or $_.Arch -eq $Arch }
foreach ($target in $targets) {
    $publish = Join-Path $dist "publish-$($target.Arch)"
    Remove-Item -Recurse -Force $publish -ErrorAction SilentlyContinue
    "Publishing the $($target.Arch) app"
    Push-Location $app
    try {
        & dotnet publish -c Release "-p:Platform=$($target.Platform)" -r $target.Runtime --self-contained true `
            -p:DebugType=none "-p:Version=$version" "-p:FileVersion=$fileVersion" -o $publish --nologo -v quiet
        if ($LASTEXITCODE -ne 0) { throw "The $($target.Arch) app didn't publish" }
    }
    finally { Pop-Location }

    "Building the $($target.Arch) installer"
    & $iscc /Q "/DAppVersion=$version" "/DFileVersion=$fileVersion" "/DArch=$($target.Arch)" "/DSourceDir=$publish" "/DOutputDir=$dist" $script
    if ($LASTEXITCODE -ne 0) { throw "The $($target.Arch) installer didn't build" }
    $out = Join-Path $dist "Readme-Setup-$version-$($target.Arch).exe"
    $hash = (Get-FileHash $out -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$out.sha256", "$hash  $(Split-Path -Leaf $out)`n")
    Remove-Item -Recurse -Force $publish
    "  $out ($([math]::Round((Get-Item $out).Length / 1MB)) MB)"
}
'Done.'
