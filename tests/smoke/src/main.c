#include <stdio.h>
#include <string.h>

#if defined(__ANDROID__) || defined(__MUSL__) || defined(__EMSCRIPTEN__)
#include <sys/socket.h>
#endif

int main(void) {
    const char* msg = "cross-smoke";
#if defined(__ANDROID__) || defined(__MUSL__) || defined(__EMSCRIPTEN__)
    struct sockaddr_storage ss = {0};
    if (sizeof(ss) == 0) return 2;
#endif
    if (strlen(msg) == 0) return 1;
    puts(msg);
    return 0;
}
