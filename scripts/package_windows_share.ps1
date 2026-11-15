param([string]$Release = 'build/windows/x64/runner/Release')
$ErrorActionPreference = 'Stop'
$Release = (Resolve-Path $Release).Path
$versionLine = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$parts = $versionLine.Split('+')
$version = $parts[0] + '.' + $parts[1]
$broker = Join-Path $Release 'ShareTarget'
dotnet publish windows/share_target/LanLink.ShareTarget.csproj -c Release -r win-x64 -o $broker
if ($LASTEXITCODE -ne 0) { throw 'No se pudo compilar el receptor de Windows Share.' }
& (Join-Path $broker 'LanLink.ShareTarget.exe') --self-check
if ($LASTEXITCODE -ne 0) { throw 'El receptor de Windows Share no pudo iniciar.' }
$assets = Join-Path $Release 'PackageAssets'
New-Item -ItemType Directory -Force $assets | Out-Null
Add-Type -AssemblyName System.Drawing
$icon = [System.Drawing.Icon]::new((Resolve-Path 'windows/runner/resources/app_icon.ico'))
foreach ($size in @(44, 150, 50)) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::FromArgb(8,126,133))
    $graphics.DrawIcon($icon, [System.Drawing.Rectangle]::new(0,0,$size,$size))
    $bitmap.Save((Join-Path $assets "Logo$size.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}
$icon.Dispose()
@"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:uap10="http://schemas.microsoft.com/appx/manifest/uap/windows10/10" xmlns:desktop4="http://schemas.microsoft.com/appx/manifest/desktop/windows10/4" xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities" IgnorableNamespaces="uap uap10 desktop4 desktop6 rescap">
<Identity Name="gteijeiro.LanLink" Publisher="CN=LanLink Development" Version="$version" ProcessorArchitecture="x64" />
<Properties><DisplayName>LanLink</DisplayName><PublisherDisplayName>LanLink</PublisherDisplayName><desktop6:FileSystemWriteVirtualization>disabled</desktop6:FileSystemWriteVirtualization><Logo>PackageAssets\Logo50.png</Logo></Properties>
<Dependencies><TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19043.0" MaxVersionTested="10.0.26100.0" /></Dependencies>
<Resources><Resource Language="es" /></Resources>
<Applications><Application desktop4:SupportsMultipleInstances="true" Id="LanLink" Executable="ShareTarget\LanLink.ShareTarget.exe" EntryPoint="Windows.FullTrustApplication" uap10:RuntimeBehavior="packagedClassicApp" uap10:TrustLevel="mediumIL">
<uap:VisualElements DisplayName="LanLink" Description="Compartir archivos con equipos cercanos" BackgroundColor="#087e85" Square44x44Logo="PackageAssets\Logo44.png" Square150x150Logo="PackageAssets\Logo150.png" />
<Extensions><uap:Extension Category="windows.shareTarget"><uap:ShareTarget><uap:SupportedFileTypes><uap:SupportsAnyFileType /></uap:SupportedFileTypes><uap:DataFormat>StorageItems</uap:DataFormat></uap:ShareTarget></uap:Extension></Extensions>
</Application></Applications><Capabilities><rescap:Capability Name="runFullTrust" /><rescap:Capability Name="unvirtualizedResources" /><DeviceCapability Name="bluetooth" /></Capabilities>
</Package>
"@ | Set-Content -Encoding utf8 (Join-Path $Release 'AppxManifest.xml')
# No signing key is generated or published by CI. The user signs locally once.
Copy-Item scripts/install_windows_share.ps1 (Join-Path $Release 'Install-WindowsShare.ps1')
Write-Output 'Windows Share preparado. El instalador local lo registra cuando el usuario ejecuta Install-WindowsShare.ps1.'
