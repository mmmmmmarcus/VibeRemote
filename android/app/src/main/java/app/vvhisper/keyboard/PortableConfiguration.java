package app.vvhisper.keyboard;

import android.content.Context;
import org.json.JSONObject;

/** Shared with the Apple apps: only explicit, validated portable values are applied. */
final class PortableConfiguration {
    static final int MAX_BYTES = 65536;
    final Boolean polish, punctuation;
    final String seed, ark;
    PortableConfiguration(Boolean polish, Boolean punctuation, String seed, String ark) {
        this.polish = polish; this.punctuation = punctuation; this.seed = seed; this.ark = ark;
    }
    static PortableConfiguration decode(byte[] data) throws Exception {
        if (data.length > MAX_BYTES) throw new IllegalArgumentException();
        JSONObject root = new JSONObject(new String(data, java.nio.charset.StandardCharsets.UTF_8));
        if (!"vvhisper".equals(root.opt("format")) || !(root.opt("version") instanceof Number)
                || ((Number)root.get("version")).doubleValue() != 1) throw new IllegalArgumentException();
        JSONObject settings = root.getJSONObject("settings");
        JSONObject keys = root.has("credentials") && !root.isNull("credentials") ? root.getJSONObject("credentials") : new JSONObject();
        return new PortableConfiguration(bool(settings, "polishDictation"), bool(settings, "sentencePunctuation"),
                key(keys, "seedASR"), key(keys, "polishing"));
    }
    private static Boolean bool(JSONObject object, String name) throws Exception {
        if (!object.has(name) || object.isNull(name)) return null;
        Object value = object.get(name); if (!(value instanceof Boolean)) throw new IllegalArgumentException();
        return (Boolean)value;
    }
    private static String key(JSONObject object, String name) throws Exception {
        if (!object.has(name) || object.isNull(name)) return null;
        Object value = object.get(name); if (!(value instanceof String)) throw new IllegalArgumentException();
        String key = (String)value;
        if (key.isEmpty() || key.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 8192
                || key.codePoints().anyMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c))) throw new IllegalArgumentException();
        return key;
    }
    static PortableConfiguration capture(Context context, boolean keys) throws Exception {
        var prefs = context.getSharedPreferences("keyboard", 0);
        return new PortableConfiguration(prefs.getBoolean("polish", true), prefs.getBoolean("sentencePunctuation", true), null, null);
    }

    byte[] encode() throws Exception {
        JSONObject settings = new JSONObject();
        if (polish != null) settings.put("polishDictation", polish);
        if (punctuation != null) settings.put("sentencePunctuation", punctuation);
        JSONObject root = new JSONObject().put("format", "vvhisper").put("version", 1).put("settings", settings);
        if (seed != null || ark != null) {
            JSONObject keys = new JSONObject(); if (seed != null) keys.put("seedASR", seed); if (ark != null) keys.put("polishing", ark);
            root.put("credentials", keys);
        }
        byte[] data = root.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8); decode(data); return data;
    }
    void apply(Context context) throws Exception {
        decode(encode());
        var prefs = context.getSharedPreferences("keyboard", 0);
        boolean oldPolish = prefs.getBoolean("polish", true), oldPunctuation = prefs.getBoolean("sentencePunctuation", true);
        try {
            var editor = prefs.edit();
            if (polish != null) editor.putBoolean("polish", polish);
            if (punctuation != null) editor.putBoolean("sentencePunctuation", punctuation);
            if (!editor.commit()) throw new IllegalStateException();
        } catch (Exception failure) {
            // Attempt every restoration even if a storage write fails.
            var restore = prefs.edit();
            if (polish != null) restore.putBoolean("polish", oldPolish);
            if (punctuation != null) restore.putBoolean("sentencePunctuation", oldPunctuation);
            restore.commit();
            throw failure;
        }
    }
}
