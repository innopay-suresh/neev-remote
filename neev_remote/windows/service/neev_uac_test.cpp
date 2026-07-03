// neev_uac_test.cpp — dev test client for the Phase 3b UAC IPC (localhost TCP).
//
// Stands in for the Flutter app: connects to 127.0.0.1:47921, prints the
// streamed UAC state, saves each frame to C:\ProgramData\NeevRemote\uac_frame.png,
// and lets you inject the viewer's choice back into the secure desktop.
//
// Build:  x86_64-w64-mingw32-g++ -O2 -std=c++17 neev_uac_test.cpp \
//             -o neev_uac_test.exe -lws2_32 -static
// Run (normal cmd, no admin):  neev_uac_test.exe [approve|decline]
//   commands:  yes = approve   no/esc = decline   c X Y = click   q = quit

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

static SOCKET g_sock = INVALID_SOCKET;
static const char* kFramePath = "C:\\ProgramData\\NeevRemote\\uac_frame.png";
static int g_auto = 0;        // 0=interactive, 1=auto-approve, 2=auto-decline
static bool g_acted = false;  // one action per UAC session

static bool ReadAll(void* buf, int n) {
  char* p = (char*)buf;
  int off = 0;
  while (off < n) {
    int r = recv(g_sock, p + off, n - off, 0);
    if (r <= 0) return false;
    off += r;
  }
  return true;
}

static void WriteMsg(BYTE type, const BYTE* payload, DWORD plen) {
  DWORD len = 1 + plen;
  std::vector<BYTE> buf(4 + len);
  memcpy(buf.data(), &len, 4);
  buf[4] = type;
  if (plen) memcpy(buf.data() + 5, payload, plen);
  send(g_sock, (const char*)buf.data(), (int)buf.size(), 0);
}

static DWORD WINAPI Reader(LPVOID) {
  for (;;) {
    DWORD len = 0;
    if (!ReadAll(&len, 4) || len == 0 || len > (1u << 20)) break;
    std::vector<BYTE> m(len);
    if (!ReadAll(m.data(), len)) break;
    char t = (char)m[0];
    if (t == 'A' && len >= 9) {
      int32_t w, h;
      memcpy(&w, &m[1], 4);
      memcpy(&h, &m[5], 4);
      printf("\n[UAC ACTIVE]  %dx%d\n> ", w, h);
      // Auto-respond (simulates the remote viewer): the local terminal is
      // unreachable while the secure desktop covers the screen.
      if (g_auto && !g_acted) {
        g_acted = true;
        Sleep(1200);  // let the dialog settle
        if (g_auto == 1) {
          WORD l = VK_LEFT;
          WriteMsg('K', (BYTE*)&l, 2);  // No -> Yes
          Sleep(150);
          WORD r = VK_RETURN;
          WriteMsg('K', (BYTE*)&r, 2);  // approve
          printf("\n[AUTO-APPROVE sent]\n> ");
        } else {
          WORD e = VK_ESCAPE;
          WriteMsg('K', (BYTE*)&e, 2);
          printf("\n[AUTO-DECLINE sent]\n> ");
        }
      }
    } else if (t == 'F') {
      FILE* f = fopen(kFramePath, "wb");
      if (f) {
        fwrite(&m[1], 1, len - 1, f);
        fclose(f);
      }
      printf("\n[FRAME] %u bytes -> %s\n> ", (unsigned)(len - 1), kFramePath);
    } else if (t == 'G') {
      g_acted = false;  // re-arm for the next UAC
      printf("\n[UAC GONE]\n> ");
    }
    fflush(stdout);
  }
  printf("\n[pipe closed]\n");
  return 0;
}

int main(int argc, char** argv) {
  if (argc >= 2 && strcmp(argv[1], "approve") == 0) g_auto = 1;
  if (argc >= 2 && strcmp(argv[1], "decline") == 0) g_auto = 2;
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  g_sock = socket(AF_INET, SOCK_STREAM, 0);
  sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(47921);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  if (g_sock == INVALID_SOCKET ||
      connect(g_sock, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
    printf("connect failed: %d (is the NeevRemoteHelper service running?)\n",
           WSAGetLastError());
    return 1;
  }
  printf("connected to 127.0.0.1:47921.%s\n",
         g_auto == 1 ? "  [AUTO-APPROVE mode]"
                     : (g_auto == 2 ? "  [AUTO-DECLINE mode]" : ""));
  printf("commands:  yes=approve   no=decline   c X Y=click   q=quit\n> ");
  fflush(stdout);
  CreateThread(nullptr, 0, Reader, nullptr, 0, nullptr);

  char line[256];
  while (fgets(line, sizeof(line), stdin)) {
    if (line[0] == 'q') break;
    if (!strncmp(line, "yes", 3)) {
      WORD l = VK_LEFT;
      WriteMsg('K', (BYTE*)&l, 2);  // move No -> Yes
      Sleep(150);
      WORD r = VK_RETURN;
      WriteMsg('K', (BYTE*)&r, 2);  // activate
      printf("sent: approve (Left+Enter)\n> ");
    } else if (!strncmp(line, "no", 2) || !strncmp(line, "esc", 3)) {
      WORD e = VK_ESCAPE;
      WriteMsg('K', (BYTE*)&e, 2);
      printf("sent: decline (Esc)\n> ");
    } else if (line[0] == 'c') {
      float x = 0, y = 0;
      if (sscanf(line + 1, "%f %f", &x, &y) == 2) {
        BYTE p[9];
        p[0] = 0;  // left button
        memcpy(&p[1], &x, 4);
        memcpy(&p[5], &y, 4);
        WriteMsg('C', p, 9);
        printf("sent: click (%.3f, %.3f)\n> ", x, y);
      }
    }
    fflush(stdout);
  }
  closesocket(g_sock);
  return 0;
}
