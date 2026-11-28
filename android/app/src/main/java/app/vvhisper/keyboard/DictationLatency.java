package app.vvhisper.keyboard;

import android.content.Context;
import android.os.SystemClock;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executors;

/** Durations and fixed outcome labels only, in device-local no-backup storage. */
final class DictationLatency {
    private static final java.util.concurrent.Executor IO = Executors.newSingleThreadExecutor();
    final long started = SystemClock.elapsedRealtime();
    long released;
    private final JSONObject record = new JSONObject();
    private boolean saved;
    DictationLatency() { put("date", java.time.Instant.now().toString()); }
    void duration(String name, long start) { put(name, Math.max(0, SystemClock.elapsedRealtime() - start) / 1000.0); }
    void firstText() { if (!record.has("firstText")) duration("firstText", started); }
    void mark(String name) { if (released != 0) duration(name, released); }
    void put(String name, Object value) { try { record.put(name, value); } catch (JSONException ignored) {} }
    void save(Context context) {
        if (saved) return; saved = true;
        File file = new File(context.getNoBackupFilesDir(), "DictationTiming.json");
        String snapshot = record.toString();
        IO.execute(() -> {
            try {
                JSONArray old = file.exists() && file.length() < 1000000 ? new JSONArray(new String(java.nio.file.Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8)) : new JSONArray();
                JSONArray out = new JSONArray();
                for (int i = Math.max(0, old.length() - 199); i < old.length(); i++) out.put(old.get(i));
                out.put(new JSONObject(snapshot));
                android.util.AtomicFile atomic = new android.util.AtomicFile(file);
                FileOutputStream stream = null;
                try { stream = atomic.startWrite(); stream.write(out.toString().getBytes(StandardCharsets.UTF_8)); atomic.finishWrite(stream); }
                catch (IOException e) { if (stream != null) atomic.failWrite(stream); }
            } catch (IOException | JSONException ignored) {}
        });
    }
}
