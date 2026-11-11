package org.ridgewalk.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.StatFs
import android.os.Build
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.ridgewalk.app/storage")
            .setMethodCallHandler { call, result ->
                if (call.method == "freeBytes") {
                    result.success(StatFs(filesDir.path).availableBytes)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "org.ridgewalk.app/updates")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "version" -> {
                            val info = packageManager.getPackageInfo(packageName, 0)
                            val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                            result.success(mapOf("version" to (info.versionName ?: ""), "build" to code))
                        }
                        "install" -> {
                            val apk = File(cacheDir, "updates/update.apk").canonicalFile
                            if (!apk.isFile || apk.parentFile != File(cacheDir, "updates").canonicalFile) throw IllegalStateException("Update file is missing")
                            @Suppress("DEPRECATION")
                            val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                            val incoming = packageManager.getPackageArchiveInfo(apk.path, flags) ?: throw IllegalStateException("Invalid APK")
                            val current = packageManager.getPackageInfo(packageName, flags)
                            val incomingCode = if (Build.VERSION.SDK_INT >= 28) incoming.longVersionCode else @Suppress("DEPRECATION") incoming.versionCode.toLong()
                            val currentCode = if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else @Suppress("DEPRECATION") current.versionCode.toLong()
                            @Suppress("DEPRECATION")
                            val incomingSignatures = if (Build.VERSION.SDK_INT >= 28) incoming.signingInfo?.apkContentsSigners else incoming.signatures
                            @Suppress("DEPRECATION")
                            val currentSignatures = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
                            if (incoming.packageName != packageName || incomingCode <= currentCode || incomingSignatures.isNullOrEmpty() || currentSignatures.isNullOrEmpty() || incomingSignatures.toSet() != currentSignatures.toSet()) throw IllegalStateException("Update package, version or signing key does not match the installed app")
                            if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
                                startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                                result.success("permission")
                            } else {
                                val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                                startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                result.success("installer")
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) { result.error("update", error.message, null) }
            }
    }
}

