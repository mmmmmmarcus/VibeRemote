package app.vvhisper.keyboard;

import static org.junit.Assert.*;
import android.content.ClipData;
import android.os.PersistableBundle;
import java.util.*;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class) @Config(sdk=35)
public class ClipboardHistoryTest {
    static final class MemoryStorage implements ClipboardHistory.Storage {
        String value = "[]";
        public String read() { return value; }
        public void write(String text) { value = text; }
    }
    @Test public void boundedUniqueNewestFirstPersistsExactText() {
        MemoryStorage storage = new MemoryStorage(); ClipboardHistory history = new ClipboardHistory(storage);
        for (String text : new String[]{"one", "two", "three", "four", "five", "six", "two"}) history.record(text);
        assertEquals(Arrays.asList("two", "six", "five", "four", "three"), history.items());
        history.record(" \n "); history.record(String.join("", Collections.nCopies(20001,"x"))); history.record(null);
        assertEquals(5, history.items().size());
        history.record("  中文\n👨‍👩‍👧‍👦  ");
        assertEquals("  中文\n👨‍👩‍👧‍👦  ", new ClipboardHistory(storage).items().get(0));
        assertEquals("中文 👨‍👩‍👧‍👦", ClipboardHistory.preview(history.items().get(0)));
        history.clear(); assertTrue(new ClipboardHistory(storage).items().isEmpty());
    }
    @Test public void rejectsSensitiveAndNonTextClips() {
        ClipData clip = ClipData.newPlainText("label", "copied");
        assertEquals("copied", ClipboardHistory.textFrom(clip));
        PersistableBundle extras = new PersistableBundle(); extras.putBoolean("android.content.extra.IS_SENSITIVE", true);
        clip.getDescription().setExtras(extras);
        assertNull(ClipboardHistory.textFrom(clip)); assertNull(ClipboardHistory.textFrom(null));
        assertNull(ClipboardHistory.textFrom(ClipData.newRawUri("image", android.net.Uri.parse("content://example/image"))));
    }
    @Test public void corruptStorageAndWriteFailureRemainBoundedWithoutPlaintextFallback() {
        ClipboardHistory history = new ClipboardHistory(new ClipboardHistory.Storage() {
            public String read() { return "invalid"; }
            public void write(String text) throws Exception { throw new java.io.IOException(); }
        });
        assertTrue(history.items().isEmpty());
        for (int i=0;i<20;i++) history.record("text " + i);
        assertEquals(5, history.items().size());
        history.clear(); assertTrue(history.items().isEmpty());
    }
}
