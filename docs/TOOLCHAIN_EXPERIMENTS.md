# Toolchain Experiments & Manual Execution Guide

**Document Version:** 2.1 (Revised Technical Baseline)  
**Status:** Ready for Manual Developer Execution  
**Date:** November 2026  

---

## 1. Operating Instructions & Safety Policy

This document contains step-by-step instructions and shell scripts to cross-compile and validate the Android-native LLVM toolchain (`libtanmatsu_clang.so`, `libtanmatsu_lld.so`, `libtanmatsu_clangd.so`) for Tanmatsu.

> [!IMPORTANT]
> **TOKEN CONSERVATION POLICY:**
> Automated AI agents must **NEVER** execute the long-running compilation or linking commands in this document. Cross-compiling LLVM and LLD requires significant host resources. All commands below are prepared exclusively for **manual execution by the human developer** on their Linux workstation.

---

## 2. Prerequisites & Build Environment

### 2.1 Host System Requirements
- **Operating System:** Linux x86_64 (Ubuntu 22.04/24.04, Debian 12, Arch Linux, Fedora 39+).
- **CPU / RAM:** 8+ CPU cores recommended; minimum 16 GB RAM.
- **Free Disk Space:** Minimum 35 GB free disk space.

### 2.2 Host Build Dependencies vs Target Build Dependencies
- **Host Build Dependencies (Workstation):**
  - Host C/C++ compiler: Clang or GCC
  - Build system: CMake (3.20+), Ninja (1.10+)
  - Python 3.8+
  - Host development libraries: `libncurses5-dev`, `libxml2-dev`, `zlib1g-dev`, `libzstd-dev`
- **Target Build Dependencies (Android ARM64):**
  - Android NDK r27 (contains LLVM 18 prebuilts matching target baseline)
  - Target Bionic dynamic stubs and `libc++_shared.so` provided by NDK

```bash
# Install host tools on Ubuntu / Debian
sudo apt-get update && sudo apt-get install -y \
    build-essential cmake ninja-build python3 git \
    libncurses5-dev libxml2-dev zlib1g-dev libzstd-dev

# Install host tools on Arch Linux
sudo pacman -S --needed base-devel cmake ninja python git ncurses libxml2 zlib zstd
```

### 2.3 Android NDK Setup
Download and export Android NDK r27:

```bash
export ANDROID_NDK_ROOT="$HOME/Android/Sdk/ndk/27.0.12077973"
# Or standalone NDK:
# export ANDROID_NDK_ROOT="$HOME/android-ndk-r27"

# Verify NDK path and compiler version
if [ ! -d "$ANDROID_NDK_ROOT/build/cmake" ]; then
    echo "ERROR: ANDROID_NDK_ROOT not found at $ANDROID_NDK_ROOT"
    return 1
fi
$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/clang --version
```

---

## 3. Experiment 0: Minimal Native Execution Proof-of-Concept (PoC) — [PASSED]

**Status:** **COMPLETED / EMPIRICALLY VERIFIED**  
**Verified Test Environment:**
- **Device:** Samsung SM-A065F (Samsung Galaxy A06 4G)
- **Android Version:** Android 16 (API Level 36)
- **Target ABI:** `arm64-v8a`
- **Workstation Build Environment:** Arch Linux, Gradle 8.10.2, OpenJDK 17.0.20
- **Binary:** `libtanmatsu_test_exec.so` (4,600 bytes, ELF64, AArch64, DYN, PT_INTERP to `/system/bin/linker64`, entry point `0x16E8`)

**Observed Empirical Results:**
```text
File exists: true
File size: 4600 bytes
canRead: true, canExecute: true
Working directory: /data/user/0/org.tanmatsu.poc/cache (writable: true)

--- Spawning Process via ProcessBuilder ---

Process exited with code: 0 (took 115ms)

STDOUT:
POC_SUCCESS: Native ARM64 PIE executed via ProcessBuilder PID=17652

>>> RESULT: SUCCESS!
```
*SELinux Audit Check:* `adb logcat -d | grep -E 'avc:.*(org\.tanmatsu\.poc|libtanmatsu_test_exec)'` returned zero matching entries.

**Proven Capabilities:**
1. ARM64 PIE executables packaged as `.so` files in `jniLibs` are extracted to `nativeLibraryDir` via `useLegacyPackaging = true`.
2. Package manager grants executable permissions (`rwxr-xr-x`).
3. `ProcessBuilder` spawns the binary on Android 16 without `IOException` or `EACCES`.
4. Process completes with exit code 0 and stdout is captured cleanly.

**Crucial Boundaries (What Remains to be Verified):**
- Does *not* yet prove execution of multi-library dependencies (`libLLVM.so`, `libclang-cpp.so`, `libc++_shared.so`) via `$ORIGIN`.
- Does *not* prove Clang, LLD, or clangd execution.
- Does *not* prove on-device C compilation or execution of user binaries in writable storage.

---

## 3.5. Experiment 0.5: Multi-Library Dynamic Linking PoC (Next Immediate Experiment)

**Objective:** Before embarking on the multi-gigabyte, lengthy LLVM toolchain cross-compilation, empirically verify that a native executable in `nativeLibraryDir` can dynamically resolve and call functions in a **sibling custom shared library** (`libtanmatsu_dep.so`) and link against NDK **`libc++_shared.so`** using `DT_RUNPATH` with `$ORIGIN`, without requiring `LD_LIBRARY_PATH` or root privileges.

### Step 0.5.1: Prepare Test Source Code on Host
In `experiments/poc_dynamic_linker/`:

1. Create `dep.c` (shared library source):
```c
// dep.c
__attribute__((visibility("default"))) int get_tanmatsu_token(void) {
    return 4242;
}
```

2. Create `dyn_test.cpp` (C++ executable using sibling library and STL):
```cpp
// dyn_test.cpp
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
```

### Step 0.5.2: Compile Shared Library and Dynamic Executable

You can run the automated build helper:
```bash
cd experiments/poc_dynamic_linker
export ANDROID_NDK_ROOT=/path/to/android-ndk
./build_test.sh
```

Or execute the steps manually:
```bash
cd experiments/poc_dynamic_linker

NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_LIB="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
API=29

# 1. Copy NDK libc++_shared.so into working directory
cp -f "$NDK_LIB/libc++_shared.so" ./libc++_shared.so

# 2. Compile custom shared library libtanmatsu_dep.so
$NDK_BIN/aarch64-linux-android${API}-clang -shared -fPIC -O2 \
    -Wl,-soname,libtanmatsu_dep.so \
    dep.c -o libtanmatsu_dep.so

# 3. Compile C++ PIE executable linking against sibling libtanmatsu_dep.so and libc++_shared
$NDK_BIN/aarch64-linux-android${API}-clang++ -fPIE -pie -O2 \
    -stdlib=libc++ \
    -Wl,-rpath,'$ORIGIN' \
    -Wl,--enable-new-dtags \
    -L. \
    dyn_test.cpp \
    -Wl,--no-as-needed -ltanmatsu_dep -lc++_shared -Wl,--as-needed \
    -o libtanmatsu_dyn_test.so
```

### Step 0.5.3: Verify Dynamic Tags on Host (Gate 1)
```bash
READELF="$NDK_BIN/llvm-readelf"

# Inspect libtanmatsu_dyn_test.so headers and dynamic tags
$READELF -h -l -d libtanmatsu_dyn_test.so
```
**Verification Checklist:**
- Type is `DYN` with `PT_INTERP` segment requesting `/system/bin/linker64`
- `(FLAGS_1)` contains `PIE`
- `(NEEDED)` lists `libtanmatsu_dep.so`
- `(NEEDED)` lists `libc++_shared.so`
- `(NEEDED)` lists `libc.so`, `libm.so`, `libdl.so`
- `(RUNPATH)` contains `$ORIGIN` (single-quoted to prevent shell expansion)

And inspect `libtanmatsu_dep.so`:
```bash
$READELF -h -l -d -s libtanmatsu_dep.so
```
- Type is `DYN` with NO `INTERP` segment
- Symbol table exports `get_tanmatsu_token`

### Step 0.5.4: Package in PoC App and Verify on Device (Gates 2–5)
1. Copy all three `.so` files to `app/src/main/jniLibs/arm64-v8a/`:
   ```bash
   cp -vf libtanmatsu_dyn_test.so libtanmatsu_dep.so libc++_shared.so \
      ../poc_native_exec/app/src/main/jniLibs/arm64-v8a/
   ```
2. Build and install:
   ```bash
   cd ../poc_native_exec
   ./gradlew assembleDebug
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```
3. Run and verify logcat:
   ```bash
   adb shell am start -n org.tanmatsu.poc/.MainActivity
   adb logcat -s TanmatsuPoC -d
   ```
4. Audit SELinux AVC denials separately:
   ```bash
   adb logcat -d | grep -E 'avc:.*(org\.tanmatsu\.poc|libtanmatsu)'
   ```

**Expected Logcat Output:**
```text
TanmatsuPoC: === Tanmatsu Native Execution PoC ===
TanmatsuPoC: --- Auditing Native Artifacts in nativeLibraryDir ---
TanmatsuPoC: libtanmatsu_dyn_test.so : exists=true, size=...B, exec=true
TanmatsuPoC: libtanmatsu_dep.so      : exists=true, size=...B, exec=true
TanmatsuPoC: libc++_shared.so        : exists=true, size=...B, exec=true
TanmatsuPoC: Selected binary: libtanmatsu_dyn_test.so
TanmatsuPoC: --- Spawning Process via ProcessBuilder ---
TanmatsuPoC: LD_LIBRARY_PATH: [unset - testing DT_RUNPATH $ORIGIN]
TanmatsuPoC: Process exited with code: 0 (took ...ms)
TanmatsuPoC: STDOUT:
TanmatsuPoC: DYN_SUCCESS: Sibling shared library linked! Token=4242
TanmatsuPoC: >>> RESULT: SUCCESS! Sibling shared library and libc++_shared resolved via $ORIGIN without LD_LIBRARY_PATH.
TanmatsuPoC: Note: Dynamic linking success does not independently prove absence of SELinux denials. Perform Gate 5 logcat audit separately.
```

---

---

## 4. Experiment 1: Building Host TableGen Utilities

Cross-compiling LLVM requires host-native `llvm-tblgen` and `clang-tblgen` binaries built with the host workstation compiler.

### Stage 1 Execution Steps
```bash
mkdir -p $HOME/tanmatsu-build && cd $HOME/tanmatsu-build

# Clone LLVM Project (Release 18.1.8 branch)
git clone --depth 1 --branch llvmorg-18.1.8 https://github.com/llvm/llvm-project.git

mkdir -p build-host && cd build-host

# Configure minimal host tools with CMake
cmake -G Ninja ../llvm-project/llvm \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="AArch64"

# Build TableGen binaries
ninja llvm-tblgen clang-tblgen
```

### Expected Output
- `$HOME/tanmatsu-build/build-host/bin/llvm-tblgen`
- `$HOME/tanmatsu-build/build-host/bin/clang-tblgen`
- Verify host version:
  ```bash
  $HOME/tanmatsu-build/build-host/bin/llvm-tblgen --version
  ```

---

## 5. Experiment 2: Cross-Compiling LLVM for Android ARM64

### 5.1 LLVM CMake Configuration Definitions
- `LLVM_HOST_TRIPLE="aarch64-linux-android"`: The platform where Clang and clangd will run.
- `LLVM_TARGETS_TO_BUILD="AArch64"`: The CPU architectures Clang can generate code for.
- `LLVM_DEFAULT_TARGET_TRIPLE="aarch64-linux-android29"`: The default target for compiled programs.
- `LLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld"`: Tools included in the build.
- `CMAKE_INSTALL_PREFIX="$HOME/tanmatsu-build/install-android-arm64"`: Dedicated target install directory.

### 5.2 Compiler-RT Decision: Reusing NDK Prebuilts (Unverified Compatibility Hypothesis)
- **NDK Revision:** Android NDK r27 LTS (exact release: `27.0.12077973` / `clang-r522817d`, based on LLVM 18.0.1).
- **Prebuilt Archive Path:** `$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux/libclang_rt.builtins-aarch64-android.a`.
- **Compatibility Hypothesis:** Because NDK r27 is built from LLVM 18, its prebuilt compiler builtins archive is hypothesized to be ABI-compatible with the chosen LLVM 18.1.8 compiler driver.
- **Verification Gate:** This remains an **unverified hypothesis** until a compiled C test program exercising low-level arithmetic helpers (e.g. 128-bit integer operations or 64-bit division routines) successfully links against this archive and runs on physical hardware without unresolved symbol errors or ABI faults. We deliberately omit `LLVM_ENABLE_RUNTIMES="compiler-rt"` from the CMake command, avoiding a costly and redundant runtime build unless incompatibility is proven.

### Stage 2 Execution Steps
```bash
cd $HOME/tanmatsu-build
mkdir -p build-android-arm64 && cd build-android-arm64

INSTALL_DIR="$HOME/tanmatsu-build/install-android-arm64"

# Configure Android ARM64 target build
cmake -G Ninja ../llvm-project/llvm \
    -DCMAKE_BUILD_TYPE=MinSizeRel \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-26 \
    -DANDROID_STL=c++_shared \
    -DLLVM_HOST_TRIPLE="aarch64-linux-android" \
    -DLLVM_TARGETS_TO_BUILD="AArch64" \
    -DLLVM_DEFAULT_TARGET_TRIPLE="aarch64-linux-android29" \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra;lld" \
    -DLLVM_TABLEGEN="$HOME/tanmatsu-build/build-host/bin/llvm-tblgen" \
    -DCLANG_TABLEGEN="$HOME/tanmatsu-build/build-host/bin/clang-tblgen" \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DCLANG_LINK_CLANG_DYLIB=ON \
    -DLLVM_ENABLE_PIC=ON \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath,'\$ORIGIN'" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,'\$ORIGIN'" \
    -DCLANG_DEFAULT_LINKER=lld \
    -DCLANG_DEFAULT_CXX_STDLIB=libc++ \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_ENABLE_ARCMT=OFF

# Build and install to prefix
ninja install-clang install-clangd install-lld install-LLVM install-clang-cpp
```

### 5.3 Strip, Rename, and Package Binaries
```bash
STRIP_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
READELF_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

mkdir -p $HOME/tanmatsu-build/dist/arm64-v8a

# Copy and rename executables to avoid name collisions with standard libclang.so
cp "$INSTALL_DIR/bin/clang" $HOME/tanmatsu-build/dist/arm64-v8a/libtanmatsu_clang.so
cp "$INSTALL_DIR/bin/clangd" $HOME/tanmatsu-build/dist/arm64-v8a/libtanmatsu_clangd.so
cp "$INSTALL_DIR/bin/lld" $HOME/tanmatsu-build/dist/arm64-v8a/libtanmatsu_lld.so

# Copy core shared runtime libraries
cp "$INSTALL_DIR/lib/libLLVM.so"* $HOME/tanmatsu-build/dist/arm64-v8a/
cp "$INSTALL_DIR/lib/libclang-cpp.so"* $HOME/tanmatsu-build/dist/arm64-v8a/
cp "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
   $HOME/tanmatsu-build/dist/arm64-v8a/

# Strip unneeded symbols
$STRIP_BIN --strip-unneeded $HOME/tanmatsu-build/dist/arm64-v8a/*.so
```

### 5.4 ELF Dynamic Header Inspection
Run `readelf` on each binary to inspect dependencies and search paths:
```bash
$READELF_BIN -d $HOME/tanmatsu-build/dist/arm64-v8a/libtanmatsu_clang.so
```
**Acceptance Verification:**
- `(NEEDED)` must list `libclang-cpp.so`, `libLLVM.so`, `libc++_shared.so`, and Bionic libraries.
- `(RUNPATH)` or `(RPATH)` should include `$ORIGIN`.

---

## 6. Experiment 3: Assembling Complete Sysroot & Resource Directory

To guarantee full standard C header and symbol coverage, Tanmatsu uses the **complete, canonical NDK sysroot directly**, rather than fragile partial copies.

> [!IMPORTANT]
> **Compile-Time Stubs Notice:**
> The `.so` files in `sysroot/usr/lib/aarch64-linux-android/<API>/` (`libc.so`, `libm.so`, `libdl.so`) are **compile-time stubs only**. They contain symbol stubs and ELF version maps; they are **not** bundled into the APK or deployed to the device as runtime libraries. At runtime, the compiled program dynamically links against the device's system Bionic libraries located in `/system/lib64/`.

### Canonical Sysroot & Resource Setup Script
```bash
cd $HOME/tanmatsu-build
rm -rf sysroot_complete clang_res
mkdir -p clang_res/include clang_res/lib/linux

NDK_SYSROOT="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

# 1. Copy complete canonical NDK sysroot directly
cp -a "$NDK_SYSROOT" sysroot_complete

# 2. Copy Clang internal resource headers from the target install prefix
cp -r "$INSTALL_DIR/lib/clang/18/include/"* clang_res/include/

# 3. Copy prebuilt compiler-rt builtins library from NDK
NDK_CLANG_DIR="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18"
cp "$NDK_CLANG_DIR/lib/linux/libclang_rt.builtins-aarch64-android.a" clang_res/lib/linux/

# 4. Package sysroot and resource directory for testing
tar -czf sysroot_complete.tar.gz sysroot_complete/ clang_res/
```

---

## 7. Experiment 4: Manual Device-Side C17 Compiler Validation

### 7.1 Target Compatibility Rule
$$\text{User Target API Level} \le \text{Device Physical OS API Level}$$
- If testing on a device running **Android 10+ (API 29+)**, pass `--target=aarch64-linux-android29`.
- If testing on a device running **Android 9 (API 28)**, pass `--target=aarch64-linux-android28`.
- Note: This condition is **necessary, but not a guarantee of successful execution** (device-specific SELinux policies, 16 KB page size kernel enforcement, or missing hardware libraries can still cause execution to fail).

### 7.2 Prepare Test Source (`hello.c`)
```c
#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    printf("==========================================\n");
    printf("Tanmatsu Native C17 Compiler Validation\n");
    printf("Target Architecture: aarch64\n");
    printf("PID: %d\n", getpid());
    printf("Bionic C17 Library Linkage Succeeded!\n");
    printf("==========================================\n");
    return 0;
}
```

### 7.3 Push Files to Android Device via ADB
```bash
adb shell "mkdir -p /data/local/tmp/tanmatsu_test/bin /data/local/tmp/tanmatsu_test/sysroot /data/local/tmp/tanmatsu_test/clang_res"

# Push binaries
adb push $HOME/tanmatsu-build/dist/arm64-v8a/* /data/local/tmp/tanmatsu_test/bin/

# Push complete sysroot and resource directory
adb push $HOME/tanmatsu-build/sysroot_complete/* /data/local/tmp/tanmatsu_test/sysroot/
adb push $HOME/tanmatsu-build/clang_res/* /data/local/tmp/tanmatsu_test/clang_res/

# Push test source
adb push hello.c /data/local/tmp/tanmatsu_test/

# Grant execution permissions
adb shell "chmod +x /data/local/tmp/tanmatsu_test/bin/*.so"
```

### 7.4 Execute Compiler on Android Device
```bash
adb shell
cd /data/local/tmp/tanmatsu_test
export LD_LIBRARY_PATH=/data/local/tmp/tanmatsu_test/bin:$LD_LIBRARY_PATH

# 1. Verify Clang execution
./bin/libtanmatsu_clang.so --version

# 2. Compile hello.c using explicit linker invocation (--ld-path and -fuse-ld=lld)
./bin/libtanmatsu_clang.so \
    --target=aarch64-linux-android29 \
    --sysroot=/data/local/tmp/tanmatsu_test/sysroot \
    -resource-dir=/data/local/tmp/tanmatsu_test/clang_res \
    --ld-path=/data/local/tmp/tanmatsu_test/bin/libtanmatsu_lld.so \
    -fuse-ld=lld \
    -Wall -Wextra -O2 \
    hello.c -o hello

# 3. Run generated executable
./hello
```

---

## 8. Experiment 5: Complete clangd LSP Lifecycle Test

**Objective:** Validate that `libtanmatsu_clangd.so` executes on Android, completes the full 4-stage LSP lifecycle (`initialize` -> `initialized` -> `shutdown` -> `exit`), and keeps `stdout` strictly formatted with byte-accurate `Content-Length` headers while directing diagnostic logging to `stderr`.

### 8.1 Construct Byte-Accurate Lifecycle Stream
Create a python script on the host to generate byte-accurate LSP requests:

```python
# generate_lsp_lifecycle.py
import json

def frame_lsp(payload):
    body = json.dumps(payload, separators=(',', ':'))
    body_bytes = body.encode('utf-8')
    header = f"Content-Length: {len(body_bytes)}\r\n\r\n".encode('ascii')
    return header + body_bytes

messages = [
    # 1. initialize request
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"processId": None, "rootUri": "file:///data/local/tmp/tanmatsu_test", "capabilities": {}}},
    # 2. initialized notification
    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    # 3. shutdown request
    {"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None},
    # 4. exit notification
    {"jsonrpc": "2.0", "method": "exit"}
]

with open("lsp_lifecycle.bin", "wb") as f:
    for msg in messages:
        f.write(frame_lsp(msg))
print("lsp_lifecycle.bin generated successfully.")
```

Run script on host:
```bash
python3 generate_lsp_lifecycle.py
adb push lsp_lifecycle.bin /data/local/tmp/tanmatsu_test/
```

### 8.2 Execute Lifecycle Test on Device
```bash
adb shell
cd /data/local/tmp/tanmatsu_test
export LD_LIBRARY_PATH=/data/local/tmp/tanmatsu_test/bin:$LD_LIBRARY_PATH

# Pipe lifecycle stream to clangd, redirecting stderr to clangd_debug.log
cat lsp_lifecycle.bin | ./bin/libtanmatsu_clangd.so --background-index=false -j=1 2> clangd_debug.log > lsp_output.txt

# Inspect stdout response (Must contain clean JSON-RPC initialize and shutdown responses)
cat lsp_output.txt

# Verify process exit status is 0
echo "Clangd Exit Code: $?"

# Check debug logs in stderr
cat clangd_debug.log
```

---

## 9. Remaining Technical Uncertainties & Resolution Checklist

| # | Technical Uncertainty | Hypothesized Behavior | Smallest Resolving Experiment |
|---|---|---|---|
| **1** | **APK Native Library Executability** | Android package manager extracts `.so` to `nativeLibraryDir` with executable permissions; `ProcessBuilder` executes it without SELinux block across Android 10–15. | **Experiment 0:** Execute the minimal PoC in `experiments/poc_native_exec/` on physical Android 10–15 hardware. Verify stdout and zero AVC denials. |
| **2** | **Dynamic Linker Library Resolution** | `libtanmatsu_clang.so` will find `libLLVM.so` in `nativeLibraryDir` if linked with `-Wl,-rpath,'$ORIGIN'` or if `LD_LIBRARY_PATH` is passed. | **Experiment 1:** Run `llvm-readelf -d libtanmatsu_clang.so` on host to verify `DT_RUNPATH` contains `$ORIGIN`. Test `--version` via ADB with and without `LD_LIBRARY_PATH`. |
| **3** | **Canonical Sysroot Auto-Resolution** | Clang driver resolves Bionic headers and CRT objects automatically using the complete NDK sysroot. | **Experiment 2:** Run `./libtanmatsu_clang.so -v --target=aarch64-linux-android29 --sysroot=<path> --ld-path=<path> -fuse-ld=lld hello.c -o hello` and verify where headers and CRT objects are loaded from. |
| **4** | **Sora Editor LocalSocket Transport** | Sora `editor-lsp` connects cleanly to a Kotlin `LocalServerSocket` bridge forwarding to clangd stdio. | **Experiment 3:** Implement a minimal test harness opening `LocalServerSocket`, bridging to `libtanmatsu_clangd.so`, and verify LSP `initialize` response. |
| **5** | **clangd Full Lifecycle & Memory Footprint** | clangd completes `initialize` -> `initialized` -> `shutdown` -> `exit` cleanly and stays within reasonable mobile memory limits. | **Experiment 4:** Pipe the complete 4-stage JSON-RPC lifecycle into clangd, query `/proc/<pid>/statm`, and verify exit code 0. |
