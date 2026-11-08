package nini22p.iris

import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Media info probe channel (scan-probe subproject).
//
// Backs `AndroidMediaProbeService` (lib/features/media_library/scan/probe/).
// Uses MediaMetadataRetriever so both real filesystem paths and content://
// SAF URIs are supported. Unprobeable targets answer null — never throw.
//
// App-identity channel (custom desktop entries subproject).
//
// Backs `ShortcutChannelService` (lib/features/app_identity/services/).
// Pins home-screen shortcuts with a user-chosen bitmap + label, updates them
// in place on edit, and forwards shortcut-launch intents (extra
// `iris.entry.id`) to Dart — both cold start (getIntent) and warm start
// (onNewIntent). Capability probing answers false — never throws.
class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL_ID = "iris/app_identity"
        const val EXTRA_ENTRY_ID = "iris.entry.id"

        // Must match ShortcutChannelService.shortcutIdPrefix.
        const val SHORTCUT_ID_PREFIX = "iris_entry_"
    }

    private var identityChannel: MethodChannel? = null

    // Shortcut id captured from a cold-start launch intent. Dart PULLS it via
    // "popInitialEntry" once its channel listener exists — pushing at engine
    // setup would race (invokeMethod before any Dart handler drops the msg).
    private var pendingLaunchId: String? = null

    /** Worker pool for media probing: header reads must never block the UI thread. */
    private val probeExecutor = java.util.concurrent.Executors.newFixedThreadPool(2)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── iris/media_probe (pre-existing scan-probe channel) ──
        //
        // BOTH entry points run on a small worker pool, never on the platform
        // main thread: MediaMetadataRetriever.setDataSource() opens the file and
        // parses the header, which measured 300–450 ms per call under load on a
        // 2019 device (logcat: "Slow Binder ... IMediaMetadataRetriever"). On the
        // main thread that is a frozen UI for the whole metadata pass.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iris/media_probe"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "probe" -> {
                    val target = call.argument<String>("target")
                    if (target.isNullOrBlank()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    probeExecutor.execute {
                        val info = try {
                            probeMediaInfo(target)
                        } catch (_: Exception) {
                            null
                        }
                        runOnUiThread { result.success(info) }
                    }
                }
                // Batch form: ONE channel round trip per probe batch instead of
                // one per file, so a 2k-file fallback pass does not pay 2k
                // platform-channel waits.
                "probeBatch" -> {
                    val targets = call.argument<List<String>>("targets")
                    if (targets.isNullOrEmpty()) {
                        result.success(emptyList<Map<String, Int?>>())
                        return@setMethodCallHandler
                    }
                    probeExecutor.execute {
                        val out = ArrayList<Map<String, Int?>>(targets.size)
                        for (target in targets) {
                            if (target.isBlank()) {
                                out.add(emptyMap())
                            } else {
                                out.add(
                                    try {
                                        probeMediaInfo(target)
                                    } catch (_: Exception) {
                                        // "unprobeable" is a normal outcome: the
                                        // Dart side treats empty as unknown.
                                        emptyMap<String, Int?>()
                                    }
                                )
                            }
                        }
                        runOnUiThread { result.success(out) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── iris/screenshot_scan (gallery visibility for saved shots) ──
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "iris/screenshot_scan"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanFile" -> {
                    val target = call.argument<String>("path")
                    if (target.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val mime = call.argument<String>("mime") ?: "image/png"
                    try {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            arrayOf(target),
                            arrayOf(mime),
                            null
                        )
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── iris/app_identity (custom desktop entries) ──
        pendingLaunchId = intent?.getStringExtra(EXTRA_ENTRY_ID)?.takeIf { it.isNotBlank() }
        identityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_ID
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "capability" -> result.success(capabilityMap())
                    "popInitialEntry" -> {
                        val id = pendingLaunchId
                        pendingLaunchId = null
                        result.success(id)
                    }
                    "pinShortcut" -> {
                        val id = call.argument<String>("id")
                        val name = call.argument<String>("name")
                        val png = call.argument<ByteArray>("png")
                        if (id.isNullOrBlank() || name.isNullOrBlank() || png == null) {
                            result.error("invalid_args", "id/name/png required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            pinShortcut(id, name, png)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("pin_failed", e.message, null)
                        }
                    }
                    "updateShortcut" -> {
                        val id = call.argument<String>("id")
                        val name = call.argument<String>("name")
                        val png = call.argument<ByteArray>("png")
                        if (id.isNullOrBlank() || name.isNullOrBlank()) {
                            result.error("invalid_args", "id/name required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(updateShortcut(id, name, png))
                        } catch (e: Exception) {
                            result.error("update_failed", e.message, null)
                        }
                    }
                    "queryPinned" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(emptyList<String>())
                            return@setMethodCallHandler
                        }
                        try {
                            val manager = getSystemService(ShortcutManager::class.java)
                            val ids = manager?.pinnedShortcuts
                                ?.filter { it.id.startsWith(SHORTCUT_ID_PREFIX) }
                                ?.map { it.id.removePrefix(SHORTCUT_ID_PREFIX) }
                                ?.toList() ?: emptyList()
                            result.success(ids)
                        } catch (e: Exception) {
                            result.error("query_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        // Cold-start id stays buffered in pendingLaunchId until Dart pops it.
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm-start delivery while the activity is already alive.
        forwardLaunchEntryId(intent)
    }

    override fun onDestroy() {
        // The pool is owned by the activity; leaving it alive across recreation
        // would keep two probing threads per rotation.
        probeExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun forwardLaunchEntryId(intent: Intent?) {
        val entryId = intent?.getStringExtra(EXTRA_ENTRY_ID) ?: return
        if (entryId.isBlank()) return
        identityChannel?.invokeMethod("onEntryLaunch", mapOf("entryId" to entryId))
    }

    // ── Capability ──

    private fun capabilityMap(): Map<String, Boolean> {
        val sdkOk = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        val launcherOk = sdkOk && (getSystemService(ShortcutManager::class.java)
            ?.isRequestPinShortcutSupported == true)
        return mapOf(
            "sdkOk" to sdkOk,
            "launcherSupportsPin" to launcherOk,
        )
    }

    // ── Pin / update ──

    private fun decodeSquareBitmap(png: ByteArray): Bitmap {
        val src = BitmapFactory.decodeByteArray(png, 0, png.size)
            ?: throw IllegalArgumentException("undecodable png")
        // Square already (Dart prepares 192x192); defensive re-crop keeps the
        // adaptive-icon mask from stretching non-square payloads.
        val side = minOf(src.width, src.height)
        val x = (src.width - side) / 2
        val y = (src.height - side) / 2
        val square = Bitmap.createBitmap(src, x, y, side, side)
        // Launcher icons are masked down; scale up tiny payloads so they stay
        // legible, and cap memory for huge ones.
        val target = 192
        if (square.width != target) {
            val scaled = Bitmap.createScaledBitmap(square, target, target, true)
            if (scaled != square) square.recycle()
            return scaled
        }
        return square
    }

    private fun buildShortcut(id: String, name: String, png: ByteArray): ShortcutInfo {
        val bmp = decodeSquareBitmap(png)
        val intent = Intent(Intent.ACTION_MAIN, null, applicationContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA_ENTRY_ID, id)
        return ShortcutInfo.Builder(applicationContext, SHORTCUT_ID_PREFIX + id)
            .setShortLabel(name)
            .setIcon(Icon.createWithAdaptiveBitmap(bmp))
            .setIntent(intent)
            .build()
    }

    private fun pinShortcut(id: String, name: String, png: ByteArray) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            throw IllegalStateException("pinned shortcuts require API 26+")
        }
        val manager = getSystemService(ShortcutManager::class.java)
            ?: throw IllegalStateException("ShortcutManager unavailable")
        val shortcut = buildShortcut(id, name, png)
        val pinnedAlready = manager.pinnedShortcuts.any {
            it.id == shortcut.id
        }
        if (pinnedAlready) {
            // Re-pinning an existing id would double-confirm; update instead.
            manager.updateShortcuts(listOf(shortcut))
        } else {
            if (!manager.isRequestPinShortcutSupported) {
                throw IllegalStateException("launcher does not support pinning")
            }
            manager.requestPinShortcut(shortcut, null)
        }
    }

    // Returns true when a pinned shortcut with this id was found and updated;
    // false when there was nothing pinned to update.
    private fun updateShortcut(id: String, name: String, png: ByteArray?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            throw IllegalStateException("pinned shortcuts require API 26+")
        }
        val manager = getSystemService(ShortcutManager::class.java)
            ?: throw IllegalStateException("ShortcutManager unavailable")
        val fullId = SHORTCUT_ID_PREFIX + id
        val existing = manager.pinnedShortcuts.firstOrNull { it.id == fullId }
            ?: return false
        val builder = ShortcutInfo.Builder(applicationContext, fullId)
            .setShortLabel(name)
        if (png != null) {
            builder.setIcon(Icon.createWithAdaptiveBitmap(decodeSquareBitmap(png)))
        }
        // Keep the original intent; only label/icon change.
        existing.intent?.let { builder.setIntent(it) }
        try {
            manager.updateShortcuts(listOf(builder.build()))
        } catch (e: IllegalArgumentException) {
            throw IllegalStateException("update rejected: ${e.message}")
        }
        return true
    }

    // ── Media probe (scan-probe subproject, pre-existing) ──

    private fun probeMediaInfo(target: String): Map<String, Int?> {
        val retriever = MediaMetadataRetriever()
        try {
            if (target.startsWith("content://")) {
                retriever.setDataSource(
                    applicationContext,
                    Uri.parse(target)
                )
            } else {
                retriever.setDataSource(target)
            }

            fun opt(key: Int): Int? =
                retriever.extractMetadata(key)?.toIntOrNull()

            return mapOf(
                "durationMs" to opt(MediaMetadataRetriever.METADATA_KEY_DURATION),
                "width" to opt(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH),
                "height" to opt(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            )
        } finally {
            retriever.release()
        }
    }
}
