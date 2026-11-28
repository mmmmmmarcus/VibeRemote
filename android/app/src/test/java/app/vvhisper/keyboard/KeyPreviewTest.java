package app.vvhisper.keyboard;

import static org.junit.Assert.*;

import android.content.Context;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Region;
import android.graphics.Typeface;
import android.view.View;
import android.widget.TextView;
import androidx.test.core.app.ApplicationProvider;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.GraphicsMode;
import org.robolectric.util.ReflectionHelpers;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 35)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
public class KeyPreviewTest {
    @Test public void silhouetteJoinsHeadToKeyWithinBoardAtBothEdges() {
        for (float density : new float[] {1, 3}) {
            for (float top : new float[] {42, 90}) {
                for (float x : new float[] {2, 170, 338}) {
                    RectF key = new RectF(x * density, top * density, (x + 35) * density, (top + 44) * density);
                    KeyPreviewDrawable preview = new KeyPreviewDrawable(key, 375 * density, density,
                            "Q", 0xffffffff, 0xff000000, Typeface.DEFAULT);
                    Path path = ReflectionHelpers.getField(preview, "outline");
                    RectF head = ReflectionHelpers.getField(preview, "head");
                    RectF bounds = new RectF(); path.computeBounds(bounds, true);
                    assertTrue(bounds.left >= 0); assertTrue(bounds.right <= 375 * density);
                    assertTrue(bounds.top >= 0); assertEquals(key.bottom, bounds.bottom, .01f);
                    Region inside = new Region();
                    inside.setPath(path, new Region(0, 0, (int)(375 * density), (int)(250 * density)));
                    for (float y = head.centerY(); y < key.bottom - 6 * density; y += density) {
                        float t = Math.min(1, Math.max(0, (y - head.centerY()) / (key.top - head.centerY())));
                        float center = head.centerX() + (key.centerX() - head.centerX()) * t;
                        assertTrue(inside.contains(Math.round(center), Math.round(y)));
                    }
                }
            }
        }
    }

    @Test public void lateReleaseCannotHideNewPreviewAndLayoutClearsIt() {
        Context context = ApplicationProvider.getApplicationContext();
        KeyboardBoard board = new KeyboardBoard(context, compact -> {});
        TextView a = new TextView(context), b = new TextView(context);
        a.setText("a"); b.setText("b");
        board.addView(a, 35, 44); board.addView(b, 35, 44);
        board.measure(View.MeasureSpec.makeMeasureSpec(375, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(250, View.MeasureSpec.EXACTLY));
        board.layout(0, 0, 375, 250);
        a.layout(2, 42, 37, 86); b.layout(40, 42, 75, 86);
        board.showPreview(a, -1, 0xff000000);
        board.showPreview(b, -1, 0xff000000);
        board.hidePreview(a);
        assertSame(b, ReflectionHelpers.getField(board, "previewOwner"));
        assertNotNull(ReflectionHelpers.getField(board, "preview"));
        board.hidePreview(b);
        assertNull(ReflectionHelpers.getField(board, "preview"));
        board.showPreview(a, -1, 0xff000000);
        board.layout(0, 0, 400, 250);
        assertNull(ReflectionHelpers.getField(board, "preview"));
        assertNull(a.getAnimation());
    }
}
