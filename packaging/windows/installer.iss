; Inno Setup script — bundles the game and the frozen BLE bridge into a
; single Windows installer. Paths are relative to this .iss file; the CI
; stages both executables into dist_pkg/app/ before running ISCC.

[Setup]
AppName=Gotta Bike Fast
AppVersion=0.1.0
AppPublisher=vdavis
DefaultDirName={autopf}\GottaBikeFast
DisableProgramGroupPage=yes
OutputDir=..\..\dist_pkg
OutputBaseFilename=GottaBikeFast-Setup
Compression=lzma2
SolidCompression=yes
; No admin required — installs per-user under Local AppData.
PrivilegesRequired=lowest

[Files]
Source: "..\..\dist_pkg\app\GottaBikeFast.exe"; DestDir: "{app}"; Flags: ignoreversion
; The bridge sits next to the game .exe so the game auto-launches it.
Source: "..\..\dist_pkg\app\gbf-bridge.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Gotta Bike Fast"; Filename: "{app}\GottaBikeFast.exe"
Name: "{autodesktop}\Gotta Bike Fast"; Filename: "{app}\GottaBikeFast.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\GottaBikeFast.exe"; Description: "Launch Gotta Bike Fast"; Flags: nowait postinstall skipifsilent
