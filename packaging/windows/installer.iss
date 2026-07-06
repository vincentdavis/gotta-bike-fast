; Inno Setup script — bundles the game and the frozen BLE bridge into a
; single Windows installer. Paths are relative to this .iss file; the CI
; stages both executables into dist_pkg/app/ before running ISCC.

[Setup]
AppName=GOTTA.BIKE: Virtual
AppVersion=0.1.0
AppPublisher=vdavis
DefaultDirName={autopf}\GottaBikeFast
; A colon can't appear in a Start-menu folder path, so keep {group} colon-free.
DefaultGroupName=GOTTA.BIKE Virtual
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
Name: "{group}\GOTTA.BIKE Virtual"; Filename: "{app}\GottaBikeFast.exe"
Name: "{autodesktop}\GOTTA.BIKE Virtual"; Filename: "{app}\GottaBikeFast.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\GottaBikeFast.exe"; Description: "Launch GOTTA.BIKE: Virtual"; Flags: nowait postinstall skipifsilent
