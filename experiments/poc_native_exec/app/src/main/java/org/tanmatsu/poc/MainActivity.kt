package org.tanmatsu.poc

import android.os.Bundle
import android.util.Log
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "TanmatsuPoC"
        private const val PROCESS_TIMEOUT_SECONDS = 5L
    }

    private lateinit var textView: TextView
    private val logBuffer = StringBuilder()

    private fun appendLog(msg: String) {
        Log.i(TAG, msg)
        runOnUiThread {
            logBuffer.append(msg).append("\n")
            if (!isFinishing && !isDestroyed) {
                textView.text = logBuffer.toString()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        textView = TextView(this).apply {
            textSize = 14f
            setPadding(32, 32, 32, 32)
            typeface = android.graphics.Typeface.MONOSPACE
        }

        val scrollView = ScrollView(this).apply {
            addView(textView)
        }
        setContentView(scrollView)

        // Execute process launch and stream consumption on a background thread to prevent blocking Android main thread (ANR)
        thread(name = "PoC-Runner") {
            runPoCTest()
        }
    }

    private fun runPoCTest() {
        appendLog("=== Tanmatsu Native Execution PoC ===")
        appendLog("Android OS: ${android.os.Build.VERSION.RELEASE} (API ${android.os.Build.VERSION.SDK_INT})")
        appendLog("Device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        appendLog("ABI: ${android.os.Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"}")

        val nativeDir = applicationInfo.nativeLibraryDir
        appendLog("nativeLibraryDir: $nativeDir")

        // Audit presence of M1.5 artifacts in nativeLibraryDir (Gate 2 verification)
        val dynTestFile = File(nativeDir, "libtanmatsu_dyn_test.so")
        val depFile = File(nativeDir, "libtanmatsu_dep.so")
        val libcppFile = File(nativeDir, "libc++_shared.so")
        val legacyTestFile = File(nativeDir, "libtanmatsu_test_exec.so")

        appendLog("--- Auditing Native Artifacts in nativeLibraryDir ---")
        appendLog("libtanmatsu_dyn_test.so : exists=${dynTestFile.exists()}, size=${dynTestFile.length()}B, exec=${dynTestFile.canExecute()}")
        appendLog("libtanmatsu_dep.so      : exists=${depFile.exists()}, size=${depFile.length()}B, exec=${depFile.canExecute()}")
        appendLog("libc++_shared.so        : exists=${libcppFile.exists()}, size=${libcppFile.length()}B, exec=${libcppFile.canExecute()}")
        appendLog("libtanmatsu_test_exec.so: exists=${legacyTestFile.exists()}, size=${legacyTestFile.length()}B, exec=${legacyTestFile.canExecute()}")

        // Select binary: prefer M1.5 dynamic test binary if present
        val isM15Mode = dynTestFile.exists()
        val binaryFile = when {
            isM15Mode -> dynTestFile
            legacyTestFile.exists() -> legacyTestFile
            else -> dynTestFile
        }

        appendLog("Selected binary: ${binaryFile.name}")
        appendLog("Binary path: ${binaryFile.absolutePath}")

        if (!binaryFile.exists()) {
            appendLog("ERROR: Target binary ${binaryFile.name} not found in nativeLibraryDir!")
            appendLog("Verify that packaging.jniLibs.useLegacyPackaging = true in build.gradle.kts")
            appendLog("and all .so files are placed in app/src/main/jniLibs/arm64-v8a/")
            appendLog(">>> RESULT: FAILED (Artifact missing)")
            return
        }

        if (isM15Mode && (!depFile.exists() || !libcppFile.exists())) {
            appendLog("WARNING: Sibling dependencies missing from nativeLibraryDir!")
            if (!depFile.exists()) appendLog("  Missing: libtanmatsu_dep.so")
            if (!libcppFile.exists()) appendLog("  Missing: libc++_shared.so")
            appendLog("Dynamic linker resolution will fail without sibling libraries.")
        }

        appendLog("canRead: ${binaryFile.canRead()}, canExecute: ${binaryFile.canExecute()}")

        // Use cacheDir as a suitable writable working directory rather than the read-only nativeLibraryDir
        val workingDir = cacheDir
        appendLog("Working directory: ${workingDir.absolutePath} (writable: ${workingDir.canWrite()})")

        try {
            appendLog("--- Spawning Process via ProcessBuilder ---")
            val startTime = System.currentTimeMillis()

            val processBuilder = ProcessBuilder(binaryFile.absolutePath)
            processBuilder.directory(workingDir)

            // Strictly ensure LD_LIBRARY_PATH is NOT set so we test $ORIGIN runpath resolution
            processBuilder.environment()["PATH"] = System.getenv("PATH") ?: "/system/bin"
            processBuilder.environment().remove("LD_LIBRARY_PATH")
            appendLog("LD_LIBRARY_PATH: ${processBuilder.environment()["LD_LIBRARY_PATH"] ?: "[unset - testing DT_RUNPATH \$ORIGIN]"}")

            val process = processBuilder.start()

            // Track concurrent stream consumption and ensure streams finish cleanly
            var stdoutText = ""
            var stderrText = ""
            var stdoutFinished = false
            var stderrFinished = false
            var streamException: Throwable? = null

            val stdoutThread = thread(name = "stdout-consumer") {
                try {
                    stdoutText = process.inputStream.bufferedReader().use { it.readText() }.trim()
                    stdoutFinished = true
                } catch (t: Throwable) {
                    streamException = t
                }
            }
            val stderrThread = thread(name = "stderr-consumer") {
                try {
                    stderrText = process.errorStream.bufferedReader().use { it.readText() }.trim()
                    stderrFinished = true
                } catch (t: Throwable) {
                    if (streamException == null) streamException = t
                }
            }

            // Enforce process timeout
            val finished = process.waitFor(PROCESS_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            val durationMs = System.currentTimeMillis() - startTime

            if (!finished) {
                appendLog("ERROR: Process timed out after ${PROCESS_TIMEOUT_SECONDS}s! Terminating...")
                process.destroyForcibly()

                // Wait for the forcibly terminated process to exit to ensure proper cleanup
                val terminated = process.waitFor(2, TimeUnit.SECONDS)
                if (!terminated) {
                    appendLog("WARNING: Process did not exit within 2s after destroyForcibly")
                } else {
                    val termExit = try { process.exitValue() } catch (_: Exception) { -1 }
                    appendLog("Process terminated (exit code: $termExit)")
                }

                stdoutThread.join(500)
                stderrThread.join(500)
                appendLog(">>> RESULT: TIMED OUT")
                return
            }

            // Wait for stream consumption threads to complete
            stdoutThread.join(2000)
            stderrThread.join(2000)

            // Guard against reporting success if stream collection did not finish
            if (!stdoutFinished || !stderrFinished) {
                appendLog("ERROR: Stream collection did not finish cleanly!")
                appendLog("  stdoutFinished=$stdoutFinished, stderrFinished=$stderrFinished")
                if (streamException != null) {
                    appendLog("  Stream exception: ${streamException?.message}")
                }
                appendLog(">>> RESULT: FAILED (Incomplete stream collection)")
                return
            }

            val exitCode = process.exitValue()
            appendLog("Process exited with code: $exitCode (took ${durationMs}ms)")

            if (stdoutText.isNotEmpty()) {
                appendLog("STDOUT:\n$stdoutText")
            } else {
                appendLog("STDOUT: [empty]")
            }

            if (stderrText.isNotEmpty()) {
                appendLog("STDERR:\n$stderrText")
            }

            val expectedToken = if (isM15Mode) {
                "DYN_SUCCESS: Sibling shared library linked! Token=4242"
            } else {
                "POC_SUCCESS"
            }

            val matchesExpected = stdoutText.contains(expectedToken)
            if (exitCode == 0 && matchesExpected) {
                if (isM15Mode) {
                    appendLog(">>> RESULT: SUCCESS! Sibling shared library and libc++_shared resolved via \$ORIGIN without LD_LIBRARY_PATH.")
                } else {
                    appendLog(">>> RESULT: SUCCESS! Native executable executed successfully.")
                }
                appendLog("Note: Dynamic linking success does not independently prove absence of SELinux denials. Perform Gate 5 logcat audit separately.")
            } else {
                appendLog(">>> RESULT: FAILED! Non-zero exit code ($exitCode) or missing expected message.")
                if (!matchesExpected) {
                    appendLog("Expected stdout to contain: \"$expectedToken\"")
                }
            }

        } catch (e: Exception) {
            appendLog("EXCEPTION during process execution: ${e.message}")
            Log.e(TAG, "ProcessBuilder failed", e)
            appendLog(">>> RESULT: FAILED (Exception: ${e.javaClass.simpleName})")
        }
    }
}
