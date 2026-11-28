package app.vvhisper.keyboard;

import static org.junit.Assert.*;
import android.view.inputmethod.*;
import android.widget.EditText;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.*;
import org.junit.Test;

public class PolishingTest {
    /** Production edit handlers must cancel the request and ignore a queued result. */
    @Test public void keyboardEditsCancelRequestBeforeEditing() {
        var runner = InstrumentationRegistry.getInstrumentation();
        runner.runOnMainSync(() -> {
            try {
                for (boolean delete : new boolean[] {false, true}) {
                    KeyboardService service = new KeyboardService();
                    var attach = android.content.ContextWrapper.class.getDeclaredMethod(
                            "attachBaseContext", android.content.Context.class);
                    attach.setAccessible(true);
                    attach.invoke(service, runner.getTargetContext());
                    EditText field = new EditText(runner.getTargetContext());
                    InputConnection connection = new BaseInputConnection(field, true) {
                        @Override public android.text.Editable getEditable() { return field.getText(); }
                        @Override public ExtractedText getExtractedText(ExtractedTextRequest request, int flags) {
                            ExtractedText text = new ExtractedText(); text.text = field.getText().toString();
                            text.partialStartOffset = -1; text.selectionStart = field.getSelectionStart();
                            text.selectionEnd = field.getSelectionEnd(); return text;
                        }
                        @Override public boolean sendKeyEvent(android.view.KeyEvent event) {
                            if (event.getAction() == android.view.KeyEvent.ACTION_DOWN)
                                return field.onKeyDown(event.getKeyCode(), event);
                            return field.onKeyUp(event.getKeyCode(), event);
                        }
                    };
                    service.onCreateInputMethodInterface().bindInput(new InputBinding(
                            connection, new android.os.Binder(), android.os.Process.myUid(), android.os.Process.myPid()));
                    assertSame(connection, service.getCurrentInputConnection());
                    connection.setComposingText("hello", 1);
                    PendingDictation draft = new PendingDictation(connection, 0, "hello");
                    okhttp3.Call call = new okhttp3.OkHttpClient().newCall(
                            new okhttp3.Request.Builder().url("https://example.invalid/polish").build());
                    DictationPolishPipeline pipeline = new DictationPolishPipeline((text, key, translate, completion) -> call);
                    pipeline.start("hello", "synthetic", false);
                    set(service, "pending", draft); set(service, "polishPipeline", pipeline);
                    set(service, "preview", "hello"); set(service, "plainLatin", true);
                    if (delete) {
                        var method = KeyboardService.class.getDeclaredMethod("erase");
                        method.setAccessible(true); method.invoke(service);
                    } else {
                        var method = KeyboardService.class.getDeclaredMethod("type", String.class, boolean.class);
                        method.setAccessible(true); method.invoke(service, "x", true);
                    }
                    assertTrue("Edit must cancel the request synchronously", call.isCanceled());
                    assertFalse(draft.owns(connection));
                    assertEquals(-1, BaseInputConnection.getComposingSpanStart(field.getText()));
                    assertEquals(delete ? "hell" : "hellox", field.getText().toString());
                    var late = KeyboardService.class.getDeclaredMethod(
                            "finishPolish", PendingDictation.class, String.class, boolean.class, String.class);
                    late.setAccessible(true); late.invoke(service, draft, "Late replacement.", true, null);
                    assertEquals(delete ? "hell" : "hellox", field.getText().toString());
                }
            } catch (ReflectiveOperationException error) { throw new AssertionError(error); }
        });
    }

    private static void set(KeyboardService service, String name, Object value) throws ReflectiveOperationException {
        var field = KeyboardService.class.getDeclaredField(name);
        field.setAccessible(true); field.set(service, value);
    }

    @Test public void cancellationPreservesTypingAndDeletionAndRejectsLatePolish() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            for (boolean delete : new boolean[] {false, true}) {
                EditText field = new EditText(InstrumentationRegistry.getInstrumentation().getTargetContext());
                InputConnection connection = new BaseInputConnection(field, true) {
                    @Override public android.text.Editable getEditable() { return field.getText(); }
                    @Override public ExtractedText getExtractedText(ExtractedTextRequest request, int flags) {
                        ExtractedText text = new ExtractedText(); text.text = field.getText().toString();
                        text.partialStartOffset = -1; text.selectionStart = field.getSelectionStart();
                        text.selectionEnd = field.getSelectionEnd(); return text;
                    }
                };
                connection.setComposingText("hello", 1);
                PendingDictation draft = new PendingDictation(connection, 0, "hello");
                draft.cancel(connection);
                if (delete) connection.deleteSurroundingText(1, 0);
                else connection.commitText(" world", 1);
                String edited = field.getText().toString();
                assertFalse(draft.complete(connection, "Late replacement."));
                assertEquals(delete ? "hell" : "hello world", edited);
                assertEquals(edited, field.getText().toString());
            }
        });
    }
    private String response(String reason, String content) throws Exception {
        return new JSONObject().put("choices", new JSONArray().put(new JSONObject()
                .put("finish_reason", reason).put("message", new JSONObject().put("content", content)))).toString();
    }

    @Test public void buildsArkTextOnlyRequestWithThinkingDisabled() throws Exception {
        okhttp3.Request request = DictationPolisher.request("Test transcript", "test-key");
        assertEquals("POST", request.method());
        assertEquals("https://ark.cn-beijing.volces.com/api/v3/chat/completions", request.url().toString());
        assertEquals("Bearer test-key", request.header("Authorization"));
        okio.Buffer buffer = new okio.Buffer();
        request.body().writeTo(buffer);
        JSONObject body = new JSONObject(buffer.readUtf8());
        assertEquals("doubao-seed-2-0-mini-260428", body.getString("model"));
        assertEquals("disabled", body.getJSONObject("thinking").getString("type"));
        assertEquals("json_object", body.getJSONObject("response_format").getString("type"));
        assertFalse(body.getBoolean("stream"));
        assertFalse(body.has("tools"));
        JSONArray messages = body.getJSONArray("messages");
        assertEquals(2, messages.length());
        assertEquals("system", messages.getJSONObject(0).getString("role"));
        assertEquals("user", messages.getJSONObject(1).getString("role"));
        assertEquals("Test transcript", messages.getJSONObject(1).getString("content"));
    }

    @Test public void validatesCompleteResponses() throws Exception {
        String good = "{\"text\":\"Corrected.\"}";
        assertEquals("Corrected.", DictationPolisher.parse(response("stop", good), "raw"));
        assertNull(DictationPolisher.parse(response("length", good), "raw"));
        assertNull(DictationPolisher.parse(response("stop", "{}"), "raw"));
        assertNull(DictationPolisher.parse(response("stop", "{\"text\":\"\"}"), "raw"));
        assertNull(DictationPolisher.parse("garbage", "raw"));
    }

    @Test public void completesOnlyItsOwnComposingRange() {
        var runner = InstrumentationRegistry.getInstrumentation();
        runner.runOnMainSync(() -> {
            EditText field = new EditText(runner.getTargetContext());
            InputConnection connection = field.onCreateInputConnection(new EditorInfo());
            connection.setComposingText("raw", 1);
            PendingDictation first = new PendingDictation(connection, 0, "raw");
            assertEquals(0, BaseInputConnection.getComposingSpanStart(field.getText()));
            assertTrue(first.complete(connection, "edited"));
            assertEquals("edited", field.getText().toString());
            assertEquals(-1, BaseInputConnection.getComposingSpanStart(field.getText()));
            connection.setComposingText(" raw", 1);
            PendingDictation second = new PendingDictation(connection, 6, " raw");
            second.cancel(connection);
            assertFalse(second.complete(connection, "late"));
            assertEquals("edited raw", field.getText().toString());
            connection.setComposingText(" draft", 1);
            PendingDictation third = new PendingDictation(connection, 10, " draft");
            field.setSelection(0);
            assertFalse(third.complete(connection, "late"));
            assertEquals("edited raw draft", field.getText().toString());
        });
    }
}
