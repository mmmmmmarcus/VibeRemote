package app.vvhisper.keyboard;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.drawable.Drawable;
import android.view.Gravity;
import android.widget.TextView;

/** Centers functional icons independently of the optional top-row number legend. */
final class Keycap extends TextView {
    private final Paint legendPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Drawable icon;
    private final int iconWidth, iconHeight;
    private final String legend;
    private final float density;
    private final boolean hidesText;
    private boolean listening;
    private float amplitude;
    private final Paint light = new Paint(Paint.ANTI_ALIAS_FLAG);
    void setVoice(boolean active, float level) {
        listening = active; amplitude = level; invalidate();
    }

    Keycap(Context context, String label, int iconId, String legend, int ink, int sp, boolean hidesText) {
        super(context);
        this.hidesText = hidesText;
        density = getResources().getDisplayMetrics().density;
        this.legend = legend;
        icon = iconId == 0 ? null : context.getDrawable(iconId).mutate();
        if (icon != null) icon.setTint(ink);
        float w = 28, h = 28;
        if (iconId == R.drawable.face) {
            w = h = 24;
        } else if (iconId == R.drawable.shift_on || iconId == R.drawable.shift_off) {
            w = 25;
            h = 27.5f;
        } else if (iconId == R.drawable.backspace) {
            w = 29;
            h = 31;
        } else if (iconId == R.drawable.enter_key) {
            w = 29;
            h = 24;
        }
        iconWidth = Math.round(w * density);
        iconHeight = Math.round(h * density);
        setGravity(Gravity.CENTER);
        setIncludeFontPadding(false);
        setMaxLines(label.contains("\n") ? 2 : 1);
        setTypeface(getResources().getFont(R.font.keyboard_sans));
        setTextSize(sp);
        setTextColor(ink);
        setText(icon == null ? label : "");
        legendPaint.setTextAlign(Paint.Align.RIGHT);
        legendPaint.setTypeface(getTypeface());
        legendPaint.setColor(ink);
        legendPaint.setTextSize(10 * density);
    }

    @Override
    protected void onDraw(Canvas c) {
        if (listening && amplitude > 0) {
            boolean dark = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES;
            light.setColor(android.graphics.Color.WHITE); light.setAlpha(Math.round(amplitude * (dark ? 82 : 220)));
            c.drawRoundRect(0, 0, getWidth(), getHeight(), 7 * density, 7 * density, light);
        }
        int textPosition = c.save();
        c.translate(0, -Math.round(density / 3));
        if (!listening || !hidesText) super.onDraw(c);
        c.restoreToCount(textPosition);
        int save = c.save();
        c.translate(getScrollX(), getScrollY());
        if (icon != null) {
            int x = getWidth() / 2, y = getHeight() / 2;
            int left = x - iconWidth / 2, top = y - iconHeight / 2;
            icon.setBounds(left, top, left + iconWidth, top + iconHeight);
            icon.draw(c);
        }
        if (!listening && !legend.isEmpty())
            c.drawText(legend, getWidth() - 2 * density, 12 * density, legendPaint);
        c.restoreToCount(save);
    }
}
