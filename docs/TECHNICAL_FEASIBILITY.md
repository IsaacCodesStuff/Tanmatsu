# Technical Feasibility Report: Android-Native C Toolchain & Tanmatsu IDE

**Document Version:** 2.1 (Revised Technical Baseline)  
**Target Architecture:** ARM64 (`aarch64-linux-android`)  
**Date:** November 2026  
**Status:** Rigorous Feasibility Analysis & Experimental Planning  

---

## 1. Executive Summary & Hypotheses

Tanmatsu is engineered as a standalone C Integrated Development Environment (IDE) running natively on Android devices without relying on Termux. This report investigates the technical viability of hosting Clang, LLD, and clangd directly on Android ARM64, managing process execution within Android's platform security constraints, and providing language intelligence via Language Server Protocol (LSP).

### Core Technical Hypotheses
1. **Toolchain Cross-Compilation Hypothesis:** Upstream LLVM (v18+) can be cross-compiled on an x86_64 host using the Android NDK to produce executables that run directly on Android Bionic ARM64 (`aarch64-linux-android`). *Target binary size and memory consumption are unverified hypotheses subject to empirical testing in Milestone 2.*
2. **Bundled Tool Execution (Empirically Verified for Standalone Native Executables):** Renaming compiled native executables with a `lib` prefix and `.so` extension (e.g. `libtanmatsu_clang.so`, `libtanmatsu_lld.so`), packaging them in `jniLibs/arm64-v8a/`, and setting modern AGP packaging `useLegacyPackaging = true` causes the Android package manager to extract them into `context.applicationInfo.nativeLibraryDir`. This mechanism has been **empirically verified on physical hardware running Android 16 (Samsung SM-A065F, API 36, `arm64-v8a`)**: `libtanmatsu_test_exec.so` was extracted with executable permissions, executed cleanly via `ProcessBuilder`, exited with code 0, and triggered zero relevant SELinux AVC denials. *Resolving sibling shared libraries via `$ORIGIN` remains to be verified in Milestone 1.5 before building LLVM.*
3. **User-Compiled Execution Dichotomy:** Android 10+ (API 29+) enforces strict W^X policies that block untrusted apps targeting API 29+ from executing binaries compiled into writable app storage (`app_data_file`). 
   - *Phase 1 Strategy (Target SDK 28):* Adopting `targetSdkVersion = 28` places the app into the legacy `untrusted_app_28` SELinux domain, allowing direct execution of user-compiled ELF binaries from internal storage.
   - *Phase 2 Strategy (WASI Sandbox):* Transitioning user program execution to an in-process WebAssembly/WASI runtime (e.g. Wasm3 or Wasmer JNI) to allow compliance with modern Google Play target SDK mandates (targetSdk >= 34).
4. **Editor & LSP Architecture:** Sora Editor (`0.24.x`) provides a high-performance Android View-based editing component that embeds into Jetpack Compose via `AndroidView`. Its `editor-lsp` extension natively supports both TCP sockets and Android `LocalSocket` (UNIX domain sockets). Integrating `libtanmatsu_clangd.so` (which communicates via standard I/O) requires an explicit local socket bridge implemented as a Tanmatsu application responsibility.

---

## 2. Termux Execution Architecture Deep-Dive

To evaluate native execution without Termux, we must carefully distinguish the multiple mechanisms Termux has utilized over its development history.

```
+-----------------------------------------------------------------------------------------+
|                                 Termux Execution Facets                                 |
+-----------------------------------------------------------------------------------------+
| 1. targetSdkVersion = 28 Compatibility                                                 |
|    - OS-level SELinux domain transition to untrusted_app_28                            |
|    - Kernel allows execute_no_trans on app_data_file                                    |
+-----------------------------------------------------------------------------------------+
| 2. termux-exec (LD_PRELOAD wrapper)                                                     |
|    - Client-side hook on libc execve() family                                           |
|    - Rewrites shebangs (#!/bin/sh -> $PREFIX/bin/sh)                                    |
|    - Does NOT bypass SELinux W^X rules on API 29+ on its own                            |
+-----------------------------------------------------------------------------------------+
| 3. system_linker_exec Mechanism (Working Termux Workaround for targetSdkVersion >= 29)   |
|    - Intercepts execve() to invoke /system/bin/linker64 with target binary path         |
|    - Intercepts readlink(/proc/self/exe) and manages environment shims                  |
|    - Works for dynamic ELF binaries; fails for static binaries                          |
|    - Suitability for Tanmatsu: UNRESOLVED                                               |
+-----------------------------------------------------------------------------------------+
| 4. APKLF (APK Library File) Architecture                                                |
|    - Modernization initiative packaging packages into APK native library structures     |
|    - Leverages apk_data_file SELinux context in nativeLibraryDir                        |
+-----------------------------------------------------------------------------------------+
```

### 2.1 The Android SDK Triad & Sandbox Domain Transition

Android evaluates three distinct SDK versions declared in the build configuration:
- `compileSdkVersion`: Dictates the Android platform API symbols available to Kotlin/Java code at build time. Has zero runtime effect.
- `minSdkVersion`: Minimum OS version required to install the APK.
- `targetSdkVersion`: **The critical runtime security switch.** The Android OS kernel and zygote inspect this value to assign the application's SELinux domain:
  - When `targetSdkVersion <= 28`: Android places the app in the legacy `untrusted_app_28` domain.
  - When `targetSdkVersion >= 29`: Android places the app in `untrusted_app_29` (or modern equivalents up to `untrusted_app_35`).

### 2.2 Android 10 (API 29) W^X Restrictions on `app_data_file`
In Android 10+, the SELinux policy for untrusted apps targeting API 29+ contains strict neverallow assertions:
```sepolicy
neverallow untrusted_app_all app_data_file:file { execute_no_trans };
```
When an application targeting API 29+ writes an ELF binary to internal storage (`/data/user/0/<package>/files/a.out`) and calls `execve()`:
1. The kernel rejects the system call with `EACCES` (*Permission denied*).
2. The kernel logs an AVC denial:
   ```text
   avc: denied { execute_no_trans } for path="/data/user/0/.../a.out" dev="..." ino=... scontext=u:r:untrusted_app:s0 tcontext=u:object_r:app_data_file:s0 tclass=file
   ```

### 2.3 Termux's Reliance on `targetSdkVersion = 28`
Official F-Droid and GitHub builds of Termux declare:
```xml
<uses-sdk android:minSdkVersion="24" android:targetSdkVersion="28" />
```
Because the app runs in the `untrusted_app_28` domain, the SELinux policy permits execution:
```sepolicy
allow untrusted_app_28 app_data_file:file { rx_file_perms execute_no_trans };
```
**Sustainability & Production Status (Explicitly Experimental):**
- **Experimental Status:** Targeting API 28 is strictly an **experimental research workaround** for early prototype development and sideloaded testing. It is **not** a viable production decision for mainstream distribution.
- **Google Play:** Prohibits submissions targeting API 28 (mandates targetSdk >= 34/35).
- **Platform Installation Barriers:** Android 14 (API 34) blocks installing apps with `targetSdkVersion < 23`; Android 15 raises this to 24. Future Android releases are projected to elevate this cutoff towards API 28+, requiring manual installation flags (`adb install --bypass-low-target-sdk-block`).
- **OEM Modifications:** Certain vendor ROMs (e.g. Samsung Knox, strict corporate MDMs) enforce global W^X regardless of target SDK.

### 2.4 `termux-exec` and `system_linker_exec`

Current Termux project documentation explicitly identifies **`system_linker_exec`** as a working workaround enabling Termux builds to target modern SDKs (`targetSdkVersion >= 29`):
1. **How `system_linker_exec` Operates:**
   - Preloaded via `LD_PRELOAD` using `termux-exec`.
   - Intercepts calls to `execve(target, argv, envp)`.
   - Instead of directly calling the kernel on `target`, it transforms the call into:
     ```bash
     /system/bin/linker64 /path/to/target ...argv
     ```
   - Intercepts `readlink("/proc/self/exe")` so that the running binary appears as the actual target binary rather than `/system/bin/linker64`.
   - Sets and maintains environment variables like `TERMUX_EXEC__PROC_SELF_EXE`.
2. **Technical Limitations of `system_linker_exec`:**
   - **Dynamic Binaries Only:** Requires the target to be a dynamically linked ELF binary with a dynamic interpreter (`PT_INTERP`). It cannot execute statically linked binaries.
   - **SELinux Audit & Enforcement Risks:** If the kernel enforces strict non-executable checks on memory mapped from `app_data_file` (`PROT_EXEC` denial), the dynamic linker's `mmap()` call fails.
   - **Google Play Policy Scrutiny:** Invoking dynamic linkers directly to execute code downloaded or compiled into writable storage can trigger security flags during automated app reviews.
3. **Suitability for Tanmatsu (Unresolved):**
   - For bundled tools, Tanmatsu uses APK native library extraction (`nativeLibraryDir`), making `system_linker_exec` unnecessary.
   - For user programs, `system_linker_exec` is a possible alternative to `targetSdkVersion = 28`, but introduces fragility and complex `LD_PRELOAD` interposition. Its adoption for Tanmatsu remains an **unresolved architectural decision** under active research.

---

## 3. Four Distinct Android API Levels & Target Compatibility Rule

Tanmatsu explicitly separates four distinct Android API level configurations:

| Concept | Setting / Value | Role in Tanmatsu | Impact |
|---|---|---|---|
| **App Minimum OS** | `minSdkVersion = 26` (or 28) | Host application OS compatibility | Determines the oldest physical Android device that can install the Tanmatsu APK. |
| **App Security Domain** | `targetSdkVersion = 28` | Host application SELinux sandbox | Selects the `untrusted_app_28` domain, enabling direct execution of user-compiled `a.out` binaries. |
| **Toolchain Host Minimum API** | NDK platform `android-26` (or 28) | Compilation baseline for LLVM binaries | The minimum Android OS version required to run `libtanmatsu_clang.so`, `libtanmatsu_lld.so`, and `libtanmatsu_clangd.so`. |
| **User Program Target API** | `--target=aarch64-linux-android<API>` (e.g. 29) | Target platform for compiled C programs | Determines which Bionic libc symbol stubs (`libc.so`) and CRT objects are linked into the user's `a.out`. |

### Crucial Device-Target Compatibility Rule
$$\text{User Target API Level} \le \text{Device Physical OS API Level}$$
A program compiled against Android API 29 relies on dynamic symbols introduced in Android 10 Bionic. If executed on a device running Android 9 (API 28), it will abort at launch with dynamic linker symbol errors (`cannot locate symbol`). The Tanmatsu IDE must ensure the selected compilation target does not exceed the host device's OS API level.

> [!IMPORTANT]
> **Necessary Condition, Not a Guarantee:**
> Satisfying $\text{Target API} \le \text{Device OS API}$ is a **necessary compatibility condition, but NOT a guarantee of successful execution**. Program launch can still fail due to:
> - Vendor-specific ROM security customizations and non-standard SELinux denials.
> - Kernel memory page alignment restrictions (e.g. 16 KB page size kernel enforcement introduced in Android 15 if the binary is linked with legacy 4 KB page alignment).
> - Device ABI incompatibilities (e.g. attempting to run 32-bit binaries on 64-bit-only modern chipsets).
> - Missing optional hardware or vendor shared libraries.

---

## 4. Android-Native LLVM Toolchain Feasibility

### 4.1 Strict LLVM Configuration Terminology

When cross-compiling LLVM, the following terms have exact meanings:
- **Build Machine (Build Triple):** The machine running the build (workstation `x86_64-linux-gnu`).
  - *Build Dependencies:* Host C/C++ compiler (Clang/GCC), host CMake (3.20+), host Ninja, Python 3, host zlib, zstd, ncurses.
- **Host Machine (Host Triple, `LLVM_HOST_TRIPLE`):** The platform where the generated LLVM executables will execute (Android ARM64: `aarch64-linux-android`).
  - *Target Build Dependencies:* Android NDK toolchain (`android.toolchain.cmake`), target Bionic dynamic stubs, and target `libc++_shared.so`.
- **Target Backend Architectures (`LLVM_TARGETS_TO_BUILD`):** The CPU architectures for which LLVM's code generator can emit machine code. Constrained strictly to `"AArch64"`.
- **Default Target Triple (`LLVM_DEFAULT_TARGET_TRIPLE`):** The default compilation target Clang targets if no `--target` flag is passed (e.g. `aarch64-linux-android29`).
- **Dedicated Installation Prefix (`CMAKE_INSTALL_PREFIX`):** A clean target directory (e.g. `$HOME/tanmatsu-build/install-android-arm64`) where target tools are installed via `ninja install`.

### 4.2 Distinguishing Compiler vs Program Runtime Dependencies & Compiler-RT Decision

```
+-----------------------------------------------------------------------------------+
| 1. Compiler Toolchain Runtime Dependencies (Required to execute Clang/clangd)     |
|    - Android Bionic libc.so, libm.so, libdl.so                                    |
|    - NDK C++ Standard Library: libc++_shared.so                                   |
|    - Core shared libraries: libLLVM.so, libclang-cpp.so                           |
+-----------------------------------------------------------------------------------+

+-----------------------------------------------------------------------------------+
| 2. User Program Runtime Dependencies (Required to link & execute user a.out)       |
|    - Bionic CRT startup objects: crtbegin_dynamic.o, crtend_android.o             |
|    - Real Bionic libc provided by Android device OS (/system/lib64/libc.so)       |
|    - Compiler Builtins: libclang_rt.builtins-aarch64-android.a                     |
|      (Provides low-level arithmetic and atomic helpers emitted by Clang)          |
+-----------------------------------------------------------------------------------+
```

#### NDK Stub Libraries Are Compile-Time Stubs Only
The NDK sysroot provides dynamic stubs (`usr/lib/aarch64-linux-android/29/libc.so`, `libm.so`, `libdl.so`). **These are compile-time stubs containing ELF symbol definitions only; they are NOT bundled into the APK or deployed to the device as runtime libraries.** At runtime, the compiled user program dynamically links against the device's system Bionic libraries located in `/system/lib64/` or APEX runtime paths.

#### Compiler-RT Decision: Reusing NDK Prebuilts (Unverified Compatibility Hypothesis)
- **NDK Revision:** Android NDK r27 LTS (exact release: `27.0.12077973` / `clang-r522817d`, based on LLVM 18.0.1).
- **Prebuilt Archive Path:** `$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux/libclang_rt.builtins-aarch64-android.a`.
- **Compatibility Hypothesis:** Because NDK r27 is built from LLVM 18, its prebuilt compiler builtins archive is hypothesized to be ABI-compatible with the chosen LLVM 18.1.8 compiler driver.
- **Verification Gate:** This remains an **unverified hypothesis** until a compiled C test program exercising low-level arithmetic helpers (e.g. 128-bit integer operations or 64-bit division routines) successfully links against this archive and runs on physical hardware without unresolved symbol errors or ABI faults. We will not add an unnecessary, expensive target runtime build without evidence of incompatibility.

### 4.3 Bundled Executable Naming & Linker Invocation
To avoid collisions with standard `libclang.so` (LLVM C API):
- Compiler Driver Executable: **`libtanmatsu_clang.so`** (renamed from `bin/clang`)
- Linker Executable: **`libtanmatsu_lld.so`** (renamed from `bin/lld` / `bin/ld.lld`)
- Language Server Daemon: **`libtanmatsu_clangd.so`** (renamed from `bin/clangd`)
- Shared LLVM Engine: **`libLLVM.so`**
- Shared Clang Frontend: **`libclang-cpp.so`**
- Proof-of-Concept Test Binary: **`libtanmatsu_test_exec.so`**

#### Explicit Linker Invocation
When invoking Clang to use Tanmatsu's bundled LLD executable:
```bash
libtanmatsu_clang.so \
  --target=aarch64-linux-android29 \
  --sysroot=/path/to/sysroot \
  --ld-path=/path/to/libtanmatsu_lld.so \
  -fuse-ld=lld \
  main.c -o a.out
```
In modern Clang (Clang 12+), `--ld-path` explicitly specifies the exact executable path, while `-fuse-ld=lld` indicates the linker flavor.

### 4.4 Canonical Complete NDK Sysroot Strategy

Previous partial header-copy scripts caused subtle include failures with complex standard headers (`<sys/...>`, `<linux/...>`, `<bits/...>`).  
**Decision:** For all initial experiments and on-device testing, Tanmatsu uses the **complete, canonical NDK sysroot directly** (`$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot`). This ensures complete header and symbol coverage without hand-crafted partial copying.

---

## 5. clangd Language Server Feasibility

### 5.1 Transport Architecture: LocalSocket vs TCP
`libtanmatsu_clangd.so` communicates via LSP JSON-RPC over stdin/stdout.

Sora Editor's `editor-lsp` extension natively supports both TCP socket connections and **Android `LocalSocket`** (UNIX domain sockets, introduced in PR #706):
- **TCP Socket (`socket(host, port)`):** Connects to `127.0.0.1:<port>`. Requires allocating an open TCP port.
- **LocalSocket (`localSocket(address)`):** Uses Linux UNIX domain sockets in Android's abstract namespace. Avoids port conflicts, eliminates network permission requirements, and offers lower inter-process communication latency.

**Architecture:** Tanmatsu implements a lightweight Kotlin socket bridge (`ClangdSocketBridge`) that opens a `LocalServerSocket` (or TCP `ServerSocket`), accepts the connection from `editor-lsp`, and pipes bytes directly to and from `libtanmatsu_clangd.so`'s standard I/O streams.

### 5.2 Full LSP Lifecycle Validation
LSP specifies a strict four-stage lifecycle:
1. `initialize` (Request): Client sends capabilities; server replies with server capabilities.
2. `initialized` (Notification): Client confirms readiness; server begins document processing.
3. `shutdown` (Request): Client requests graceful shutdown; server stops indexing and replies `null`.
4. `exit` (Notification): Server process terminates cleanly with exit code 0.

*Stream Discipline:* All clangd diagnostic logging is directed to `stderr`. `stdout` carries strictly formatted JSON-RPC messages prefixed with `Content-Length: <bytes>\r\n\r\n`.

---

## 6. Android Execution & Packaging Strategies

### 6.1 Modern AGP Native Library Packaging (PoC Plan)

Modern Android Gradle Plugin (AGP 7.0+ / 8.0+) manages native library extraction via the Gradle DSL rather than `AndroidManifest.xml`:

```kotlin
android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```
Setting `useLegacyPackaging = true` forces the Android package manager to extract `.so` files from the APK into `context.applicationInfo.nativeLibraryDir` upon installation.

### 6.2 Milestone 1 Empirical Verification Report (Completed / Passed)

The native execution Proof-of-Concept was executed and verified on physical hardware:

#### Test Environment:
- **Device:** Samsung SM-A065F (Samsung Galaxy A06 4G)
- **OS Version:** Android 16 (API Level 36)
- **ABI:** `arm64-v8a`
- **Workstation Build Environment:** Arch Linux
- **Gradle Version:** 8.10.2
- **JDK Version:** OpenJDK 17.0.20
- **Test Artifact:** `app/src/main/jniLibs/arm64-v8a/libtanmatsu_test_exec.so` (4,600 bytes)

#### Observed Test Results:
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

#### ELF Header Verification:
```text
Class: ELF64
Type: DYN
Machine: AArch64
Entry point address: 0x16E8

INTERP:
[Requesting program interpreter: /system/bin/linker64]
```

#### SELinux Audit Verification:
```bash
adb logcat -d | grep -E 'avc:.*(org\.tanmatsu\.poc|libtanmatsu_test_exec)'
```
*Result:* **Zero matching AVC denial entries.**

#### What This Result Proves:
1. Native ARM64 PIE executables can be successfully packaged through APK `jniLibs`.
2. Package manager extracts them into Android's `nativeLibraryDir` when `useLegacyPackaging = true`.
3. Executable permissions (`rwxr-xr-x`) are preserved on extracted binaries.
4. Java's `ProcessBuilder` spawns the binary on a background thread without `IOException` or `EACCES`.
5. The Android 16 dynamic linker (`/system/bin/linker64`) executes the binary smoothly without triggering SELinux blocks.
6. Process exit code (0) and standard output are captured cleanly.

#### Crucial Scope Boundary: What This Does NOT Yet Prove:
To avoid overgeneralizing this result, we explicitly acknowledge that this test does **NOT** prove:
- **Clang, LLD, or clangd execution:** Complex compiler binaries with multi-megabyte footprints have not yet been run.
- **Dynamically linked sibling dependencies:** `libtanmatsu_test_exec.so` only linked against system Bionic libc; it did not test resolving sibling shared libraries (`libLLVM.so`, `libclang-cpp.so`, `libc++_shared.so`) via `$ORIGIN`.
- **On-device C compilation:** No source code parsing, code generation, or linking was performed on device.
- **User program execution:** User-compiled binaries located in writable storage (`app_data_file`) were not tested.
- **Cross-device/cross-version uniformity:** Behavior on Android 10–14 or other OEM skins (e.g. Pixel, Xiaomi) remains to be confirmed.

---

## 7. Licensing & Redistribution Analysis

| Component | Upstream Project | License | Redistribution Terms & Conditions |
|---|---|---|---|
| **LLVM / Clang / clangd / LLD** | LLVM Project | Apache-2.0 with LLVM Exception | Permitted. Include copyright and Apache-2.0 notice. |
| **Bionic Sysroot Headers** | AOSP / Bionic | BSD-2-Clause & Apache-2.0 | Permitted. Distribute BSD/Apache notices alongside header files. |
| **Bionic CRT Objects** | AOSP / Bionic | BSD-2-Clause | Permitted when built from AOSP sources. |
| **Android NDK Prebuilts** | Google LLC | Android SDK License Agreement | **Proprietary SDK EULA.** Section 3.1 prohibits redistributing raw Google NDK packages. Open-source components within the NDK remain governed by their upstream licenses (Section 3.5). |
| **Sora Editor** | Rosemoe | LGPL-2.1 | Permitted via dynamic Gradle linking. Include LGPL text and attribution. |

---

## 8. Remaining Technical Uncertainties & Proposed Next Experiment

### 8.1 Remaining Technical Uncertainties

| # | Technical Uncertainty | Hypothesized Behavior | Resolving Experiment | Status |
|---|---|---|---|---|
| **1** | **APK Native Library Executability** | Android extracts `.so` to `nativeLibraryDir` with executable permissions; `ProcessBuilder` executes it without SELinux block. | **Experiment 0 (Milestone 1):** Standalone PIE executable test. | **VERIFIED / PASSED** (Samsung SM-A065F, Android 16) |
| **2** | **Dynamic Linker Sibling Library Resolution** | Dynamic linker will locate sibling `.so` files (`libtanmatsu_dep.so`, `libc++_shared.so`) in `nativeLibraryDir` via `$ORIGIN` without `LD_LIBRARY_PATH`. | **Experiment 0.5 (Milestone 1.5):** Build multi-library test executable with C++ STL and sibling `.so` dependency. | *Pending (Next Experiment)* |
| **3** | **Full LLVM Shared-Library Toolchain Execution** | `libtanmatsu_clang.so` will find `libLLVM.so` and `libclang-cpp.so` in `nativeLibraryDir`. | **Experiment 1 (Milestone 2):** Strip and test LLVM toolchain `--version` via ADB. | *Pending* |
| **4** | **Canonical Complete Sysroot Auto-Resolution** | Clang driver resolves Bionic headers and CRT objects automatically using the complete NDK sysroot. | **Experiment 2 (Milestone 3):** Run `./libtanmatsu_clang.so -v --target=aarch64-linux-android29 --sysroot=<path> --ld-path=<path> -fuse-ld=lld hello.c -o hello`. | *Pending* |
| **5** | **Sora Editor LocalSocket Transport** | Sora `editor-lsp` connects cleanly to a Kotlin `LocalServerSocket` bridge forwarding to clangd stdio. | **Experiment 3 (Milestone 4):** Implement test harness opening `LocalServerSocket`, bridging to `libtanmatsu_clangd.so`, and verify LSP `initialize` response. | *Pending* |
| **6** | **clangd Full Lifecycle & Memory Footprint** | clangd completes `initialize` -> `initialized` -> `shutdown` -> `exit` cleanly and stays within reasonable mobile memory limits. | **Experiment 4 (Milestone 4):** Pipe the complete 4-stage JSON-RPC lifecycle into clangd, query `/proc/<pid>/statm`, and verify exit code 0. | *Pending* |
| **7** | **User-Compiled Program Execution in Writable Storage** | Untrusted app can execute user-compiled binaries from private storage under `targetSdkVersion = 28`. | **Experiment 5 (Milestone 3/7):** Compile `hello.c` on device into `filesDir` and test process spawning under targetSdk 28. | *Pending* |

### 8.2 Recommended Next Smallest Experiment: Milestone 1.5
Before committing host workstation resources to cross-compile the complete 100+ MB LLVM toolchain, the immediate next experiment is **Milestone 1.5: Dynamic Linker & Shared Library Resolution PoC**.
- **Objective:** Test that an ARM64 native executable (`libtanmatsu_dyn_test.so`) packaged in `nativeLibraryDir` can dynamically resolve and call functions in a **sibling custom shared library** (`libtanmatsu_dep.so`) and link against NDK **`libc++_shared.so`** using `DT_RUNPATH` with `$ORIGIN`, without requiring root or external environment manipulation.
- **Why this is critical:** Clang and clangd are modular binaries that depend heavily on `libLLVM.so`, `libclang-cpp.so`, and `libc++_shared.so`. Validating multi-library dynamic linking in `nativeLibraryDir` using a tiny (10 KB) C++ test library prevents discovering dynamic linker resolution failures only after hours of LLVM cross-compilation.
