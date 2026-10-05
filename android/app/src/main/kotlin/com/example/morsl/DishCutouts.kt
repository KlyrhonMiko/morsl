package com.example.morsl

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.security.MessageDigest
import kotlin.math.*

/** Detect dishes, then prompt a separate mask for each. Photos never leave the device. */
internal class DishCutouts(context: Context) {
    private val directory = File(context.noBackupFilesDir, "dish-models-v1")
    private val receipt get() = File(directory, "verified-v1")
    private data class Model(val name: String, val url: String, val size: Long, val sha: String)
    private val models = listOf(
        Model("detector.onnx", "https://huggingface.co/onnx-community/grounding-dino-tiny-ONNX/resolve/ff690b0a8050566c290287545bd059350f3e9096/onnx/model_quantized.onnx", 203824675,
            "70bf2d3310d1ae73769c96a71e00cbf2861eb33a1f4d97d84a108a7bf02c03c9"),
        Model("encoder.onnx", "https://huggingface.co/Acly/MobileSAM/resolve/0d3b403339b4674a82493d5e97964dd78089ddc8/mobile_sam_image_encoder.onnx", 28157093,
            "580f5fb648ea1062c0aabc26217aed56921985f03f0cbbd852bba81d760cc749"),
        Model("decoder.onnx", "https://huggingface.co/Acly/MobileSAM/resolve/0d3b403339b4674a82493d5e97964dd78089ddc8/sam_mask_decoder_multi.onnx", 16496559,
            "8976b90a87ba50a6a72217a5ff994f7d25ce16f2229fcc1ed259e1294c622ffe")
    )
    fun available() = receipt.isFile && models.all { File(directory, it.name).length() == it.size }
    fun prepare(): Boolean {
        directory.mkdirs()
        receipt.delete()
        for (model in models) {
            val target = File(directory, model.name)
            if (target.length() == model.size && digest(target) == model.sha) continue
            val partial = File(directory, model.name + ".partial")
            val connection = URL(model.url).openConnection() as HttpURLConnection
            connection.connectTimeout = 30000
            connection.readTimeout = 60000
            try {
                check(connection.responseCode == 200) { "Model download unavailable. Please retry online." }
                connection.inputStream.use { input -> partial.outputStream().use { input.copyTo(it) } }
                check(partial.length() == model.size && digest(partial) == model.sha) {
                    "Model download was incomplete. Please retry online."
                }
                check(partial.renameTo(target)) { "Could not store the cutout model." }
            } finally {
                connection.disconnect()
                partial.delete()
            }
        }
        receipt.writeText("Grounding DINO + MobileSAM v1")
        return available()
    }
    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }
    private val env get() = OrtEnvironment.getEnvironment()
    private fun session(name: String): OrtSession = OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads(min(4, Runtime.getRuntime().availableProcessors()))
        options.setInterOpNumThreads(1)
        options.setCPUArenaAllocator(false)
        env.createSession(File(directory, name).absolutePath, options)
    }
    private fun floats(values: FloatArray, vararg shape: Long) =
        OnnxTensor.createTensor(env, FloatBuffer.wrap(values), shape)
    private fun longs(values: LongArray, vararg shape: Long) =
        OnnxTensor.createTensor(env, LongBuffer.wrap(values), shape)

    internal data class Box(val l: Float, val t: Float, val r: Float, val b: Float, val score: Float) {
        val area get() = (r - l) * (b - t)
        fun intersection(other: Box) = max(0f, min(r, other.r) - max(l, other.l)) *
            max(0f, min(b, other.b) - max(t, other.t))
    }
    private fun detect(photo: Bitmap): List<Box> {
        val scaled = Bitmap.createScaledBitmap(photo, 800, 800, true)
        val pixels = IntArray(800 * 800)
        scaled.getPixels(pixels, 0, 800, 0, 0, 800, 800)
        if (scaled !== photo) scaled.recycle()
        val mean = floatArrayOf(.485f, .456f, .406f)
        val std = floatArrayOf(.229f, .224f, .225f)
        val rgb = FloatArray(pixels.size * 3)
        for (c in 0..2) for (i in pixels.indices) {
            rgb[c * pixels.size + i] = (((pixels[i] shr (16 - c * 8)) and 255) / 255f - mean[c]) / std[c]
        }
        // Fixed BERT tokenization of "plate . bowl . food tray ." from the pinned tokenizer.
        val ids = longArrayOf(101, 5127, 1012, 4605, 1012, 2833, 11851, 1012, 102)
        val inputs = mapOf(
            "pixel_values" to floats(rgb, 1, 3, 800, 800),
            "pixel_mask" to longs(LongArray(800 * 800) { 1 }, 1, 800, 800),
            "input_ids" to longs(ids, 1, ids.size.toLong()),
            "token_type_ids" to longs(LongArray(ids.size), 1, ids.size.toLong()),
            "attention_mask" to longs(LongArray(ids.size) { 1 }, 1, ids.size.toLong())
        )
        try {
            session("detector.onnx").use { detector ->
                detector.run(inputs).use { output ->
                    val logits = (output.get("logits").get() as OnnxTensor).floatBuffer
                    val boxes = (output.get("pred_boxes").get() as OnnxTensor).floatBuffer
                    val candidates = mutableListOf<Box>()
                    for (i in 0 until 900) {
                        val logit = intArrayOf(1, 3, 5, 6).maxOf { logits.get(i * 256 + it) }
                        val score = 1f / (1f + exp(-logit))
                        if (score < .25f) continue
                        val x = boxes.get(i * 4); val y = boxes.get(i * 4 + 1)
                        val w = boxes.get(i * 4 + 2); val h = boxes.get(i * 4 + 3)
                        val box = Box(max(0f, x - w / 2), max(0f, y - h / 2),
                            min(1f, x + w / 2), min(1f, y + h / 2), score)
                        if (box.area >= .012f && box.area <= 1f) candidates.add(box)
                    }
                    return selectBoxes(candidates)
                }
            }
        } finally { inputs.values.forEach { it.close() } }
    }
    fun subjects(path: String): List<Map<String, Any>> {
        check(available()) { "Download the dish models once in Settings, then retry offline." }
        val photo = requireNotNull(BitmapFactory.decodeFile(path)) { "The photo could not be opened." }
        try {
            val boxes = detect(photo)
            if (boxes.isEmpty()) return emptyList()
            val factor = 1024f / max(photo.width, photo.height)
            val width = (photo.width * factor).roundToInt()
            val height = (photo.height * factor).roundToInt()
            val scaled = Bitmap.createScaledBitmap(photo, width, height, true)
            val pixels = IntArray(width * height)
            scaled.getPixels(pixels, 0, width, 0, 0, width, height)
            if (scaled !== photo) scaled.recycle()
            val rgb = FloatArray(pixels.size * 3)
            for (i in pixels.indices) for (c in 0..2) rgb[i * 3 + c] = ((pixels[i] shr (16 - c * 8)) and 255).toFloat()
            // Free the detector before loading either mask stage to bound peak memory.
            val embedding = floats(rgb, height.toLong(), width.toLong(), 3).use { input ->
                session("encoder.onnx").use { encoder ->
                    encoder.run(mapOf("input_image" to input)).use { result ->
                        val buffer = (result[0] as OnnxTensor).floatBuffer
                        FloatArray(buffer.remaining()).also { buffer.get(it) }
                    }
                }
            }
            floats(embedding, 1, 256, 64, 64).use { encoded ->
                session("decoder.onnx").use { decoder ->
                    return boxes.mapNotNull { box -> mask(decoder, encoded, box, width, height, photo.width, photo.height) }
                }
            }
        } finally { photo.recycle() }
    }
    private fun mask(decoder: OrtSession, embedding: OnnxTensor, box: Box,
                     scaledW: Int, scaledH: Int, width: Int, height: Int): Map<String, Any>? {
        // Include raised toppings; the center prompt includes the food as well as the plate.
        val dx = (box.r - box.l) * .06f; val dy = (box.b - box.t) * .15f
        val l = max(0f, box.l - dx); val t = max(0f, box.t - dy)
        val r = min(1f, box.r + dx); val b = min(1f, box.b + dy)
        val own = mapOf(
            "point_coords" to floats(floatArrayOf(l * scaledW, t * scaledH, r * scaledW, b * scaledH,
                (l + r) / 2 * scaledW, (t + b) / 2 * scaledH), 1, 3, 2),
            "point_labels" to floats(floatArrayOf(2f, 3f, 1f), 1, 3),
            "mask_input" to floats(FloatArray(256 * 256), 1, 1, 256, 256),
            "has_mask_input" to floats(floatArrayOf(0f), 1),
            "orig_im_size" to floats(floatArrayOf(height.toFloat(), width.toFloat()), 2)
        )
        try {
            decoder.run(own + ("image_embeddings" to embedding)).use { output ->
                val scores = (output.get("iou_predictions").get() as OnnxTensor).floatBuffer
                val best = (0 until scores.remaining()).maxBy { scores.get(it) }
                val values = (output.get("masks").get() as OnnxTensor).floatBuffer
                val binary = BooleanArray(width * height)
                val offset = best * binary.size
                for (y in (t * height).toInt() until min(height, ceil(b * height).toInt())) {
                    for (x in (l * width).toInt() until min(width, ceil(r * width).toInt())) {
                        binary[y * width + x] = values.get(offset + y * width + x) > 0f
                    }
                }
                cleanMask(binary, width, height)
                var left = width; var top = height; var right = -1; var bottom = -1
                for (i in binary.indices) if (binary[i]) {
                    left = min(left, i % width); right = max(right, i % width)
                    top = min(top, i / width); bottom = max(bottom, i / width)
                }
                if (right < left || bottom < top) return null
                val w = right - left + 1; val h = bottom - top + 1
                if (w.toLong() * h < width.toLong() * height / 1000) return null
                val pixels = IntArray(w * h) { i -> if (binary[(top + i / w) * width + left + i % w]) -1 else 0 }
                val bitmap = Bitmap.createBitmap(pixels, w, h, Bitmap.Config.ARGB_8888)
                val bytes = ByteArrayOutputStream()
                try { bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes) } finally { bitmap.recycle() }
                return mapOf("mask" to bytes.toByteArray(), "bounds" to listOf(
                    left.toDouble() / width, top.toDouble() / height, w.toDouble() / width, h.toDouble() / height))
            }
        } finally { own.values.forEach { it.close() } }
    }
    companion object {
        internal fun selectBoxes(candidates: List<Box>): List<Box> {
            val kept = mutableListOf<Box>()
            for (box in candidates.sortedByDescending { it.score }) {
                if (kept.none { box.intersection(it) / (box.area + it.area - box.intersection(it)) > .5f }) kept.add(box)
            }
            // A sauce cup wholly inside a plate belongs to that dish.
            return kept.filter { child -> kept.none { parent ->
                parent !== child && parent.area > child.area * 1.8f && child.intersection(parent) / child.area > .9f
            } }.take(12).sortedWith(compareBy<Box> { it.t }.thenBy { it.l })
        }
        /** Remove remote fragments, then fill enclosed holes within the dish silhouette. */
        internal fun cleanMask(mask: BooleanArray, width: Int, height: Int) {
            val visited = BooleanArray(mask.size)
            val queue = IntArray(mask.size)
            var largest = IntArray(0)
            fun visit(seed: Int, foreground: Boolean): Int {
                var head = 0; var tail = 1; queue[0] = seed; visited[seed] = true
                while (head < tail) {
                    val i = queue[head++]; val x = i % width
                    fun add(j: Int) { if (!visited[j] && mask[j] == foreground) { visited[j] = true; queue[tail++] = j } }
                    if (x > 0) add(i - 1)
                    if (x + 1 < width) add(i + 1)
                    if (i >= width) add(i - width)
                    if (i + width < mask.size) add(i + width)
                }
                return tail
            }
            for (i in mask.indices) if (mask[i] && !visited[i]) {
                val count = visit(i, true)
                if (count > largest.size) largest = queue.copyOf(count)
            }
            mask.fill(false); largest.forEach { mask[it] = true }; visited.fill(false)
            for (x in 0 until width) for (y in intArrayOf(0, height - 1)) {
                val i = y * width + x; if (!mask[i] && !visited[i]) visit(i, false)
            }
            for (y in 0 until height) for (x in intArrayOf(0, width - 1)) {
                val i = y * width + x; if (!mask[i] && !visited[i]) visit(i, false)
            }
            for (i in mask.indices) if (!visited[i]) mask[i] = true
        }
    }
}
