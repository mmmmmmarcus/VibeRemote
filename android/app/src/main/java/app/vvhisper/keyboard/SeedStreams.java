package app.vvhisper.keyboard;

import android.media.*;
import android.os.*;

import okhttp3.*;

import okio.ByteString;

import org.json.*;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.zip.GZIPInputStream;

/** Streams the same PCM to live and refinement sessions and delivers editor updates on main. */
final class SeedStreams {
    private final Dictation.Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final WebSocket live, polish;
    private volatile boolean liveFailed, polishFailed;
    private String latestLive = "", latestPolish = "";
    private boolean liveDone;
    private volatile boolean closed;

    SeedStreams(WebSocket.Factory client, String key, Dictation.Listener listener) {
        this.listener = listener;
        Request request =
                new Request.Builder()
                        .url("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
                        .header("X-Api-Key", key)
                        .header("X-Api-Resource-Id", "volc.bigasr.sauc.duration")
                        .header("X-Api-Connect-Id", UUID.randomUUID().toString())
                        .build();
        live = client.newWebSocket(request, receiver(false));
        polish =
                client.newWebSocket(
                        request.newBuilder()
                                .header("X-Api-Connect-Id", UUID.randomUUID().toString())
                                .url("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")
                                .build(),
                        receiver(true));
        String hello =
                "{\"user\":{\"uid\":\"vvhisper\"},\"audio\":{\"format\":\"pcm\",\"codec\":\"raw\",\"rate\":16000,\"bits\":16,\"channel\":1},\"request\":{\"model_name\":\"bigmodel\",\"enable_ddc\":true,\"enable_itn\":true,\"enable_punc\":true,\"result_type\":\"full\"}}";
        if (!frame(0x10, 0x10, hello.getBytes(StandardCharsets.UTF_8)))
            fail("Seed connection failed");
    }

    private WebSocketListener receiver(boolean accurate) {
        return new WebSocketListener() {
            @Override
            public void onMessage(WebSocket ws, ByteString message) {
                try {
                    response(message.toByteArray(), accurate);
                } catch (Exception e) {
                    unavailable(accurate);
                }
            }

            @Override
            public void onFailure(WebSocket ws, Throwable t, Response r) {
                unavailable(accurate);
            }

            @Override
            public void onClosed(WebSocket ws, int code, String reason) {
                unavailable(accurate);
            }
        };
    }

    private void unavailable(boolean accurate) {
        main.post(
                () -> {
                    if (closed) return;
                    if (accurate) polishFailed = true;
                    else liveFailed = true;
                    if (polishFailed && liveDone && !latestLive.isEmpty())
                        listener.text(latestLive, true);
                    else if (polishFailed && liveFailed)
                        listener.error("Seed unavailable. Check the API key and network.");
                });
    }

    void fail(String reason) {
        main.post(
                () -> {
                    if (!closed) listener.error(reason);
                });
    }

    private boolean frame(int kind, int serialization, byte[] payload) {
        ByteBuffer bytes = ByteBuffer.allocate(8 + payload.length);
        bytes.put((byte) 0x11)
                .put((byte) kind)
                .put((byte) serialization)
                .put((byte) 0)
                .putInt(payload.length)
                .put(payload);
        ByteString packet = ByteString.of(bytes.array());
        boolean sentLive = !liveFailed && live.send(packet);
        boolean sentPolish = !polishFailed && polish.send(packet);
        return sentLive || sentPolish;
    }

    private void response(byte[] data, boolean accurate) throws Exception {
        ByteBuffer in = ByteBuffer.wrap(data);
        int header = in.get() & 255, type = in.get() & 255, codec = in.get() & 255;
        in.position((header & 15) * 4);
        if ((type >> 4) == 15) {
            unavailable(accurate);
            return;
        }
        if ((type >> 4) != 9) throw new IOException();
        if ((type & 1) != 0) in.getInt();
        int size = in.getInt();
        if (size != in.remaining()) throw new IOException();
        InputStream input = new ByteArrayInputStream(data, in.position(), size);
        if ((codec & 15) == 1) input = new GZIPInputStream(input);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] chunk = new byte[4096];
        for (int n; (n = input.read(chunk)) != -1; ) {
            if (out.size() + n > 4000000) throw new IOException();
            out.write(chunk, 0, n);
        }
        Object result =
                out.size() == 0 ? null : new JSONObject(out.toString("UTF-8")).opt("result");
        if (result instanceof JSONArray) result = ((JSONArray) result).opt(0);
        String text =
                result instanceof JSONObject ? ((JSONObject) result).optString("text", "") : "";
        boolean last = (type & 2) != 0;
        main.post(
                () -> {
                    if (closed) return;
                    if (accurate) {
                        if (!text.isEmpty()) latestPolish = text;
                        if (last)
                            listener.text(latestPolish.isEmpty() ? latestLive : latestPolish, true);
                    } else {
                        if (!text.isEmpty()) latestLive = text;
                        liveDone = last;
                        listener.text(latestLive, last && polishFailed);
                    }
                });
    }

    boolean audio(byte[] pcm, boolean last) {
        return frame(last ? 0x22 : 0x20, 0, pcm);
    }

    void cancel() {
        closed = true;
        live.cancel();
        polish.cancel();
    }
}
