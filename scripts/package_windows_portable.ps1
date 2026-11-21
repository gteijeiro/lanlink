param(
    [string]$Release = 'build/windows/x64/runner/Release',
    [string]$Output = 'build/windows-portable',
    [string]$Commit = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-X64([string]$Path) {
    $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($Path))
    try {
        if ([System.IO.Path]::GetFileName($Path) -eq 'app.so') {
            # Dart's AOT snapshot uses ELF even on Windows; the engine loads it.
            if ($reader.ReadUInt32() -ne 0x464C457F -or $reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1) {
                throw "Snapshot AOT inválido o de otra arquitectura: $Path"
            }
            $reader.BaseStream.Position = 18
            if ($reader.ReadUInt16() -ne 62) { throw "El snapshot AOT no es x64: $Path" }
            return
        }
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "No es un ejecutable PE: $Path" }
        $reader.BaseStream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt $reader.BaseStream.Length - 6) { throw "Cabecera PE inválida: $Path" }
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw "El binario no es Windows AMD64/x64: $Path"
        }
    } finally { $reader.Dispose() }
}

$Release = (Resolve-Path -LiteralPath $Release).Path
$versionLine = (Select-String -LiteralPath 'pubspec.yaml' -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$version = $versionLine.Split('+')[0]
if (-not $Commit) { $Commit = (& git rev-parse HEAD).Trim() }
$folderName = 'LanLink-Windows-x64'
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$Output = (Resolve-Path -LiteralPath $Output).Path
$stage = Join-Path $Output $folderName
if (Test-Path -LiteralPath $stage) { throw "La carpeta de preparación ya existe: $stage" }
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -Path (Join-Path $Release '*') -Destination $stage -Recurse

# Ship the release CRT app-locally. No redistributable installer or elevation.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'No se encontró vswhere.exe' }
$visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $visualStudio) { throw 'No se encontró Visual Studio con herramientas C++ x64' }
$crt = Get-ChildItem -LiteralPath (Join-Path $visualStudio 'VC/Redist/MSVC') -Directory -Recurse |
    Where-Object { $_.Name -like 'Microsoft.VC*.CRT' -and $_.FullName -match '[/\\]x64[/\\]' } |
    Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'No se encontró el runtime redistribuible x64 de Visual C++' }
Copy-Item -Path (Join-Path $crt.FullName '*.dll') -Destination $stage

foreach ($required in @('lanlink.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'data/icudtl.dat', 'data/app.so', 'data/flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required))) { throw "Falta $required" }
}
foreach ($binary in Get-ChildItem -LiteralPath $stage -File -Recurse | Where-Object { $_.Extension -in '.exe', '.dll' -or $_.Name -eq 'app.so' }) {
    Assert-X64 $binary.FullName
}

@"
LanLink $version — Windows x64 portable

1. Extraé el ZIP completo en una carpeta de tu elección.
2. Abrí lanlink.exe dentro de la carpeta LanLink-Windows-x64.
3. Conservá juntos el ejecutable, las DLL y la carpeta data.

No requiere instalador ni ejecutar la aplicación como administrador.
Windows 10/11 de 64 bits. Incluye el runtime necesario de Visual C++.
Si Windows pregunta por acceso a la red, permití la red privada para recibir archivos.

La aplicación se ejecuta desde esta carpeta; los ajustes y las vinculaciones se
guardan en tu perfil de Windows. Los archivos recibidos usan la configuración de
descargas de LanLink. Copiar esta carpeta no copia claves ni vinculaciones.

Esta edición no registra LanLink en el menú Compartir de Windows. Podés abrir
LanLink y elegir los archivos desde la aplicación.

Versión estable $versionLine. Las mejoras de recepción en segundo plano y push
que están en desarrollo no forman parte de esta edición.
Código fuente: https://github.com/gteijeiro/lanlink
Compilación: $Commit
"@ | Set-Content -LiteralPath (Join-Path $stage 'LEEME.txt') -Encoding utf8BOM

@{ version = $versionLine; commit = $Commit; platform = 'windows'; architecture = 'x64'; configuration = 'Release'; portable = $true } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'BUILD.json') -Encoding utf8
$hashes = foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName) {
    $relative = [System.IO.Path]::GetRelativePath($stage, $file.FullName).Replace([char]92, [char]47)
    '{0}  {1}' -f (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
}
$hashes | Set-Content -LiteralPath (Join-Path $stage 'FILES.sha256') -Encoding utf8
$zip = Join-Path $Output "LanLink-$version-Windows-x64-portable.zip"
if (Test-Path -LiteralPath $zip) { throw "El ZIP ya existe: $zip" }
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$zipHash  $([System.IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Output $zip
