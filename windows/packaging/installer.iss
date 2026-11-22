; ClaudeNotch for Windows: per-user installer (ticket W16, decision D6).
; Built by build.ps1:  ISCC /DAppVersion=0.45.0 installer.iss
; No admin, no UAC prompt: installs to %LOCALAPPDATA%\Programs\ClaudeNotch.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define AppExe "ClaudeNotch.exe"

[Setup]
; Never change AppId: it is how upgrades find the installed copy.
AppId={{145A1E6D-8626-4FCD-9490-3E63DB68674C}
AppName=ClaudeNotch
AppVersion={#AppVersion}
AppVerName=ClaudeNotch {#AppVersion}
AppPublisher=rawsun007
AppPublisherURL=https://github.com/rawsun007/claude-notch
AppSupportURL=https://github.com/rawsun007/claude-notch/issues
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\ClaudeNotch
DisableProgramGroupPage=yes
DisableDirPage=yes
; The running app holds this mutex; the installer closes it before
; replacing files, through the Restart Manager, and starts it again after.
AppMutex=ClaudeNotch
CloseApplications=force
RestartApplications=yes
OutputDir=..\dist
OutputBaseFilename=ClaudeNotch-{#AppVersion}-windows-x64-setup
SetupIconFile=..\resources\ClaudeNotch.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName=ClaudeNotch
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
LicenseFile=..\..\LICENSE

[Files]
Source: "..\dist\ClaudeNotch\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The AppUserModelID must match paths.AUMID, so toasts carry our name and
; icon now and actionable toasts can come later without a reinstall.
Name: "{userprograms}\ClaudeNotch"; Filename: "{app}\{#AppExe}"; AppUserModelID: "Rawsun.ClaudeNotch"

[Run]
; Last page: wire Claude Code to the app and start it with a welcome.
Filename: "{app}\{#AppExe}"; Parameters: "--first-run"; Description: "Start ClaudeNotch"; Flags: nowait postinstall

[UninstallRun]
; The lesson from the Linux purge bug: removing the app must stop the
; running copy and take our hooks out of settings.json, or Claude Code
; keeps calling a server that is gone.
Filename: "{app}\{#AppExe}"; Parameters: "--quit-running --uninstall-hooks"; Flags: runhidden waituntilterminated; RunOnceId: "RemoveHooks"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// Start at login lives in the user's Run key; take it out on uninstall.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'ClaudeNotch');
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run', 'ClaudeNotch');
    // Settings and always-allow rules in %APPDATA%\ClaudeNotch are kept
    // unless the user asks for a clean removal.
    if MsgBox('Also remove your ClaudeNotch settings and Always allow rules?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
      DelTree(ExpandConstant('{userappdata}\ClaudeNotch'), True, True, True);
  end;
end;
