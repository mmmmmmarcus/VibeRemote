package app.vvhisper.keyboard;

import static org.junit.Assert.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

@RunWith(RobolectricTestRunner.class)
public class EncryptedConfigurationTest {
    private static final String PASSWORD = "vvhisper-test-密码🔐";
    private byte[] fixture() throws Exception {
        try (var stream = getClass().getResourceAsStream("/encrypted-config-v1.json")) { return stream.readAllBytes(); }
    }
    private void assertDocument(PortableConfiguration document) {
        assertEquals("test-asr", document.seed); assertEquals("test-ark", document.ark);
        assertEquals(Boolean.FALSE, document.polish); assertEquals(Boolean.TRUE, document.punctuation);
    }
    @Test public void independentUtf8VectorRandomizedRoundtripAndAppleInteroperability() throws Exception {
        assertDocument(EncryptedConfiguration.open(fixture(), PASSWORD));
        var document = new PortableConfiguration(false, true, "test-asr", "test-ark");
        byte[] first = EncryptedConfiguration.seal(document, PASSWORD), second = EncryptedConfiguration.seal(document, PASSWORD);
        assertFalse(java.util.Arrays.equals(first, second));
        assertFalse(new String(first, StandardCharsets.UTF_8).contains("test-asr"));
        assertDocument(EncryptedConfiguration.open(first, PASSWORD));
        assertThrows(Exception.class, () -> EncryptedConfiguration.open(first, "wrong-password"));
        String appleFixture = System.getenv("VVHISPER_CRYPTO_APPLE_FIXTURE");
        if (appleFixture != null) assertDocument(EncryptedConfiguration.open(Files.readAllBytes(Path.of(appleFixture)), PASSWORD));
        String javaOutput = System.getenv("VVHISPER_CRYPTO_JAVA_OUTPUT");
        if (javaOutput != null) Files.write(Path.of(javaOutput), first);
    }
    @Test public void tamperedMalformedAndExcessiveWorkFactorsAreRejected() throws Exception {
        JSONObject value = new JSONObject(new String(fixture(), StandardCharsets.UTF_8));
        byte[] encrypted = java.util.Base64.getDecoder().decode(value.getString("ciphertext")); encrypted[0] ^= 1;
        value.put("ciphertext", java.util.Base64.getEncoder().encodeToString(encrypted));
        assertThrows(Exception.class, () -> EncryptedConfiguration.open(value.toString().getBytes(StandardCharsets.UTF_8), PASSWORD));
        value.put("iterations", Integer.MAX_VALUE);
        assertThrows(Exception.class, () -> EncryptedConfiguration.open(value.toString().getBytes(StandardCharsets.UTF_8), PASSWORD));
        assertThrows(Exception.class, () -> EncryptedConfiguration.open(new byte[131073], PASSWORD));
        assertThrows(Exception.class, () -> EncryptedConfiguration.open(new PortableConfiguration(true, true, null, null).encode(), PASSWORD));
        assertThrows(Exception.class, () -> EncryptedConfiguration.seal(new PortableConfiguration(true, true, null, null), "short"));
    }
}
