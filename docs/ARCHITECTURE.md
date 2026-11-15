# Architecture Proposal: Tanmatsu C IDE

**Document Version:** 2.1 (Revised Technical Baseline)  
**Status:** Approved Design  
**Date:** November 2026  

---

## 1. Architectural Goals & Core Principles

Tanmatsu is engineered as a lightweight, robust, native C IDE for Android. The architecture is guided by four principles:

1. **Process Boundary Isolation:**
   Toolchain utilities (Clang, LLD, clangd) run as isolated OS processes rather than in-process shared libraries. A crash, segfault, or infinite loop in a compiler invocation or user program will never crash the Android application or corrupt the user's unsaved buffers.
2. **Lifecycle Specialization:**
   Different process types have fundamentally different lifecycles:
   - **Compiler / Linker:** Ephemeral batch processes executed to completion with full output capture.
   - **Language Server (clangd):** Long-running stateful daemons communicating via two-way JSON-RPC streams synchronized with document edits.
   - **User Programs:** Supervised interactive processes attached to terminal emulators or redirected console streams with execution timeouts.
3. **Modular Layering without Overengineering:**
   Components are decoupled through clean Kotlin interfaces and reactive `StateFlow` streams. We deliberately avoid complex dynamic plugin or extension architectures in this initial phase.
4. **Android Platform Fidelity:**
   Follows modern Android architecture guidelines (Unidirectional Data Flow, ViewModels, Repository pattern, Jetpack Compose UI, Coroutines for asynchronous I/O).

---

## 2. Four Distinct Android API Levels & Target Compatibility Rule

To ensure architectural clarity across all modules:

1. **Host App `minSdkVersion` (e.g. 26/28):** Minimum OS version required for an Android device to install the Tanmatsu APK.
2. **Host App `targetSdkVersion = 28`:** Preserves access to the `untrusted_app_28` SELinux domain, allowing direct execution of user-compiled `a.out` binaries.
3. **Bundled Toolchain Host Minimum API (NDK Platform Level, e.g. `android-26`):** The Bionic API baseline against which `libtanmatsu_clang.so`, `libtanmatsu_lld.so`, and `libtanmatsu_clangd.so` are linked.
4. **User Program Target API Level (`--target=aarch64-linux-android<API>`):** The Bionic API baseline targeted by compiled user C programs (e.g. API 29), linking against compile-time dynamic stubs in `<sysroot>/usr/lib/aarch64-linux-android/29/libc.so`.

### Crucial Device-Target Compatibility Rule
$$\text{User Target API Level} \le \text{Device Physical OS API Level}$$
Compiled user binaries rely on dynamic libc symbols present on the physical device. If a user targets API 29 and attempts to run on an API 28 device, the Android dynamic linker will abort with unresolved symbol errors. The IDE will enforce/warn that the target API must not exceed the running device's API level.

---

## 3. System Overview & Module Decomposition

```
+---------------------------------------------------------------------------------+
|                                 UI Layer (Jetpack Compose)                      |
|  - MainScreen / WorkspaceView                                                   |
|  - SoraEditorWrapper (AndroidView hosting CodeEditor)                           |
|  - FileTreeDrawer / ProjectExplorer                                             |
|  - BuildOutputPanel / DiagnosticsList                                           |
|  - TerminalConsolePanel (Interactive Stdio)                                     |
+---------------------------------------------------------------------------------+
                                       |
                                       v
+---------------------------------------------------------------------------------+
|                               IDE Core Layer                                    |
|  - ProjectManager (Workspace state, project roots)                              |
|  - DocumentManager (Buffer management, dirty state, file saving)                |
|  - BuildOrchestrator (State machine: Compile -> Link -> Run)                    |
|  - DiagnosticsCoordinator (Coordinates diagnostics between LSP and Editor)     |
+---------------------------------------------------------------------------------+
                    |                                         |
                    v                                         v
+------------------------------------+   +----------------------------------------+
|       C Language Integration       |   |         Native Infrastructure          |
|  - ClangDriver (Compiler flags)    |   |  - ProcessManager (Process lifecycle)  |
|  - ClangdSocketBridge (LocalSocket)|   |  - NativeToolchainManager (Binaries)   |
|  - CompileCommandsGenerator        |   |  - SysrootManager (Complete NDK layout)|
|  - CToolchainConfig                |   |  - ConsoleStreamBuffer (Stdio piping)  |
+------------------------------------+   +----------------------------------------+
                    \                                         /
                     \                                       /
                      v                                     v
+---------------------------------------------------------------------------------+
|                       OS & Execution Layer (Android Bionic)                     |
|  - nativeLibraryDir (/data/app/.../lib/arm64/libtanmatsu_clang.so, etc.)        |
|  - Internal Files Storage (/data/user/0/.../files/sysroot, /files/projects)     |
|  - Linux Pipes & ProcessBuilder (fork/execve via Bionic libc)                   |
|  - Device System Bionic Libraries (/system/lib64/libc.so, etc.)                 |
+---------------------------------------------------------------------------------+
```

---

## 4. Component Responsibilities & Module Contracts

### 4.1 IDE Core (`core:*`)

- **`ProjectManager`:**
  - Tracks the currently open project directory on device storage.
  - Monitors file creation, deletion, and renaming within the project tree.
  - Automatically triggers compilation database generation when project layout changes.
- **`DocumentManager`:**
  - Maintains open document buffers in memory.
  - Tracks dirty/modified states and coordinates auto-saving.
  - Emits document change events to the language server (`didOpen`, `didChange`, `didClose`).
- **`BuildOrchestrator`:**
  - Coordinates the multi-step build workflow:
    1. Save dirty documents to disk.
    2. Invoke `libtanmatsu_clang.so` on source files.
    3. Invoke `libtanmatsu_lld.so` via `--ld-path` and `-fuse-ld=lld` to link object files into an executable.
    4. Report compiler warnings/errors to `DiagnosticsCoordinator`.
    5. Hand off successful executables to `UserProgramRunner`.
- **`DiagnosticsCoordinator`:**
  - Aggregates diagnostics from two sources:
    - Real-time diagnostics streamed from clangd over LSP.
    - Batch diagnostics parsed from Clang compiler stderr output.
  - Translates LSP diagnostic coordinates into Sora Editor marker regions.

---

### 4.2 C Language Integration (`lang:c:*`)

- **`ClangDriver`:**
  - Formulates the exact argument list required to invoke `libtanmatsu_clang.so`:
    - Target triple: `--target=aarch64-linux-android<API>`.
    - Sysroot path: `--sysroot=<internal_storage>/sysroot`.
    - Clang resource directory: `-resource-dir=<internal_storage>/clang_res`.
    - Explicit linker invocation: `--ld-path=<nativeLibraryDir>/libtanmatsu_lld.so -fuse-ld=lld`.
    - Standard warnings and optimization flags (`-Wall -Wextra -O2`).
  - Executes Clang via `ProcessManager` and parses output streams into structured error objects.
- **`ClangdSocketBridge`:**
  - Spawns `libtanmatsu_clangd.so` as a background daemon with redirected stdio.
  - Opens an Android `LocalServerSocket` (UNIX domain socket in abstract namespace).
  - Forwards byte streams between the `LocalSocket` and clangd's stdin/stdout streams.
  - Feeds the local socket address to Sora Editor's `editor-lsp` extension (`connection { localSocket(address) }`).
- **`CompileCommandsGenerator`:**
  - Inspects project C source files.
  - Writes a valid `compile_commands.json` compilation database into the project root directory.

---

### 4.3 Native Infrastructure (`infra:*`)

- **`NativeToolchainManager`:**
  - Locates bundled native executables (`libtanmatsu_clang.so`, `libtanmatsu_clangd.so`, `libtanmatsu_lld.so`) in `context.applicationInfo.nativeLibraryDir`.
  - Verifies executable permissions (`canExecute()`).
  - Manages asset extraction on first launch (extracting the complete canonical NDK sysroot and Clang resource directory into private app storage).
- **`ProcessManager`:**
  - Abstract process execution engine supporting distinct execution models:
    - `BatchProcess`: Synchronously runs a process with timeout and gathers stdout/stderr into strings.
    - `DaemonProcess`: Asynchronously pipes stdin and stdout streams to a coroutine channel.
    - `InteractiveProcess`: Attaches standard I/O to a live terminal console.
  - Manages environment variables and shared-library resolution:
    - Standalone PIE execution from `nativeLibraryDir` is verified on Android 16 (Milestone 1).
    - For multi-library toolchain binaries (`libtanmatsu_clang.so` requiring `libLLVM.so` and `libc++_shared.so`), `ProcessManager` verifies that `DT_RUNPATH` with `$ORIGIN` resolves sibling libraries, or injects `LD_LIBRARY_PATH` pointing to `nativeLibraryDir` if needed (evaluated in Milestone 1.5).
- **`UserProgramRunner`:**
  - Supervises the execution of compiled user binaries (`a.out`).
  - Implements execution limits (maximum runtime timeout to prevent infinite loops).
  - Captures program exit codes and standard error/output for display in the IDE console.

---

## 5. Storage & Directory Layout

To comply with Android sandboxing and preserve the complete canonical NDK sysroot layout:

```text
/data/app/<app-id>-<hash>/lib/arm64/                 <-- nativeLibraryDir (Read-Only, Executable)
├── libtanmatsu_clang.so                            (Clang compiler executable)
├── libtanmatsu_clangd.so                           (clangd LSP daemon executable)
├── libtanmatsu_lld.so                              (LLD linker executable)
├── libLLVM.so                                      (Shared LLVM engine)
├── libclang-cpp.so                                 (Shared Clang libraries)
└── libc++_shared.so                                (NDK C++ runtime library)

/data/user/0/org.tanmatsu.ide/files/                 <-- Internal Private Storage (Writable)
├── sysroot/                                        <-- Complete Canonical NDK Sysroot
│   └── usr/
│       ├── include/                                <-- Complete C/POSIX headers
│       │   ├── aarch64-linux-android/              <-- Arch-specific headers (asm/, etc.)
│       │   ├── android/                            <-- Android OS platform headers
│       │   ├── sys/                                <-- System headers
│       │   └── linux/                              <-- Linux kernel headers
│       └── lib/
│           └── aarch64-linux-android/
│               ├── 29/                             <-- Target API compile-time stubs
│               │   ├── crtbegin_dynamic.o          <-- Bionic C runtime startup object
│               │   ├── crtend_android.o            <-- Bionic C runtime exit object
│               │   ├── libc.so                     <-- Compile-time stub ONLY
│               │   ├── libm.so                     <-- Compile-time stub ONLY
│               │   └── libdl.so                    <-- Compile-time stub ONLY
│               ├── libc++_shared.so
│               └── libc++_static.a
├── clang_res/                                      <-- Clang Resource Directory
│   ├── include/                                    <-- Internal compiler headers (stdarg.h, stddef.h, stdbool.h)
│   └── lib/
│       └── linux/
│           └── libclang_rt.builtins-aarch64-android.a <-- Prebuilt NDK compiler builtins
└── projects/                                       <-- User workspaces
    └── MyCProject/
        ├── .tanmatsu/
        │   ├── build/                              (Object files: main.o)
        │   └── bin/                                (Output executable: a.out)
        ├── compile_commands.json                   (Generated compilation database)
        └── main.c                                  (User source file)
```

---

## 6. Key Interface Specifications

### 6.1 Process Runner Interface
```kotlin
package org.tanmatsu.infra.process

import kotlinx.coroutines.flow.Flow
import java.io.File

sealed interface ProcessEvent {
    data class StandardOutput(val text: String) : ProcessEvent
    data class StandardError(val text: String) : ProcessEvent
    data class Exited(val exitCode: Int) : ProcessEvent
}

interface ProcessRunner {
    suspend fun executeBatch(
        executable: File,
        arguments: List<String>,
        workingDirectory: File,
        environment: Map<String, String> = emptyMap(),
        timeoutMs: Long = 30_000L
    ): BatchExecutionResult

    fun startInteractive(
        executable: File,
        arguments: List<String>,
        workingDirectory: File,
        environment: Map<String, String> = emptyMap()
    ): InteractiveProcessSession
}

data class BatchExecutionResult(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
    val durationMs: Long
)

interface InteractiveProcessSession {
    val events: Flow<ProcessEvent>
    suspend fun writeInput(text: String)
    suspend fun sendSignal(signal: Int)
    fun terminate()
}
```

### 6.2 Clangd LocalSocket Bridge Interface
```kotlin
package org.tanmatsu.lang.c.lsp

import java.io.File

interface ClangdSocketBridge {
    val socketAddress: String
    val isRunning: Boolean

    suspend fun start(
        clangdExecutable: File,
        projectRoot: File,
        compileCommandsDir: File,
        additionalFlags: List<String> = emptyList()
    )

    suspend fun stop()
}
```

---

## 7. Packaging Configuration in `app/build.gradle.kts`

```kotlin
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "org.tanmatsu"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.tanmatsu"
        minSdk = 28
        targetSdk = 28 // Compatibility mode for user executable launching
        versionCode = 1
        versionName = "1.0"

        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // Forces AGP and Package Manager to extract native libraries to nativeLibraryDir
            useLegacyPackaging = true
        }
    }
}
```
