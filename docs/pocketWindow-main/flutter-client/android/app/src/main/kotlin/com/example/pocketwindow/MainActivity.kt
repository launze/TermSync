package com.example.pocketwindow

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private data class InstallValidationError(
        val code: String,
        val message: String,
    )

    private var h264VideoDecoder: H264VideoDecoder? = null
    private var h264WorkerThread: HandlerThread? = null
    private var h264WorkerHandler: Handler? = null
    private val mainHandler: Handler by lazy { Handler(mainLooper) }

    // Heartbeat infrastructure. Two independent loops:
    //   1) Native loop (HandlerThread) writes a line to native_heartbeat.log
    //      every 2s. This proves the Android process / our JVM is alive even
    //      if the UI thread is jammed - which is exactly what we suspect on
    //      foreground resume.
    //   2) Dart loop (Timer in control_screen.dart) writes a line to
    //      dart_heartbeat.log via a method-channel call into Kotlin. If Dart
    //      side is alive but the Android UI thread is blocked, the Dart log
    //      will keep growing while native ping reverse calls (delivered on
    //      the UI thread) stop arriving.
    //   3) On top of that, the UI thread posts a reverse "native_ping" so
    //      Dart can record `last_native_ping_age_ms` in its own log,
    //      revealing UI-thread stalls from Dart's perspective.
    private var heartbeatChannel: MethodChannel? = null
    private var nativeHeartbeatThread: HandlerThread? = null
    private var nativeHeartbeatHandler: Handler? = null
    private var heartbeatDir: File? = null
    private var nativeHeartbeatTick: Long = 0L
    @Volatile private var heartbeatLifecycle: String = "init"
    private val nativeHeartbeatRunnable = object : Runnable {
        override fun run() {
            nativeHeartbeatTick++
            appendHeartbeatLine(
                "native_heartbeat.log",
                "{\"ts_ms\":${System.currentTimeMillis()}," +
                    "\"tick\":$nativeHeartbeatTick," +
                    "\"thread\":\"native_worker\"," +
                    "\"lifecycle\":\"$heartbeatLifecycle\"}",
            )
            nativeHeartbeatHandler?.postDelayed(this, 2000L)
        }
    }
    private val mainThreadPingRunnable = object : Runnable {
        override fun run() {
            heartbeatChannel?.invokeMethod("native_ping", System.currentTimeMillis())
            mainHandler.postDelayed(this, 2000L)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        h264VideoDecoder = H264VideoDecoder(flutterEngine.renderer)
        // Dedicated background thread for MediaCodec operations.
        // start/stop/pushFrame can each block the calling thread for hundreds
        // of milliseconds (sometimes seconds during reconfigure). Running
        // them on the Android main thread freezes Flutter's UI isolate,
        // stalls Dart Timers, and produces the "frozen UI on resume" bug.
        h264WorkerThread = HandlerThread("PocketWindow-H264Worker").also { it.start() }
        h264WorkerHandler = Handler(h264WorkerThread!!.looper)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pocketwindow/app_update",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> handleInstallApk(call, result)
                "canRequestPackageInstalls" -> result.success(canInstallPackages())
                "currentVersionCode" -> result.success(currentVersionCode())
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pocketwindow/h264_video",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> handleH264StartAsync(call, result)
                "pushFrame" -> dispatchH264(call, result, ::handleH264PushFrameSync)
                "stop" -> dispatchH264(call, result, ::handleH264StopSync)
                else -> result.notImplemented()
            }
        }
        heartbeatChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pocketwindow/isolate_heartbeat",
        )
        heartbeatChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart asks "where do I write my heartbeat file?". We hand
                // back an absolute path so the Dart side can write directly
                // without going through path_provider on the slow path.
                "getHeartbeatDir" -> result.success(heartbeatDir?.absolutePath)
                // Dart writes a heartbeat line. We persist on whatever thread
                // the channel hands us (binary messenger thread); File append
                // is short enough that this is fine, and crucially does NOT
                // touch the Android UI thread, so a frozen UI thread cannot
                // hide a live Dart isolate.
                "writeDartHeartbeat" -> {
                    val line = call.argument<String>("line").orEmpty()
                    if (line.isNotEmpty()) {
                        appendHeartbeatLine("dart_heartbeat.log", line)
                    }
                    result.success(null)
                }
                "setLifecycle" -> {
                    heartbeatLifecycle = call.argument<String>("state").orEmpty()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        heartbeatDir = File(filesDir, "diagnostics").apply { mkdirs() }
        nativeHeartbeatThread = HandlerThread("PocketWindow-Heartbeat").also { it.start() }
        nativeHeartbeatHandler = Handler(nativeHeartbeatThread!!.looper).also {
            it.postDelayed(nativeHeartbeatRunnable, 2000L)
        }
        mainHandler.postDelayed(mainThreadPingRunnable, 2000L)
    }

    private fun appendHeartbeatLine(fileName: String, line: String) {
        val dir = heartbeatDir ?: return
        try {
            FileOutputStream(File(dir, fileName), true).use { out ->
                out.write((line + "\n").toByteArray(Charsets.UTF_8))
            }
        } catch (_: Exception) {
            // Heartbeat must never throw; swallow IO errors.
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mainHandler.removeCallbacks(mainThreadPingRunnable)
        nativeHeartbeatHandler?.removeCallbacks(nativeHeartbeatRunnable)
        nativeHeartbeatHandler = null
        nativeHeartbeatThread?.quitSafely()
        nativeHeartbeatThread = null
        heartbeatChannel?.setMethodCallHandler(null)
        heartbeatChannel = null
        h264VideoDecoder?.stopAll()
        h264VideoDecoder = null
        h264WorkerHandler = null
        h264WorkerThread?.quitSafely()
        h264WorkerThread = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private data class H264Result(
        val value: Any? = null,
        val errorCode: String? = null,
        val errorMessage: String? = null,
    )

    private fun dispatchH264(
        call: MethodCall,
        result: MethodChannel.Result,
        worker: (MethodCall) -> H264Result,
    ) {
        val handler = h264WorkerHandler
        if (handler == null) {
            result.error("decoder_unavailable", "H264 worker thread not running", null)
            return
        }
        handler.post {
            val outcome = try {
                worker(call)
            } catch (error: Exception) {
                H264Result(errorCode = "decoder_call_failed", errorMessage = error.message)
            }
            // MethodChannel.Result must be invoked on the UI thread.
            mainHandler.post {
                if (outcome.errorCode != null) {
                    result.error(outcome.errorCode, outcome.errorMessage, null)
                } else {
                    result.success(outcome.value)
                }
            }
        }
    }

    private fun handleH264StartAsync(call: MethodCall, result: MethodChannel.Result) {
        val handler = h264WorkerHandler
        val decoder = h264VideoDecoder
        if (handler == null || decoder == null) {
            result.error("decoder_unavailable", "H264 worker thread not running", null)
            return
        }
        val width = call.argument<Int>("width") ?: 0
        val height = call.argument<Int>("height") ?: 0
        val codec = call.argument<String>("codec") ?: "h264"
        val configData = call.argument<ByteArray>("configData")
        val handle = try {
            decoder.prepareSurface(width, height)
        } catch (error: Exception) {
            result.error("decoder_surface_failed", error.message, null)
            return
        }
        handler.post {
            val outcome = try {
                val textureId = decoder.attachCodec(handle, codec, width, height, configData)
                H264Result(value = textureId)
            } catch (error: Exception) {
                handle.release()
                H264Result(errorCode = "decoder_start_failed", errorMessage = error.message)
            }
            mainHandler.post {
                if (outcome.errorCode != null) {
                    result.error(outcome.errorCode, outcome.errorMessage, null)
                } else {
                    result.success(outcome.value)
                }
            }
        }
    }

    private fun handleH264PushFrameSync(call: MethodCall): H264Result {
        val textureId = numberToLong(call.argument<Any>("textureId"))
        val data = call.argument<ByteArray>("data")
        val ptsUs = numberToLong(call.argument<Any>("ptsUs"))
        if (textureId <= 0 || data == null || data.isEmpty()) {
            return H264Result(value = null)
        }
        val stats = h264VideoDecoder?.pushFrame(textureId, data, ptsUs)
            ?: mapOf("rendered" to false, "error" to "decoder_unavailable")
        return H264Result(value = stats)
    }

    private fun handleH264StopSync(call: MethodCall): H264Result {
        val textureId = numberToLong(call.argument<Any>("textureId"))
        if (textureId > 0) {
            h264VideoDecoder?.stop(textureId)
        }
        return H264Result(value = null)
    }

    private fun numberToLong(value: Any?): Long {
        return when (value) {
            is Long -> value
            is Int -> value.toLong()
            is Number -> value.toLong()
            else -> 0L
        }
    }

    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return true
        }
        return packageManager.canRequestPackageInstalls()
    }

    /**
     * Returns the currently installed APK's manifest versionCode without
     * relying on cached values inside Flutter (package_info_plus caches
     * PackageInfo for the lifetime of the Dart isolate, so right after
     * an in-place upgrade Flutter still reports the *old* versionCode).
     * The update flow uses this to decide whether a release on the server
     * is genuinely newer than what's installed right now.
     */
    private fun currentVersionCode(): Long {
        return try {
            val info = packageManager.getPackageInfo(packageName, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
        } catch (_: PackageManager.NameNotFoundException) {
            -1L
        }
    }

    private fun handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
        val filePath = call.argument<String>("filePath")?.trim().orEmpty()
        if (filePath.isEmpty()) {
            result.error("invalid_path", "APK file path is empty", null)
            return
        }

        val apkFile = File(filePath)
        if (!apkFile.exists() || !apkFile.isFile) {
            result.error("missing_file", "APK file not found", null)
            return
        }

        val validationError = validateApkBeforeInstall(apkFile)
        if (validationError != null) {
            result.error(validationError.code, validationError.message, null)
            return
        }

        if (!canInstallPackages()) {
            val permissionIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(permissionIntent)
            result.success("permission_required")
            return
        }

        try {
            val authority = "$packageName.fileprovider"
            val contentUri = FileProvider.getUriForFile(this, authority, apkFile)
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(contentUri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(installIntent)
            result.success("launched")
        } catch (error: ActivityNotFoundException) {
            result.error("installer_not_found", "No installer available to open the APK", null)
        } catch (error: IllegalArgumentException) {
            result.error("file_provider_error", error.message, null)
        } catch (error: Exception) {
            result.error("install_failed", error.message, null)
        }
    }

    private fun validateApkBeforeInstall(apkFile: File): InstallValidationError? {
        return try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                PackageManager.GET_SIGNING_CERTIFICATES
            } else {
                @Suppress("DEPRECATION")
                PackageManager.GET_SIGNATURES
            }

            val archiveInfo = packageManager.getPackageArchiveInfo(apkFile.absolutePath, flags)
                ?: return InstallValidationError(
                    "invalid_apk",
                    "无法解析安装包，请重新下载后再试。",
                )

            val archivePackageName = archiveInfo.packageName?.trim().orEmpty()
            if (archivePackageName.isNotEmpty() && archivePackageName != packageName) {
                return InstallValidationError(
                    "package_mismatch",
                    "安装包和当前应用的包名不一致，无法直接更新。",
                )
            }

            val installedInfo = packageManager.getPackageInfo(packageName, flags)
            val installedDigests = signingDigests(installedInfo)
            val archiveDigests = signingDigests(archiveInfo)
            if (
                installedDigests.isNotEmpty() &&
                archiveDigests.isNotEmpty() &&
                installedDigests != archiveDigests
            ) {
                return InstallValidationError(
                    "signature_mismatch",
                    "安装包签名和当前已安装版本不同，Android 不允许直接覆盖安装。请先卸载旧版本，或使用同一发布签名重新打包。",
                )
            }

            val archiveVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                archiveInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                archiveInfo.versionCode.toLong()
            }
            val installedVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                installedInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                installedInfo.versionCode.toLong()
            }
            if (archiveVersionCode > 0 && archiveVersionCode <= installedVersionCode) {
                return InstallValidationError(
                    "version_not_newer",
                    "下载的安装包版本 ($archiveVersionCode) 不高于已安装版本 ($installedVersionCode)，无法覆盖安装。请清除应用数据中的下载缓存后重试。",
                )
            }

            null
        } catch (_: Exception) {
            null
        }
    }

    private fun signingDigests(packageInfo: PackageInfo): Set<String> {
        return try {
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signingInfo = packageInfo.signingInfo ?: return emptySet()
                if (signingInfo.hasMultipleSigners()) {
                    signingInfo.apkContentsSigners.orEmpty().toList()
                } else {
                    signingInfo.signingCertificateHistory.orEmpty().toList()
                }
            } else {
                @Suppress("DEPRECATION")
                packageInfo.signatures?.toList().orEmpty()
            }

            signatures.mapNotNull { signature ->
                val bytes = signature?.toByteArray() ?: return@mapNotNull null
                val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
                digest.joinToString("") { value -> "%02x".format(value) }
            }.toSet()
        } catch (_: Exception) {
            emptySet()
        }
    }
}
