; The Windows installer for GitHub releases, built with Inno Setup 6 by scripts/windows-installer.ps1,
; which passes AppVersion, FileVersion, Arch (x64 or arm64), SourceDir (a self-contained publish of
; Readme.App) and OutputDir. The Microsoft Store has its own package; this is for everyone else.
;
; It installs for the current user by default, with no administrator rights, into
; %LOCALAPPDATA%\Programs\Readme (or Program Files, if the user chooses all users). Readme's library
; in Documents\Readme is never touched, so uninstalling and reinstalling keeps every book.

#ifndef AppVersion
  #error AppVersion is required: run scripts/windows-installer.ps1
#endif

[Setup]
; Never change this: it's how Windows knows a new installer upgrades the old install.
AppId={{C36E7616-CE4A-441A-9261-70C86AF100BA}
AppName=Readme
AppVersion={#AppVersion}
AppVerName=Readme {#AppVersion}
VersionInfoVersion={#FileVersion}
AppPublisher=Rajan Chavda
AppPublisherURL=https://github.com/rajanchavda/readme
AppSupportURL=https://github.com/rajanchavda/readme/issues
AppUpdatesURL=https://github.com/rajanchavda/readme/releases/latest
DefaultDirName={autopf}\Readme
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; Windows 11 only, as decided for the app.
MinVersion=10.0.22000
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
#endif
OutputDir={#OutputDir}
OutputBaseFilename=Readme-Setup-{#AppVersion}-{#Arch}
SetupIconFile=..\Readme.App\Assets\Readme.ico
UninstallDisplayIcon={app}\Readme.exe
UninstallDisplayName=Readme
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
ChangesAssociations=yes
; Readme open while it's updated is closed first, and not restarted.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; An update replaces the whole app folder, so files a newer version dropped don't linger.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: filesandordirs; Name: "{app}\*"

[Icons]
Name: "{autoprograms}\Readme"; Filename: "{app}\Readme.exe"
Name: "{autodesktop}\Readme"; Filename: "{app}\Readme.exe"; Tasks: desktopicon

[Registry]
; Readme in "Open with" for EPUBs. It doesn't take EPUBs over from another app: Windows asks once,
; or the reader chooses it in Settings > Apps > Default apps.
Root: HKA; Subkey: "Software\Classes\Readme.epub"; ValueType: string; ValueData: "EPUB book"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Readme.epub\DefaultIcon"; ValueType: string; ValueData: """{app}\Readme.exe"",0"
Root: HKA; Subkey: "Software\Classes\Readme.epub\shell\open\command"; ValueType: string; ValueData: """{app}\Readme.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.epub\OpenWithProgids"; ValueType: string; ValueName: "Readme.epub"; ValueData: ""; Flags: uninsdeletevalue

; A .readmelibrary file is Readme's own, so Readme opens it.
Root: HKA; Subkey: "Software\Classes\Readme.readmelibrary"; ValueType: string; ValueData: "Readme library"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Readme.readmelibrary\DefaultIcon"; ValueType: string; ValueData: """{app}\Readme.exe"",0"
Root: HKA; Subkey: "Software\Classes\Readme.readmelibrary\shell\open\command"; ValueType: string; ValueData: """{app}\Readme.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.readmelibrary"; ValueType: string; ValueData: "Readme.readmelibrary"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.readmelibrary\OpenWithProgids"; ValueType: string; ValueName: "Readme.readmelibrary"; ValueData: ""; Flags: uninsdeletevalue

; So Readme is listed under Settings > Apps > Default apps, where EPUBs can be given to it.
Root: HKA; Subkey: "Software\Classes\Applications\Readme.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Readme"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\Readme.exe\SupportedTypes"; ValueType: string; ValueName: ".epub"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\Readme.exe\SupportedTypes"; ValueType: string; ValueName: ".readmelibrary"; ValueData: ""
Root: HKA; Subkey: "Software\Readme\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Readme"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Readme\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "A quiet EPUB reader that turns pages like a book."
Root: HKA; Subkey: "Software\Readme\Capabilities\FileAssociations"; ValueType: string; ValueName: ".epub"; ValueData: "Readme.epub"
Root: HKA; Subkey: "Software\Readme\Capabilities\FileAssociations"; ValueType: string; ValueName: ".readmelibrary"; ValueData: "Readme.readmelibrary"
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Readme"; ValueData: "Software\Readme\Capabilities"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Readme.exe"; Description: "{cm:LaunchProgram,Readme}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Settings, window placement and WebView2's cache, as the Store version's uninstall removes them.
; Never the library, which is in Documents\Readme.
Type: filesandordirs; Name: "{localappdata}\Readme"
