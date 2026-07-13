package com.example.pocketwindow

import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap

class H264VideoDecoder(private val textures: TextureRegistry) {
    private data class Session(
        val textureEntry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
        val codec: MediaCodec,
    )

    private val sessions = ConcurrentHashMap<Long, Session>()
    private val lock = Any()

    /**
     * Reserve a Flutter SurfaceTexture and wrap it with a Surface. Must be
     * invoked on the platform (UI) thread because [TextureRegistry] APIs
     * require it. Returns a handle that subsequently identifies the session.
     */
    fun prepareSurface(width: Int, height: Int): SurfaceHandle {
        require(width > 0 && height > 0) { "invalid video size" }
        val textureEntry = textures.createSurfaceTexture()
        textureEntry.surfaceTexture().setDefaultBufferSize(width, height)
        val surface = Surface(textureEntry.surfaceTexture())
        return SurfaceHandle(textureEntry, surface)
    }

    /**
     * Configure and start a MediaCodec decoder bound to [handle]'s surface.
     * Safe to call on any thread; intended to run on a background worker
     * because MediaCodec.configure / start can block hundreds of ms.
     */
    fun attachCodec(
        handle: SurfaceHandle,
        codecName: String,
        width: Int,
        height: Int,
        configData: ByteArray?,
    ): Long {
        val mime = when (codecName.lowercase()) {
            "h265", "hevc" -> "video/hevc"
            else -> "video/avc"
        }
        val codec = MediaCodec.createDecoderByType(mime)
        val format = MediaFormat.createVideoFormat(mime, width, height)
        if (configData != null) {
            if (mime == "video/hevc") {
                val csd = extractHevcCsd(configData)
                if (csd.isNotEmpty()) {
                    format.setByteBuffer("csd-0", ByteBuffer.wrap(csd))
                }
            } else {
                val avcCsd = extractAvcCsd(configData)
                avcCsd["csd-0"]?.let { format.setByteBuffer("csd-0", ByteBuffer.wrap(it)) }
                avcCsd["csd-1"]?.let { format.setByteBuffer("csd-1", ByteBuffer.wrap(it)) }
            }
        }
        codec.configure(format, handle.surface, null, 0)
        codec.start()
        val textureId = handle.textureEntry.id()
        sessions[textureId] = Session(handle.textureEntry, handle.surface, codec)
        return textureId
    }

    fun pushFrame(textureId: Long, data: ByteArray, ptsUs: Long): Map<String, Any> {
        val startedNs = System.nanoTime()
        val session: Session
        synchronized(lock) {
            session = sessions[textureId] ?: return mapOf(
                "rendered" to false,
                "error" to "missing_session",
            )
        }
        val codec = session.codec
        var rendered = false
        var queuedInput = false
        var outputCount = 0
        var renderedOutputCount = 0
        var inputWaitUs = 0L
        var outputWaitUs = 0L
        var releaseOutputUs = 0L
        val inputWaitStartedNs = System.nanoTime()
        val inputIndex = codec.dequeueInputBuffer(2_000)
        inputWaitUs = (System.nanoTime() - inputWaitStartedNs) / 1_000
        if (inputIndex >= 0) {
            val inputBuffer: ByteBuffer? = codec.getInputBuffer(inputIndex)
            inputBuffer?.clear()
            inputBuffer?.put(data)
            codec.queueInputBuffer(inputIndex, 0, data.size, ptsUs, 0)
            queuedInput = true
        }

        val info = MediaCodec.BufferInfo()
        while (true) {
            val outputWaitStartedNs = System.nanoTime()
            val outputIndex = codec.dequeueOutputBuffer(info, 5_000)
            outputWaitUs += (System.nanoTime() - outputWaitStartedNs) / 1_000
            if (outputIndex >= 0) {
                val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                val shouldRender = !isConfig
                val releaseStartedNs = System.nanoTime()
                codec.releaseOutputBuffer(outputIndex, shouldRender)
                releaseOutputUs += (System.nanoTime() - releaseStartedNs) / 1_000
                outputCount += 1
                if (shouldRender) renderedOutputCount += 1
                rendered = rendered || shouldRender
            } else if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ||
                outputIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED
            ) {
                continue
            } else if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                break
            } else {
                break
            }
        }
        return mapOf(
            "rendered" to rendered,
            "queued_input" to queuedInput,
            "input_wait_us" to inputWaitUs,
            "output_wait_us" to outputWaitUs,
            "release_output_us" to releaseOutputUs,
            "output_count" to outputCount,
            "rendered_output_count" to renderedOutputCount,
            "total_us" to ((System.nanoTime() - startedNs) / 1_000),
        )
    }

    fun stop(textureId: Long) {
        val removed: Session?
        synchronized(lock) {
            removed = sessions.remove(textureId)
        }
        val session = removed ?: return
        try {
            session.codec.stop()
        } catch (_: Exception) {
        }
        try {
            session.codec.release()
        } catch (_: Exception) {
        }
        try {
            session.surface.release()
        } catch (_: Exception) {
        }
        try {
            session.textureEntry.release()
        } catch (_: Exception) {
        }
    }

    fun stopAll() {
        val ids = sessions.keys.toList()
        for (id in ids) {
            stop(id)
        }
    }

    private fun extractHevcCsd(data: ByteArray): ByteArray {
        val units = splitAnnexB(data)
        val csd = ArrayList<Byte>()
        for (unit in units) {
            if (unit.isEmpty()) continue
            val nalType = (unit[0].toInt() and 0x7E) shr 1
            if (nalType == 32 || nalType == 33 || nalType == 34) {
                csd.add(0)
                csd.add(0)
                csd.add(0)
                csd.add(1)
                for (value in unit) csd.add(value)
            }
        }
        return csd.toByteArray()
    }

    private fun extractAvcCsd(data: ByteArray): Map<String, ByteArray> {
        val units = splitAnnexB(data)
        var sps: ByteArray? = null
        var pps: ByteArray? = null
        for (unit in units) {
            if (unit.isEmpty()) continue
            when (unit[0].toInt() and 0x1F) {
                7 -> sps = withStartCode(unit)
                8 -> pps = withStartCode(unit)
            }
        }
        val result = HashMap<String, ByteArray>()
        if (sps != null) result["csd-0"] = sps
        if (pps != null) result["csd-1"] = pps
        return result
    }

    private fun withStartCode(unit: ByteArray): ByteArray {
        val result = ByteArray(unit.size + 4)
        result[0] = 0
        result[1] = 0
        result[2] = 0
        result[3] = 1
        System.arraycopy(unit, 0, result, 4, unit.size)
        return result
    }

    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Pair<Int, Int>>()
        var i = 0
        while (i <= data.size - 3) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0) {
                if (data[i + 2].toInt() == 1) {
                    starts.add(Pair(i, 3))
                    i += 3
                    continue
                }
                if (i <= data.size - 4 && data[i + 2].toInt() == 0 && data[i + 3].toInt() == 1) {
                    starts.add(Pair(i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        if (starts.isEmpty()) return emptyList()
        val result = ArrayList<ByteArray>()
        for (index in starts.indices) {
            val start = starts[index].first + starts[index].second
            val end = if (index + 1 < starts.size) starts[index + 1].first else data.size
            if (end > start) {
                result.add(data.copyOfRange(start, end))
            }
        }
        return result
    }

    /**
     * Opaque pair of a Flutter surface texture and its [Surface]. Created on
     * the platform thread and consumed on the worker thread.
     */
    class SurfaceHandle(
        val textureEntry: TextureRegistry.SurfaceTextureEntry,
        val surface: Surface,
    ) {
        fun release() {
            try { surface.release() } catch (_: Exception) {}
            try { textureEntry.release() } catch (_: Exception) {}
        }
    }
}
