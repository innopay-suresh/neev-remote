// neev_helper.cpp — Neev Remote privileged helper (UAC support, Phase 1).
//
// WHY THIS EXISTS
//   A normal user-session app (the Flutter host) cannot see or click the
//   Windows UAC consent prompt or other elevated windows: UAC runs on the
//   isolated "secure desktop" and Windows UIPI forbids a lower-integrity
//   process from injecting input into a higher-integrity window. The only
//   robust fix (what AnyDesk/TeamViewer ship) is a LOCAL SYSTEM service plus a
//   SYSTEM-level agent running inside the interactive session. This binary is
//   that helper.
//
// PHASE 1 SCOPE (this file) — prove the privileged foundation on real machines:
//   * install / uninstall / run as a LOCAL SYSTEM auto-start service
//   * the service launches an AGENT *as SYSTEM* in the active interactive
//     session (so the agent can later open the secure desktop + inject into
//     elevated windows)
//   * the agent logs the current input-desktop name; triggering a UAC prompt
//     makes the log show the secure desktop ("Winlogon") being detected.
//   Later phases add: secure-desktop capture, input injection into
//   consent.exe / elevated windows, and a named-pipe IPC to the Flutter app.
//
// BUILD (standalone, no Flutter deps):
//   cl /EHsc /O2 /DUNICODE /D_UNICODE neev_helper.cpp ^
//      /link advapi32.lib user32.lib wtsapi32.lib userenv.lib
//
// USAGE:
//   neev_helper.exe install     (elevated) — create + start the service
//   neev_helper.exe uninstall   (elevated) — stop + delete the service
//   neev_helper.exe agent       — session-agent loop (the service launches this)
//   neev_helper.exe             — service entry point (invoked by the SCM)

#define _CRT_RAND_S      // enable rand_s (must precede <cstdlib>)
#include <cstdlib>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <wtsapi32.h>
#include <userenv.h>
#include <objidl.h>
#include <gdiplus.h>
#include <string>
#include <vector>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <cstdint>

static const wchar_t* kServiceName = L"NeevRemoteHelper";
static const wchar_t* kDisplayName = L"Neev Remote Helper";
static const wchar_t* kLogDir = L"C:\\ProgramData\\NeevRemote";
static const wchar_t* kLogPath = L"C:\\ProgramData\\NeevRemote\\helper.log";
// Machine-wide credentials (multi-user / cross-session access). Owned by the
// SYSTEM helper so a single ID + password work for every account on the box and
// survive user-switching. Stored as two UTF-8 lines: "id\npassword\n".
static const wchar_t* kCredPath = L"C:\\ProgramData\\NeevRemote\\machine.dat";

// --------------------------------------------------------------------------
// Logging (single shared file; both the service and the agent append to it).
// --------------------------------------------------------------------------
static void Log(const wchar_t* tag, const wchar_t* fmt, ...) {
  CreateDirectoryW(kLogDir, nullptr);
  // Plain append mode (portable across the MSVC and MinGW runtimes); log text
  // is ASCII so no wide-encoding mode is needed.
  FILE* f = _wfopen(kLogPath, L"a+");
  if (!f) return;
  SYSTEMTIME st;
  GetLocalTime(&st);
  fwprintf(f, L"[%04d-%02d-%02d %02d:%02d:%02d] %ls: ", st.wYear, st.wMonth,
           st.wDay, st.wHour, st.wMinute, st.wSecond, tag);
  va_list args;
  va_start(args, fmt);
  vfwprintf(f, fmt, args);
  va_end(args);
  fwprintf(f, L"\n");
  fclose(f);
}

static std::wstring SelfPath() {
  wchar_t buf[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return std::wstring(buf);
}

// --------------------------------------------------------------------------
// Machine-wide credential store (multi-user / cross-session).
//   File: C:\ProgramData\NeevRemote\machine.dat — two UTF-8 lines: id, password.
// The SYSTEM helper is the single owner; standard-user Flutter hosts fetch/set
// these over the localhost IPC so the ID + password are identical for every
// account and follow whichever session is active.
// --------------------------------------------------------------------------
// Read the two lines. Returns false if the file is missing/empty.
static bool LoadMachineCreds(std::string& id, std::string& pw) {
  id.clear();
  pw.clear();
  HANDLE hf = CreateFileW(kCredPath, GENERIC_READ, FILE_SHARE_READ, nullptr,
                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (hf == INVALID_HANDLE_VALUE) return false;
  char buf[512];
  DWORD rd = 0;
  std::string all;
  while (ReadFile(hf, buf, sizeof(buf), &rd, nullptr) && rd > 0)
    all.append(buf, rd);
  CloseHandle(hf);
  // Split on the first newline; strip CR.
  size_t nl = all.find('\n');
  std::string a = (nl == std::string::npos) ? all : all.substr(0, nl);
  std::string b = (nl == std::string::npos) ? std::string() : all.substr(nl + 1);
  size_t nl2 = b.find('\n');
  if (nl2 != std::string::npos) b = b.substr(0, nl2);
  auto trim = [](std::string& s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' '))
      s.pop_back();
  };
  trim(a);
  trim(b);
  id = a;
  pw = b;
  return !id.empty();
}

static bool SaveMachineCreds(const std::string& id, const std::string& pw) {
  CreateDirectoryW(kLogDir, nullptr);
  HANDLE hf = CreateFileW(kCredPath, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL, nullptr);
  if (hf == INVALID_HANDLE_VALUE) return false;
  std::string out = id + "\n" + pw + "\n";
  DWORD wr = 0;
  BOOL ok = WriteFile(hf, out.data(), (DWORD)out.size(), &wr, nullptr);
  CloseHandle(hf);
  return ok == TRUE;
}

// Generate a stable 9-digit numeric ID once, if the store has none yet.
static std::string EnsureMachineId() {
  std::string id, pw;
  if (LoadMachineCreds(id, pw) && !id.empty()) return id;
  // No id yet: mint one from a crypto-quality source.
  unsigned int r1 = 0, r2 = 0;
  rand_s(&r1);
  rand_s(&r2);
  unsigned long long v =
      ((unsigned long long)r1 << 32 | r2) % 1000000000ULL;  // 0..1e9-1
  char num[16];
  sprintf(num, "%09llu", v);
  id = num;
  SaveMachineCreds(id, pw);  // pw may be empty until the user sets one
  Log(L"svc", L"minted machine id %hs", id.c_str());
  return id;
}

// --------------------------------------------------------------------------
// Service install / uninstall.
// --------------------------------------------------------------------------
static int InstallService() {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (!scm) {
    wprintf(L"OpenSCManager failed: %lu (run elevated)\n", GetLastError());
    return 1;
  }
  std::wstring path = L"\"" + SelfPath() + L"\"";
  SC_HANDLE svc = CreateServiceW(
      scm, kServiceName, kDisplayName, SERVICE_ALL_ACCESS,
      SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
      path.c_str(), nullptr, nullptr, nullptr,
      nullptr /* LocalSystem */, nullptr);
  if (!svc) {
    DWORD e = GetLastError();
    if (e == ERROR_SERVICE_EXISTS) {
      svc = OpenServiceW(scm, kServiceName, SERVICE_ALL_ACCESS);
      if (svc) {
        // Service already exists (likely an older build): update its binary
        // path to THIS exe and stop it, so StartService below loads the new
        // binary. Without this, re-running 'install' silently keeps the old exe.
        ChangeServiceConfigW(svc, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE,
                             SERVICE_NO_CHANGE, path.c_str(), nullptr, nullptr,
                             nullptr, nullptr, nullptr, nullptr);
        SERVICE_STATUS st = {0};
        ControlService(svc, SERVICE_CONTROL_STOP, &st);
        Sleep(1200);
        wprintf(L"Updated existing service to this binary\n");
      }
    } else {
      wprintf(L"CreateService failed: %lu\n", e);
      CloseServiceHandle(scm);
      return 1;
    }
  }
  if (svc) {
    StartServiceW(svc, 0, nullptr);
    CloseServiceHandle(svc);
    wprintf(L"Installed + started '%ls'. Log: %ls\n", kServiceName, kLogPath);
  }
  CloseServiceHandle(scm);
  return 0;
}

static int UninstallService() {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
  if (!scm) {
    wprintf(L"OpenSCManager failed: %lu (run elevated)\n", GetLastError());
    return 1;
  }
  SC_HANDLE svc = OpenServiceW(scm, kServiceName, SERVICE_ALL_ACCESS);
  if (svc) {
    SERVICE_STATUS st = {0};
    ControlService(svc, SERVICE_CONTROL_STOP, &st);
    Sleep(500);
    DeleteService(svc);
    CloseServiceHandle(svc);
    wprintf(L"Uninstalled '%ls'\n", kServiceName);
  } else {
    wprintf(L"Service '%ls' not found\n", kServiceName);
  }
  CloseServiceHandle(scm);
  return 0;
}

// --------------------------------------------------------------------------
// Launch the agent AS SYSTEM in the active interactive session.
//
// A service lives in session 0 (isolated), so SendInput/capture there never
// touch the user's screen. We duplicate our own SYSTEM token, retarget it to
// the active console session, and CreateProcessAsUser — yielding a SYSTEM
// process inside the user's session that CAN reach the secure desktop and
// inject into elevated windows.
// --------------------------------------------------------------------------
// Pick the session that is actively receiving user input. With RDP the physical
// console (WTSGetActiveConsoleSessionId) is LOCKED and the user is in a separate
// session, so we must target the WTSActive session — that's where the user (and
// their UAC prompt) actually is. Fall back to the console.
static DWORD GetTargetSessionId() {
  DWORD result = 0xFFFFFFFF;
  PWTS_SESSION_INFOW sessions = nullptr;
  DWORD count = 0;
  if (WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, &sessions,
                            &count)) {
    for (DWORD i = 0; i < count; i++) {
      if (sessions[i].State == WTSActive) {
        result = sessions[i].SessionId;
        break;
      }
    }
    WTSFreeMemory(sessions);
  }
  if (result == 0xFFFFFFFF) result = WTSGetActiveConsoleSessionId();
  return result;
}

// Install directory (this exe's folder) with a trailing backslash.
static std::wstring InstallDir() {
  std::wstring self = SelfPath();
  size_t slash = self.find_last_of(L"\\/");
  return (slash == std::wstring::npos) ? L"" : self.substr(0, slash + 1);
}

// The Flutter host exe sits next to the helper in the install dir.
static std::wstring HostExePath() { return InstallDir() + L"neev_remote.exe"; }

// Opt-in "service owns the host" mode: HKLM\SOFTWARE\NeevRemote\ServiceHost=1
// (written by the installer's unattended task). When set, the service launches
// + follows neev_remote.exe into the active session so the machine is reachable
// across user-switching and, later, at the login screen. Read every loop so the
// installer toggle takes effect without a service restart.
static bool ReadServiceHostFlag() {
  DWORD val = 0, sz = sizeof(val);
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\NeevRemote", L"ServiceHost",
                   RRF_RT_REG_DWORD, nullptr, &val, &sz) == ERROR_SUCCESS) {
    return val != 0;
  }
  return false;
}

// Launch [cmdline] AS SYSTEM in the interactive [sid]. Used for both the helper
// agent and (in ServiceHost mode) the Flutter host — same token-retarget trick.
static HANDLE LaunchProcessInSession(DWORD sid, const std::wstring& cmdline,
                                     const wchar_t* tag) {
  if (sid == 0xFFFFFFFF) {
    Log(L"svc", L"no target session yet (%ls)", tag);
    return nullptr;
  }

  HANDLE selfTok = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(),
                        TOKEN_DUPLICATE | TOKEN_ADJUST_SESSIONID |
                            TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY,
                        &selfTok)) {
    Log(L"svc", L"OpenProcessToken failed: %lu", GetLastError());
    return nullptr;
  }
  HANDLE primary = nullptr;
  if (!DuplicateTokenEx(selfTok, MAXIMUM_ALLOWED, nullptr, SecurityImpersonation,
                        TokenPrimary, &primary)) {
    Log(L"svc", L"DuplicateTokenEx failed: %lu", GetLastError());
    CloseHandle(selfTok);
    return nullptr;
  }
  CloseHandle(selfTok);

  // Retarget the SYSTEM token to the target session.
  if (!SetTokenInformation(primary, TokenSessionId, &sid, sizeof(sid))) {
    Log(L"svc", L"SetTokenInformation(session=%lu) failed: %lu", sid,
        GetLastError());
    // continue anyway — some configs still launch into the right session
  }

  LPVOID env = nullptr;
  CreateEnvironmentBlock(&env, primary, FALSE);

  STARTUPINFOW si = {0};
  si.cb = sizeof(si);
  si.lpDesktop = const_cast<LPWSTR>(L"winsta0\\default");
  PROCESS_INFORMATION pi = {0};
  std::wstring mutableCmd = cmdline;  // CreateProcess may modify the buffer

  BOOL ok = CreateProcessAsUserW(
      primary, nullptr, &mutableCmd[0], nullptr, nullptr, FALSE,
      CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, env, nullptr, &si, &pi);

  if (env) DestroyEnvironmentBlock(env);
  CloseHandle(primary);

  if (!ok) {
    Log(L"svc", L"CreateProcessAsUser(%ls) failed: %lu", tag, GetLastError());
    return nullptr;
  }
  Log(L"svc", L"launched %ls in session %lu (pid %lu)", tag, sid,
      pi.dwProcessId);
  CloseHandle(pi.hThread);
  return pi.hProcess;  // caller owns; used to detect exit
}

static HANDLE LaunchAgentInSession(DWORD sid) {
  return LaunchProcessInSession(sid, L"\"" + SelfPath() + L"\" agent", L"agent");
}

static HANDLE LaunchHostInSession(DWORD sid) {
  return LaunchProcessInSession(
      sid, L"\"" + HostExePath() + L"\" --service-host", L"host");
}

// --------------------------------------------------------------------------
// Service control + main loop. Keeps exactly one agent alive, relaunching it
// when it exits (e.g. session switch / logoff).
// --------------------------------------------------------------------------
static SERVICE_STATUS g_status = {0};
static SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
static HANDLE g_stopEvent = nullptr;

static void SetState(DWORD state) {
  g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_status.dwCurrentState = state;
  g_status.dwControlsAccepted = (state == SERVICE_RUNNING) ? SERVICE_ACCEPT_STOP : 0;
  SetServiceStatus(g_statusHandle, &g_status);
}

static void WINAPI ServiceCtrl(DWORD ctrl) {
  if (ctrl == SERVICE_CONTROL_STOP || ctrl == SERVICE_CONTROL_SHUTDOWN) {
    SetState(SERVICE_STOP_PENDING);
    if (g_stopEvent) SetEvent(g_stopEvent);
  }
}

static void WINAPI ServiceMain(DWORD, LPWSTR*) {
  g_statusHandle = RegisterServiceCtrlHandlerW(kServiceName, ServiceCtrl);
  if (!g_statusHandle) return;
  g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  SetState(SERVICE_RUNNING);
  Log(L"svc", L"service started (LOCAL SYSTEM, session 0)");

  HANDLE agent = nullptr;
  DWORD agentSession = 0xFFFFFFFF;
  HANDLE host = nullptr;  // ServiceHost mode: the service-owned Flutter host
  DWORD hostSession = 0xFFFFFFFF;
  for (;;) {
    DWORD target = GetTargetSessionId();

    // ---- helper agent (always kept alive in the active session) ----
    bool dead = (!agent || WaitForSingleObject(agent, 0) == WAIT_OBJECT_0);
    bool moved = (agent && target != 0xFFFFFFFF && target != agentSession);
    if (dead || moved) {
      if (agent) {
        if (moved) {
          Log(L"svc", L"active session %lu -> %lu; relaunching agent",
              agentSession, target);
          TerminateProcess(agent, 0);
        } else {
          Log(L"svc", L"agent exited; relaunching");
        }
        CloseHandle(agent);
        agent = nullptr;
      }
      agent = LaunchAgentInSession(target);
      agentSession = target;
    }

    // ---- Flutter host (opt-in ServiceHost mode) ----
    // When enabled, the service owns a single host that follows the active
    // session — reachable across user-switching / logoff with the machine-wide
    // id+password. When disabled, the host is user-launched as before.
    if (ReadServiceHostFlag()) {
      bool hDead = (!host || WaitForSingleObject(host, 0) == WAIT_OBJECT_0);
      bool hMoved = (host && target != 0xFFFFFFFF && target != hostSession);
      if (hDead || hMoved) {
        if (host) {
          if (hMoved)
            Log(L"svc", L"active session %lu -> %lu; relaunching host",
                hostSession, target);
          else
            Log(L"svc", L"host exited; relaunching");
          if (hMoved) TerminateProcess(host, 0);
          CloseHandle(host);
          host = nullptr;
        }
        host = LaunchHostInSession(target);
        hostSession = target;
      }
    } else if (host) {
      // Mode was turned off — stop the service-owned host.
      Log(L"svc", L"ServiceHost mode off; stopping host");
      TerminateProcess(host, 0);
      CloseHandle(host);
      host = nullptr;
      hostSession = 0xFFFFFFFF;
    }

    if (WaitForSingleObject(g_stopEvent, 3000) == WAIT_OBJECT_0) break;
  }

  if (agent) {
    TerminateProcess(agent, 0);
    CloseHandle(agent);
  }
  if (host) {
    TerminateProcess(host, 0);
    CloseHandle(host);
  }
  Log(L"svc", L"service stopping");
  SetState(SERVICE_STOPPED);
}

// --------------------------------------------------------------------------
// Phase 2: capture a desktop by name via GDI. The secure (Winlogon) desktop is
// NOT DWM-composited, so a plain BitBlt captures it correctly (unlike the
// normal desktop, which needs DXGI). The agent runs as SYSTEM, so it may
// OpenInputDesktop(Winlogon), SetThreadDesktop onto it, and BitBlt.
// --------------------------------------------------------------------------
static bool SaveHBitmapToBmp(HBITMAP hbm, HDC hdc, int w, int h,
                             const wchar_t* path) {
  BITMAPINFOHEADER bi = {0};
  bi.biSize = sizeof(bi);
  bi.biWidth = w;
  bi.biHeight = h;  // bottom-up
  bi.biPlanes = 1;
  bi.biBitCount = 24;
  bi.biCompression = BI_RGB;
  const int rowSize = ((w * 3 + 3) & ~3);
  const int imgSize = rowSize * h;
  std::vector<BYTE> bits(imgSize);
  if (!GetDIBits(hdc, hbm, 0, h, bits.data(),
                 reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS)) {
    return false;
  }
  BITMAPFILEHEADER bf = {0};
  bf.bfType = 0x4D42;  // 'BM'
  bf.bfOffBits = sizeof(bf) + sizeof(bi);
  bf.bfSize = bf.bfOffBits + imgSize;
  HANDLE hf = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL, nullptr);
  if (hf == INVALID_HANDLE_VALUE) return false;
  DWORD wr = 0;
  WriteFile(hf, &bf, sizeof(bf), &wr, nullptr);
  WriteFile(hf, &bi, sizeof(bi), &wr, nullptr);
  WriteFile(hf, bits.data(), imgSize, &wr, nullptr);
  CloseHandle(hf);
  return true;
}

static bool CaptureInputDesktopToBmp(const wchar_t* path) {
  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) {
    Log(L"agent", L"capture: OpenInputDesktop failed %lu", GetLastError());
    return false;
  }
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (!SetThreadDesktop(hDesk)) {
    Log(L"agent", L"capture: SetThreadDesktop failed %lu", GetLastError());
    CloseDesktop(hDesk);
    return false;
  }

  bool ok = false;
  HDC hScreen = GetDC(nullptr);
  if (hScreen) {
    int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (w <= 0 || h <= 0) {
      w = GetSystemMetrics(SM_CXSCREEN);
      h = GetSystemMetrics(SM_CYSCREEN);
      x = 0;
      y = 0;
    }
    HDC hMem = CreateCompatibleDC(hScreen);
    HBITMAP hbm = CreateCompatibleBitmap(hScreen, w, h);
    if (hMem && hbm) {
      HGDIOBJ oldObj = SelectObject(hMem, hbm);
      BitBlt(hMem, 0, 0, w, h, hScreen, x, y, SRCCOPY);
      SelectObject(hMem, oldObj);  // deselect before GetDIBits
      ok = SaveHBitmapToBmp(hbm, hScreen, w, h, path);
    }
    if (hbm) DeleteObject(hbm);
    if (hMem) DeleteDC(hMem);
    ReleaseDC(nullptr, hScreen);
  }

  SetThreadDesktop(hPrev);
  CloseDesktop(hDesk);
  if (ok) Log(L"agent", L"capture: wrote %ls", path);
  return ok;
}

// --------------------------------------------------------------------------
// Phase 3b: stream the secure desktop to the Flutter app over a named pipe and
// inject the viewer's real clicks/keys into consent.exe (no more auto-decline).
//
//   IPC: localhost TCP on 127.0.0.1:47921 (the SYSTEM agent listens; the
//   user-session Flutter app connects — a plain Dart Socket). Length-prefixed:
//     [uint32 LE len][uint8 type][payload]   (len = 1 + payloadLen)
//   Agent -> app:  'A' int32 w,h (UAC active)   'F' PNG bytes   'G' (UAC gone)
//   App  -> agent: 'C' uint8 btn, float x,y (click)   'K' uint16 vk (key)
// --------------------------------------------------------------------------
static const unsigned short kPort = 47921;  // 127.0.0.1 only
static CRITICAL_SECTION g_clientLock;
static SOCKET g_client = INVALID_SOCKET;

static int GetEncoderClsid(const WCHAR* mime, CLSID* clsid) {
  UINT num = 0, size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  std::vector<BYTE> buf(size);
  auto* info = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buf.data());
  Gdiplus::GetImageEncoders(num, size, info);
  for (UINT i = 0; i < num; i++) {
    if (wcscmp(info[i].MimeType, mime) == 0) {
      *clsid = info[i].Clsid;
      return (int)i;
    }
  }
  return -1;
}

// Encode the captured desktop as JPEG, downscaled so the longest side is
// <= kMaxDim. PNG of a UAC *credential* prompt (standard-user login: the full
// wallpaper shows behind it, undimmed) ran 1.5-7 MB — too big for the viewer's
// TCP framer AND for a single WebRTC data-channel message, so those frames were
// silently dropped and the prompt never appeared in the viewer. JPEG + downscale
// keeps every frame to ~100-150 KB; the dialog stays perfectly legible and the
// viewer's normalized-coordinate clicks are unaffected by the scale.
static bool EncodeHBitmapToJpeg(HBITMAP hbm, std::vector<BYTE>& out) {
  Gdiplus::Bitmap src(hbm, (HPALETTE) nullptr);
  UINT sw = src.GetWidth(), sh = src.GetHeight();
  if (sw == 0 || sh == 0) return false;

  const UINT kMaxDim = 1366;
  UINT mx = sw > sh ? sw : sh;
  double scale = (mx > kMaxDim) ? (double)kMaxDim / (double)mx : 1.0;
  UINT dw = (UINT)(sw * scale + 0.5), dh = (UINT)(sh * scale + 0.5);
  if (dw == 0) dw = 1;
  if (dh == 0) dh = 1;

  CLSID clsid;
  if (GetEncoderClsid(L"image/jpeg", &clsid) < 0) return false;

  ULONG quality = 80;
  Gdiplus::EncoderParameters params;
  params.Count = 1;
  params.Parameter[0].Guid = Gdiplus::EncoderQuality;
  params.Parameter[0].Type = Gdiplus::EncoderParameterValueTypeLong;
  params.Parameter[0].NumberOfValues = 1;
  params.Parameter[0].Value = &quality;

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK) return false;

  bool ok;
  if (scale < 1.0) {
    Gdiplus::Bitmap scaled(dw, dh, PixelFormat24bppRGB);
    Gdiplus::Graphics g(&scaled);
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.DrawImage(&src, 0, 0, (INT)dw, (INT)dh);
    ok = (scaled.Save(stream, &clsid, &params) == Gdiplus::Ok);
  } else {
    ok = (src.Save(stream, &clsid, &params) == Gdiplus::Ok);
  }

  if (ok) {
    HGLOBAL hg = nullptr;
    if (GetHGlobalFromStream(stream, &hg) == S_OK && hg) {
      SIZE_T sz = GlobalSize(hg);
      void* p = GlobalLock(hg);
      if (p) {
        out.assign((BYTE*)p, (BYTE*)p + sz);
        GlobalUnlock(hg);
      } else {
        ok = false;
      }
    } else {
      ok = false;
    }
  }
  stream->Release();
  return ok;
}

// Capture the current input (secure) desktop to PNG bytes + report its size.
// Pixels are grabbed WHILE on the secure desktop (fast BitBlt), then the desktop
// is restored BEFORE the GDI+ PNG encode — GDI+ run while the thread sits on the
// Winlogon desktop can stall. Timing is logged so we can see where time goes.
static bool CaptureSecureDesktopToPng(std::vector<BYTE>& png, int& outW,
                                      int& outH) {
  DWORD t0 = GetTickCount();
  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) return false;
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (!SetThreadDesktop(hDesk)) {
    CloseDesktop(hDesk);
    return false;
  }

  // Capture the PRIMARY monitor only (origin 0,0). The UAC secure desktop is
  // drawn on the primary, so this frames the dialog centered and large instead
  // of losing it in a whole multi-monitor virtual desktop. Injection below uses
  // ABSOLUTE-over-primary (no VIRTUALDESK) to match.
  HBITMAP hbm = nullptr;
  int x = 0;
  int y = 0;
  int w = GetSystemMetrics(SM_CXSCREEN);
  int h = GetSystemMetrics(SM_CYSCREEN);
  HDC hScreen = GetDC(nullptr);
  if (hScreen) {
    // Use the TRUE physical resolution. On a high-DPI display GetSystemMetrics
    // can return the DPI-scaled (logical) size (e.g. 1707x1067 for a 2560x1600
    // panel at 150%) while the screen DC is physical — BitBlt then grabs only
    // the top-left region, so the centered UAC dialog landed in the bottom-right
    // and got cut off. DESKTOPHORZRES/VERTRES report physical pixels regardless
    // of the process's DPI-awareness, so the whole screen is captured.
    int pw = GetDeviceCaps(hScreen, DESKTOPHORZRES);
    int ph = GetDeviceCaps(hScreen, DESKTOPVERTRES);
    if (pw > 0 && ph > 0) {
      w = pw;
      h = ph;
    }
    HDC hMem = CreateCompatibleDC(hScreen);
    hbm = CreateCompatibleBitmap(hScreen, w, h);
    if (hMem && hbm) {
      HGDIOBJ old = SelectObject(hMem, hbm);
      BitBlt(hMem, 0, 0, w, h, hScreen, x, y, SRCCOPY);
      SelectObject(hMem, old);
    }
    if (hMem) DeleteDC(hMem);
    ReleaseDC(nullptr, hScreen);
  }
  DWORD t1 = GetTickCount();

  // Restore the original desktop BEFORE encoding.
  SetThreadDesktop(hPrev);
  CloseDesktop(hDesk);

  bool ok = false;
  if (hbm) {
    ok = EncodeHBitmapToJpeg(hbm, png);
    DeleteObject(hbm);
    outW = w;
    outH = h;
  }
  DWORD t2 = GetTickCount();
  Log(L"agent", L"capture-img: blt=%lums encode=%lums size=%u%ls", t1 - t0,
      t2 - t1, (unsigned)png.size(), ok ? L"" : L"  (FAILED)");
  return ok;
}

// Inject a mouse click at normalized (nx,ny) over the PRIMARY monitor on the
// current (secure) input desktop. Runs as SYSTEM, so it reaches consent.exe.
// ABSOLUTE without VIRTUALDESK maps 0..65535 to the primary monitor, matching
// the primary-only secure-desktop capture — so a click lands on the dialog.
static void InjectClickOnSecureDesktop(int button, float nx, float ny) {
  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) return;
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (!SetThreadDesktop(hDesk)) {
    CloseDesktop(hDesk);
    return;
  }
  LONG ax = (LONG)(nx * 65535.0f), ay = (LONG)(ny * 65535.0f);
  DWORD dn = (button == 1) ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
  DWORD up = (button == 1) ? MOUSEEVENTF_RIGHTUP : MOUSEEVENTF_LEFTUP;
  INPUT in[3] = {0};
  in[0].type = INPUT_MOUSE;
  in[0].mi.dx = ax;
  in[0].mi.dy = ay;
  in[0].mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
  in[1].type = INPUT_MOUSE;
  in[1].mi.dx = ax;
  in[1].mi.dy = ay;
  in[1].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | dn;
  in[2].type = INPUT_MOUSE;
  in[2].mi.dx = ax;
  in[2].mi.dy = ay;
  in[2].mi.dwFlags = MOUSEEVENTF_ABSOLUTE | up;
  UINT sent = SendInput(3, in, sizeof(INPUT));
  Log(L"agent", L"inject: click btn=%d (%.3f,%.3f) sent=%u", button, nx, ny,
      sent);
  SetThreadDesktop(hPrev);
  CloseDesktop(hDesk);
}

// Arrow keys, Home/End, Insert/Delete, etc. are "extended" keys. Injected
// without KEYEVENTF_EXTENDEDKEY they collapse to their numpad location — e.g.
// VK_LEFT becomes numpad-4, which does NOT move UAC focus. That silently broke
// Approve's Left->Yes step, so Approve only worked when Yes was already the
// default. Mirror the runner injector (input_injector.cpp): set scan + ext.
static bool IsExtendedVk(WORD vk) {
  switch (vk) {
    case VK_RIGHT: case VK_LEFT: case VK_UP: case VK_DOWN:
    case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT:
    case VK_INSERT: case VK_DELETE:
    case VK_RCONTROL: case VK_RMENU:
    case VK_LWIN: case VK_RWIN:
      return true;
    default:
      return false;
  }
}

static void InjectKeyOnSecureDesktop(WORD vk) {
  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) return;
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (!SetThreadDesktop(hDesk)) {
    CloseDesktop(hDesk);
    return;
  }
  WORD scan = (WORD)MapVirtualKey(vk, MAPVK_VK_TO_VSC);
  DWORD ext = IsExtendedVk(vk) ? KEYEVENTF_EXTENDEDKEY : 0;
  INPUT in[2] = {0};
  in[0].type = INPUT_KEYBOARD;
  in[0].ki.wVk = vk;
  in[0].ki.wScan = scan;
  in[0].ki.dwFlags = ext;
  in[1].type = INPUT_KEYBOARD;
  in[1].ki.wVk = vk;
  in[1].ki.wScan = scan;
  in[1].ki.dwFlags = ext | KEYEVENTF_KEYUP;
  UINT sent = SendInput(2, in, sizeof(INPUT));
  Log(L"agent", L"inject: key vk=0x%02X ext=%lu sent=%u", vk, ext, sent);
  SetThreadDesktop(hPrev);
  CloseDesktop(hDesk);
}

static std::wstring WidenUtf8(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), &w[0], n);
  return w;
}

// Type a unicode string into whatever field is focused on the current (secure)
// input desktop — used to transmit credentials to a UAC / login prompt. Each
// char goes in via KEYEVENTF_UNICODE (no VK mapping, so any character/layout
// works), then optional Tab / Enter as real key events to move fields / submit.
static void InjectTextOnSecureDesktop(const std::wstring& text, bool tab,
                                      bool enter) {
  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) return;
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (!SetThreadDesktop(hDesk)) {
    CloseDesktop(hDesk);
    return;
  }
  for (wchar_t ch : text) {
    INPUT in[2] = {0};
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wScan = ch;
    in[0].ki.dwFlags = KEYEVENTF_UNICODE;
    in[1].type = INPUT_KEYBOARD;
    in[1].ki.wScan = ch;
    in[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
  }
  auto vkTap = [](WORD vk) {
    WORD scan = (WORD)MapVirtualKey(vk, MAPVK_VK_TO_VSC);
    INPUT in[2] = {0};
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = vk;
    in[0].ki.wScan = scan;
    in[1].type = INPUT_KEYBOARD;
    in[1].ki.wVk = vk;
    in[1].ki.wScan = scan;
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
  };
  if (tab) vkTap(VK_TAB);
  if (enter) vkTap(VK_RETURN);
  Log(L"agent", L"inject: text len=%d tab=%d enter=%d", (int)text.size(),
      tab ? 1 : 0, enter ? 1 : 0);
  SetThreadDesktop(hPrev);
  CloseDesktop(hDesk);
}

// USB HID usage -> Win32 VK. Mirrors input_injector.cpp's HidToVk so forwarded
// keyboard input maps identically whether it goes through the app or the agent.
static WORD HidToVk(int usage) {
  if (usage >= 0x04 && usage <= 0x1D) return (WORD)('A' + (usage - 0x04));
  if (usage >= 0x1E && usage <= 0x26) return (WORD)('1' + (usage - 0x1E));
  if (usage == 0x27) return (WORD)'0';
  if (usage >= 0x3A && usage <= 0x45) return (WORD)(VK_F1 + (usage - 0x3A));
  switch (usage) {
    case 0x28: return VK_RETURN;
    case 0x29: return VK_ESCAPE;
    case 0x2A: return VK_BACK;
    case 0x2B: return VK_TAB;
    case 0x2C: return VK_SPACE;
    case 0x2D: return VK_OEM_MINUS;
    case 0x2E: return VK_OEM_PLUS;
    case 0x2F: return VK_OEM_4;
    case 0x30: return VK_OEM_6;
    case 0x31: return VK_OEM_5;
    case 0x33: return VK_OEM_1;
    case 0x34: return VK_OEM_7;
    case 0x35: return VK_OEM_3;
    case 0x36: return VK_OEM_COMMA;
    case 0x37: return VK_OEM_PERIOD;
    case 0x38: return VK_OEM_2;
    case 0x39: return VK_CAPITAL;
    case 0x49: return VK_INSERT;
    case 0x4A: return VK_HOME;
    case 0x4B: return VK_PRIOR;
    case 0x4C: return VK_DELETE;
    case 0x4D: return VK_END;
    case 0x4E: return VK_NEXT;
    case 0x4F: return VK_RIGHT;
    case 0x50: return VK_LEFT;
    case 0x51: return VK_DOWN;
    case 0x52: return VK_UP;
    case 0xE0: return VK_LCONTROL;
    case 0xE1: return VK_LSHIFT;
    case 0xE2: return VK_LMENU;
    case 0xE3: return VK_LWIN;
    case 0xE4: return VK_RCONTROL;
    case 0xE5: return VK_RSHIFT;
    case 0xE6: return VK_RMENU;
    case 0xE7: return VK_RWIN;
    default: return 0;
  }
}

// Last forwarded pointer position (normalized) and which mouse buttons are held
// via the forwarded path. Only ever touched on the single PipeServer reader
// thread, so no locking is needed — same rule as the runner's gLastNx/gLastNy.
// The held-buttons mask lets us auto-release on client disconnect so a drag
// interrupted by a dropped connection never leaves the host cursor stuck down.
static float g_fwdNx = 0.0f;
static float g_fwdNy = 0.0f;
static int g_fwdHeld = 0;  // bit0=left, bit1=right, bit2=middle

// Inject one ordinary input event (forwarded from the app when the foreground
// window is elevated) onto the current input desktop. Runs as SYSTEM, so it
// reaches High-integrity windows the app's own injector can't. Mirrors the
// runner injector (input_injector.cpp) so behavior is identical.
static void InjectForwardedInput(const std::vector<BYTE>& m) {
  if (m.size() < 2) return;
  BYTE sub = m[1];
  const BYTE* p = m.data() + 2;
  size_t n = m.size() - 2;

  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) return;
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (!SetThreadDesktop(hDesk)) {
    CloseDesktop(hDesk);
    return;
  }

  if (sub == 'm' && n >= 8) {
    float nx, ny;
    memcpy(&nx, p, 4);
    memcpy(&ny, p + 4, 4);
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dx = (LONG)(nx * 65535.0f);
    in.mi.dy = (LONG)(ny * 65535.0f);
    // ABSOLUTE over the primary monitor (no VIRTUALDESK) to match the app's own
    // injector exactly, so the cursor lands identically when routing switches.
    in.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
    SendInput(1, &in, sizeof(INPUT));
    g_fwdNx = nx;
    g_fwdNy = ny;
  } else if (sub == 'b' && n >= 11) {
    BYTE btn = p[0], down = p[1], hasPos = p[2];
    float nx, ny;
    memcpy(&nx, p + 3, 4);
    memcpy(&ny, p + 7, 4);
    if (!hasPos) {
      nx = g_fwdNx;
      ny = g_fwdNy;
    }
    DWORD f;
    int bit;
    if (btn == 1) {
      f = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
      bit = 2;
    } else if (btn == 2) {
      f = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
      bit = 4;
    } else {
      f = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
      bit = 1;
    }
    if (down) g_fwdHeld |= bit; else g_fwdHeld &= ~bit;
    INPUT in = {0};
    in.type = INPUT_MOUSE;
    in.mi.dx = (LONG)(nx * 65535.0f);
    in.mi.dy = (LONG)(ny * 65535.0f);
    in.mi.dwFlags = MOUSEEVENTF_MOVE | f | MOUSEEVENTF_ABSOLUTE;
    UINT sent = SendInput(1, &in, sizeof(INPUT));
    Log(L"agent", L"inject-fwd: btn=%d %ls (%.3f,%.3f) sent=%u", btn,
        down ? L"down" : L"up", nx, ny, sent);
    g_fwdNx = nx;
    g_fwdNy = ny;
  } else if (sub == 'w' && n >= 8) {
    float dx, dy;
    memcpy(&dx, p, 4);
    memcpy(&dy, p + 4, 4);
    if (dy != 0.0f) {
      INPUT in = {0};
      in.type = INPUT_MOUSE;
      in.mi.mouseData = (DWORD)(int)(-dy);
      in.mi.dwFlags = MOUSEEVENTF_WHEEL;
      SendInput(1, &in, sizeof(INPUT));
    }
    if (dx != 0.0f) {
      INPUT in = {0};
      in.type = INPUT_MOUSE;
      in.mi.mouseData = (DWORD)(int)(dx);
      in.mi.dwFlags = MOUSEEVENTF_HWHEEL;
      SendInput(1, &in, sizeof(INPUT));
    }
  } else if (sub == 'k' && n >= 3) {
    WORD usage;
    memcpy(&usage, p, 2);
    BYTE down = p[2];
    WORD vk = HidToVk(usage);
    if (vk) {
      INPUT in = {0};
      in.type = INPUT_KEYBOARD;
      in.ki.wVk = vk;
      in.ki.wScan = (WORD)MapVirtualKey(vk, MAPVK_VK_TO_VSC);
      in.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
      if (IsExtendedVk(vk)) in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
      UINT sent = SendInput(1, &in, sizeof(INPUT));
      Log(L"agent", L"inject-fwd: key vk=0x%02X %ls sent=%u", vk,
          down ? L"down" : L"up", sent);
    }
  }

  SetThreadDesktop(hPrev);
  CloseDesktop(hDesk);
}

// Release any mouse button still held via the forwarded path — called when the
// app disconnects, so a drag cut off by a dropped connection never leaves the
// host's button stuck down (which would freeze its cursor).
static void ReleaseForwardedButtons() {
  if (!g_fwdHeld) return;
  HDESK hDesk = OpenInputDesktop(0, FALSE, GENERIC_ALL);
  if (!hDesk) { g_fwdHeld = 0; return; }
  HDESK hPrev = GetThreadDesktop(GetCurrentThreadId());
  if (SetThreadDesktop(hDesk)) {
    const int bits[3] = {1, 2, 4};
    const DWORD ups[3] = {MOUSEEVENTF_LEFTUP, MOUSEEVENTF_RIGHTUP,
                          MOUSEEVENTF_MIDDLEUP};
    for (int i = 0; i < 3; i++) {
      if (g_fwdHeld & bits[i]) {
        INPUT in = {0};
        in.type = INPUT_MOUSE;
        in.mi.dx = (LONG)(g_fwdNx * 65535.0f);
        in.mi.dy = (LONG)(g_fwdNy * 65535.0f);
        in.mi.dwFlags = ups[i] | MOUSEEVENTF_ABSOLUTE;
        SendInput(1, &in, sizeof(INPUT));
      }
    }
    SetThreadDesktop(hPrev);
  }
  CloseDesktop(hDesk);
  Log(L"agent", L"inject: released held buttons on disconnect (mask=%d)",
      g_fwdHeld);
  g_fwdHeld = 0;
}

static bool RecvAll(SOCKET s, void* buf, int n) {
  char* p = (char*)buf;
  int off = 0;
  while (off < n) {
    int r = recv(s, p + off, n - off, 0);
    if (r <= 0) return false;
    off += r;
  }
  return true;
}

static bool SendAll(SOCKET s, const void* buf, int n) {
  const char* p = (const char*)buf;
  int off = 0;
  while (off < n) {
    int r = send(s, p + off, n - off, 0);
    if (r == SOCKET_ERROR) return false;
    off += r;
  }
  return true;
}

// Send a framed message to the connected app. A separate-thread recv is NOT
// serialized against this send (TCP is full-duplex), so streaming never stalls.
static void PipeSend(BYTE type, const BYTE* payload, DWORD plen) {
  EnterCriticalSection(&g_clientLock);
  if (g_client != INVALID_SOCKET) {
    DWORD len = 1 + plen;
    std::vector<BYTE> buf(4 + len);
    memcpy(buf.data(), &len, 4);
    buf[4] = type;
    if (plen) memcpy(buf.data() + 5, payload, plen);
    if (!SendAll(g_client, buf.data(), (int)buf.size())) {
      Log(L"agent", L"tcp: send failed; dropping client");
      shutdown(g_client, SD_BOTH);  // unblock the reader; it closesocket()s
      g_client = INVALID_SOCKET;
    }
  }
  LeaveCriticalSection(&g_clientLock);
}

static bool ClientConnected() {
  EnterCriticalSection(&g_clientLock);
  bool c = (g_client != INVALID_SOCKET);
  LeaveCriticalSection(&g_clientLock);
  return c;
}

// Reply to a getcreds ('M') request with the machine-wide id + password as
// 'm' + "id\npassword" (UTF-8). Password may be empty (none set yet).
static void SendMachineCreds() {
  std::string id, pw;
  LoadMachineCreds(id, pw);
  if (id.empty()) id = EnsureMachineId();
  std::string out = id + "\n" + pw;
  PipeSend('m', (const BYTE*)out.data(), (DWORD)out.size());
}

// Generate a real Ctrl+Alt+Del (Secure Attention Sequence). Only a SYSTEM
// service can do this; a normal app's synthetic Ctrl+Alt+Del is ignored by
// Windows. First enable the "services may generate SAS" policy (we run as
// SYSTEM so we can write it), then call SendSAS from sas.dll.
static void TriggerSAS() {
  HKEY k;
  if (RegCreateKeyExW(
          HKEY_LOCAL_MACHINE,
          L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", 0,
          nullptr, 0, KEY_SET_VALUE, nullptr, &k, nullptr) == ERROR_SUCCESS) {
    DWORD v = 1;  // 1 = services, 2 = ease-of-access apps, 3 = both
    RegSetValueExW(k, L"SoftwareSASGeneration", 0, REG_DWORD, (const BYTE*)&v,
                   sizeof(v));
    RegCloseKey(k);
  }
  typedef void(WINAPI * SendSAS_t)(BOOL);
  HMODULE h = LoadLibraryW(L"sas.dll");
  if (h) {
    SendSAS_t fn = (SendSAS_t)GetProcAddress(h, "SendSAS");
    if (fn) {
      fn(FALSE);  // FALSE = called from a service (SYSTEM, session 0)
      Log(L"agent", L"SAS (Ctrl+Alt+Del) triggered");
    } else {
      Log(L"agent", L"SendSAS not found in sas.dll");
    }
  } else {
    Log(L"agent", L"sas.dll not available");
  }
}

// A viewer command (click/key) -> inject onto the secure desktop.
static void HandleClientMessage(const std::vector<BYTE>& m) {
  if (m.empty()) return;
  if (m[0] == 'C' && m.size() >= 10) {
    BYTE btn = m[1];
    float x, y;
    memcpy(&x, &m[2], 4);
    memcpy(&y, &m[6], 4);
    InjectClickOnSecureDesktop(btn, x, y);
  } else if (m[0] == 'K' && m.size() >= 3) {
    WORD vk;
    memcpy(&vk, &m[1], 2);
    InjectKeyOnSecureDesktop(vk);
  } else if (m[0] == 'I' && m.size() >= 2) {
    InjectForwardedInput(m);
  } else if (m[0] == 'T' && m.size() >= 2) {
    // Transmit credentials: type a unicode string into the focused field.
    // Payload: [u8 flags][utf8 text]; flags bit0 = Enter after, bit1 = Tab.
    BYTE flags = m[1];
    std::string s(m.begin() + 2, m.end());
    InjectTextOnSecureDesktop(WidenUtf8(s), (flags & 0x02) != 0,
                              (flags & 0x01) != 0);
  } else if (m[0] == 'S') {
    // Ctrl+Alt+Del (Secure Attention Sequence).
    TriggerSAS();
  } else if (m[0] == 'M') {
    // getcreds: host asks for the machine-wide id + password.
    SendMachineCreds();
  } else if (m[0] == 'N') {
    // setcreds: host sets the machine-wide password (payload = UTF-8 password).
    // The id is never overwritten — it stays stable for the machine's lifetime.
    std::string id, oldpw;
    LoadMachineCreds(id, oldpw);
    if (id.empty()) id = EnsureMachineId();
    std::string newpw((const char*)m.data() + 1, m.size() - 1);
    SaveMachineCreds(id, newpw);
    Log(L"agent", L"machine password updated (%d chars)", (int)newpw.size());
    SendMachineCreds();  // echo back so every connected host converges
  }
}

// TCP server on 127.0.0.1: one client at a time. This thread is the reader
// (recv loop for viewer commands); frames are pushed from the agent loop via
// PipeSend (send), concurrently — TCP is full-duplex so neither blocks.
static DWORD WINAPI PipeServerThread(LPVOID) {
  SOCKET srv = socket(AF_INET, SOCK_STREAM, 0);
  if (srv == INVALID_SOCKET) {
    Log(L"agent", L"tcp: socket failed %d", WSAGetLastError());
    return 0;
  }
  int yes = 1;
  setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (char*)&yes, sizeof(yes));
  sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(kPort);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  if (bind(srv, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
    Log(L"agent", L"tcp: bind 127.0.0.1:%d failed %d", kPort, WSAGetLastError());
    closesocket(srv);
    return 0;
  }
  listen(srv, 1);
  Log(L"agent", L"tcp: listening on 127.0.0.1:%d", kPort);
  for (;;) {
    SOCKET c = accept(srv, nullptr, nullptr);
    if (c == INVALID_SOCKET) {
      Sleep(500);
      continue;
    }
    DWORD tmo = 5000;
    setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, (char*)&tmo, sizeof(tmo));
    EnterCriticalSection(&g_clientLock);
    g_client = c;
    LeaveCriticalSection(&g_clientLock);
    Log(L"agent", L"tcp: client connected");
    for (;;) {
      DWORD len = 0;
      if (!RecvAll(c, &len, 4) || len == 0 || len > (1 << 20)) break;
      std::vector<BYTE> msg(len);
      if (!RecvAll(c, msg.data(), (int)len)) break;
      HandleClientMessage(msg);
    }
    EnterCriticalSection(&g_clientLock);
    if (g_client == c) g_client = INVALID_SOCKET;
    LeaveCriticalSection(&g_clientLock);
    closesocket(c);
    ReleaseForwardedButtons();  // never leave a drag stuck after a disconnect
    Log(L"agent", L"tcp: client disconnected");
  }
}

// --------------------------------------------------------------------------
// Agent main loop: detect the secure desktop; while it is up, stream PNG frames
// to a connected app and let it inject the viewer's Yes/No. With no app
// connected it just logs + keeps a debug BMP (NO auto-decline anymore).
// --------------------------------------------------------------------------
// Make the agent per-monitor DPI aware so GetSystemMetrics / GDI report physical
// pixels — otherwise captures on a scaled high-DPI display are wrong (see the
// DESKTOPHORZRES note in CaptureSecureDesktopToPng). Loaded dynamically so it
// still links/runs on older Windows, falling back to the legacy call.
static void MakeDpiAware() {
  HMODULE u = GetModuleHandleW(L"user32.dll");
  if (u) {
    typedef BOOL(WINAPI * SetCtxFn)(HANDLE);
    auto fn = (SetCtxFn)GetProcAddress(u, "SetProcessDpiAwarenessContext");
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 == (HANDLE)-4
    if (fn && fn((HANDLE)-4)) return;
  }
  SetProcessDPIAware();  // Vista+ fallback (system-DPI aware)
}

// Classify the current secure (Winlogon) desktop so the viewer can label it and
// pick the right UI: 0 = UAC prompt (user logged in, not locked), 1 = login
// screen (no user logged in), 2 = locked session. Best-effort — defaults to UAC.
static int DetectSecureKind() {
  DWORD sid = GetTargetSessionId();
  if (sid == 0xFFFFFFFF) return 1;  // no active user session -> login screen

  // Empty username => nobody is logged into the active session => login screen.
  LPWSTR user = nullptr;
  DWORD ulen = 0;
  bool hasUser = false;
  if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, sid, WTSUserName,
                                  &user, &ulen)) {
    hasUser = (user && user[0] != L'\0');
    WTSFreeMemory(user);
  }
  if (!hasUser) return 1;

  // Logged in + on the secure desktop: locked session vs a UAC prompt.
  int kind = 0;  // default: UAC
  LPWSTR info = nullptr;
  DWORD ilen = 0;
  if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, sid,
                                  WTSSessionInfoEx, &info, &ilen) &&
      info && ilen >= sizeof(WTSINFOEXW)) {
    WTSINFOEXW* ex = (WTSINFOEXW*)info;
    if (ex->Level == 1 &&
        ex->Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK) {
      kind = 2;  // locked
    }
  }
  if (info) WTSFreeMemory(info);
  return kind;
}

static int RunAgent() {
  MakeDpiAware();
  EnsureMachineId();  // machine-wide id exists before any host asks for it
  InitializeCriticalSection(&g_clientLock);
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  ULONG_PTR gdipToken = 0;
  Gdiplus::GdiplusStartupInput gdipInput;
  Gdiplus::GdiplusStartup(&gdipToken, &gdipInput, nullptr);
  CreateThread(nullptr, 0, PipeServerThread, nullptr, 0, nullptr);
  Log(L"agent", L"agent started (capture + TCP streaming on 127.0.0.1:47921)");

  std::wstring last;
  bool wasSecure = false;
  int lastSecureKind = -1;
  int frameTick = 0;
  for (;;) {
    std::wstring name = L"(unknown)";
    HDESK d = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (d) {
      wchar_t buf[256] = {0};
      DWORD needed = 0;
      if (GetUserObjectInformationW(d, UOI_NAME, buf, sizeof(buf), &needed))
        name = buf;
      CloseDesktop(d);
    }
    bool secure = (_wcsicmp(name.c_str(), L"Winlogon") == 0);

    if (name != last) {
      Log(L"agent", L"input desktop -> %ls%ls", name.c_str(),
          secure ? L"   <<< SECURE DESKTOP / UAC PROMPT ACTIVE" : L"");
      last = name;
    }

    if (secure) {
      int kind = DetectSecureKind();
      // Send 'A' (with dims + kind) on entering the secure desktop OR when the
      // kind changes (e.g. login screen -> UAC after sign-in), then stream
      // frames every tick so the sign-in / lock screen is interactive, not just
      // a slow snapshot.
      bool announce = (!wasSecure || kind != lastSecureKind);
      if (announce) {
        if (!wasSecure) Sleep(500);  // let the screen finish drawing
        std::vector<BYTE> png;
        int w = 0, h = 0;
        if (CaptureSecureDesktopToPng(png, w, h)) {
          int32_t dims[3] = {w, h, kind};
          DWORD ts = GetTickCount();
          PipeSend('A', (BYTE*)dims, sizeof(dims));
          PipeSend('F', png.data(), (DWORD)png.size());
          Log(L"agent",
              L"pipe: sent active+frame (%dx%d kind=%d, %u bytes) send=%lums%ls",
              w, h, kind, (unsigned)png.size(), GetTickCount() - ts,
              ClientConnected() ? L"" : L"  (no client)");
        }
        lastSecureKind = kind;
        frameTick = 0;
      } else if (ClientConnected()) {
        std::vector<BYTE> png;
        int w = 0, h = 0;
        if (CaptureSecureDesktopToPng(png, w, h))
          PipeSend('F', png.data(), (DWORD)png.size());
      }
      wasSecure = true;
    } else {
      if (wasSecure) {
        PipeSend('G', nullptr, 0);
        Log(L"agent", L"pipe: sent secure-desktop gone");
      }
      wasSecure = false;
      lastSecureKind = -1;
    }
    Sleep(400);
  }
}

int wmain(int argc, wchar_t** argv) {
  if (argc >= 2) {
    if (_wcsicmp(argv[1], L"install") == 0) return InstallService();
    if (_wcsicmp(argv[1], L"uninstall") == 0) return UninstallService();
    if (_wcsicmp(argv[1], L"agent") == 0) return RunAgent();
  }
  // No recognised argument: assume the SCM is starting us as a service.
  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<LPWSTR>(kServiceName), ServiceMain}, {nullptr, nullptr}};
  if (!StartServiceCtrlDispatcherW(table)) {
    wprintf(L"Neev Remote Helper (UAC support)\n"
            L"Usage: neev_helper.exe [install|uninstall|agent]\n");
    return 1;
  }
  return 0;
}
