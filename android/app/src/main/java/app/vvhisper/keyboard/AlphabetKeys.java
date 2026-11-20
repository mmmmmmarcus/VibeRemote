package app.vvhisper.keyboard;

import android.animation.ValueAnimator;
import android.content.Context;
import android.view.View;
import android.view.animation.PathInterpolator;
import android.widget.FrameLayout;
import android.widget.LinearLayout;

/** Keeps the action row anchored while the letter rows fold underneath the toolbar. */
final class AlphabetKeys extends LinearLayout {
    private final KeyboardRow top, home, letters, dictate;
    private final FrameLayout actionRow;
    private ValueAnimator resize;
    private float expansion;
    private boolean compact;

    AlphabetKeys(
            Context context,
            KeyboardRow top,
            KeyboardRow home,
            KeyboardRow letters,
            KeyboardRow dictate,
            boolean compact) {
        super(context);
        setOrientation(VERTICAL);
        this.top = top;
        this.home = home;
        this.letters = letters;
        this.dictate = dictate;
        addView(top);
        addView(home);
        actionRow = new FrameLayout(context);
        addView(actionRow, -1, letters.getLayoutParams().height);
        actionRow.addView(letters, -1, -1);
        actionRow.addView(dictate, -1, -1);
        setCompact(compact, false);
    }

    void setCompact(boolean next, boolean animate) {
        if (resize != null) {
            resize.cancel();
            resize = null;
        }
        compact = next;
        float end = next ? 0f : 1f;
        if (!animate || !ValueAnimator.areAnimatorsEnabled() || expansion == end) {
            showExpansion(end);
            return;
        }
        resize = ValueAnimator.ofFloat(expansion, end);
        resize.setDuration(Math.max(1, Math.round((next ? 180 : 220) * Math.abs(expansion - end))));
        resize.setInterpolator(new PathInterpolator(.2f, 0f, .2f, 1f));
        resize.addUpdateListener(a -> showExpansion((float) a.getAnimatedValue()));
        resize.start();
    }

    private void showExpansion(float fraction) {
        expansion = fraction;
        top.setAlpha(fraction);
        home.setAlpha(fraction);
        letters.setAlpha(fraction);
        dictate.setAlpha(1f - fraction);
        for (int i = 0; i < actionRow.getChildCount(); i++) {
            View child = actionRow.getChildAt(i);
            boolean active = child == (compact ? dictate : letters);
            child.setVisibility(child.getAlpha() == 0f ? INVISIBLE : VISIBLE);
            child.setImportantForAccessibility(
                    active
                            ? IMPORTANT_FOR_ACCESSIBILITY_AUTO
                            : IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        }
        int access =
                compact
                        ? IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                        : IMPORTANT_FOR_ACCESSIBILITY_AUTO;
        top.setImportantForAccessibility(access);
        home.setImportantForAccessibility(access);
        // The editor uses the measured IME height for its bottom inset on each frame.
        requestLayout();
    }

    private int hiddenHeight() {
        return Math.round((top.getMeasuredHeight() + home.getMeasuredHeight()) * (1f - expansion));
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        super.onMeasure(widthSpec, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED));
        setMeasuredDimension(
                getMeasuredWidth(), resolveSize(getMeasuredHeight() - hiddenHeight(), heightSpec));
    }

    @Override
    protected void onLayout(boolean changed, int l, int t, int r, int b) {
        super.onLayout(changed, l, t, r, b);
        int delta = -hiddenHeight();
        top.offsetTopAndBottom(delta);
        home.offsetTopAndBottom(delta);
        actionRow.offsetTopAndBottom(delta);
    }

    KeyboardRow rowAt(float y) {
        if (y < 0 || y >= getHeight()) return null;
        if (y >= actionRow.getTop()) return compact ? dictate : letters;
        if (compact) return null;
        return y >= home.getTop() ? home : top;
    }

    @Override
    protected void onDetachedFromWindow() {
        setCompact(compact, false);
        super.onDetachedFromWindow();
    }
}
