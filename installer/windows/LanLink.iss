#define AppVersion "1.0.0"

[Setup]
AppId={{9E4B814C-68CC-4FA3-944E-208A58A7CEAD}
AppName=LanLink
AppVersion={#AppVersion}
AppPublisher=LanLink
DefaultDirName={localappdata}\Programs\LanLink
DefaultGroupName=LanLink
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
OutputDir=..\..\build\windows-installer
OutputBaseFilename=LanLink-Windows-x64-Setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\lanlink.exe
WizardStyle=modern

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\LanLink"; Filename: "{app}\lanlink.exe"
Name: "{autodesktop}\LanLink"; Filename: "{app}\lanlink.exe"; Tasks: desktopicon

[Tasks]
Name: desktopicon; Description: "Crear acceso directo en el escritorio"

[Run]
Filename: "{app}\lanlink.exe"; Description: "Abrir LanLink"; Flags: nowait postinstall skipifsilent
