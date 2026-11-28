package app.vvhisper.keyboard;

import android.media.*;

import okhttp3.OkHttpClient;

import java.io.IOException;
import java.util.Arrays;

/** The capture thread owns the microphone for the duration of one hold. */
final class SeedSession extends Dictation {
    private static final OkHttpClient CLIENT = new OkHttpClient();
    private final int packet;
    private final SeedStreams streams;
    private final Listener listener;
    private long lastLevel;
    private volatile boolean closed, stopping;

    SeedSession(String key, Listener listener, int packetMilliseconds) {
        packet = packetMilliseconds == 200 ? 6400 : 3200;
        this.listener = listener;
        streams = new SeedStreams(CLIENT, key, listener);
        new Thread(this::capture, "vvhisper-seed").start();
    }

    private void capture() {
        AudioRecord mic = null;
        try {
            int min =
                    AudioRecord.getMinBufferSize(
                            16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            mic =
                    new AudioRecord(
                            MediaRecorder.AudioSource.VOICE_RECOGNITION,
                            16000,
                            AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT,
                            Math.max(min, packet * 2));
            if (!closed && !stopping) mic.startRecording();
            byte[] data = new byte[packet];
            int used = 0;
            boolean first = true;
            while (!closed && !stopping) {
                int n = mic.read(data, used, Math.min(640, packet - used));
                if (n <= 0) throw new IOException();
                if (first) { first = false; listener.timing("micLive"); }
                long now = android.os.SystemClock.uptimeMillis();
                if (now - lastLevel >= 50) {
                    double sum = 0;
                    for (int i = used; i + 1 < used + n; i += 2) { double sample = (short) ((data[i] & 255) | (data[i + 1] << 8)) / 32768.0; sum += sample * sample; }
                    listener.level((float) Math.min(1, Math.sqrt(sum / Math.max(1, n / 2)) * 8)); lastLevel = now;
                }
                used += n;
                if (used == packet) {
                    if (!streams.audio(data, false)) throw new IOException();
                    used = 0;
                }
            }
            if (!closed && !streams.audio(Arrays.copyOf(data, used), true)) throw new IOException();
        } catch (SecurityException denied) {
            streams.fail("Microphone permission was revoked");
        } catch (Exception e) {
            streams.fail("Seed could not capture or send audio");
        } finally {
            if (mic != null) mic.release();
            if (!closed) listener.timing("captureStopped");
        }
    }

    void stop() {
        streams.released();
        stopping = true;
    }

    void cancel() {
        closed = true;
        streams.cancel();
    }
}
