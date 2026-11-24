package app.vvhisper.keyboard;

import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import androidx.test.core.app.ApplicationProvider;

@RunWith(RobolectricTestRunner.class)
public class PortableConfigurationTest {
    @Test public void roundTripAndSettingsOnlyPreserveOmittedValues() throws Exception {
        var value = new PortableConfiguration(false, true, "test-asr", "test-polish");
        var restored = PortableConfiguration.decode(value.encode());
        assertEquals(value.seed, restored.seed); assertEquals(value.ark, restored.ark);
        assertEquals(value.polish, restored.polish); assertEquals(value.punctuation, restored.punctuation);
        android.content.Context context = ApplicationProvider.getApplicationContext();
        context.getSharedPreferences("keyboard", 0).edit().putBoolean("polish", true).putBoolean("sentencePunctuation", false).commit();
        new PortableConfiguration(false, null, null, null).apply(context);
        assertFalse(context.getSharedPreferences("keyboard", 0).getBoolean("polish", true));
        assertFalse(context.getSharedPreferences("keyboard", 0).getBoolean("sentencePunctuation", true));
        assertNull(PortableConfiguration.capture(context, false).seed);
    }
    @Test public void privateBuildTransfersSettingsWithoutTouchingCredentials() throws Exception {
        android.content.Context context = ApplicationProvider.getApplicationContext();
        context.getSharedPreferences("seed", 0).edit().putString("value", "legacy-sentinel").commit();
        context.getSharedPreferences("ark", 0).edit().putString("value", "legacy-sentinel").commit();
        new PortableConfiguration(false, true, "imported-seed", "imported-ark").apply(context);
        assertEquals("legacy-sentinel", context.getSharedPreferences("seed", 0).getString("value", ""));
        assertEquals("legacy-sentinel", context.getSharedPreferences("ark", 0).getString("value", ""));
        assertNull(PortableConfiguration.capture(context, true).seed);
        assertNull(PortableConfiguration.capture(context, true).ark);
    }
    @Test public void rejectsInvalidDocumentsBeforeApplying() {
        for (String text : new String[]{
            "{\"format\":\"vvhisper\",\"version\":2,\"settings\":{}}",
            "{\"format\":\"vvhisper\",\"version\":1,\"settings\":{\"polishDictation\":\"true\"}}",
            "{\"format\":\"vvhisper\",\"version\":1,\"settings\":{},\"credentials\":{\"seedASR\":\"\"}}",
            "{\"format\":\"vvhisper\",\"version\":1,\"settings\":{},\"credentials\":{\"polishing\":\"a b\"}}"
        }) assertThrows(Exception.class, () -> PortableConfiguration.decode(text.getBytes(StandardCharsets.UTF_8)));
        assertThrows(Exception.class, () -> PortableConfiguration.decode(new byte[65537]));
    }
}
