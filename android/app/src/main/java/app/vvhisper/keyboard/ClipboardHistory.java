package app.vvhisper.keyboard;

import android.content.Context;
import android.content.ClipData;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.AtomicFile;
import org.json.JSONArray;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.*;
import javax.crypto.*;
import javax.crypto.spec.GCMParameterSpec;

/** Five exact text clips, encrypted locally, excluded from backup and never sent to providers. */
final class ClipboardHistory {
    interface Storage { String read() throws Exception; void write(String value) throws Exception; }
    private final Storage storage;
    private final ArrayList<String> items = new ArrayList<>();
    ClipboardHistory(Context context) { this(new DeviceStorage(context)); }
    ClipboardHistory(Storage storage) {
        this.storage = storage;
        try {
            JSONArray saved = new JSONArray(storage.read());
            for (int i = 0; i < saved.length() && items.size() < 5; i++) {
                Object value = saved.get(i);
                if (value instanceof String && accepts((String) value) && !items.contains(value)) items.add((String) value);
            }
        } catch (Exception ignored) { /* Never log clipboard content. */ }
    }
    List<String> items() { return new ArrayList<>(items); }
    static boolean accepts(String text) {
        return text != null && text.length() <= 20000 && !text.trim().isEmpty();
    }
    static String textFrom(ClipData clip) {
        if (clip == null || clip.getItemCount() != 1) return null;
        var extras = clip.getDescription().getExtras();
        if (extras != null && extras.getBoolean("android.content.extra.IS_SENSITIVE", false)) return null;
        CharSequence text = clip.getItemAt(0).getText();
        return text == null ? null : text.toString();
    }
    void record(String text) {
        if (!accepts(text) || (!items.isEmpty() && items.get(0).equals(text))) return;
        items.remove(text); items.add(0, text);
        while (items.size() > 5) items.remove(items.size() - 1);
        save();
    }
    void clear() { items.clear(); save(); }
    private void save() {
        try { storage.write(new JSONArray(items).toString()); }
        catch (Exception ignored) { /* Retain a bounded session list; no plaintext fallback. */ }
    }
    static String preview(String text) {
        String title = text.replaceAll("\\s+", " ").trim();
        int count = title.codePointCount(0, title.length());
        return count > 70 ? title.substring(0, title.offsetByCodePoints(0, 70)) + "…" : title;
    }
    private static final class DeviceStorage implements Storage {
        private final AtomicFile file;
        DeviceStorage(Context context) { file = new AtomicFile(new File(context.getNoBackupFilesDir(), "clipboard-history.bin")); }
        private SecretKey key() throws Exception {
            String alias = "vvhisper.clipboard-history";
            KeyStore store = KeyStore.getInstance("AndroidKeyStore"); store.load(null);
            if (store.containsAlias(alias)) return (SecretKey) store.getKey(alias, null);
            KeyGenerator generator = KeyGenerator.getInstance("AES", "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
            return generator.generateKey();
        }
        public String read() throws Exception {
            if (!file.getBaseFile().exists()) return "[]";
            if (file.getBaseFile().length() > 1_000_000) throw new IOException("Invalid history size");
            byte[] data = file.readFully();
            if (data.length < 28) throw new IOException("Invalid history");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, Arrays.copyOfRange(data, 0, 12)));
            return new String(cipher.doFinal(data, 12, data.length - 12), StandardCharsets.UTF_8);
        }
        public void write(String value) throws Exception {
            if (value.equals("[]")) { file.delete(); return; }
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key());
            byte[] encrypted = cipher.doFinal(value.getBytes(StandardCharsets.UTF_8));
            FileOutputStream output = null;
            try {
                output = file.startWrite(); output.write(cipher.getIV()); output.write(encrypted); file.finishWrite(output);
            } catch (Exception error) { if (output != null) file.failWrite(output); throw error; }
        }
    }
}
