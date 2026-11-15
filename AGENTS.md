# AGENTS.md — Tanmatsu Engineering Guide

Persistent development reference and architecture guide for **Tanmatsu**, a standalone Android Integrated Development Environment (IDE) targeting C programming without Termux dependency.

---

## 1. Project Purpose & Objectives

Tanmatsu is designed to deliver a self-contained, native software development environment on Android devices. Unlike existing workflows that rely on Termux or external emulation layers, Tanmatsu integrates the code editor, native C toolchain (Clang/LLVM), language intelligence (clangd LSP), and program execution within a single unified Android application.

### Key Objectives
- **Zero Termux Dependency:** Execute the entire build and language-server toolchain using Android-native binaries packaged directly with the application or managed in its sandboxed environment.
- **Modern Android Stack:** User interface constructed purely with Kotlin, Jetpack Compose, and Material 3 Expressive styling.
- **Production-Grade Toolchain:** Leverage upstream Clang, LLD, and clangd cross-compiled to execute on Android Bionic ARM64 (`aarch64-linux-android`).
- **Comprehensive C IDE Features:**
  - High-performance code editing with line numbers, syntax highlighting, and code folding.
  - Live compiler diagnostics rendered as inline error/warning squiggles and annotations.
  - Full Language Server Protocol (LSP) capabilities (completion, hover, go-to-definition, symbol outline).
  - On-device compilation of C17 source code to native ARM64 executables.
  - Execution console with standard input, output, and exit status reporting.

---

## 2. Technology Stack & Current Decisions

| Component | Technology / Tool | Decision Justification |
|---|---|---|
| **Host Application Platform** | Android (minSdkVersion = 26/28, targetSdkVersion = 28) | Target SDK 28 preserves legacy SELinux compatibility for running user executables; see Section 5. |
| **Primary Language** | Kotlin 2.0+ | Modern Android standard; native coroutines support for asynchronous LSP and process I/O. |
| **UI Framework** | Jetpack Compose | Declarative UI enabling reactive state updates for diagnostics, build status, and console streams. |
| **Design System** | Material 3 Expressive | Official modern Android design guidelines with dynamic theming and expressive motion. |
| **Initial Language** | C (ISO C17 standard) | Foundational system programming language; minimal runtime overhead compared to C++ or Rust. |
| **Compiler** | Clang / LLVM (v18.x+) | Upstream LLVM cross-compiled for Android Bionic host; native AArch64 code generator. |
| **Linker** | LLD (`ld.lld`) | High-speed LLVM linker with first-class ELF and Android ARM64 support; invoked via `--ld-path` and `-fuse-ld=lld`. |
| **Language Server** | clangd | Official LLVM LSP implementation; provides indexing, diagnostics, and code intelligence. |
| **Target ABI** | ARM64 (`arm64-v8a` / `aarch64`) | Dominant architecture for modern Android hardware; 32-bit targets omitted to minimize complexity. |
| **C Standard Library**| Android Bionic | Native system C library on Android; zero additional libc runtime overhead. |
| **Code Editor** | Sora Editor (`0.24.x`) | Native Android View-based code editor with Compose interop, TextMate/Tree-sitter highlighting, and LSP capabilities via `LocalSocket`/TCP. |

---

## 3. Four Distinct Android API Levels & Target Compatibility Rule

To avoid architectural confusion, Tanmatsu explicitly distinguishes between four separate API level concepts:

1. **`minSdkVersion` (Host App Minimum OS, e.g. 26 or 28):**  
   The minimum Android version required to install and run the Tanmatsu app. Devices below this cannot install the APK.
2. **`compileSdkVersion` / `targetSdkVersion` (Host App Sandbox Domain):**  
   `compileSdkVersion` (e.g. 34/35) allows using modern AndroidX APIs. `targetSdkVersion = 28` keeps the app in the legacy `untrusted_app_28` SELinux domain to enable running user-compiled binaries directly from app storage.
3. **Bundled Toolchain Host Minimum API (NDK Platform Level, e.g. `android-26`):**  
   The minimum Android API against which `libtanmatsu_clang.so`, `libtanmatsu_lld.so`, and `libtanmatsu_clangd.so` are linked. Binaries linked against API 26 can run on Android 8.0 through Android 16+.
4. **User Program Target API Level (`--target=aarch64-linux-android<API>`):**  
   The API level selected for compiled user C programs (e.g. API 29). This dictates which Bionic libc symbol stubs (`libc.so`) and CRT startup objects are linked into the user's `a.out`.

### Crucial Device-Target Compatibility Rule
$$\text{User Target API Level} \le \text{Device Physical OS API Level}$$
A program compiled against Android API 29 relies on dynamic symbols introduced in Android 10. If executed on a device running Android 9 (API 28), it will abort at launch with dynamic linker symbol errors. The IDE must guide users to target an API level $\le$ their physical device's OS level. Note that this is a **necessary compatibility condition, but not a guarantee of execution** (vendor ROM customizations, 16 KB page size kernel enforcement in Android 15+, or missing optional libraries can still prevent execution).

---

## 4. Native Toolchain Terminology & Build Requirements

### 4.1 Strict LLVM Terminology Definitions
- **Build Machine (Build Triple):** The machine compiling LLVM itself (workstation `x86_64-linux-gnu`).
- **Host Machine (Host Triple, `LLVM_HOST_TRIPLE`):** The platform where the generated LLVM executables will execute (Android device: `aarch64-linux-android`).
- **Target Backend Architectures (`LLVM_TARGETS_TO_BUILD`):** The CPU architectures for which LLVM can generate code. Constrained strictly to `"AArch64"`.
- **Default Target Triple (`LLVM_DEFAULT_TARGET_TRIPLE`):** The default target platform assumed by Clang when invoked without `--target` (e.g. `aarch64-linux-android29`).
- **Installation Prefix (`CMAKE_INSTALL_PREFIX`):** A dedicated, cleanly isolated destination directory for target binaries.

### 4.2 Distinguishing Runtime Dependencies & Compiler-RT Decision
- **Compiler's Own Runtime Dependencies:** Shared libraries required by the compiler executables to run on Android (`libc.so`, `libm.so`, `libdl.so`, and NDK `libc++_shared.so`).
- **Generated Program Runtime Dependencies:**
  - Bionic C library dynamic symbols provided by the host OS (`/system/lib64/libc.so`, `libm.so`, `libdl.so`).
  - Bionic CRT startup objects (`crtbegin_dynamic.o`, `crtend_android.o`).
  - Clang compiler builtins (`libclang_rt.builtins-aarch64-android.a`), which provide low-level arithmetic and atomic helper routines generated by Clang.
- **Compiler-RT Decision (Unverified Compatibility Hypothesis):** Android NDK r27 LTS (revision `27.0.12077973` / `clang-r522817d`) provides prebuilt builtins at `$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18/lib/linux/libclang_rt.builtins-aarch64-android.a`. We hypothesize this archive is ABI-compatible with the chosen LLVM 18.1.8 compiler. This remains an unverified hypothesis until a compiled C test program exercising low-level arithmetic helpers links against this archive and runs successfully on hardware. We will avoid adding a resource-intensive target runtime build without evidence of incompatibility.

### 4.3 Naming Convention & Linker Invocation
To avoid name collisions with the standard LLVM C API shared library (`libclang.so`), bundled executables are named:
- Compiler Driver: `libtanmatsu_clang.so`
- Linker: `libtanmatsu_lld.so`
- Language Server Daemon: `libtanmatsu_clangd.so`
- Proof-of-Concept Test Executable: `libtanmatsu_test_exec.so`
- Dynamic Linker Test Executable: `libtanmatsu_dyn_test.so`
- Shared Test Dependency: `libtanmatsu_dep.so`

When invoking Clang to use the custom linker:
```bash
libtanmatsu_clang.so --ld-path=/path/to/libtanmatsu_lld.so -fuse-ld=lld ...
```

---

## 5. Android Execution & Packaging Strategy

### 5.1 Bundled Tools: APK Native Library Packaging
- Bundled toolchain binaries are packaged into `app/src/main/jniLibs/arm64-v8a/` and extracted to `context.applicationInfo.nativeLibraryDir` via modern AGP DSL:
  ```kotlin
  packaging.jniLibs.useLegacyPackaging = true
  ```
- **Status: Verified for Standalone Native Executables (Milestone 1 Passed).**
  - Empirically demonstrated on physical Android 16 (Samsung SM-A065F, API 36, `arm64-v8a`).
  - `libtanmatsu_test_exec.so` was extracted into `nativeLibraryDir` with permissions `rwxr-xr-x`, executed via `ProcessBuilder`, exited with code 0, and returned expected stdout with zero relevant SELinux AVC denials.
  - **Remaining Hypothesis to Verify:** Multi-library dynamic linking resolution (`$ORIGIN` search paths for sibling shared libraries such as `libLLVM.so` and `libc++_shared.so`).

### 5.2 User-Generated Programs: Target SDK 28 vs WebAssembly Sandbox
- **Short-Term (Phase 1, Explicitly Experimental):** Sideloaded APK targeting API 28 (`targetSdkVersion = 28`) as an experimental research workaround, placing the app in the `untrusted_app_28` SELinux domain where direct execution of `app_data_file` is permitted. Not a production decision for app store distribution.
- **Long-Term (Phase 2):** Compilation to WebAssembly (`wasm32-wasi`) executed in-process via an embedded runtime (Wasm3 or Wasmer JNI) to achieve full Google Play compliance (targetSdk >= 34).
- **Termux `system_linker_exec` Status:** Acknowledged as Termux's current working workaround on `targetSdkVersion >= 29`. Because it relies on `LD_PRELOAD`, path rewrites, and dynamic linker wrapping, its suitability for Tanmatsu remains **unresolved** and under active observation.

---

## 6. Build, Testing & Development Policies

### 6.1 Agent Execution Rule: No Heavy Builds
To conserve execution tokens and prevent timeout failures:
1. **Never** run `cmake --build`, `ninja`, or multi-threaded toolchain cross-compilation inside the agent session.
2. **Never** launch lengthy Gradle builds inside the agent session.
3. Ordinary file inspection, source code analysis, dependency queries, and documentation updates are permitted.
4. Prepare reproducible shell scripts and manual step-by-step instructions in `docs/TOOLCHAIN_EXPERIMENTS.md`.
5. Require verified terminal outputs before advancing milestones.

### 6.2 Code Style and Conventions
- **Kotlin:** Follow official Kotlin coding conventions with explicit return types on public APIs.
- **Compose:** Use unidirectional data flow (State hoisting). ViewModels expose immutable `StateFlow` states and accept `Intent` / `Action` events.
- **ELF Inspection:** Every compiled native shared object or executable must be inspected via `llvm-readelf -d` and `llvm-readelf -l` to verify `DT_NEEDED`, `DT_RUNPATH`, `PT_INTERP`, and `$ORIGIN`.

---

## 7. Licensing & Attribution Considerations

| Component | License | Redistribution Terms |
|---|---|---|
| **LLVM / Clang / clangd / LLD** | Apache-2.0 with LLVM Exception | Permitted. Include copyright and Apache-2.0 notice. |
| **Android Bionic (Sysroot headers & CRT)** | BSD-2-Clause & Apache-2.0 | Permitted. Bionic headers and open-source CRT sources are BSD/Apache; raw proprietary Google NDK archives cannot be redistributed under SDK EULA. |
| **Sora Editor** | LGPL-2.1 | Permitted via dynamic Gradle linking. Any modifications to Sora Editor core must remain LGPL-2.1. |

---

## 8. Current Project Status & Milestones

### Project Status: Milestone 1 (Native Execution PoC) COMPLETED
Milestone 1 has been empirically completed and verified on physical hardware. Development advances to **Milestone 1.5: Dynamic Linker & Shared Library Resolution PoC** before commencing full LLVM builds.

### Milestones Ledger

| Milestone | Title | Status | Evidence / Verification |
|---|---|---|---|
| **M0** | Project Foundations & Technical Feasibility | **Completed** | Delivery of corrected `AGENTS.md`, `TECHNICAL_FEASIBILITY.md`, `ARCHITECTURE.md`, `DEVELOPMENT_ROADMAP.md`, `TOOLCHAIN_EXPERIMENTS.md`. |
| **M1** | Native Execution Proof-of-Concept (PoC) | **Completed / Passed** | Verified on Samsung SM-A065F (Android 16, API 36, `arm64-v8a`). `libtanmatsu_test_exec.so` extracted to `nativeLibraryDir`, executed via `ProcessBuilder`, exit code 0, 115ms duration, zero AVC denials. |
| **M1.5** | Dynamic Linker & Shared Library Resolution PoC | *Pending (Next)* | Smallest experiment: Package `libtanmatsu_dyn_test.so` depending on sibling `libtanmatsu_dep.so` and NDK `libc++_shared.so` via `$ORIGIN` to verify multi-library dynamic linking on device. |
| **M2** | Host Cross-Compilation of Minimal LLVM Toolchain | *Pending* | Manual host build producing stripped `libtanmatsu_clang.so`, `libtanmatsu_lld.so`, `libtanmatsu_clangd.so`, `libLLVM.so`. |
| **M3** | Canonical Sysroot Assembly & On-Device C17 Compile | *Pending* | Compiling `hello.c` to `a.out` using on-device Clang and canonical Bionic sysroot. |
| **M4** | On-Device clangd LSP Protocol Verification | *Pending* | Communicating with `libtanmatsu_clangd.so` via full LSP lifecycle over socket/LocalSocket bridge. |
| **M5** | Android IDE App Shell & Sora Editor Integration | *Pending* | Compose UI displaying Sora Editor with C syntax highlighting. |
| **M6** | Editor-LSP Integration & Live Diagnostics | *Pending* | Red wavy error underlines from clangd diagnostics rendered in Sora Editor. |
| **M7** | Build Orchestration & Execution Console | *Pending* | One-click compile and run inside Tanmatsu UI with interactive console. |

---

## 9. Verified Facts vs. Remaining Technical Uncertainties

### 9.1 Experimentally Verified Facts (Empirical Evidence)
1. **Standalone Native Executable Execution:** Android package manager correctly extracts ARM64 PIE binaries packaged as `.so` files in `jniLibs/arm64-v8a` into `context.applicationInfo.nativeLibraryDir` when `packaging.jniLibs.useLegacyPackaging = true`.
2. **Permissions & Execution:** Files in `nativeLibraryDir` obtain executable permissions (`canExecute() == true`). Standard `ProcessBuilder` spawns them on a background thread without `IOException` or `EACCES`.
3. **Android 16 Compatibility:** Dynamic linker `/system/bin/linker64` on Android 16 (API 36) executes ARM64 PIE binaries from `nativeLibraryDir` without SELinux AVC blocks.

### 9.2 Remaining Technical Uncertainties & Resolution Experiments

| Technical Uncertainty | Hypothesized Behavior | Smallest Resolving Experiment |
|---|---|---|
| **1. Dynamic Linker Sibling Library Resolution** | Dynamic linker will locate sibling `.so` files in `nativeLibraryDir` via `$ORIGIN` in `DT_RUNPATH` without needing `LD_LIBRARY_PATH`. | **Experiment 0.5 (Milestone 1.5):** Build a small C++ binary (`libtanmatsu_dyn_test.so`) calling a function in sibling `libtanmatsu_dep.so` and using `std::string` from `libc++_shared.so`, linked with `-Wl,-rpath,'$ORIGIN'`, and launch via `ProcessBuilder`. |
| **2. Dynamic Linker Library Resolution for LLVM** | `libtanmatsu_clang.so` will find `libLLVM.so` and `libclang-cpp.so` in `nativeLibraryDir`. | **Experiment 1 (Milestone 2):** Inspect ELF headers with `readelf -d` and run `libtanmatsu_clang.so --version` via ADB with and without `LD_LIBRARY_PATH`. |
| **3. Canonical Sysroot Resolution** | Clang driver resolves Bionic headers and CRT objects automatically using the complete NDK sysroot. | **Experiment 2 (Milestone 3):** Run Clang with `--target=aarch64-linux-android29 --sysroot=<path> --ld-path=<path> -fuse-ld=lld` on `hello.c` and verify via `-v` flag where headers and CRT objects are loaded from. |
| **4. Sora Editor LSP Transport (LocalSocket vs TCP)** | Sora `editor-lsp` supports `LocalSocket` (UNIX domain socket) which provides faster, port-free communication on Android. | **Experiment 3 (Milestone 4):** Implement a lightweight local socket bridge in Kotlin (`LocalServerSocket`) connecting `editor-lsp` to clangd's stdio streams. |
| **5. clangd Memory Footprint & Lifecycle** | clangd with `--background-index=false -j=2` will stay within reasonable memory bounds and complete full initialize/shutdown cycles cleanly. | **Experiment 4 (Milestone 4):** Measure `libtanmatsu_clangd.so` Resident Set Size (RSS) via `/proc/<pid>/statm` during editing and verify clean exit on `shutdown`/`exit` JSON-RPC messages. |
| **6. User-Compiled Binary Execution on API 29+** | Running user binaries in writable storage (`app_data_file`) requires either targetSdk 28, Wasm sandbox, or `system_linker_exec`. | **Experiment 5 (Milestone 3/7):** Compile `hello.c` on device into `filesDir` and attempt launch under `targetSdkVersion = 28`. |

---

## 10. AGENTS.md Maintenance Protocol

Whenever an agent or engineer completes a task:
1. Update the **Current Project Status** and mark the corresponding milestone in the **Milestones Ledger**.
2. Record concrete evidence (command output, file hashes, test results) before marking a milestone as completed.
3. Update **Remaining Technical Uncertainties** as hypotheses are verified or refuted.
4. Keep the document concise and focused on engineering realities.
