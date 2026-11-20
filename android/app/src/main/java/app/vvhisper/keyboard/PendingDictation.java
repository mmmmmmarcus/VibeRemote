package app.vvhisper.keyboard;

import android.view.inputmethod.ExtractedText;
import android.view.inputmethod.ExtractedTextRequest;
import android.view.inputmethod.InputConnection;

/** Owns one final ASR draft while the text-only request runs. Main thread only. */
final class PendingDictation {
    private final InputConnection owner;
    private final String original;
    private final int start;
    private boolean active = true;

    PendingDictation(InputConnection owner, int start, String original) {
        this.owner = owner;
        this.start = start;
        this.original = original;
    }

    boolean owns(InputConnection current) {
        if (!active || current != owner || start < 0) return false;
        ExtractedText text = owner.getExtractedText(new ExtractedTextRequest(), 0);
        if (text == null || text.text == null || text.partialStartOffset != -1) return false;
        int from = start - text.startOffset;
        int end = from + original.length();
        return from >= 0 && end <= text.text.length() && text.selectionStart == end
                && text.selectionEnd == end && original.contentEquals(text.text.subSequence(from, end));
    }

    boolean complete(InputConnection current, String polished) {
        if (!active) return false;
        boolean owned = owns(current);
        active = false;
        if (!owned) return false;
        owner.beginBatchEdit();
        try {
            if (polished.equals(original)) return owner.finishComposingText();
            if (!owner.setComposingRegion(start, start + original.length())) return false;
            return owner.commitText(polished, 1);
        } finally {
            owner.endBatchEdit();
        }
    }

    void cancel(InputConnection current) {
        if (owns(current)) owner.finishComposingText();
        active = false;
    }
}
