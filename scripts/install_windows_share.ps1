param([switch]$RegisterDeveloperPackage)
$ErrorActionPreference = 'Stop'
$folder = $PSScriptRoot
$manifest = Join-Path $folder 'AppxManifest.xml'
if (-not (Test-Path $manifest)) { throw 'Ejecutá este script desde la carpeta instalada de LanLink.' }
if (-not $RegisterDeveloperPackage) {
    Write-Host 'Para habilitar LanLink en Compartir, Windows necesita registrar su identidad de paquete.'
    Write-Host 'Este registro de desarrollo requiere que actives el modo para desarrolladores en Configuración > Sistema > Avanzado.'
    Write-Host 'Después ejecutá: powershell -NoProfile -File .\Install-WindowsShare.ps1 -RegisterDeveloperPackage'
    exit 2
}
# The user explicitly opts in; no trust store, certificate or system policy is changed here.
Get-Process lanlink -ErrorAction SilentlyContinue | Stop-Process
Add-AppxPackage -Register $manifest -DisableDevelopmentMode:$false
$package = Get-AppxPackage -Name 'gteijeiro.LanLink'
if (-not $package) { throw 'Windows no confirmó el registro de LanLink.' }
Write-Host 'LanLink registrado en Compartir. Abrí una foto > Compartir > LanLink.'
