; Inno Setup script for the Lumtub installer, built by .github/workflows/build.yml:
;   iscc /DAppVersion=0.1.0 /DSourceDir=<release folder> /DOutputDir=<folder> lumtub.iss
; Installs for the current user only, so no administrator rights are needed,
; the same as the portable ZIP.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif
#ifndef PackageArch
  #define PackageArch "x64"
#endif
#ifndef InstallArch
  #define InstallArch "x64"
#endif

[Setup]
AppId={{6F1C2E9A-3B7D-4C55-9E2A-8D4F1A7B9C31}
AppName=Lumtub
AppVersion={#AppVersion}
AppVerName=Lumtub {#AppVersion}
AppPublisher=Lumtub
AppPublisherURL=https://github.com/0x696c757a696f/lumtub
AppSupportURL=https://github.com/0x696c757a696f/lumtub/issues
DefaultDirName={autopf}\Lumtub
DefaultGroupName=Lumtub
DisableProgramGroupPage=yes
UsePreviousGroup=no
PrivilegesRequired=lowest
ArchitecturesAllowed={#InstallArch}
ArchitecturesInstallIn64BitMode={#InstallArch}
MinVersion=10.0
LicenseFile={#SourceDir}\LICENSE
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\lumtub.exe
OutputDir={#OutputDir}
OutputBaseFilename=Lumtub_{#AppVersion}_windows-{#PackageArch}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; The app must be closed so its DLLs can be replaced.
CloseApplications=yes

[Languages]
#if FileExists(CompilerPath + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Left by versions released as YTPlus.
Type: files; Name: "{app}\ytplus.exe"
Type: files; Name: "{app}\ytplus_core.dll"
Type: filesandordirs; Name: "{autoprograms}\YTPlus"
Type: files; Name: "{autodesktop}\YTPlus.lnk"

[Icons]
Name: "{group}\Lumtub"; Filename: "{app}\lumtub.exe"
Name: "{group}\{cm:UninstallProgram,Lumtub}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Lumtub"; Filename: "{app}\lumtub.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\lumtub.exe"; Description: "{cm:LaunchProgram,Lumtub}"; Flags: nowait postinstall skipifsilent

; Settings, history, the library and downloaded components live in
; %LOCALAPPDATA%\Lumtub and are kept on uninstall, so reinstalling or
; switching to the portable ZIP keeps them.
