param(
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$Client = Join-Path $Root "client"
$AppDir = Join-Path $Client "build\windows\x64\runner\Release"
$Exe = Join-Path $AppDir "omo_switcher_client.exe"
$OutDir = Join-Path $Root "release\installer"
$WorkDir = Join-Path $OutDir "wix"
$Wxs = Join-Path $WorkDir "omo-switcher.wxs"
$License = Join-Path $WorkDir "License.rtf"
$Msi = Join-Path $OutDir "omo-switcher-windows-setup.msi"
$Wix = Join-Path $Root ".tools\wix.exe"

if (-not $SkipBuild) {
  $flutterCommand = Get-Command "flutter" -ErrorAction SilentlyContinue
  $flutter = if ($flutterCommand) { $flutterCommand.Source } else { "C:\Users\User\flutter\bin\flutter.bat" }
  if (-not (Test-Path $flutter) -and -not $flutterCommand) {
    throw "Flutter was not found on PATH or at $flutter"
  }
  Push-Location $Client
  try {
    & $flutter build windows --release
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path $Exe)) {
  throw "Windows release build was not found: $Exe"
}

if (-not (Test-Path $Wix)) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Root ".tools") | Out-Null
  & dotnet tool install --tool-path (Join-Path $Root ".tools") wix
}

& $Wix eula accept wix7 | Out-Null
& $Wix extension add WixToolset.UI.wixext 2>$null | Out-Null

New-Item -ItemType Directory -Force -Path $OutDir, $WorkDir | Out-Null
@'
{\rtf1\ansi\deff0 {\fonttbl {\f0 Segoe UI;}}\f0\fs20 omo-switcher\par\par Copyright (C) 2026 aceaura. All rights reserved.\par}
'@ | Set-Content -Path $License -Encoding ASCII

function XmlEscape([string]$value) {
  return [Security.SecurityElement]::Escape($value)
}

function HashFor([string]$value) {
  $md5 = [Security.Cryptography.MD5]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes($value)
  return (($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 12)
}

function IdFor([string]$prefix, [string]$value) {
  $clean = ($value -replace "[^A-Za-z0-9_]", "_")
  if ($clean.Length -gt 38) { $clean = $clean.Substring(0, 38) }
  return "${prefix}_${clean}_$(HashFor $value)"
}

function RelativePath([string]$base, [string]$target) {
  $basePath = [IO.Path]::GetFullPath($base)
  if (-not $basePath.EndsWith([IO.Path]::DirectorySeparatorChar)) {
    $basePath += [IO.Path]::DirectorySeparatorChar
  }
  $targetPath = [IO.Path]::GetFullPath($target)
  $baseUri = New-Object Uri($basePath)
  $targetUri = New-Object Uri($targetPath)
  return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace("/", [IO.Path]::DirectorySeparatorChar)
}

function BuildDirXml([string]$dir, [hashtable]$dirIds, [array]$allDirs, [int]$indent) {
  $pad = " " * $indent
  $childDirs = $allDirs | Where-Object { (Split-Path $_ -Parent) -eq $dir } | Sort-Object
  $text = New-Object System.Text.StringBuilder
  foreach ($child in $childDirs) {
    $name = Split-Path $child -Leaf
    [void]$text.AppendLine("$pad<Directory Id=""$($dirIds[$child])"" Name=""$(XmlEscape $name)"">")
    [void]$text.Append((BuildDirXml $child $dirIds $allDirs ($indent + 2)))
    [void]$text.AppendLine("$pad</Directory>")
  }
  return $text.ToString()
}

$files = Get-ChildItem -Path $AppDir -File -Recurse | Sort-Object FullName
$dirIds = @{$AppDir = "INSTALLFOLDER"}
foreach ($dir in ($files | ForEach-Object { $_.Directory.FullName } | Sort-Object -Unique)) {
  if ($dir -eq $AppDir) { continue }
  $rel = RelativePath $AppDir $dir
  $parent = $AppDir
  foreach ($part in ($rel -split "[\\/]")) {
    $cur = Join-Path $parent $part
    if (-not $dirIds.ContainsKey($cur)) {
      $dirIds[$cur] = IdFor "Dir" (RelativePath $AppDir $cur)
    }
    $parent = $cur
  }
}

$allDirs = @($dirIds.Keys | Where-Object { $_ -ne $AppDir })
$nestedDirs = BuildDirXml $AppDir $dirIds $allDirs 8
$compXml = New-Object System.Text.StringBuilder
foreach ($file in $files) {
  $rel = RelativePath $AppDir $file.FullName
  $compId = IdFor "Cmp" $rel
  $fileId = IdFor "File" $rel
  $dirId = $dirIds[$file.Directory.FullName]
  [void]$compXml.AppendLine("      <Component Id=""$compId"" Directory=""$dirId"" Guid=""*"">")
  [void]$compXml.AppendLine("        <File Id=""$fileId"" Source=""$(XmlEscape $file.FullName)"" KeyPath=""yes"" />")
  [void]$compXml.AppendLine("      </Component>")
}

$icon = XmlEscape (Join-Path $Root "client\windows\runner\resources\app_icon.ico")
$licenseEscaped = XmlEscape $License
@"
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs" xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui">
  <Package Name="omo-switcher" Manufacturer="aceaura" Version="1.0.0" UpgradeCode="{9E1C03B2-52F5-4B70-B3E8-4A1F87396E8F}" Scope="perMachine">
    <MajorUpgrade DowngradeErrorMessage="A newer version of omo-switcher is already installed." />
    <MediaTemplate EmbedCab="yes" />
    <Icon Id="AppIcon.ico" SourceFile="$icon" />
    <Property Id="ARPPRODUCTICON" Value="AppIcon.ico" />
    <Property Id="WIXUI_INSTALLDIR" Value="INSTALLFOLDER" />
    <WixVariable Id="WixUILicenseRtf" Value="$licenseEscaped" />
    <ui:WixUI Id="WixUI_InstallDir" />

    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="INSTALLFOLDER" Name="omo-switcher">
$nestedDirs      </Directory>
    </StandardDirectory>
    <StandardDirectory Id="ProgramMenuFolder">
      <Directory Id="ApplicationProgramsFolder" Name="omo-switcher" />
    </StandardDirectory>

    <ComponentGroup Id="AppFiles">
$compXml
      <Component Id="ApplicationShortcut" Directory="ApplicationProgramsFolder" Guid="*">
        <Shortcut Id="StartMenuShortcut" Name="omo-switcher" Description="omo-switcher" Target="[INSTALLFOLDER]omo_switcher_client.exe" WorkingDirectory="INSTALLFOLDER" Icon="AppIcon.ico" />
        <RemoveFolder Id="ApplicationProgramsFolder" On="uninstall" />
        <RegistryValue Root="HKCU" Key="Software\aceaura\omo-switcher" Name="installed" Type="integer" Value="1" KeyPath="yes" />
      </Component>
    </ComponentGroup>

    <Feature Id="MainFeature" Title="omo-switcher" Level="1">
      <ComponentGroupRef Id="AppFiles" />
    </Feature>
  </Package>
</Wix>
"@ | Set-Content -Path $Wxs -Encoding UTF8

& $Wix build $Wxs -ext WixToolset.UI.wixext -arch x64 -o $Msi
Get-Item $Msi
