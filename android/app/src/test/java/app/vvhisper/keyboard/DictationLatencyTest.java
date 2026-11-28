package app.vvhisper.keyboard;

import static org.junit.Assert.*;
import android.os.Looper;
import okio.ByteString;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import okhttp3.*;
import java.time.Duration;
import java.util.*;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import static org.robolectric.Shadows.shadowOf;

@RunWith(RobolectricTestRunner.class) @Config(sdk=35)
public class DictationLatencyTest {
    @Test public void shortTextMatchesAppleRules() {
        for (String text : new String[]{"OK", "send it to me", "我知道了", "谢谢你", "don't do that"}) assertTrue(DictationShortText.skipsPolishing(text));
        for (String text : new String[]{"please send it to me", "我们明天再讨论吧", "send this to Marcus 明天"}) assertFalse(DictationShortText.skipsPolishing(text));
    }
    static class Loader implements DictationPolishPipeline.Loader {
        List<DictationPolisher.Completion> callbacks = new ArrayList<>();
        List<Call> calls = new ArrayList<>();
        public Call start(String source, String key, boolean translate, DictationPolisher.Completion done) {
            callbacks.add(done);
            Call call = new OkHttpClient().newCall(new Request.Builder().url("https://example.invalid").build());
            calls.add(call); return call;
        }
    }
    @Test public void exactMatchReusesRequestAndWaitsForSelection() {
        Loader loader = new Loader(); DictationPolishPipeline pipeline = new DictationPolishPipeline(loader);
        List<String> output = new ArrayList<>();
        pipeline.start("source", "synthetic", false);
        loader.callbacks.get(0).accept("polished", null); shadowOf(Looper.getMainLooper()).idle();
        assertTrue(output.isEmpty());
        pipeline.select("source", "synthetic", false, (text, error) -> output.add(text));
        assertEquals(List.of("polished"), output); assertEquals(1, loader.calls.size());
    }
    @Test public void changedInputRejectsLateSpeculation() {
        Loader loader = new Loader(); DictationPolishPipeline pipeline = new DictationPolishPipeline(loader);
        List<String> output = new ArrayList<>();
        pipeline.start("old source", "synthetic", false);
        pipeline.select("new source", "synthetic", false, (text, error) -> output.add(text));
        assertTrue(loader.calls.get(0).isCanceled());
        loader.callbacks.get(0).accept("wrong", null); shadowOf(Looper.getMainLooper()).idle();
        assertTrue(output.isEmpty());
        loader.callbacks.get(1).accept("right", null); shadowOf(Looper.getMainLooper()).idle();
        assertEquals(List.of("right"), output);
    }
    @Test public void budgetCommitsOriginalAndRejectsLateResponse() {
        Loader loader = new Loader(); DictationPolishPipeline pipeline = new DictationPolishPipeline(loader);
        List<String> output = new ArrayList<>();
        pipeline.select("source", "synthetic", false, (text, error) -> output.add(text));
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(3));
        assertEquals(List.of("source"), output); assertTrue(loader.calls.get(0).isCanceled());
        loader.callbacks.get(0).accept("late", null); shadowOf(Looper.getMainLooper()).idle();
        assertEquals(List.of("source"), output);
    }
    @Test public void cancellationCannotCommitFallbackOrLateResult() {
        Loader loader = new Loader(); DictationPolishPipeline pipeline = new DictationPolishPipeline(loader);
        List<String> output = new ArrayList<>();
        pipeline.select("source", "synthetic", true, (text, error) -> output.add(text));
        pipeline.cancel(); loader.callbacks.get(0).accept("late", null);
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(10));
        assertTrue(output.isEmpty()); assertTrue(loader.calls.get(0).isCanceled());
    }
    static class Socket implements WebSocket {
        final Request request;
        final WebSocketListener receiver;
        final List<ByteString> frames = new ArrayList<>();
        boolean closed;

        Socket(Request r, WebSocketListener l) {
            request = r;
            receiver = l;
        }

        public Request request() {
            return request;
        }

        public long queueSize() {
            return 0;
        }

        public boolean send(String s) {
            throw new AssertionError();
        }

        public boolean send(ByteString bytes) {
            frames.add(bytes);
            return true;
        }

        public boolean close(int code, String reason) {
            closed = true;
            return true;
        }

        public void cancel() {
            closed = true;
        }

        void result(String text, boolean last) {
            byte[] payload =
                    ("{\"result\":{\"text\":\"" + text + "\"}}").getBytes(StandardCharsets.UTF_8);
            ByteBuffer packet = ByteBuffer.allocate(8 + payload.length);
            packet.put((byte) 0x11)
                    .put((byte) (last ? 0x92 : 0x90))
                    .put((byte) 0x10)
                    .put((byte) 0)
                    .putInt(payload.length)
                    .put(payload);
            receiver.onMessage(this, ByteString.of(packet.array()));
        }
    }


    @Test public void stalledRefinementFallsBackOnceAtDeadline() {
        List<Socket> sockets = new ArrayList<>(); List<String> output = new ArrayList<>();
        SeedStreams streams = new SeedStreams((request, listener) -> { Socket socket = new Socket(request, listener); sockets.add(socket); return socket; }, "synthetic", new Dictation.Listener() {
            public void text(String text, boolean done) { if (done) output.add(text); }
            public void error(String error) { fail(error); }
        });
        streams.released(); sockets.get(0).result("usable live final", true);
        shadowOf(Looper.getMainLooper()).idle(); assertTrue(output.isEmpty());
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1500));
        assertEquals(List.of("usable live final"), output);
        sockets.get(1).result("late refinement", true);
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(6));
        assertEquals(List.of("usable live final"), output); streams.cancel();
    }
    @Test public void noTextWaitsForRecognitionBudgetAndCancelStopsTimers() {
        List<String> output = new ArrayList<>();
        SeedStreams streams = new SeedStreams((request, listener) -> new Socket(request, listener), "synthetic", new Dictation.Listener() {
            public void text(String text, boolean done) { if (done) output.add("text"); }
            public void error(String error) { output.add("error"); }
        });
        streams.released(); shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1500));
        assertTrue(output.isEmpty());
        streams.cancel(); shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(6));
        assertTrue(output.isEmpty());
    }
}
