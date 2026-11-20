package app.vvhisper.keyboard;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

enum ProviderKey {
    SEED("seed"), ARK("ark");

    private final String storeName;

    ProviderKey(String storeName) {
        this.storeName = storeName;
    }

    private SecretKey key() throws Exception {
        String alias = "vvhisper." + storeName;
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(alias)) return (SecretKey) store.getKey(alias, null);
        KeyGenerator generator = KeyGenerator.getInstance("AES", "AndroidKeyStore");
        generator.init(
                new KeyGenParameterSpec.Builder(
                                alias,
                                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build());
        return generator.generateKey();
    }

    void save(Context context, String value) throws Exception {
        SharedPreferences.Editor editor = context.getSharedPreferences(storeName, 0).edit();
        if (value.isEmpty()) {
            editor.clear().apply();
            return;
        }
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        editor.putString("iv", Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .putString(
                        "value",
                        Base64.encodeToString(
                                cipher.doFinal(value.getBytes("UTF-8")), Base64.NO_WRAP))
                .apply();
    }

    String read(Context context) throws Exception {
        SharedPreferences prefs = context.getSharedPreferences(storeName, 0);
        if (!prefs.contains("value")) return "";
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(
                Cipher.DECRYPT_MODE,
                key(),
                new GCMParameterSpec(128, Base64.decode(prefs.getString("iv", ""), 0)));
        return new String(cipher.doFinal(Base64.decode(prefs.getString("value", ""), 0)), "UTF-8");
    }
}
