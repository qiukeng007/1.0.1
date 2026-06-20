package com.smarteye.smart_eye_stock

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.ToneGenerator
import android.speech.RecognizerIntent
import android.webkit.CookieManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var speechChannel: MethodChannel? = null
    private var audioRecord: AudioRecord? = null
    private var isRecording = false
    private var recordThread: Thread? = null
    private var pendingRecordResult: MethodChannel.Result? = null
    private var pendingRecordPath: String = ""

    companion object {
        private const val REQUEST_RECORD_AUDIO = 9998
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Cookie channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.smarteye/cookies")
            .setMethodCallHandler { call, result ->
                if (call.method == "getCookies") {
                    val url = call.argument<String>("url") ?: ""
                    val cookieManager = CookieManager.getInstance()
                    val cookies = cookieManager.getCookie(url) ?: ""
                    result.success(cookies)
                } else {
                    result.notImplemented()
                }
            }

        // Speech recognition channel
        speechChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.smarteye/speech")
        speechChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "listen") {
                val locale = call.argument<String>("locale") ?: "zh-CN"
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                    putExtra(RecognizerIntent.EXTRA_PROMPT, "说话中…")
                }
                if (intent.resolveActivity(packageManager) != null) {
                    startActivityForResult(intent, 9999)
                    result.success(null)
                } else {
                    result.error("NOT_AVAILABLE", "语音识别不可用", null)
                }
            } else {
                result.notImplemented()
            }
        }

        // Audio recording channel (PCM WAV for ASR)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.smarteye/audio")
            .setMethodCallHandler { call, result ->
                if (call.method == "startRecord") {
                    val path = call.argument<String>("path") ?: ""

                    // Check runtime permission (required on Android 6+)
                    if (ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.RECORD_AUDIO)
                        != PackageManager.PERMISSION_GRANTED) {
                        pendingRecordResult = result
                        pendingRecordPath = path
                        ActivityCompat.requestPermissions(
                            this@MainActivity,
                            arrayOf(Manifest.permission.RECORD_AUDIO),
                            REQUEST_RECORD_AUDIO
                        )
                        return@setMethodCallHandler
                    }

                    startRecording(path)
                    result.success(true)
                } else if (call.method == "stopRecord") {
                    stopRecording()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        // Audio playback channel — short beeps for voice recording feedback
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.smarteye/audio_play")
            .setMethodCallHandler { call, result ->
                if (call.method == "beep") {
                    val start = call.argument<Boolean>("start") ?: true
                    val toneType = if (start) ToneGenerator.TONE_PROP_BEEP else ToneGenerator.TONE_PROP_NACK
                    val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80)
                    tone.startTone(toneType, 150)
                    // Release after the tone duration
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        tone.release()
                    }, 200)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun startRecording(path: String) {
        val sampleRate = 16000
        val channelConfig = AudioFormat.CHANNEL_IN_MONO
        val audioFormat = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
        // Use 2× the minimum buffer for stable reads, capped at 4096
        val bufferSize = (minBuf * 2).coerceIn(2048, 4096)

        audioRecord = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, // tuned for ASR quality
            sampleRate, channelConfig, audioFormat,
            bufferSize
        )

        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            audioRecord?.release()
            audioRecord = null
            throw IllegalStateException("AudioRecord init failed — microphone permission denied or in use")
        }

        audioRecord?.startRecording()
        isRecording = true

        val dataStream = ByteArrayOutputStream()

        recordThread = thread {
            val buffer = ByteArray(bufferSize)
            while (isRecording) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: break
                if (read > 0) dataStream.write(buffer, 0, read)
            }

            // Write WAV file
            val audioData = dataStream.toByteArray()
            FileOutputStream(path).use { out ->
                val totalDataLen = audioData.size + 36
                val byteRate = sampleRate * 2
                // RIFF
                out.write("RIFF".toByteArray())
                out.write(intLE(totalDataLen))
                out.write("WAVE".toByteArray())
                // fmt
                out.write("fmt ".toByteArray())
                out.write(intLE(16))
                out.write(shortLE(1))      // PCM
                out.write(shortLE(1))      // mono
                out.write(intLE(sampleRate))
                out.write(intLE(byteRate))
                out.write(shortLE(2))      // block align
                out.write(shortLE(16))     // bits per sample
                // data
                out.write("data".toByteArray())
                out.write(intLE(audioData.size))
                out.write(audioData)
            }
        }
    }

    private fun stopRecording() {
        isRecording = false
        recordThread?.join(2000)
        audioRecord?.apply {
            stop()
            release()
        }
        audioRecord = null
        recordThread = null
    }

    private fun intLE(v: Int) = byteArrayOf(
        (v and 0xff).toByte(),
        (v shr 8 and 0xff).toByte(),
        (v shr 16 and 0xff).toByte(),
        (v shr 24 and 0xff).toByte()
    )

    private fun shortLE(v: Int) = byteArrayOf(
        (v and 0xff).toByte(),
        (v shr 8 and 0xff).toByte()
    )

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_RECORD_AUDIO) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                try {
                    startRecording(pendingRecordPath)
                    pendingRecordResult?.success(true)
                } catch (e: Exception) {
                    pendingRecordResult?.error("RECORD_ERROR", e.message, null)
                }
            } else {
                pendingRecordResult?.error("PERMISSION_DENIED", "麦克风权限被拒绝", null)
            }
            pendingRecordResult = null
            pendingRecordPath = ""
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 9999) {
            var spoken = ""
            if (resultCode == Activity.RESULT_OK && data != null) {
                val results = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                spoken = results?.firstOrNull() ?: ""
            }
            speechChannel?.invokeMethod("onSpeechResult", spoken)
        }
    }
}
