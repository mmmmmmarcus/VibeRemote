package app.vvhisper.keyboard;

import android.os.*;
import okhttp3.Call;

/** At most one speculative source per hold. Only an exact selected source can reuse it. */
final class DictationPolishPipeline {
    interface Loader { Call start(String source, String key, boolean translate, DictationPolisher.Completion completion) throws Exception; }
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Loader loader;
    private Call call;
    private long generation, startedAt, completedAt;
    double duration() { return Math.max(0, completedAt - startedAt) / 1000.0; }
    private String source, result, error;
    private boolean translation, done;
    private DictationPolisher.Completion selected;
    private Runnable deadline;
    DictationPolishPipeline() { this(DictationPolisher::start); }
    DictationPolishPipeline(Loader loader) { this.loader = loader; }
    void start(String text, String key, boolean translate) {
        cancel(); source = text; translation = translate; startedAt = SystemClock.elapsedRealtime();
        long id = generation;
        deadline = () -> complete(id, text, translate ? "Translation took too long. Kept the transcript." : null);
        main.postDelayed(deadline, translate ? 8000 : 3000);
        try { call = loader.start(text, key, translate, (value, failure) -> main.post(() -> complete(id, value == null ? text : value, failure))); }
        catch (Exception e) { complete(id, text, "Editing request unavailable"); }
    }
    boolean matches(String text, boolean translate) { return text.equals(source) && translation == translate; }
    void select(String text, String key, boolean translate, DictationPolisher.Completion completion) {
        if (!matches(text, translate)) start(text, key, translate);
        selected = completion;
        deliver();
    }
    private void complete(long id, String value, String failure) {
        if (id != generation || done) return;
        done = true; completedAt = SystemClock.elapsedRealtime(); result = value; error = failure;
        if (deadline != null) main.removeCallbacks(deadline);
        if (call != null) call.cancel(); call = null;
        deliver();
    }
    private void deliver() {
        if (!done || selected == null) return;
        DictationPolisher.Completion callback = selected; selected = null;
        callback.accept(result, error);
    }
    void cancel() {
        generation++; if (call != null) call.cancel(); call = null;
        if (deadline != null) main.removeCallbacks(deadline); deadline = null;
        source = result = error = null; selected = null; done = false;
    }
}
