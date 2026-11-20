package app.vvhisper.keyboard;

import android.content.Context;
import android.widget.LinearLayout;

/** Weights describe entire touch slots, including the gutter around each visible key. */
final class KeyboardRow extends LinearLayout {
    KeyboardRow(Context context) {
        super(context);
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        int width = MeasureSpec.getSize(widthSpec);
        float weight = 0;
        int remaining = width;
        int count = getChildCount();
        for (int i = 0; i < count; i++)
            weight += ((LayoutParams) getChildAt(i).getLayoutParams()).weight;
        // The staggered home row has a half-key inset measured across the full board.
        int start = 0, end = count;
        if (count > 2
                && getChildAt(0).getClass() == android.view.View.class
                && getChildAt(count - 1).getClass() == android.view.View.class) {
            LayoutParams left = (LayoutParams) getChildAt(0).getLayoutParams();
            LayoutParams right = (LayoutParams) getChildAt(count - 1).getLayoutParams();
            android.view.View board = (android.view.View) getParent();
            if (board instanceof AlphabetKeys) board = (android.view.View) board.getParent();
            int inset =
                    Math.round(
                            (width + board.getPaddingLeft() + board.getPaddingRight())
                                    * left.weight
                                    / weight);
            left.width = right.width = inset;
            remaining -= 2 * inset;
            weight -= left.weight + right.weight;
            start++;
            end--;
        }
        for (int i = start; i < end && weight > 0; i++) {
            LayoutParams lp = (LayoutParams) getChildAt(i).getLayoutParams();
            int slot = i == end - 1 ? remaining : (int) (remaining * lp.weight / weight);
            lp.width = Math.max(0, slot - lp.leftMargin - lp.rightMargin);
            remaining -= slot;
            weight -= lp.weight;
        }
        super.onMeasure(widthSpec, heightSpec);
    }
}
