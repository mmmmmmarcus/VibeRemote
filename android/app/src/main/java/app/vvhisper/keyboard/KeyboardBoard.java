package app.vvhisper.keyboard;

import android.content.Context;
import android.view.MotionEvent;
import android.view.View;
import android.widget.LinearLayout;

import java.util.function.Consumer;

/** Captures each key's surrounding gutter and lets a two-finger pinch change layout. */
final class KeyboardBoard extends LinearLayout {
    private final Consumer<Boolean> compact;
    private View target;
    private boolean pinching, switched;
    private float span;
    private View previewOwner;
    private KeyPreviewDrawable preview;

    void showPreview(android.widget.TextView key, int color, int ink) {
        clearPreview();
        if (getWidth() <= 4 || key.getWidth() == 0 || key.getHeight() == 0) return;
        android.graphics.Rect bounds = new android.graphics.Rect();
        key.getDrawingRect(bounds);
        offsetDescendantRectToMyCoords(key, bounds);
        preview = new KeyPreviewDrawable(new android.graphics.RectF(bounds), getWidth(),
                getResources().getDisplayMetrics().density, key.getText().toString(), color, ink, key.getTypeface());
        preview.setBounds(0, 0, getWidth(), getHeight());
        previewOwner = key;
        getOverlay().add(preview);
    }

    void hidePreview(View owner) {
        if (previewOwner == owner) clearPreview();
    }

    void clearPreview() {
        if (preview != null) getOverlay().remove(preview);
        preview = null;
        previewOwner = null;
    }

    @Override protected void onLayout(boolean changed, int l, int t, int r, int b) {
        clearPreview();
        super.onLayout(changed, l, t, r, b);
    }

    @Override protected void onDetachedFromWindow() {
        clearPreview();
        super.onDetachedFromWindow();
    }


    KeyboardBoard(Context context, Consumer<Boolean> compact) {
        super(context);
        this.compact = compact;
    }

    private float distance(MotionEvent event) {
        return (float) Math.hypot(event.getX(1) - event.getX(), event.getY(1) - event.getY());
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) {
            target = null;
            pinching = switched = false;
            for (int i = 1; i < getChildCount(); i++) {
                View child = getChildAt(i);
                if (event.getY() < child.getTop() || event.getY() >= child.getBottom()) continue;
                KeyboardRow row;
                if (child instanceof AlphabetKeys)
                    row = ((AlphabetKeys) child).rowAt(event.getY() - child.getTop());
                else if (child instanceof KeyboardRow) row = (KeyboardRow) child;
                else continue;
                if (row == null) return true;
                float closest = Float.MAX_VALUE;
                for (int k = 0; k < row.getChildCount(); k++) {
                    View key = row.getChildAt(k);
                    if (!key.isClickable()) continue;
                    float dx =
                            Math.max(
                                    0,
                                    Math.max(
                                            key.getLeft() - event.getX(),
                                            event.getX() - key.getRight()));
                    if (dx < closest) {
                        closest = dx;
                        target = key;
                    }
                }
                break;
            }
        }
        if (target != null
                && action == MotionEvent.ACTION_POINTER_DOWN
                && event.getPointerCount() == 2) {
            dispatchKey(event, MotionEvent.ACTION_CANCEL);
            target = null;
            pinching = true;
            span = distance(event);
        }
        if (pinching) {
            if (action == MotionEvent.ACTION_MOVE && !switched && event.getPointerCount() == 2) {
                float change = distance(event) - span;
                if (Math.abs(change) > Math.max(12 * getResources().getDisplayMetrics().density, Math.min(24 * getResources().getDisplayMetrics().density, span * .08f))) {
                    switched = true;
                    compact.accept(change < 0);
                }
            }
            return true;
        }
        if (target == null) return super.dispatchTouchEvent(event);
        dispatchKey(event, action);
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) target = null;
        return true;
    }

    private void dispatchKey(MotionEvent event, int action) {
        MotionEvent copy = MotionEvent.obtain(event);
        if (target.isAttachedToWindow()) {
            copy.setAction(action);
            View ancestor = target;
            while (ancestor != this) {
                copy.offsetLocation(-ancestor.getLeft(), -ancestor.getTop());
                ancestor = (View) ancestor.getParent();
            }
            target.dispatchTouchEvent(copy);
        }
        copy.recycle();
    }
}
