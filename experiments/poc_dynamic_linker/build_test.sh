#!/usr/bin/env bash
# build_test.sh — Host build and verification helper for Milestone 1.5 (Experiment 0.5)
# Validates NDK tools, compiles ARM64 shared library and PIE executable with $ORIGIN runpath,
# verifies all ELF dynamic tags automatically, and deploys artifacts to the Android PoC app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "======================================================================"
echo " Tanmatsu Milestone 1.5: Dynamic Linker & Shared Library Resolution"
echo "======================================================================"

# --------------------------------------------------------------------
# 1. Environment & NDK Validation
# --------------------------------------------------------------------
echo ""
echo "[Step 1/6] Validating Android NDK environment..."

if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
    if [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}/ndk" ]; then
        DETECTED_NDK=$(ls -1d "${ANDROID_HOME}/ndk/"* 2>/dev/null | sort -V | tail -n 1 || true)
        if [ -n "$DETECTED_NDK" ] && [ -d "$DETECTED_NDK" ]; then
            export ANDROID_NDK_ROOT="$DETECTED_NDK"
            echo "--> Auto-detected ANDROID_NDK_ROOT: $ANDROID_NDK_ROOT"
        fi
    fi
fi

if [ -z "${ANDROID_NDK_ROOT:-}" ] || [ ! -d "${ANDROID_NDK_ROOT}" ]; then
    echo "ERROR: ANDROID_NDK_ROOT is unset or invalid!" >&2
    echo "Please set ANDROID_NDK_ROOT to your Android NDK installation directory." >&2
    echo "Example: export ANDROID_NDK_ROOT=\$HOME/Android/Sdk/ndk/27.0.12077973" >&2
    exit 1
fi

echo "--> ANDROID_NDK_ROOT: $ANDROID_NDK_ROOT"

NDK_BIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin"
TARGET_API=29

# Verify Clang C compiler
NDK_CC=""
if [ -x "$NDK_BIN/aarch64-linux-android${TARGET_API}-clang" ]; then
    NDK_CC="$NDK_BIN/aarch64-linux-android${TARGET_API}-clang"
elif [ -x "$NDK_BIN/clang" ]; then
    NDK_CC="$NDK_BIN/clang --target=aarch64-linux-android${TARGET_API}"
else
    echo "ERROR: Unable to find AArch64 C compiler in $NDK_BIN" >&2
    exit 1
fi

# Verify Clang C++ compiler
NDK_CXX=""
if [ -x "$NDK_BIN/aarch64-linux-android${TARGET_API}-clang++" ]; then
    NDK_CXX="$NDK_BIN/aarch64-linux-android${TARGET_API}-clang++"
elif [ -x "$NDK_BIN/clang++" ]; then
    NDK_CXX="$NDK_BIN/clang++ --target=aarch64-linux-android${TARGET_API}"
else
    echo "ERROR: Unable to find AArch64 C++ compiler in $NDK_BIN" >&2
    exit 1
fi

# Verify ELF inspection tool
READELF=""
if [ -x "$NDK_BIN/llvm-readelf" ]; then
    READELF="$NDK_BIN/llvm-readelf"
elif command -v llvm-readelf >/dev/null 2>&1; then
    READELF="$(command -v llvm-readelf)"
elif command -v readelf >/dev/null 2>&1; then
    READELF="$(command -v readelf)"
else
    echo "ERROR: Unable to find llvm-readelf or readelf on host." >&2
    exit 1
fi

echo "--> Clang C Compiler   : $NDK_CC"
echo "--> Clang C++ Compiler : $NDK_CXX"
echo "--> ELF Inspector      : $READELF"

# --------------------------------------------------------------------
# 2. Locate Canonical ARM64 libc++_shared.so
# --------------------------------------------------------------------
echo ""
echo "[Step 2/6] Locating canonical ARM64 libc++_shared.so from NDK..."

NDK_SYSROOT_LIB="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
SOURCE_LIBCPP=""

if [ -f "$NDK_SYSROOT_LIB/libc++_shared.so" ]; then
    SOURCE_LIBCPP="$NDK_SYSROOT_LIB/libc++_shared.so"
elif [ -f "$NDK_SYSROOT_LIB/${TARGET_API}/libc++_shared.so" ]; then
    SOURCE_LIBCPP="$NDK_SYSROOT_LIB/${TARGET_API}/libc++_shared.so"
else
    # Fallback search across NDK directory for aarch64 libc++_shared.so
    DETECTED_LIBCPP=$(find "$ANDROID_NDK_ROOT" -name "libc++_shared.so" 2>/dev/null | grep -E "(aarch64|arm64-v8a)" | head -n 1 || true)
    if [ -n "$DETECTED_LIBCPP" ] && [ -f "$DETECTED_LIBCPP" ]; then
        SOURCE_LIBCPP="$DETECTED_LIBCPP"
    fi
fi

if [ -z "$SOURCE_LIBCPP" ] || [ ! -f "$SOURCE_LIBCPP" ]; then
    echo "ERROR: Unable to locate ARM64 libc++_shared.so in NDK!" >&2
    echo "Checked: $NDK_SYSROOT_LIB" >&2
    exit 1
fi

echo "--> Found libc++_shared.so at: $SOURCE_LIBCPP"
cp -f "$SOURCE_LIBCPP" ./libc++_shared.so
chmod 644 ./libc++_shared.so
echo "--> Copied libc++_shared.so to current directory ($(stat -c%s ./libc++_shared.so) bytes)"

# --------------------------------------------------------------------
# 3. Compile Sibling Shared Library libtanmatsu_dep.so
# --------------------------------------------------------------------
echo ""
echo "[Step 3/6] Compiling sibling shared library libtanmatsu_dep.so..."

$NDK_CC -shared -fPIC -O2 \
    -Wl,-soname,libtanmatsu_dep.so \
    dep.c -o libtanmatsu_dep.so

if [ ! -f "libtanmatsu_dep.so" ]; then
    echo "ERROR: Failed to compile libtanmatsu_dep.so" >&2
    exit 1
fi
echo "--> Successfully generated libtanmatsu_dep.so ($(stat -c%s libtanmatsu_dep.so) bytes)"

# --------------------------------------------------------------------
# 4. Compile Dynamic Test Executable libtanmatsu_dyn_test.so
# --------------------------------------------------------------------
echo ""
echo "[Step 4/6] Compiling PIE executable libtanmatsu_dyn_test.so with DT_RUNPATH=\$ORIGIN..."

# Linker flags breakdown:
#   -fPIE -pie                   : Position Independent Executable (ET_DYN with PT_INTERP and DF_1_PIE)
#   -stdlib=libc++               : Use LLVM libc++
#   -Wl,-rpath,'$ORIGIN'         : Set runpath to $ORIGIN (single quotes protect literal $ from shell)
#   -Wl,--enable-new-dtags       : Generate DT_RUNPATH instead of legacy DT_RPATH
#   -L.                          : Search current directory for libraries
#   -Wl,--no-as-needed           : Force DT_NEEDED entries for libtanmatsu_dep and libc++_shared
#   -ltanmatsu_dep -lc++_shared  : Sibling dependencies to resolve dynamically at runtime
#   -Wl,--as-needed              : Re-enable default as-needed behavior
$NDK_CXX -fPIE -pie -O2 \
    -stdlib=libc++ \
    -Wl,-rpath,'$ORIGIN' \
    -Wl,--enable-new-dtags \
    -L. \
    dyn_test.cpp \
    -Wl,--no-as-needed -ltanmatsu_dep -lc++_shared -Wl,--as-needed \
    -o libtanmatsu_dyn_test.so

if [ ! -f "libtanmatsu_dyn_test.so" ]; then
    echo "ERROR: Failed to compile libtanmatsu_dyn_test.so" >&2
    exit 1
fi
echo "--> Successfully generated libtanmatsu_dyn_test.so ($(stat -c%s libtanmatsu_dyn_test.so) bytes)"

# --------------------------------------------------------------------
# 5. Programmatic Gate 1 ELF Verification
# --------------------------------------------------------------------
echo ""
echo "[Step 5/6] Verifying ELF headers, program headers, and dynamic tags..."

PASS=true

# Helper to assert regex match in tool output
assert_match() {
    local label="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -qE "$pattern"; then
        echo "  [PASS] $label"
    else
        echo "  [FAIL] $label (Pattern not found: '$pattern')" >&2
        PASS=false
    fi
}

assert_no_match() {
    local label="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -qE "$pattern"; then
        echo "  [FAIL] $label (Unexpected pattern found: '$pattern')" >&2
        PASS=false
    else
        echo "  [PASS] $label"
    fi
}

# Helper to assert fixed string in tool output (avoids regex escaping issues with brackets and symbols)
assert_fixed() {
    local label="$1"
    local output="$2"
    local fixed_str="$3"
    if echo "$output" | grep -F -q "$fixed_str"; then
        echo "  [PASS] $label"
    else
        echo "  [FAIL] $label (Fixed string not found: '$fixed_str')" >&2
        PASS=false
    fi
}

echo "--- Verifying libtanmatsu_dep.so (Shared Library) ---"
DEP_HDR=$($READELF -h libtanmatsu_dep.so)
DEP_PHDR=$($READELF -l libtanmatsu_dep.so)
DEP_SYM=$($READELF -s libtanmatsu_dep.so)

assert_match "dep.so: Class is ELF64" "$DEP_HDR" "Class:.*ELF64"
assert_match "dep.so: Machine is AArch64" "$DEP_HDR" "Machine:.*AArch64"
assert_match "dep.so: Type is DYN" "$DEP_HDR" "Type:.*DYN"
assert_no_match "dep.so: Has NO INTERP segment" "$DEP_PHDR" "INTERP"
assert_match "dep.so: Exports get_tanmatsu_token symbol" "$DEP_SYM" "get_tanmatsu_token"

echo "--- Verifying libtanmatsu_dyn_test.so (PIE Executable) ---"
DYN_HDR=$($READELF -h libtanmatsu_dyn_test.so)
DYN_PHDR=$($READELF -l libtanmatsu_dyn_test.so)
DYN_DYN=$($READELF -d libtanmatsu_dyn_test.so)

assert_match "dyn_test: Class is ELF64" "$DYN_HDR" "Class:.*ELF64"
assert_match "dyn_test: Machine is AArch64" "$DYN_HDR" "Machine:.*AArch64"
assert_match "dyn_test: Type is DYN (PIE executable)" "$DYN_HDR" "Type:.*DYN"
assert_match "dyn_test: Has PT_INTERP segment requesting /system/bin/linker64" "$DYN_PHDR" "/system/bin/linker64"
assert_match "dyn_test: FLAGS_1 contains PIE" "$DYN_DYN" "FLAGS_1.*PIE"
assert_match "dyn_test: DT_NEEDED contains libtanmatsu_dep.so" "$DYN_DYN" "\(NEEDED\).*Shared library: \[libtanmatsu_dep\.so\]"
assert_match "dyn_test: DT_NEEDED contains libc++_shared.so" "$DYN_DYN" "\(NEEDED\).*Shared library: \[libc\+\+_shared\.so\]"

# Fixed-string checks for RUNPATH to avoid fragile regex parsing of brackets and dollar signs
assert_fixed "dyn_test: DT_RUNPATH tag exists" "$DYN_DYN" "(RUNPATH)"
assert_fixed "dyn_test: DT_RUNPATH contains Library runpath: [\$ORIGIN]" "$DYN_DYN" 'Library runpath: [$ORIGIN]'

echo "--- Verifying libc++_shared.so (NDK Runtime) ---"
CPP_HDR=$($READELF -h libc++_shared.so)
assert_match "libc++_shared: Class is ELF64" "$CPP_HDR" "Class:.*ELF64"
assert_match "libc++_shared: Machine is AArch64" "$CPP_HDR" "Machine:.*AArch64"

if [ "$PASS" = false ]; then
    echo ""
    echo "ERROR: One or more ELF verification assertions failed!" >&2
    exit 1
fi

echo ""
echo "======================================================================"
echo ">>> Gate 1 (Host ELF Verification): PASSED"
echo "======================================================================"

# --------------------------------------------------------------------
# 6. Automatic Deployment to Android PoC App
# --------------------------------------------------------------------
echo ""
echo "[Step 6/6] Staging native artifacts into PoC app jniLibs..."

APP_JNILIBS="../poc_native_exec/app/src/main/jniLibs/arm64-v8a"
if [ -d "$APP_JNILIBS" ]; then
    cp -vf libtanmatsu_dyn_test.so "$APP_JNILIBS/"
    cp -vf libtanmatsu_dep.so "$APP_JNILIBS/"
    cp -vf libc++_shared.so "$APP_JNILIBS/"
    echo "--> Staged all 3 artifacts into: $APP_JNILIBS"
    ls -lh "$APP_JNILIBS"
    echo ""
    echo "--> Note on Gate 2: Artifacts staged into jniLibs for APK packaging."
    echo "    Verification of Gate 2 (Extraction into nativeLibraryDir) occurs on device at runtime."
else
    echo "WARNING: $APP_JNILIBS directory not found. Please copy artifacts manually."
fi

echo ""
echo "======================================================================"
echo " Milestone 1.5 Host Build Complete — Ready for Device Verification"
echo "======================================================================"
echo ""
echo "Gate Status Summary:"
echo "  - Gate 1 (Host ELF Verification)          : PASSED"
echo "  - Gate 2 (nativeLibraryDir Extraction)    : Pending Device Verification"
echo "  - Gate 3 (Dynamic Linker Resolution)      : Pending Device Verification"
echo "  - Gate 4 (Program Execution & Output)     : Pending Device Verification"
echo "  - Gate 5 (SELinux AVC Denial Audit)       : Pending Device Verification"
echo ""
echo "Next Steps for Physical Device Verification (Gates 2-5):"
echo "  1. cd ../poc_native_exec"
echo "  2. ./gradlew assembleDebug"
echo "  3. adb install -r app/build/outputs/apk/debug/app-debug.apk"
echo "  4. adb shell am start -n org.tanmatsu.poc/.MainActivity"
echo "  5. adb logcat -s TanmatsuPoC -d"
echo "  6. adb logcat -d | grep -E 'avc:.*(org\.tanmatsu\.poc|libtanmatsu)'"
echo ""
