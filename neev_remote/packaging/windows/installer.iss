; Inno Setup script for Neev Remote (Windows installer).
; Build with: iscc.exe packaging\windows\installer.iss
; (build_windows.ps1 runs this automatically when iscc.exe is on PATH)

#define AppName "Neev Remote"
#define AppVersion "1.0.0"
#define AppPublisher "Neev"
#define AppExe "neev_remote.exe"

[Setup]
AppId={{8F1B6C3A-7E2D-4B5A-9C11-NEEVREMOTE001}}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=..\..\dist
OutputBaseFilename=NeevRemote-Setup-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
; Admin is needed to (optionally) install the UAC helper as a LOCAL SYSTEM
; service and to install into Program Files. The installer elevates once, like
; AnyDesk/TeamViewer.
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"
; Multi-user / unattended access: the SYSTEM service launches + follows the host
; into whichever session is active (across user-switching / logoff) so the
; machine is reachable with its machine-wide id + password no matter which
; account is active. Opt-in, off by default.
Name: "allusersstart"; Description: "Keep reachable for every user (service-managed unattended access)"; GroupDescription: "Unattended access:"; Flags: unchecked

[Files]
; Packages the entire release folder produced by `flutter build windows`.
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; ALWAYS install + start the SYSTEM helper service. It is required for the host
; to control elevated / run-as-admin apps and UAC prompts (a Medium-integrity
; app is UIPI-blocked from clicking High-integrity windows; only the SYSTEM
; service can). Mandatory like the AnyDesk/TeamViewer service — not opt-in, so a
; host is never left unable to receive clicks on an admin session.
Filename: "{app}\neev_helper.exe"; Parameters: "install"; Flags: runhidden waituntilterminated; StatusMsg: "Installing helper service..."
Filename: "{app}\{#AppExe}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

[Registry]
; ServiceHost mode (opt-in via the "allusersstart" task): the helper SERVICE
; launches + follows the host into the active session, so there is exactly ONE
; service-owned host (no duplicate from a per-user Run key). The service reads
; this flag live. Removed on uninstall.
Root: HKLM; Subkey: "SOFTWARE\NeevRemote"; ValueType: dword; ValueName: "ServiceHost"; ValueData: "1"; Flags: uninsdeletevalue; Tasks: allusersstart

[UninstallRun]
; Always remove the service on uninstall (no-op if it was never installed).
Filename: "{app}\neev_helper.exe"; Parameters: "uninstall"; Flags: runhidden; RunOnceId: "uninstallneevhelper"
