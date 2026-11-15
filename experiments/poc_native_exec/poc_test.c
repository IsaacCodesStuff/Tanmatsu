#include <stdio.h>
#include <unistd.h>

int main(void) {
    printf("POC_SUCCESS: Native ARM64 PIE executed via ProcessBuilder PID=%d\n", getpid());
    return 0;
}
