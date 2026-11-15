// dep.c — Sibling shared library for Experiment 0.5 (Milestone 1.5)
// Exports a simple C function with default visibility.

__attribute__((visibility("default"))) int get_tanmatsu_token(void) {
    return 4242;
}
