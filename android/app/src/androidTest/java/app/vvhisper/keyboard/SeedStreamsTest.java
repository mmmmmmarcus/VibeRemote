package app.vvhisper.keyboard;

import static org.junit.Assert.*;

import android.app.Instrumentation;

import androidx.test.platform.app.InstrumentationRegistry;

import okhttp3.*;

import okio.ByteString;

import org.junit.Test;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class SeedStreamsTest {
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

    @Test
    public void previewsThenRefinesOnlyThisHold() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        List<Socket> sockets = new ArrayList<>();
        List<String> events = new ArrayList<>();
        SeedStreams streams =
                new SeedStreams(
                        (request, listener) -> {
                            Socket socket = new Socket(request, listener);
                            sockets.add(socket);
                            return socket;
                        },
                        "synthetic",
                        new Dictation.Listener() {
                            public void text(String text, boolean done) {
                                events.add((done ? "final " : "partial ") + text);
                            }

                            public void error(String error) {
                                fail(error);
                            }
                        });
        assertTrue(streams.audio(new byte[] {1, 2}, false));
        assertTrue(streams.audio(new byte[] {3, 4}, true));
        assertEquals(sockets.get(0).frames, sockets.get(1).frames);
        assertEquals(0x10, sockets.get(0).frames.get(0).getByte(1));
        assertEquals("11220000000000020304", sockets.get(1).frames.get(2).hex());
        sockets.get(0).result("你好", false);
        sockets.get(0).result("你好", true);
        sockets.get(1).result("你好。", true);
        instrumentation.waitForIdleSync();
        assertEquals(Arrays.asList("partial 你好", "partial 你好", "final 你好。"), events);
        streams.cancel();
        sockets.get(0).result("late", true);
        instrumentation.waitForIdleSync();
        assertEquals(3, events.size());
        assertTrue(sockets.stream().allMatch(s -> s.closed));
    }
}
