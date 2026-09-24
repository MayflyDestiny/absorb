package com.barnabas.absorb

import android.content.Context
import android.content.Intent
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.documentfile.provider.DocumentFile
import java.io.File
import java.io.FileInputStream
import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.LoudnessEnhancer
import android.media.audiofx.Virtualizer
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.StatFs

import android.util.Log
import android.view.KeyEvent
import android.view.WindowManager
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.AudioServicePlugin
import com.ryanheise.just_audio.MonoController
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val TAG = "AbsorbEQ"
    private val CHANNEL = "com.absorb.equalizer"

    // Marker file name stored inside each SAF book folder at download/migrate
    // time. A scan reads it to identify previously downloaded books without
    // opening any audio bytes.
    companion object {
        private const val ABSORB_MARKER = ".absorb"
        private const val EBOOKS_SUBDIR = "ebooks"
        private const val EBOOK_META_SUBDIR = ".absorb-ebook"
        private const val EBOOK_META_SUFFIX = ".absorb-ebook"
    }

    // Ebook reader: volume keys turn pages while watching is on. The keys are
    // consumed here so system volume doesn't change.
    private var volumeKeysChannel: MethodChannel? = null
    private var watchVolumeKeys = false

    private var equalizer: Equalizer? = null
    private var bassBoost: BassBoost? = null
    private var virtualizer: Virtualizer? = null
    private var loudnessEnhancer: LoudnessEnhancer? = null
    private var currentSessionId: Int = 0
    private var eqEnabled: Boolean = false
    private var eqLoudnessGainMb: Int = 0  // gain from EQ loudness slider
    // Some devices (e.g. older Samsung on Android 9) have a broken audio-effect
    // HAL that fails to initialize. Constructing AudioEffects against it during
    // playback can crash the process natively, which Kotlin can't catch. Once
    // init proves the engine is unavailable, skip attaching native effects.
    private var effectsAvailable: Boolean = true

    // Android brings a task back from a dead process by recreating its root
    // activity with the intent that first created it. When that was the
    // widget's play button, every later plain open (the widget cover, the
    // installer's Open button, Recents) replayed the play deep link and the
    // app started playing on its own. A real tap always creates the activity
    // fresh, so only a recreated one can be carrying a replay.
    override fun onCreate(savedInstanceState: Bundle?) {
        if (savedInstanceState != null &&
            intent?.action == HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION) {
            Log.d(TAG, "Dropping replayed widget launch ${intent.data}")
            intent.action = Intent.ACTION_MAIN
            intent.data = null
        }
        super.onCreate(savedInstanceState)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        // Headless service starts (Android Auto binds, media buttons on a
        // dead process) boot the engine with no activity so the browse tree
        // works. Never attach the UI to such an engine unless it's actually
        // mid-playback - it has never rendered a frame and the launch sticks
        // on the splash screen. Tear it down and boot fresh instead.
        val cache = FlutterEngineCache.getInstance()
        val cached = cache.get(AudioServicePlugin.getFlutterEngineId())
        if (cached != null && AudioServicePlugin.wasEngineBornHeadless() &&
            !AudioService.isInstancePlaying()) {
            try {
                cache.remove(AudioServicePlugin.getFlutterEngineId())
                cached.destroy()
                Log.d(TAG, "Replaced idle headless-born engine with a fresh launch")
            } catch (e: Exception) {
                Log.e(TAG, "Headless engine teardown failed", e)
            }
        }
        return super.provideFlutterEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "moveToBackground" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }

                    "isBluetoothAudioConnected" -> {
                        result.success(isBluetoothAudioConnected())
                    }
                    "init" -> handleInit(result)
                    "attachSession" -> {
                        val sessionId = call.argument<Int>("sessionId") ?: 0
                        handleAttachSession(sessionId, result)
                    }
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        handleSetEnabled(enabled, result)
                    }
                    "setBand" -> {
                        val band = call.argument<Int>("band") ?: 0
                        val level = call.argument<Int>("level") ?: 0
                        handleSetBand(band, level, result)
                    }
                    "setBassBoost" -> {
                        val strength = call.argument<Int>("strength") ?: 0
                        handleSetBassBoost(strength, result)
                    }
                    "setVirtualizer" -> {
                        val strength = call.argument<Int>("strength") ?: 0
                        handleSetVirtualizer(strength, result)
                    }
                    "setLoudness" -> {
                        val gain = call.argument<Int>("gain") ?: 0
                        handleSetLoudness(gain, result)
                    }
                    "setMono" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        MonoController.setMonoEnabled(enabled)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        Log.d(TAG, "EQ method channel registered")

        // Auto scroll in the ebook reader keeps the screen on for as long as it
        // runs; the reader releases it when the scroll stops or it closes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.absorb.screen_wake")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.absorb.audio_diag")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "snapshot" -> result.success(AudioService.getDiagnosticSnapshot())
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.absorb.update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBaseBuildNumber" ->
                        result.success(BuildConfig.ABSORB_BASE_VERSION_CODE)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.absorb.storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceStorage" -> {
                        try {
                            val stat = StatFs(Environment.getDataDirectory().path)
                            result.success(mapOf(
                                "totalBytes" to stat.totalBytes,
                                "availableBytes" to stat.availableBytes
                            ))
                        } catch (e: Exception) {
                            result.error("STORAGE_ERROR", e.message, null)
                        }
                    }
                    "getStorageStats" -> {
                        // Android 8+ counts what the system shows under
                        // Settings → Apps → {app} → Storage. dataBytes is the
                        // "App data / 数据" figure, cacheBytes the "Cache /
                        // 缓存" figure. queryStatsForPackage needs no extra
                        // permission when the queried package is ourselves.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val storageManager = getSystemService(
                                    Context.STORAGE_SERVICE) as android.app.usage.StorageStatsManager
                                val stats = storageManager.queryStatsForPackage(
                                    android.os.storage.StorageManager.UUID_DEFAULT,
                                    packageName,
                                    android.os.Process.myUserHandle())
                                result.success(mapOf(
                                    "cacheBytes" to stats.cacheBytes,
                                    "dataBytes" to stats.dataBytes,
                                    "codeCacheBytes" to codeCacheDirSize()
                                ))
                            } catch (e: Exception) {
                                result.error("STORAGE_ERROR", e.message, null)
                            }
                        } else {
                            result.error("UNSUPPORTED", "StorageStats requires API 26+", null)
                        }
                    }
                    "moveBookToSaf" -> handleMoveBookToSaf(call, result)
                    "migrateBook" -> handleMigrateBook(call, result)
                    "scanSafDirectory" -> handleScanSafDirectory(call, result)
                    "checkSafFiles" -> handleCheckSafFiles(call, result)
                    "saveEbookToSaf" -> handleSaveEbookToSaf(call, result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.absorb.clip")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "exportClip" -> handleExportClip(call, result)
                    else -> result.notImplemented()
                }
            }

        // On-device bookmark transcription: decode a window of a downloaded
        // audio file into 16kHz mono WAV for Whisper. Heavy work runs on a
        // worker thread; the result is posted back on the main thread.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.barnabas.absorb/transcription")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractWav" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val outPath = call.argument<String>("outPath")
                        val startSeconds = call.argument<Double>("startSeconds") ?: 0.0
                        val durationSeconds = call.argument<Double>("durationSeconds") ?: 0.0
                        if (sourcePath == null || outPath == null) {
                            result.error("ARGS", "sourcePath and outPath are required", null)
                        } else {
                            Thread {
                                val ok = try {
                                    AudioWindowExtractor.extractWav(applicationContext, sourcePath, startSeconds, durationSeconds, outPath)
                                } catch (e: Exception) {
                                    Log.e(TAG, "extractWav crashed: ${e.message}")
                                    false
                                }
                                Handler(Looper.getMainLooper()).post { result.success(ok) }
                            }.start()
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        volumeKeysChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "com.absorb.volume_keys")
        volumeKeysChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "watch" -> { watchVolumeKeys = true; result.success(true) }
                "clearWatch" -> { watchVolumeKeys = false; result.success(true) }
                else -> result.notImplemented()
            }
        }

        // GMS-backed channels (cast foreground service, wear bridges).
        // Resolves to the real impl in github/playstore, no-op in fdroid.
        PlatformIntegration.registerChannels(this, flutterEngine)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (watchVolumeKeys) {
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeKeysChannel?.invokeMethod("volumePressed", "up")
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeKeysChannel?.invokeMethod("volumePressed", "down")
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    // Consume the matching key-up too so the system doesn't act on it.
    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (watchVolumeKeys &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    // Physical page-turn keys - e-ink devices like the Boox Palma map their
    // side button to these. They must be grabbed BEFORE the view tree: a
    // focused WebView treats PAGE_UP/DOWN as scroll keys and shifts the
    // paginated book vertically instead of letting the app turn the page.
    // The Dart side decides what they do (page turn in the reader, play/pause
    // toggle otherwise).
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_PAGE_UP ||
            event.keyCode == KeyEvent.KEYCODE_PAGE_DOWN) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                volumeKeysChannel?.invokeMethod(
                    "pagePressed",
                    if (event.keyCode == KeyEvent.KEYCODE_PAGE_UP) "up" else "down")
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * Size of the app's code_cache directory (ART/JIT compiled output). The
     * OS counts it inside StorageStats.cacheBytes, but Dart can't reach it via
     * path_provider (it exposes the plain cache dir only), so the settings
     * cache panel would otherwise under-report against the system figure.
     * Reported separately so the panel can reconcile the ~sub-MB gap.
     */
    private fun codeCacheDirSize(): Long {
        return try {
            val dir = File(codeCacheDir, ".")
            if (!dir.exists()) return 0L
            dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        } catch (e: Exception) {
            0L
        }
    }

    // Move downloaded temp files into the user's SAF folder, creating the nested
    // [subfolder] (e.g. "Author/Title") under the granted tree via the DocumentFile
    // chain so files nest correctly and stay readable through the original grant.
    // The byte copy runs off the main thread. A tiny marker file ([marker], a
    // JSON string) is written into the book folder so a later scan can identify
    // who downloaded these files without opening any audio.
    private fun handleMoveBookToSaf(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")
        val subfolder = call.argument<String>("subfolder") ?: ""
        val filenames = call.argument<List<String>>("filenames")
        val tempPaths = call.argument<List<String>>("tempPaths")
        val marker = call.argument<String>("marker")
        if (treeUri == null || filenames == null || tempPaths == null || filenames.size != tempPaths.size) {
            result.error("SAF_ARGS", "Invalid arguments", null)
            return
        }
        Thread {
            try {
                val tree = DocumentFile.fromTreeUri(applicationContext, Uri.parse(treeUri))
                    ?: throw IllegalStateException("Download folder not accessible")
                var dir: DocumentFile = tree
                for (segment in subfolder.split('/').filter { it.isNotBlank() }) {
                    val existing = dir.findFile(segment)
                    dir = if (existing != null && existing.isDirectory) existing
                        else (dir.createDirectory(segment)
                            ?: throw IllegalStateException("Could not create folder: $segment"))
                }
                val fileUris = ArrayList<String>(filenames.size)
                val temps = ArrayList<File>(filenames.size)
                for (i in filenames.indices) {
                    val name = filenames[i]
                    val temp = File(tempPaths[i])
                    if (!temp.exists()) throw IllegalStateException("Missing downloaded file: ${tempPaths[i]}")
                    // Replace any existing file of the same name (e.g. re-download).
                    dir.findFile(name)?.delete()
                    // octet-stream so SAF keeps the exact filename + extension (a
                    // real audio MIME makes the provider rewrite e.g. .m4b to .m4a).
                    // ExoPlayer detects the format from the file content anyway.
                    val doc = dir.createFile("application/octet-stream", name)
                        ?: throw IllegalStateException("Could not create file: $name")
                    contentResolver.openOutputStream(doc.uri)?.use { output ->
                        FileInputStream(temp).use { input -> input.copyTo(output, 64 * 1024) }
                    } ?: throw IllegalStateException("Could not write: $name")
                    temps.add(temp)
                    fileUris.add(doc.uri.toString())
                }
                // Only remove the internal copies once every file moved, so a
                // mid-way failure leaves the internal download intact to fall back on.
                temps.forEach { it.delete() }
                // Identification marker so a folder scan can tell who owns these
                // files. Best-effort: a read-only / stale marker never blocks a move.
                if (!marker.isNullOrBlank()) {
                    dir.findFile(ABSORB_MARKER)?.delete()
                    val m = dir.createFile("application/octet-stream", ABSORB_MARKER)
                    m?.let { doc ->
                        contentResolver.openOutputStream(doc.uri)?.use { it.write(marker!!.toByteArray()) }
                    }
                }
                val dirUri = dir.uri.toString()
                runOnUiThread { result.success(mapOf("dirUri" to dirUri, "fileUris" to fileUris)) }
            } catch (e: Exception) {
                Log.e(TAG, "moveBookToSaf failed: ${e.message}", e)
                runOnUiThread { result.error("SAF_MOVE_ERROR", e.message, null) }
            }
        }.start()
    }

    // Move an already-completed download to a new location. Sources may be
    // internal file paths or content:// URIs (a download already stored in a
    // SAF folder); the destinations are either a SAF tree (with [subfolder]
    // nesting under the granted folder) or an internal directory. Bytes are
    // copied cross-thread and the sources are only deleted after every file
    // landed successfully, so a mid-way failure leaves the original intact.
    private fun handleMigrateBook(call: MethodCall, result: MethodChannel.Result) {
        val sources = call.argument<List<String>>("sources")
        val filenames = call.argument<List<String>>("filenames")
        val subfolder = call.argument<String>("subfolder") ?: ""
        val treeUri = call.argument<String>("treeUri") // SAF destination
        val targetDir = call.argument<String>("targetDir") // internal destination
        val marker = call.argument<String>("marker")
        if (sources == null || filenames == null || sources.isEmpty() || sources.size != filenames.size) {
            result.error("MIGRATE_ARGS", "Invalid arguments", null)
            return
        }
        if (treeUri == null && targetDir == null) {
            result.error("MIGRATE_ARGS", "No destination given", null)
            return
        }
        Thread {
            try {
                val fileUris = ArrayList<String>()
                val filePaths = ArrayList<String>()
                var dirUri: String? = null
                var dirPath: String? = null
                // Open the destination: a SAF folder chain, or a plain
                // internal directory.
                var safDir: DocumentFile? = null
                var intDir: File? = null
                if (treeUri != null) {
                    val tree = DocumentFile.fromTreeUri(applicationContext, Uri.parse(treeUri))
                        ?: throw IllegalStateException("Download folder not accessible")
                    var dir = tree
                    for (segment in subfolder.split('/').filter { it.isNotBlank() }) {
                        val existing = dir.findFile(segment)
                        dir = if (existing != null && existing.isDirectory) existing
                            else (dir.createDirectory(segment)
                                ?: throw IllegalStateException("Could not create folder: $segment"))
                    }
                    safDir = dir
                } else if (targetDir != null) {
                    val dir = File(targetDir)
                    if (!dir.exists() && !dir.mkdirs()) {
                        throw IllegalStateException("Could not create folder: $targetDir")
                    }
                    intDir = dir
                }
                for (i in sources.indices) {
                    // Prefer the real display name from the source (content URIs
                    // hide the filename), falling back to the caller's list.
                    var name: String? = null
                    val src = sources[i]
                    if (src.startsWith("content://")) {
                        try {
                            contentResolver.query(Uri.parse(src), arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                                if (c.moveToFirst()) {
                                    name = c.getString(c.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME))
                                }
                            }
                        } catch (_: Exception) {}
                    } else {
                        name = File(src).name
                    }
                    if (name.isNullOrEmpty() || name == "null") name = filenames[i]
                    val fileName = name ?: filenames[i]
                    val input = if (src.startsWith("content://")) {
                        contentResolver.openInputStream(Uri.parse(src))
                            ?: throw IllegalStateException("Could not open source: $fileName")
                    } else {
                        val f = File(src)
                        if (!f.exists()) throw IllegalStateException("Missing source file: $src")
                        FileInputStream(f)
                    }
                    if (safDir != null) {
                        safDir.findFile(fileName)?.delete()
                        val doc = safDir.createFile("application/octet-stream", fileName)
                            ?: throw IllegalStateException("Could not create file: $fileName")
                        contentResolver.openOutputStream(doc.uri)?.use { output ->
                            input.use { it.copyTo(output, 64 * 1024) }
                        } ?: throw IllegalStateException("Could not write: $fileName")
                        fileUris.add(doc.uri.toString())
                    } else {
                        val dst = File(intDir!!, fileName)
                        dst.outputStream().use { output ->
                            input.use { it.copyTo(output, 64 * 1024) }
                        }
                        filePaths.add(dst.absolutePath)
                    }
                }
                dirUri = safDir?.uri?.toString()
                dirPath = intDir?.absolutePath
                // Write the identification marker into a SAF destination so a
                // later scan still recognizes the book after migration.
                if (safDir != null && !marker.isNullOrBlank()) {
                    safDir.findFile(ABSORB_MARKER)?.delete()
                    val m = safDir.createFile("application/octet-stream", ABSORB_MARKER)
                    m?.let { doc ->
                        contentResolver.openOutputStream(doc.uri)?.use { it.write(marker!!.toByteArray()) }
                    }
                }
                // Only remove the old files once every copy succeeded.
                for (src in sources) {
                    if (src.startsWith("content://")) {
                        try { contentResolver.delete(Uri.parse(src), null, null) } catch (_: Exception) {}
                    } else {
                        try { File(src).delete() } catch (_: Exception) {}
                    }
                }
                runOnUiThread { result.success(mapOf(
                    "dirUri" to dirUri, "fileUris" to fileUris,
                    "dirPath" to dirPath, "filePaths" to filePaths)) }
            } catch (e: Exception) {
                Log.e(TAG, "migrateBook failed: ${e.message}", e)
                runOnUiThread { result.error("MIGRATE_ERROR", e.message, null) }
            }
        }.start()
    }

    // Light-weight scan of a SAF download folder: walks at most three levels
    // (root -> Author -> Title), reads only the tiny .absorb marker files, never
    // the audio bytes, and returns each book folder whose marker exists plus a
    // count of audio-bearing folders without a marker (likely foreign files).
    // Runs off the main thread and is only triggered once when the user picks a
    // folder, so per-build cost stays negligible.
    private fun handleScanSafDirectory(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")
        if (treeUri == null) {
            result.error("SCAN_ARGS", "treeUri is required", null)
            return
        }
        Thread {
            try {
                val tree = DocumentFile.fromTreeUri(applicationContext, Uri.parse(treeUri))
                    ?: throw IllegalStateException("Download folder not accessible")
                val audioExts = setOf(
                    "mp3", "m4a", "m4b", "m4p", "m4v", "flac", "aac",
                    "ogg", "oga", "opus", "wav", "amr", "mka")
                val known = ArrayList<Map<String, Any?>>()
                var unknownCount = 0

                fun walk(dir: DocumentFile, depth: Int) {
                    if (depth > 2) return
                    for (child in dir.listFiles()) {
                        if (!child.isDirectory) continue
                        val marker = child.findFile(ABSORB_MARKER)
                        if (marker != null && marker.isFile) {
                            val content = try {
                                contentResolver.openInputStream(marker.uri)
                                    ?.use { it.readBytes().toString(Charsets.UTF_8) }
                            } catch (e: Exception) { null }
                            if (content != null && content.isNotBlank()) {
                                val fileUris = ArrayList<String>()
                                val fileNames = ArrayList<String>()
                                for (f in child.listFiles()) {
                                    if (!f.isFile || f.name == ABSORB_MARKER) continue
                                    val ext = (f.name ?: "").substringAfterLast('.', "").lowercase()
                                    if (audioExts.contains(ext)) {
                                        fileUris.add(f.uri.toString())
                                        fileNames.add(f.name ?: "")
                                    }
                                }
                                known.add(mapOf(
                                    "dirUri" to child.uri.toString(),
                                    "marker" to content,
                                    "fileUris" to fileUris,
                                    "fileNames" to fileNames,
                                ))
                            } else {
                                // Marker present but unreadable/corrupt: still an
                                // Absorb book folder, but treat as unidentified.
                                unknownCount++
                            }
                        } else {
                            // No marker here: might be an Author dir holding book
                            // subdirs, or an unidentified leaf. Recurse, then count
                            // this folder as unidentified only if it holds audio.
                            walk(child, depth + 1)
                            var hasAudio = false
                            for (f in child.listFiles()) {
                                if (f.isFile) {
                                    val ext = (f.name ?: "").substringAfterLast('.', "").lowercase()
                                    if (audioExts.contains(ext)) { hasAudio = true; break }
                                }
                            }
                            if (hasAudio) unknownCount++
                        }
                    }
                }

                walk(tree, 0)
                runOnUiThread {
                    val ebookExports = ArrayList<Map<String, Any?>>()
                    // Recognize exported ebook copies in the `ebooks/` sibling
                    // folder: each one carries a `<name>.absorb-ebook` metadata
                    // file (itemId + title) written at export time, so a scan
                    // after reinstall can restore the "exported" state.
                    try {
                        val ebooksDir = tree.findFile(EBOOKS_SUBDIR)
                        if (ebooksDir != null && ebooksDir.isDirectory) {
                            val metaDir = ebooksDir.findFile(EBOOK_META_SUBDIR)
                            if (metaDir != null && metaDir.isDirectory) {
                                for (metaDoc in metaDir.listFiles()) {
                                    if (!metaDoc.isFile) continue
                                    val metaName = metaDoc.name ?: continue
                                    if (!metaName.endsWith(EBOOK_META_SUFFIX)) continue
                                    val baseName =
                                        metaName.removeSuffix(EBOOK_META_SUFFIX)
                                    val fileDoc = ebooksDir.findFile(baseName)
                                    if (fileDoc == null || !fileDoc.isFile) continue
                                    val content = try {
                                        contentResolver.openInputStream(metaDoc.uri)
                                            ?.use { it.readBytes().toString(Charsets.UTF_8) }
                                    } catch (e: Exception) { null }
                                    if (content != null && content.isNotBlank()) {
                                        ebookExports.add(mapOf(
                                            "fileUri" to fileDoc.uri.toString(),
                                            "metaUri" to metaDoc.uri.toString(),
                                            "meta" to content,
                                        ))
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "ebook scan failed: ${e.message}", e)
                    }
                    result.success(mapOf("known" to known, "unknownCount" to unknownCount,
                        "ebooks" to ebookExports))
                }
            } catch (e: Exception) {
                Log.e(TAG, "scanSafDirectory failed: ${e.message}", e)
                runOnUiThread { result.error("SCAN_ERROR", e.message, null) }
            }
        }.start()
    }

    // Write an exported ebook copy (plus a tiny `<name>.absorb-ebook` metadata
    // file) into the `ebooks` subfolder of the granted SAF tree. The metadata
    // lets a later folder scan restore the "exported" state after a reinstall.
    // Runs off the main thread, like the other SAF helpers.
    private fun handleSaveEbookToSaf(call: MethodCall, result: MethodChannel.Result) {
        val treeUri = call.argument<String>("treeUri")
        val fileName = call.argument<String>("fileName")
        val tempPath = call.argument<String>("tempPath")
        val meta = call.argument<String>("meta")
        if (treeUri == null || fileName == null || tempPath == null) {
            result.error("SAF_ARGS", "Invalid arguments", null)
            return
        }
        Thread {
            try {
                val tree = DocumentFile.fromTreeUri(applicationContext, Uri.parse(treeUri))
                    ?: throw IllegalStateException("Download folder not accessible")
                val temp = File(tempPath)
                if (!temp.exists()) throw IllegalStateException("Missing ebook file: $tempPath")
                var dir = tree.findFile(EBOOKS_SUBDIR)
                if (dir == null || !dir.isDirectory) {
                    dir = tree.createDirectory(EBOOKS_SUBDIR)
                        ?: throw IllegalStateException("Could not create folder: $EBOOKS_SUBDIR")
                }
                dir.findFile(fileName)?.delete()
                val doc = dir.createFile("application/octet-stream", fileName)
                    ?: throw IllegalStateException("Could not create file: $fileName")
                contentResolver.openOutputStream(doc.uri)?.use { output ->
                    FileInputStream(temp).use { input -> input.copyTo(output, 64 * 1024) }
                } ?: throw IllegalStateException("Could not write: $fileName")
                temp.delete()
                var metaUri: String? = null
                if (!meta.isNullOrBlank()) {
                    // Metadata lives in a hidden `.absorb-ebook` subfolder (one
                    // file per copy, named exactly like the book file) so the
                    // public `ebooks/` folder only shows the user's copies.
                    var metaDir = dir.findFile(EBOOK_META_SUBDIR)
                    if (metaDir == null || !metaDir.isDirectory) {
                        metaDir = dir.createDirectory(EBOOK_META_SUBDIR)
                    }
                    metaDir?.let { md ->
                        val metaName = "$fileName$EBOOK_META_SUFFIX"
                        md.findFile(metaName)?.delete()
                        val m = md.createFile("application/octet-stream", metaName)
                        m?.let { metaDoc ->
                            contentResolver.openOutputStream(metaDoc.uri)?.use {
                                it.write(meta!!.toByteArray())
                            }
                            metaUri = metaDoc.uri.toString()
                        }
                    }
                }
                runOnUiThread {
                    result.success(mapOf("fileUri" to doc.uri.toString(), "metaUri" to metaUri))
                }
            } catch (e: Exception) {
                Log.e(TAG, "saveEbookToSaf failed: ${e.message}", e)
                runOnUiThread { result.error("SAF_SAVE_ERROR", e.message, null) }
            }
        }.start()
    }

    // Batch existence check for SAF content URIs. The download registry cannot
    // stat content:// URIs from Dart, so native probes each one cheaply via
    // DocumentsContract without opening audio bytes. Runs off the main thread.
    private fun handleCheckSafFiles(call: MethodCall, result: MethodChannel.Result) {
        val uris = call.argument<List<String>>("uris") ?: emptyList()
        Thread {
            try {
                val exists = HashMap<String, Boolean>()
                for (u in uris) {
                    val ok = try {
                        Uri.parse(u).let { uri ->
                            contentResolver.openFileDescriptor(uri, "r")?.use { true } ?: false
                        }
                    } catch (e: Exception) {
                        false
                    }
                    exists[u] = ok
                }
                runOnUiThread { result.success(exists) }
            } catch (e: Exception) {
                Log.e(TAG, "checkSafFiles failed: ${e.message}", e)
                runOnUiThread { result.error("CHECK_ERROR", e.message, null) }
            }
        }.start()
    }

    // Extract a short audio window starting at a bookmark and write it as an
    // AAC .m4a clip (bookmark clip export). Runs off the main thread.
    private fun handleExportClip(call: MethodCall, result: MethodChannel.Result) {
        val source = call.argument<String>("source")
        val isLocal = call.argument<Boolean>("isLocal") ?: true
        val headers = call.argument<Map<String, String>>("headers")
        val startSeconds = call.argument<Double>("startSeconds") ?: 0.0
        val durationSeconds = call.argument<Double>("durationSeconds") ?: 60.0
        val outPath = call.argument<String>("outPath")
        if (source == null || outPath == null) {
            result.error("CLIP_ARGS", "Missing source or outPath", null)
            return
        }
        Thread {
            val ok = AudioClipExporter.exportM4a(
                applicationContext, source, isLocal, headers, startSeconds, durationSeconds, outPath)
            runOnUiThread {
                if (ok) result.success(true)
                else result.error("CLIP_FAILED", "Could not export clip", null)
            }
        }.start()
    }

    private fun handleInit(result: MethodChannel.Result) {
        try {
            val tempEq = Equalizer(0, 0)
            val numBands = tempEq.numberOfBands.toInt()
            val frequencies = mutableListOf<Int>()
            for (i in 0 until numBands) {
                frequencies.add(tempEq.getCenterFreq(i.toShort()) / 1000)
            }
            val bandRange = tempEq.bandLevelRange
            val minLevel = bandRange[0] / 100.0
            val maxLevel = bandRange[1] / 100.0
            tempEq.release()

            effectsAvailable = true
            Log.d(TAG, "init: $numBands bands, frequencies=$frequencies, range=[$minLevel, $maxLevel]dB")
            result.success(mapOf(
                "bands" to numBands,
                "frequencies" to frequencies,
                "minLevel" to minLevel,
                "maxLevel" to maxLevel
            ))
        } catch (e: Exception) {
            effectsAvailable = false
            Log.d(TAG, "EQ probe deferred until playback: ${e.message}")
            result.success(mapOf(
                "bands" to 5,
                "frequencies" to listOf(60, 230, 910, 3600, 14000),
                "minLevel" to -15.0,
                "maxLevel" to 15.0,
                "deferred" to true
            ))
        }
    }

    private fun handleAttachSession(sessionId: Int, result: MethodChannel.Result) {
        try {
            Log.d(TAG, "attachSession: $sessionId (previous: $currentSessionId, haveEffects=${equalizer != null})")
            // ExoPlayer reuses one audio session id across books. Re-attaching to
            // the SAME live session must reuse the effects already bound to it —
            // building a second Equalizer/BassBoost/etc. on that session without
            // releasing the old ones leaks native effects every book switch and
            // can cost our instance control of the engine, so EQ silently stops
            // affecting the sound until the process restarts. Only tear down and
            // rebuild when the session actually changed. Dart re-pushes the band /
            // enabled / effect values right after this call in either case.
            if (sessionId != 0 && sessionId == currentSessionId && equalizer != null) {
                result.success(true)
                return
            }
            releaseEffects()
            currentSessionId = sessionId

            if (sessionId == 0) {
                result.success(true)
                return
            }

            // init() probes Equalizer(0, 0) on the global output mix, which some
            // devices/HAL states reject with a catchable Error -3 right after a
            // process start (e.g. just after an app update) — which used to leave
            // effectsAvailable=false and EQ silent until a force-restart. A real
            // per-session effect usually still works, so build it here regardless
            // of the probe result and let this construction decide availability.
            // (A device that hard-crashes on construction would have crashed at
            // init already, so reaching this point means construction is catch-safe.)
            try {
                equalizer = Equalizer(0, sessionId).apply { enabled = false }
                effectsAvailable = true
            } catch (e: Exception) {
                effectsAvailable = false
                equalizer = null
                Log.w(TAG, "attachSession: Equalizer unavailable on session $sessionId: ${e.message}")
                result.success(true)
                return
            }
            bassBoost = try {
                BassBoost(0, sessionId).apply { enabled = false }
            } catch (e: Exception) {
                Log.w(TAG, "BassBoost not supported: ${e.message}"); null
            }
            virtualizer = try {
                Virtualizer(0, sessionId).apply { enabled = false }
            } catch (e: Exception) {
                Log.w(TAG, "Virtualizer not supported: ${e.message}"); null
            }
            loudnessEnhancer = try {
                LoudnessEnhancer(sessionId).apply {
                    setTargetGain(eqLoudnessGainMb)
                    enabled = false
                }
            } catch (e: Exception) {
                Log.w(TAG, "LoudnessEnhancer not supported: ${e.message}"); null
            }

            // Alpha: capture LoudnessEnhancer/eq state on attach for GH #179 (volume falls off).
            Log.d(TAG, "Effects attached to session $sessionId: eqEnabled=$eqEnabled loudnessGainMb=$eqLoudnessGainMb loudnessEffectOk=${loudnessEnhancer != null}")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "attachSession failed: ${e.message}")
            result.error("EQ_ATTACH_ERROR", e.message, null)
        }
    }

    private fun handleSetEnabled(enabled: Boolean, result: MethodChannel.Result) {
        try {
            // Master switch gates only the band EQ. Bass / virtualizer /
            // loudness are independent and track their own values, so they
            // keep working with the equalizer off.
            eqEnabled = enabled
            equalizer?.enabled = enabled
            result.success(true)
        } catch (e: Exception) {
            result.error("EQ_ERROR", e.message, null)
        }
    }

    private fun handleSetBand(band: Int, level: Int, result: MethodChannel.Result) {
        try {
            equalizer?.setBandLevel(band.toShort(), level.toShort())
            result.success(true)
        } catch (e: Exception) {
            result.error("EQ_ERROR", e.message, null)
        }
    }

    private fun handleSetBassBoost(strength: Int, result: MethodChannel.Result) {
        try {
            val s = strength.toShort().coerceIn(0, 1000)
            bassBoost?.setStrength(s)
            // Independent of the band-EQ master: on when there's something to do.
            bassBoost?.enabled = s > 0
            result.success(true)
        } catch (e: Exception) {
            result.error("EQ_ERROR", e.message, null)
        }
    }

    private fun handleSetVirtualizer(strength: Int, result: MethodChannel.Result) {
        try {
            val s = strength.toShort().coerceIn(0, 1000)
            virtualizer?.setStrength(s)
            virtualizer?.enabled = s > 0
            result.success(true)
        } catch (e: Exception) {
            result.error("EQ_ERROR", e.message, null)
        }
    }

    private fun handleSetLoudness(gain: Int, result: MethodChannel.Result) {
        try {
            eqLoudnessGainMb = gain
            loudnessEnhancer?.setTargetGain(gain)
            loudnessEnhancer?.enabled = gain > 0
            result.success(true)
        } catch (e: Exception) {
            result.error("EQ_ERROR", e.message, null)
        }
    }

    private fun releaseEffects() {
        try { equalizer?.release() } catch (_: Exception) {}
        try { bassBoost?.release() } catch (_: Exception) {}
        try { virtualizer?.release() } catch (_: Exception) {}
        try { loudnessEnhancer?.release() } catch (_: Exception) {}
        equalizer = null
        bassBoost = null
        virtualizer = null
        loudnessEnhancer = null
        eqLoudnessGainMb = 0
        eqEnabled = false
    }

    private fun isBluetoothAudioConnected(): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            return devices.any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            }
        }
        @Suppress("DEPRECATION")
        return am.isBluetoothA2dpOn || am.isBluetoothScoOn
    }

    // Discard media search intents from Google Assistant / Android Auto so the
    // voice query text doesn't leak into the app's search field.
    override fun onNewIntent(intent: Intent) {
        val action = intent.action
        if (action == MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH ||
            action == Intent.ACTION_SEARCH ||
            action == "android.media.action.MEDIA_PLAY_FROM_SEARCH") {
            Log.d(TAG, "Discarding search intent: $action")
            return
        }
        // FlutterActivity never adopts a new intent, so the widget's "launched
        // from" query kept answering with whatever intent created the activity.
        // On a task restored from a dead process that lost a fresh play-button
        // tap and replayed an old one. Keep the latest so the query sees the
        // tap that actually opened the app this time.
        setIntent(intent)
        super.onNewIntent(intent)
    }

    override fun onDestroy() {
        releaseEffects()
        super.onDestroy()
    }

}
