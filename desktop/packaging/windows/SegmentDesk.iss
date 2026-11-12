#ifndef AppVersion
  #define AppVersion "0.1.1"
#endif

[Setup]
AppId=SegmentDesk.Desktop
AppName=SegmentDesk
AppVersion={#AppVersion}
AppPublisher=SegmentDesk contributors
AppPublisherURL=https://github.com/evan-dev0608/segmentdesk
DefaultDirName={localappdata}\Programs\SegmentDesk
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\stream_download.exe
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
OutputDir=..\..\dist
OutputBaseFilename=SegmentDesk-windows-x64-setup
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Icons]
Name: "{userprograms}\SegmentDesk"; Filename: "{app}\stream_download.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\SegmentDesk"; Filename: "{app}\stream_download.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\stream_download.exe"; Description: "{cm:LaunchProgram,SegmentDesk}"; Flags: nowait postinstall skipifsilent
