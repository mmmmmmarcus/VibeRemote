package app.vvhisper.keyboard;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.PBEKeySpec;
import javax.crypto.spec.SecretKeySpec;
import org.json.JSONObject;

final class EncryptedConfiguration {
    static final int MAX_BYTES = 131072, ROUNDS = 600000;
    private static final byte[] AAD = "vvhisper-config:v1".getBytes(StandardCharsets.UTF_8);
    static void validatePassword(String password) {
        int size = password.codePointCount(0, password.length());
        if (size < 8 || size > 256) throw new IllegalArgumentException("Use a long, unique password (8–256 characters).");
    }
    private static SecretKeySpec key(String password, byte[] salt) throws Exception {
        validatePassword(password);
        char[] chars = password.toCharArray();
        PBEKeySpec specification = new PBEKeySpec(chars, salt, ROUNDS, 256);
        Arrays.fill(chars, '\0');
        byte[] bytes = null;
        try {
            bytes = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(specification).getEncoded();
            return new SecretKeySpec(bytes, "AES");
        } finally {
            specification.clearPassword();
            if (bytes != null) Arrays.fill(bytes, (byte)0);
        }
    }
    static byte[] seal(PortableConfiguration document, String password) throws Exception {
        byte[] salt = new byte[16], nonce = new byte[12];
        SecureRandom random = new SecureRandom(); random.nextBytes(salt); random.nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key(password, salt), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(AAD);
        byte[] plaintext = document.encode();
        byte[] ciphertext;
        try { ciphertext = cipher.doFinal(plaintext); } finally { Arrays.fill(plaintext, (byte)0); }
        return new JSONObject().put("format", "vvhisper.encrypted").put("version", 1)
                .put("kdf", "pbkdf2-sha256").put("iterations", ROUNDS).put("cipher", "aes-256-gcm")
                .put("salt", Base64.getEncoder().encodeToString(salt))
                .put("nonce", Base64.getEncoder().encodeToString(nonce))
                .put("ciphertext", Base64.getEncoder().encodeToString(ciphertext))
                .toString(2).getBytes(StandardCharsets.UTF_8);
    }
    static PortableConfiguration open(byte[] data, String password) throws Exception {
        if (data.length > MAX_BYTES) throw new IllegalArgumentException("Unsupported encrypted configuration.");
        JSONObject envelope = new JSONObject(new String(data, StandardCharsets.UTF_8));
        if (!"vvhisper.encrypted".equals(envelope.opt("format")) || !number(envelope, "version", 1)
                || !"pbkdf2-sha256".equals(envelope.opt("kdf")) || !number(envelope, "iterations", ROUNDS)
                || !"aes-256-gcm".equals(envelope.opt("cipher"))) throw new IllegalArgumentException("Unsupported encrypted configuration.");
        byte[] salt = decode(envelope, "salt"), nonce = decode(envelope, "nonce"), ciphertext = decode(envelope, "ciphertext");
        if (salt.length != 16 || nonce.length != 12 || ciphertext.length < 16 || ciphertext.length > PortableConfiguration.MAX_BYTES + 16)
            throw new IllegalArgumentException("Unsupported encrypted configuration.");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(password, salt), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(AAD);
        byte[] plaintext = cipher.doFinal(ciphertext);
        try { return PortableConfiguration.decode(plaintext); } finally { Arrays.fill(plaintext, (byte)0); }
    }
    private static boolean number(JSONObject value, String field, int expected) {
        Object found = value.opt(field);
        return found instanceof Number && ((Number)found).doubleValue() == expected;
    }
    private static byte[] decode(JSONObject object, String field) throws Exception {
        Object value = object.get(field);
        if (!(value instanceof String)) throw new IllegalArgumentException();
        return Base64.getDecoder().decode((String)value);
    }
}
