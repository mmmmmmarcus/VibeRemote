package app.vvhisper.keyboard;

import static org.junit.Assert.*;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Intent;
import android.graphics.Rect;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;

/** Runs with vvhisper selected as the IME on an unlocked device. */
public class KeyboardSmokeTest {
    final Instrumentation runner = InstrumentationRegistry.getInstrumentation();
    final UiAutomation automation = runner.getUiAutomation();

    private AccessibilityNodeInfo match(AccessibilityNodeInfo node, String label) {
        if (node == null) return null;
        if (label.contentEquals(
                        node.getContentDescription() == null ? "" : node.getContentDescription())
                || label.contentEquals(node.getText() == null ? "" : node.getText())) return node;
        for (int i = 0; i < node.getChildCount(); i++) {
            AccessibilityNodeInfo found = match(node.getChild(i), label);
            if (found != null) return found;
        }
        return null;
    }

    private AccessibilityNodeInfo find(String label) {
        for (int attempt = 0; attempt < 30; attempt++) {
            for (AccessibilityWindowInfo window : automation.getWindows()) {
                AccessibilityNodeInfo node = match(window.getRoot(), label);
                if (node != null) return node;
            }
            SystemClock.sleep(100);
        }
        throw new AssertionError("Missing keyboard or field element: " + label);
    }

    private void tap(String label) throws Exception {
        AccessibilityNodeInfo node = find(label);
        // The IME window animates its surface after a compact/full height change.
        automation.waitForIdle(180, 3000);
        node.refresh();
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        long now = SystemClock.uptimeMillis();
        for (int action : new int[] {MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP}) {
            MotionEvent motion =
                    MotionEvent.obtain(
                            now,
                            SystemClock.uptimeMillis(),
                            action,
                            bounds.centerX(),
                            bounds.centerY(),
                            0);
            motion.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
            automation.injectInputEvent(motion, true);
            motion.recycle();
        }
        runner.waitForIdleSync();
    }

    private void pinchSpace(boolean inward) throws java.util.concurrent.TimeoutException {
        automation.waitForIdle(300, 3000);
        Rect space = new Rect();
        find("Space").getBoundsInScreen(space);
        long down = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties[] fingers = new MotionEvent.PointerProperties[2];
        MotionEvent.PointerCoords[] positions = new MotionEvent.PointerCoords[2];
        for (int i = 0; i < 2; i++) {
            fingers[i] = new MotionEvent.PointerProperties();
            fingers[i].id = i;
            fingers[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            positions[i] = new MotionEvent.PointerCoords();
            positions[i].y = space.centerY();
            positions[i].pressure = 1;
            positions[i].size = 1;
        }
        int second = 1 << MotionEvent.ACTION_POINTER_INDEX_SHIFT;
        for (int action :
                new int[] {
                    MotionEvent.ACTION_DOWN,
                    MotionEvent.ACTION_POINTER_DOWN | second,
                    MotionEvent.ACTION_MOVE,
                    MotionEvent.ACTION_POINTER_UP | second,
                    MotionEvent.ACTION_UP
                }) {
            boolean initial =
                    action == MotionEvent.ACTION_DOWN
                            || action == (MotionEvent.ACTION_POINTER_DOWN | second);
            float spread = space.width() * (initial == inward ? .40f : .10f);
            positions[0].x = space.centerX() - spread;
            positions[1].x = space.centerX() + spread;
            int count =
                    action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_UP ? 1 : 2;
            MotionEvent event =
                    MotionEvent.obtain(
                            down,
                            SystemClock.uptimeMillis(),
                            action,
                            count,
                            fingers,
                            positions,
                            0,
                            0,
                            1,
                            1,
                            0,
                            0,
                            android.view.InputDevice.SOURCE_TOUCHSCREEN,
                            0);
            automation.injectInputEvent(event, true);
            event.recycle();
        }
    }

    private Rect visibleEditorFrame(SetupActivity activity) throws java.util.concurrent.TimeoutException {
        automation.waitForIdle(300, 3000);
        Rect frame = new Rect();
        runner.runOnMainSync(() -> activity.getWindow().getDecorView().getWindowVisibleDisplayFrame(frame));
        return frame;
    }

    @Test
    public void composingCandidateSpaceAndCompactRoundTrip() throws Exception {
        AccessibilityServiceInfo service = automation.getServiceInfo();
        service.flags |= AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
        automation.setServiceInfo(service);
        android.content.SharedPreferences prefs =
                runner.getTargetContext().getSharedPreferences("keyboard", 0);
        boolean wasChinese =
                prefs.getBoolean(
                        "chinese", java.util.Locale.getDefault().getLanguage().equals("zh"));
        boolean wasMini = prefs.getBoolean("mini", false);
        prefs.edit().putBoolean("chinese", true).putBoolean("mini", false).commit();
        Intent intent = new Intent(runner.getTargetContext(), SetupActivity.class);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        SetupActivity activity = (SetupActivity) runner.startActivitySync(intent);
        try {
            runner.runOnMainSync(
                    () ->
                            activity.getWindow()
                                    .addFlags(
                                            android.view.WindowManager.LayoutParams
                                                    .FLAG_KEEP_SCREEN_ON));
            tap("Type here, or hold a letter to dictate");
            find("Space");
            SystemClock.sleep(400);
            Rect idleFrame = visibleEditorFrame(activity);
            for (char c : "nihao".toCharArray()) tap(Character.toString(c));
            assertNotNull(find("你好"));
            assertEquals(idleFrame, visibleEditorFrame(activity));
            tap("Expand or collapse candidates");
            tap("你好");
            tap("n");
            tap("i");
            tap("Space");
            assertNotNull(find("你好你"));
            tap("Switch typing language");
            tap("x");
            assertNotNull(find("你好你x"));
            tap("Delete");
            assertNotNull(find("你好你"));
            pinchSpace(true);
            assertNotNull(find("Hold to dictate"));
            tap("EN");
            assertTrue(prefs.getBoolean("chinese", false));
            tap("中");
            assertFalse(prefs.getBoolean("chinese", true));
            automation.waitForIdle(300, 3000);
            for (AccessibilityWindowInfo window : automation.getWindows())
                assertNull(match(window.getRoot(), "Toggle compact keyboard"));
            pinchSpace(false);
            assertNotNull(find("q"));
            automation.waitForIdle(300, 3000);
            for (AccessibilityWindowInfo window : automation.getWindows())
                assertNull(match(window.getRoot(), "Toggle compact keyboard"));
            tap("h");
            tap("e");
            assertNotNull(find("he"));
            assertEquals(idleFrame, visibleEditorFrame(activity));
            tap("he");
            assertNotNull(find("你好你he "));
            assertEquals(idleFrame, visibleEditorFrame(activity));
        } finally {
            runner.runOnMainSync(activity::finish);
            prefs.edit().putBoolean("chinese", wasChinese).putBoolean("mini", wasMini).commit();
        }
    }
}
