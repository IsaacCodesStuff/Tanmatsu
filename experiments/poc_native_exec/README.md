# Experiment 0: Minimal Native Execution Proof-of-Concept (PoC)

**Target Binary:** `libtanmatsu_test_exec.so`  
**Purpose:** Empirically verify that Android extracts native executables named `lib*.so` from an APK's `jniLibs` into `context.applicationInfo.nativeLibraryDir` using modern Android Gradle Plugin packaging (`useLegacyPackaging = true`), and that `ProcessBuilder` can execute the binary without triggering SELinux W^X denials.

> [!IMPORTANT]
> **Safety Rule:** All commands below are designed for **manual execution by the human developer**. Do not run automated builds in agent sessions.

---

## 1. Prerequisites & Required Toolchain Versions

- **Host OS:** Linux x86_64
- **Android NDK:** NDK r27 LTS (e.g. `27.0.12077973` or r26c)
- **JDK:** Java 17 or Java 21 (`java -version`)
- **Gradle:** Version 8.9 to 8.11 (recommended: `8.10.2`)
- **Android Gradle Plugin (AGP):** Version `8.7.2`
- **Target Device:** Physical Android hardware running Android 10, 11, 12, 13, 14, or 15 with USB Debugging enabled.

Export your NDK path:
```bash
export ANDROID_NDK_ROOT="$HOME/Android/Sdk/ndk/27.0.12077973"
# Or your local NDK path:
# export ANDROID_NDK_ROOT="$HOME/android-ndk-r27"
```

---

## 2. Step-by-Step Manual Execution

### Step 1: Compile `poc_test.c` to an ARM64 Position-Independent Executable (PIE)

```bash
cd experiments/poc_native_exec

# Compile using NDK Clang targeting ARM64 as a Position-Independent Executable (PIE)
$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang \
    -fPIE -pie -O2 poc_test.c -o libtanmatsu_test_exec.so
```

---

### Step 2: Comprehensive ELF Header & Program Header Verification

Both Position-Independent Executables (PIE) and shared libraries (`.so`) are encoded with the ELF type `ET_DYN` (`Type: DYN`). **ELF type `DYN` alone does not distinguish an executable from a shared library.**

What differentiates a PIE executable from a shared library is:
1. **The Program Interpreter Header (`PT_INTERP`):** Standalone executables contain a `PT_INTERP` segment instructing the Linux kernel to load the dynamic linker (`/system/bin/linker64`). Shared libraries do not have an interpreter segment because they are loaded into an existing process via `dlopen()`.
2. **The Executable Entry Point:** Standalone executables define an entry point address (`_start`) invoked upon process execution.

Run the following commands to verify all required ELF properties:

```bash
READELF="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"

# 1. Verify ELF Class is ELF64
$READELF -h libtanmatsu_test_exec.so | grep "Class:"
# Expected: Class: ELF64

# 2. Verify Machine Architecture is AArch64
$READELF -h libtanmatsu_test_exec.so | grep "Machine:"
# Expected: Machine: AArch64

# 3. Verify ELF Type is DYN
$READELF -h libtanmatsu_test_exec.so | grep "Type:"
# Expected: Type: DYN (Position-Independent Executable file) or (Shared object file)

# 4. Verify Entry Point is a valid non-zero address
$READELF -h libtanmatsu_test_exec.so | grep "Entry point address:"
# Expected: Entry point address: 0x... (non-zero)

# 5. Verify Program Header contains PT_INTERP pointing to /system/bin/linker64
$READELF -l libtanmatsu_test_exec.so | grep -A 1 "INTERP"
# Expected Output:
#   INTERP         0x... 0x... 0x...
#       [Requesting program interpreter: /system/bin/linker64]
```

---

### Step 3: Copy Binary into App `jniLibs`

```bash
mkdir -p app/src/main/jniLibs/arm64-v8a
cp libtanmatsu_test_exec.so app/src/main/jniLibs/arm64-v8a/
```

---

### Step 4: Configure Gradle & Build Test APK

#### Packaging Directive Explanation
In `app/build.gradle.kts`:
```kotlin
android {
    packaging {
        jniLibs {
            // Tells AGP to compress the native library in the APK, signaling the
            // Android package manager (installd) to extract it to nativeLibraryDir on installation.
            useLegacyPackaging = true
        }
    }
}
```
> [!NOTE]
> `useLegacyPackaging = true` controls the packaging format inside the APK. If Android App Bundles (`.aab`) were used, the equivalent property would be `useLegacyPackagingFromBundle = true`. However, setting this flag is merely a build-time directive; **actual on-device extraction and execution permissions must still be confirmed at runtime on the physical device.**

#### Building the APK
Build the debug APK using the included Gradle wrapper (or open the project in Android Studio):

```bash
cd experiments/poc_native_exec

# Build debug APK (requires JDK 17 or JDK 21)
./gradlew assembleDebug
```

---

### Step 5: Install APK onto Physical Android Device

```bash
# Verify ADB connection to physical device
adb devices

# Install APK onto device
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

---

### Step 6: Launch App & Inspect Execution Output

```bash
# Clear device logcat
adb logcat -c

# Launch MainActivity
adb shell am start -n org.tanmatsu.poc/.MainActivity

# Check application output via tag TanmatsuPoC
adb logcat -s TanmatsuPoC -d
```

---

### Step 7: Investigate Relevant SELinux Denials

Do not look for generic, unrelated device AVC messages. Specifically filter for AVC denials related to the PoC package or binary:

```bash
adb logcat -d | grep -E 'avc:.*(org\.tanmatsu\.poc|libtanmatsu_test_exec)'
```
*Expected:* No AVC denial entries mentioning `org.tanmatsu.poc` or `libtanmatsu_test_exec`.

---

## 3. Expected Acceptance Output

### Logcat Output (`adb logcat -s TanmatsuPoC -d`):
```text
TanmatsuPoC: === Tanmatsu Native Execution PoC ===
TanmatsuPoC: Android OS: 14 (API 34)
TanmatsuPoC: Device: Google Pixel 7
TanmatsuPoC: ABI: arm64-v8a
TanmatsuPoC: nativeLibraryDir: /data/app/~~.../org.tanmatsu.poc-.../lib/arm64
TanmatsuPoC: Binary path: /data/app/~~.../org.tanmatsu.poc-.../lib/arm64/libtanmatsu_test_exec.so
TanmatsuPoC: File exists: true
TanmatsuPoC: File size: 14856 bytes
TanmatsuPoC: canRead: true, canExecute: true
TanmatsuPoC: Working directory: /data/user/0/org.tanmatsu.poc/cache (writable: true)
TanmatsuPoC: --- Spawning Process via ProcessBuilder ---
TanmatsuPoC: Process exited with code: 0 (took 22ms)
TanmatsuPoC: STDOUT: POC_SUCCESS: Native ARM64 PIE executed via ProcessBuilder PID=...
TanmatsuPoC: >>> RESULT: SUCCESS! Native executable executed without SELinux block.
```

---

## 4. Distinct Pass / Fail Acceptance Gates

Before declaring this PoC successful, verify each gate independently:

- [ ] **Gate 1 (ELF Format Verified on Host):**
  - Class is `ELF64`
  - Machine is `AArch64`
  - Type is `DYN`
  - `PT_INTERP` segment is present and points to `/system/bin/linker64`
  - Entry point address is non-zero
- [ ] **Gate 2 (File Extraction Verified on Device):**
  - `File(nativeLibraryDir, "libtanmatsu_test_exec.so").exists()` is `true`
  - `File.canExecute()` is `true`
- [ ] **Gate 3 (Process Launch Verified on Device):**
  - `ProcessBuilder.start()` succeeds on background thread without `IOException` or `EACCES`
  - Process does not deadlock or exceed the 5-second timeout
- [ ] **Gate 4 (Execution Output Verified on Device):**
  - Standard output contains `"POC_SUCCESS"`
  - Exit code is `0`
- [ ] **Gate 5 (Relevant SELinux Denials Investigated):**
  - Zero AVC denials referencing `org.tanmatsu.poc` or `libtanmatsu_test_exec` in `logcat`.

---

## 5. Decision Gate

- **If all 5 gates pass on physical devices:** The hypothesis that APK native libraries can be executed via `ProcessBuilder` without SELinux violation is verified. Record verified evidence in `AGENTS.md` and advance to **Milestone 2 (Host Cross-Compilation of Minimal LLVM Toolchain)**.
- **If execution fails (e.g. `EACCES` or SELinux denial on `apk_data_file`):** Stop and investigate alternative execution architectures before building LLVM.
