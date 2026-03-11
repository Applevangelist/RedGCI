/*

- GCI POC — UDP Server
- 
- Kompilieren (Windows/MinGW):
- cmake -B build -G “MinGW Makefiles” -DCMAKE_BUILD_TYPE=Release
- cmake –build build
- 
- Kompilieren (Linux, für Tests):
- cmake -B build -DCMAKE_BUILD_TYPE=Release
- cmake –build build
- 
- Testen ohne DCS:
- echo “PING” | nc -u -q1 127.0.0.1 9088
- echo “INTERCEPT|0|0|5000|250|30000|30000|5500|220|0|-220|0” | nc -u -q1 127.0.0.1 9088
  */

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, “ws2_32.lib”)
typedef int socklen_t;
#else
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#define closesocket close
#define SOCKET int
#define INVALID_SOCKET (-1)
#define SOCKET_ERROR   (-1)
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include “message_handler.h”

#define GCI_PORT   9088
#define BUFSIZE    4096

static void platform_init(void) {
#ifdef _WIN32
WSADATA wsa;
if (WSAStartup(MAKEWORD(2,2), &wsa) != 0) {
fprintf(stderr, “[GCI] WSAStartup failed\n”);
exit(1);
}
#endif
srand((unsigned)time(NULL));
}

static void platform_cleanup(void) {
#ifdef _WIN32
WSACleanup();
#endif
}

int main(void) {
platform_init();

```
SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
if (sock == INVALID_SOCKET) {
    fprintf(stderr, "[GCI] socket() failed\n");
    return 1;
}

struct sockaddr_in addr;
memset(&addr, 0, sizeof(addr));
addr.sin_family = AF_INET;
addr.sin_port   = htons(GCI_PORT);
/* inet_pton: modernes API, kein Deprecation-Warning auf MSVC */
if (inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) != 1) {
    fprintf(stderr, "[GCI] inet_pton() failed\n");
    closesocket(sock);
    return 1;
}

if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
    fprintf(stderr, "[GCI] bind() failed — port %d in use?\n", GCI_PORT);
    closesocket(sock);
    return 1;
}

printf("╔══════════════════════════════════════╗\n");
printf("║  GCI POC Server  —  UDP :%d         ║\n", GCI_PORT);
printf("║  Warschauer Pakt  /  MiG-29A  1985   ║\n");
printf("╚══════════════════════════════════════╝\n");
printf("[GCI] Ready. Waiting for DCS Export.lua...\n\n");

char buf[BUFSIZE];
char resp[BUFSIZE];
struct sockaddr_in client;
socklen_t client_len = sizeof(client);
int msg_count = 0;

while (1) {
    memset(buf, 0, sizeof(buf));
    memset(resp, 0, sizeof(resp));

    int n = recvfrom(sock, buf, BUFSIZE-1, 0,
                     (struct sockaddr*)&client, &client_len);
    if (n <= 0) continue;
    buf[n] = '\0';

    msg_count++;

    // Verarbeiten
    gci_process_message(buf, resp, sizeof(resp));

    // Log (kompakt)
    if (strncmp(resp, "SILENCE", 7) != 0 &&
        strncmp(resp, "PONG", 4)    != 0 &&
        strncmp(resp, "OK:", 3)     != 0) {
        printf("[%05d] IN:  %.60s\n", msg_count, buf);
        // Nur russischen Text im Terminal
        char *ru = strstr(resp, "RU:");
        if (ru) {
            char *end = strstr(ru, "|EN:");
            if (end) *end = '\0';
            printf("[%05d] GCI: %s\n\n", msg_count, ru + 3);
        } else {
            printf("[%05d] OUT: %.80s\n\n", msg_count, resp);
        }
    }

    sendto(sock, resp, (int)strlen(resp), 0,
           (struct sockaddr*)&client, client_len);
}

closesocket(sock);
platform_cleanup();
return 0;
```

}
