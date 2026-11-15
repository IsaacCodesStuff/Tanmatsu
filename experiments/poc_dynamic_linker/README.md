# Milestone 1.5: Dynamic Linker & Shared Library Resolution PoC

## 1. Objective & Purpose

Milestone 1 successfully demonstrated that a standalone ARM64 PIE executable (`libtanmatsu_test_exec.so`) packaged in `jniLibs` can be extracted by AGP's `useLegacyPackaging = true` into `nativeLibraryDir` and executed via `ProcessBuilder` on Android 16 hardware without SELinux denials.

However, the complete Clang/LLVM toolchain is not a monolithic static binary. It consists of:
- Modular compiler and language server executables (`libtanmatsu_clang.so`, `libtanmatsu_clangd.so`, `libtanmatsu_lld.so`).
- Heavy sibling shared libraries (`libLLVM.so`, `libclang-cpp.so`).
- C++ runtime (`libc++_shared.so`).
- Runtime path resolution via ELF dynamic tags (`DT_RUNPATH` with `$ORIGIN`).

Before investing developer time and workstation CPU cycles into cross-compiling LLVM (Milestone 2), **Milestone 1.5 (Experiment 0.5)** determines whether Android's dynamic linker (`/system/bin/linker64`) resolves sibling shared libraries in `nativeLibraryDir` when invoked via `ProcessBuilder` without root and without setting `LD_LIBRARY_PATH`.

---

## 2. Test Architecture

Three native ARM64 artifacts are packaged together in `app/src/main/jniLibs/arm64-v8a/`:

```text
app/src/main/jniLibs/arm64-v8a/
├── libtanmatsu_dyn_test.so    (ARM64 PIE executable linking against sibling .so files via $ORIGIN)
├── libtanmatsu_dep.so         (Custom ARM64 shared library exporting get_tanmatsu_token())
└── libc++_shared.so           (Canonical NDK C++ runtime library)
```

### Source Code:
1. **`dep.c`** (Shared library):
   ```c
   __attribute__((visibility("default"))) int get_tanmatsu_token(void) {
       return 4242;
   }
   ```
2. **`dyn_test.cpp`** (C++ PIE executable):
   ```cpp
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

When `ProcessBuilder` executes `libtanmatsu_dyn_test.so`:
1. The kernel loads `libtanmatsu_dyn_test.so` and hands execution to `/system/bin/linker64` (requested by `PT_INTERP`).
2. The dynamic linker inspects `DT_NEEDED` and discovers dependencies: `libtanmatsu_dep.so`, `libc++_shared.so`, `libc.so`, `libdl.so`.
3. The dynamic linker inspects `DT_RUNPATH` containing `$ORIGIN`, evaluates `$ORIGIN` as `nativeLibraryDir`, and searches that directory for the sibling `.so` files.
4. The dynamic linker binds symbols (including `get_tanmatsu_token` and `std::string` routines).
5. The executable outputs `DYN_SUCCESS: Sibling shared library linked! Token=4242` and exits with code 0.

---

## 3. Host Build System (`build_test.sh`)

An automated, self-verifying build script is provided at `build_test.sh`.

### Prerequisites:
Set `ANDROID_NDK_ROOT` to your Android NDK (e.g. NDK r27 LTS):
```bash
export ANDROID_NDK_ROOT="$HOME/Android/Sdk/ndk/27.0.12077973"
# Or your local NDK path:
# export ANDROID_NDK_ROOT="$HOME/android-ndk-r27"
```

### Automated Execution:
```bash
cd experiments/poc_dynamic_linker
./build_test.sh
```

### Manual Build Steps (For Direct Control):

```bash
cd experiments/poc_dynamic_linker

NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_LIB="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
API=29

# 1. Copy canonical ARM64 libc++_shared.so from NDK sysroot
cp -f "$NDK_LIB/libc++_shared.so" ./libc++_shared.so

# 2. Compile sibling shared library libtanmatsu_dep.so
$NDK_BIN/aarch64-linux-android${API}-clang \
    -shared -fPIC -O2 \
    -Wl,-soname,libtanmatsu_dep.so \
    dep.c -o libtanmatsu_dep.so

# 3. Compile dynamic test executable with $ORIGIN runpath
$NDK_BIN/aarch64-linux-android${API}-clang++ \
    -fPIE -pie -O2 \
    -stdlib=libc++ \
    -Wl,-rpath,'$ORIGIN' \
    -Wl,--enable-new-dtags \
    -L. \
    dyn_test.cpp \
    -Wl,--no-as-needed -ltanmatsu_dep -lc++_shared -Wl,--as-needed \
    -o libtanmatsu_dyn_test.so
```

#### Important Compiler & Linker Flag Notes:
- `-Wl,-rpath,'$ORIGIN'`: In bash, single quotes are required to ensure the literal string `$ORIGIN` is passed to the linker without shell variable expansion.
- `-Wl,--enable-new-dtags`: Generates `DT_RUNPATH` instead of legacy `DT_RPATH`.
- `-Wl,--no-as-needed -ltanmatsu_dep -lc++_shared -Wl,--as-needed`: Forces the linker to emit `DT_NEEDED` entries for both libraries even if compiler optimizations might otherwise consider symbols elidable.
- `-Wl,-soname,libtanmatsu_dep.so`: Ensures the recorded dependency name in `DT_NEEDED` is exactly `libtanmatsu_dep.so`.

---

## 4. Host ELF Verification (Gate 1)

Every artifact must be inspected using `llvm-readelf` before deployment.

### Why ELF type `DYN` alone is insufficient:
Both shared libraries (`.so`) and Position Independent Executables (PIE) are encoded with `e_type = ET_DYN` in ELF64. To distinguish them:
- An **executable** contains a `PT_INTERP` program header requesting `/system/bin/linker64` and dynamic flag `FLAGS_1 ... PIE`.
- A **shared library** does **not** contain a `PT_INTERP` header and has no `FLAGS_1 ... PIE`.

### Verification Commands & Expected Outputs:

#### 1. Inspect `libtanmatsu_dep.so`:
```bash
$NDK_BIN/llvm-readelf -h -l -d -s libtanmatsu_dep.so
```
- **Type:** `DYN (Shared object file)`
- **Machine:** `AArch64`
- **Program Headers:** No `INTERP` segment.
- **Dynamic Section:** `SONAME: [libtanmatsu_dep.so]`
- **Symbol Table:** `GLOBAL DEFAULT ... get_tanmatsu_token`

#### 2. Inspect `libtanmatsu_dyn_test.so`:
```bash
$NDK_BIN/llvm-readelf -h -l -d libtanmatsu_dyn_test.so
```
- **Type:** `DYN (Shared object file)`
- **Machine:** `AArch64`
- **Entry point:** Non-zero (e.g. `0x1xxx`)
- **Program Headers:**
  ```text
  INTERP ...
      [Requesting program interpreter: /system/bin/linker64]
  ```
- **Dynamic Section:**
  ```text
  (NEEDED) Shared library: [libtanmatsu_dep.so]
  (NEEDED) Shared library: [libc++_shared.so]
  (NEEDED) Shared library: [libc.so]
  (NEEDED) Shared library: [libdl.so]
  (FLAGS_1) NOW PIE
  (RUNPATH) Library runpath: [$ORIGIN]
  ```

#### 3. Inspect `libc++_shared.so`:
```bash
$NDK_BIN/llvm-readelf -h libc++_shared.so
```
- **Class:** `ELF64`
- **Machine:** `AArch64`
- **Type:** `DYN (Shared object file)`

---

## 5. Deployment and Execution on Physical Device

### Step 1: Copy Artifacts to PoC App
```bash
APP_JNILIBS="../poc_native_exec/app/src/main/jniLibs/arm64-v8a"
cp -vf libtanmatsu_dyn_test.so libtanmatsu_dep.so libc++_shared.so "$APP_JNILIBS/"
```

### Step 2: Assemble and Install Debug APK
```bash
cd ../poc_native_exec
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Step 3: Launch PoC Activity
```bash
adb shell am start -n org.tanmatsu.poc/.MainActivity
```

### Step 4: Capture Application Logs
```bash
adb logcat -s TanmatsuPoC -d
```

#### Expected Logcat Output:
```text
TanmatsuPoC: === Tanmatsu Native Execution PoC ===
TanmatsuPoC: Android OS: 16 (API 36)
TanmatsuPoC: Device: samsung SM-A065F
TanmatsuPoC: ABI: arm64-v8a
TanmatsuPoC: nativeLibraryDir: /data/app/.../lib/arm64
TanmatsuPoC: --- Auditing Native Artifacts in nativeLibraryDir ---
TanmatsuPoC: libtanmatsu_dyn_test.so : exists=true, size=...B, exec=true
TanmatsuPoC: libtanmatsu_dep.so      : exists=true, size=...B, exec=true
TanmatsuPoC: libc++_shared.so        : exists=true, size=...B, exec=true
TanmatsuPoC: Selected binary: libtanmatsu_dyn_test.so
TanmatsuPoC: Working directory: /data/user/0/org.tanmatsu.poc/cache (writable: true)
TanmatsuPoC: --- Spawning Process via ProcessBuilder ---
TanmatsuPoC: LD_LIBRARY_PATH: [unset - testing DT_RUNPATH $ORIGIN]
TanmatsuPoC: Process exited with code: 0 (took ...ms)
TanmatsuPoC: STDOUT:
TanmatsuPoC: DYN_SUCCESS: Sibling shared library linked! Token=4242
TanmatsuPoC: >>> RESULT: SUCCESS! Sibling shared library and libc++_shared resolved via $ORIGIN without LD_LIBRARY_PATH.
TanmatsuPoC: Note: Dynamic linking success does not independently prove absence of SELinux denials. Perform Gate 5 logcat audit separately.
```

---

## 6. SELinux AVC Audit (Gate 5)

Dynamic linking and SELinux enforcement are independent subsystems. A process may spawn and execute successfully while minor denials occur, or conversely, dynamic linker failures could mask underlying SELinux policies.

Audit SELinux specifically:
```bash
adb logcat -d | grep -E 'avc:.*(org\.tanmatsu\.poc|libtanmatsu)'
```
- **Passing Condition:** Zero matching AVC denials returned.

---

## 7. The Five Acceptance Gates Ledger

| Gate | Criterion | Validation Method | Current Status |
|---|---|---|---|
| **Gate 1** | ELF inspection confirms AArch64, PIE (`PT_INTERP`), `DT_NEEDED` (`dep.so`, `libc++_shared.so`), `DT_RUNPATH` (`$ORIGIN`). | `build_test.sh` fixed-string readelf assertions. | **PASSED on Host** |
| **Gate 2** | All 3 artifacts packaged in APK and extracted to `nativeLibraryDir`. | Logcat audit logged by `MainActivity.kt`. (Host staging completed; extraction verified on device). | *Pending Device Verification* |
| **Gate 3** | Android dynamic linker resolves sibling libraries without `cannot locate symbol` or `library not found` crashes. | Process launch without linker abort. | *Pending Device Verification* |
| **Gate 4** | Process outputs `DYN_SUCCESS: Sibling shared library linked! Token=4242` and exits with code `0`. | Stdout and exit value captured by `MainActivity.kt`. | *Pending Device Verification* |
| **Gate 5** | SELinux logcat check confirms zero AVC denials. | `adb logcat -d \| grep -E 'avc:.*'` | *Pending Device Verification* |

Milestone 1.5 is marked **Completed** in `AGENTS.md` only after all five gates are empirically satisfied and verified with hardware logs.
