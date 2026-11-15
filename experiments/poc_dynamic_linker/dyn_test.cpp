// dyn_test.cpp — C++ executable testing multi-library dynamic resolution via $ORIGIN
// Exercising sibling shared library resolution and NDK libc++_shared.so STL usage.

#include <iostream>
#include <string>
#include <unistd.h>

extern "C" int get_tanmatsu_token(void);

int main() {
    int token = get_tanmatsu_token();
    std::string msg = "DYN_SUCCESS: Sibling shared library linked! Token=" + std::to_string(token);
    std::cout << msg << std::endl;
    return 0;
}
