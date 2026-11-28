package app.vvhisper.keyboard;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;

/** Visual-only Soft lift preview in board coordinates. No popup window or animation. */
final class KeyPreviewDrawable extends Drawable {
    private final Path outline = new Path();
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint legend = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF head;
    private final String text;

    KeyPreviewDrawable(RectF key, float boardWidth, float density, String text,
                       int color, int ink, Typeface typeface) {
        this.text = text;
        float width = Math.min(boardWidth - 4 * density,
                Math.min(82 * density, Math.max(62 * density, key.width() + 26 * density)));
        float top = Math.max(2 * density, key.top - 63 * density);
        float height = Math.min(56 * density, Math.max(32 * density, key.top - top - 2 * density));
        float left = Math.min(Math.max(key.centerX() - width / 2, 2 * density),
                boardWidth - width - 2 * density);
        head = new RectF(left, top, left + width, top + height);
        float radius = 14 * density, footRadius = Math.min(6 * density, key.height() / 4);
        float shoulder = top + height * (36f / 56f);
        float neck = Math.max(shoulder + density, key.top + Math.min(4 * density, key.height() / 5));
        float bend = (neck - shoulder) * .52f;
        outline.moveTo(left + radius, top);
        outline.lineTo(head.right - radius, top);
        outline.quadTo(head.right, top, head.right, top + radius);
        outline.lineTo(head.right, shoulder);
        outline.cubicTo(head.right, shoulder + bend, key.right, neck - bend, key.right, neck);
        outline.lineTo(key.right, key.bottom - footRadius);
        outline.quadTo(key.right, key.bottom, key.right - footRadius, key.bottom);
        outline.lineTo(key.left + footRadius, key.bottom);
        outline.quadTo(key.left, key.bottom, key.left, key.bottom - footRadius);
        outline.lineTo(key.left, neck);
        outline.cubicTo(key.left, neck - bend, left, shoulder + bend, left, shoulder);
        outline.lineTo(left, top + radius);
        outline.quadTo(left, top, left + radius, top);
        outline.close();
        fill.setColor(color);
        fill.setShadowLayer(3 * density, 0, 2 * density, 0x33000000);
        legend.setColor(ink);
        legend.setTypeface(typeface);
        legend.setTextAlign(Paint.Align.CENTER);
        legend.setTextSize(Math.min(32 * density, height - 4 * density));
    }

    @Override public void draw(Canvas canvas) {
        canvas.drawPath(outline, fill);
        Paint.FontMetrics font = legend.getFontMetrics();
        canvas.drawText(text, head.centerX(), head.centerY() - (font.ascent + font.descent) / 2, legend);
    }

    @Override public void setAlpha(int alpha) { fill.setAlpha(alpha); legend.setAlpha(alpha); invalidateSelf(); }
    @Override public void setColorFilter(ColorFilter filter) { fill.setColorFilter(filter); legend.setColorFilter(filter); invalidateSelf(); }
    @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
}
