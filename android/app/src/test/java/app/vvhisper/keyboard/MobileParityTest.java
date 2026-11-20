package app.vvhisper.keyboard;

import static org.junit.Assert.*;
import android.content.Context;
import android.view.*;
import android.view.inputmethod.*;
import android.widget.*;
import androidx.test.core.app.ApplicationProvider;
import org.json.*;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class) @Config(sdk=35)
public class MobileParityTest {
    @Test public void miniHasOnlyOneRowAndPillsOpenAppShortcuts() throws Exception {
        var controller = org.robolectric.Robolectric.buildService(KeyboardService.class).create();
        KeyboardService service = controller.get();
        try {
            service.getSharedPreferences("keyboard",0).edit().putBoolean("mini",false).commit();
            LinearLayout board = (LinearLayout) service.onCreateInputView();
            board.measure(View.MeasureSpec.makeMeasureSpec(1080,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(0,View.MeasureSpec.UNSPECIFIED));
            board.layout(0,0,1080,board.getMeasuredHeight());
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
            LinearLayout strip = (LinearLayout) board.getChildAt(0);
            assertEquals("Shortcuts",strip.getChildAt(0).getContentDescription());
            strip.getChildAt(0).performClick();
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle();
            assertTrue(hasLabel(strip,"Clipboard History")); assertTrue(hasLabel(strip,"Open 1Password")); assertTrue(hasLabel(strip,"Open Messages")); assertTrue(hasLabel(strip,"Open Phone"));
            java.lang.reflect.Method compact = KeyboardService.class.getDeclaredMethod("setCompact",boolean.class); compact.setAccessible(true); compact.invoke(service,true);
            assertEquals(View.GONE,board.getChildAt(0).getVisibility());
            assertEquals(2,board.getChildCount());
            LinearLayout keys = (LinearLayout) board.getChildAt(1);
            assertEquals(4,keys.getChildCount()); assertEquals("Full keyboard",keys.getChildAt(0).getContentDescription()); assertEquals("Hold to dictate",keys.getChildAt(1).getContentDescription());
        } finally { controller.destroy(); }
    }
    private boolean hasLabel(View view,String text) {
        if (text.contentEquals(view.getContentDescription() == null ? "" : view.getContentDescription())) return true;
        if (view instanceof android.view.ViewGroup) { android.view.ViewGroup group=(android.view.ViewGroup)view; for(int i=0;i<group.getChildCount();i++) if(hasLabel(group.getChildAt(i),text)) return true; }
        return false;
    }
    @Test public void chinesePunctuationAndAlternativesPreservePeriod() {
        assertEquals("。", MobileSymbols.chinese("."));
        assertEquals("，", MobileSymbols.chinese(","));
        assertEquals("「", MobileSymbols.chinese("\""));
        assertTrue(MobileSymbols.alternatives("。").contains("."));
        assertTrue(MobileSymbols.alternatives("。").contains("…"));
        assertEquals("。", MobileSymbols.alternatives("。").get(0));
    }
    @Test public void localDictionaryKeepsCorrectChineseAndRepairsEnglish() throws Exception {
        Candidates candidates = new Candidates(); candidates.open(ApplicationProvider.getApplicationContext());
        try {
            assertEquals("I'm", candidates.correctEnglish("im"));
            assertEquals("don't", candidates.correctEnglish("dont"));
            assertEquals("DESIGN", candidates.correctEnglish("DESIGN"));
            assertEquals("我知道了", candidates.lookup("wozhidaole").get(0));
            assertTrue(candidates.lookup("zouch a".replace(" ", "")).contains("走查"));
            assertTrue(Candidates.oneSlip("teh", "the"));
            assertFalse(Candidates.oneSlip("test", "word"));
        } finally { candidates.close(); }
    }
    @Test public void emojiPanelLoadsLocalCatalogAndClosesWithoutSwitchingIme() {
        Context context = ApplicationProvider.getApplicationContext(); boolean[] closed = {false};
        NativeEmojiPanel panel = new NativeEmojiPanel(context, 0xff000000, () -> {}, text -> {}, () -> closed[0] = true, () -> {});
        GridView grid = (GridView) panel.getChildAt(1);
        assertTrue(grid.getAdapter().getCount() > 100);
        LinearLayout bottom = (LinearLayout) panel.getChildAt(2);
        bottom.getChildAt(0).performClick(); assertTrue(closed[0]);
    }
    @Test public void translationIsOptInTextOnlyAndDoesNotChangeTypingLanguage() throws Exception {
        var request = DictationPolisher.request("你好", "test-key", true);
        okio.Buffer buffer = new okio.Buffer(); request.body().writeTo(buffer);
        JSONObject body = new JSONObject(buffer.readUtf8());
        assertFalse(body.has("tools"));
        assertEquals("你好", body.getJSONArray("messages").getJSONObject(1).getString("content"));
        assertTrue(body.getJSONArray("messages").getJSONObject(0).getString("content").contains("opposite language"));
        assertEquals("disabled", body.getJSONObject("thinking").getString("type"));
    }
    @Test public void polishingOnlyReplacesOwnedDraftAndClearsUnderline() {
        EditText field = new EditText(ApplicationProvider.getApplicationContext());
        InputConnection connection = field.onCreateInputConnection(new EditorInfo());
        connection.setComposingText("draft", 1);
        PendingDictation pending = new PendingDictation(connection, 0, "draft");
        assertTrue(pending.complete(connection, "Final."));
        assertEquals("Final.", field.getText().toString());
        assertEquals(-1, BaseInputConnection.getComposingSpanStart(field.getText()));
        connection.setComposingText(" next", 1);
        PendingDictation late = new PendingDictation(connection, 6, " next");
        field.setSelection(0); assertFalse(late.complete(connection, "wrong"));
    }
}
