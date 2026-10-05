package com.example.morsl

import android.graphics.BitmapFactory
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/** Opt-in real-model test; only reads an explicitly staged fixture, never app records. */
class DishCutoutsDeviceTest {
    @Test fun separatesSuppliedPhotoOffline() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val folder = File(context.cacheDir, "cutout-fixture")
        val photo = File(folder, "photo.png")
        assertTrue("Stage the supplied fixture before running this opt-in test", photo.isFile)
        val engine = DishCutouts(context)
        // Models are staged locally. prepare() verifies checksums and makes no request.
        assertTrue(engine.prepare())
        val start = SystemClock.elapsedRealtime()
        val rows = engine.subjects(photo.absolutePath)
        val elapsed = SystemClock.elapsedRealtime()-start
        assertEquals("All four main dishes should be separate",4,rows.size)
        val result=JSONArray()
        rows.forEachIndexed { index,row ->
            val bytes=row["mask"] as ByteArray
            val mask=BitmapFactory.decodeByteArray(bytes,0,bytes.size)
            val pixels=IntArray(mask.width*mask.height)
            mask.getPixels(pixels,0,mask.width,0,0,mask.width,mask.height)
            assertTrue("Mask must retain the dish",pixels.count { (it ushr 24)>0 } > pixels.size/3)
            assertTrue("Mask must remove background",pixels.any { (it ushr 24)==0 })
            mask.recycle()
            File(folder,"mask-$index.png").writeBytes(bytes)
            result.put(JSONObject().put("bounds",JSONArray(row["bounds"] as List<*>)))
        }
        File(folder,"result.json").writeText(JSONObject().put("elapsedMs",elapsed).put("plates",result).toString())
    }
}
