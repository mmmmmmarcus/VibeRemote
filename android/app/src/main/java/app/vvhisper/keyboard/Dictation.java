package app.vvhisper.keyboard;

import android.content.Context;
import android.content.Intent;
import android.os.Bundle;
import android.speech.*;

import java.util.ArrayList;

/** All editor-facing callbacks are delivered on the main thread. */
abstract class Dictation {
    interface Listener {
        void text(String text, boolean finished);

        void error(String message);
        default void level(float value) {}
        default void liveFinal(String text) {}
        default void timing(String stage) {}
        default void route(String path) {}
    }

    abstract void stop();

    abstract void cancel();

    static Dictation start(Context context, String seedKey, String language, Listener listener) {
        if (!seedKey.isEmpty()) return new SeedSession(seedKey, listener, context.getSharedPreferences("keyboard", 0).getInt("dictationAudioPacketMilliseconds", 100));
        if (!SpeechRecognizer.isRecognitionAvailable(context))
            throw new IllegalStateException("Set up Android speech recognition or add a Seed key");
        SpeechRecognizer recognizer = SpeechRecognizer.createSpeechRecognizer(context);
        recognizer.setRecognitionListener(
                new RecognitionListener() {
                    private void result(Bundle data, boolean done) {
                        ArrayList<String> words =
                                data == null
                                        ? null
                                        : data.getStringArrayList(
                                                SpeechRecognizer.RESULTS_RECOGNITION);
                        listener.text(words == null || words.isEmpty() ? "" : words.get(0), done);
                    }

                    public void onResults(Bundle data) {
                        result(data, true);
                    }

                    public void onPartialResults(Bundle data) {
                        result(data, false);
                    }

                    public void onError(int code) {
                        String message;
                        switch (code) {
                            case SpeechRecognizer.ERROR_NO_MATCH:
                            case SpeechRecognizer.ERROR_SPEECH_TIMEOUT:
                                listener.text("", true);
                                return;
                            case SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS:
                                message = "Allow microphone access in Settings";
                                break;
                            case SpeechRecognizer.ERROR_NETWORK_TIMEOUT:
                            case SpeechRecognizer.ERROR_NETWORK:
                                message = "Speech service network error";
                                break;
                            default:
                                message = "Speech recognition unavailable (" + code + ")";
                        }
                        listener.error(message);
                    }

                    public void onReadyForSpeech(Bundle b) {}

                    public void onBeginningOfSpeech() {}

                    public void onRmsChanged(float rms) { listener.level(Math.max(0, Math.min(1, (rms + 2) / 12))); }

                    public void onBufferReceived(byte[] b) {}

                    public void onEndOfSpeech() {}

                    public void onEvent(int type, Bundle b) {}
                });
        Intent intent =
                new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                        .putExtra(
                                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                        .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            intent.putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true);
            intent.putExtra(
                    RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH,
                    RecognizerIntent.LANGUAGE_SWITCH_BALANCED);
            intent.putStringArrayListExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_SWITCH_ALLOWED_LANGUAGES,
                    new ArrayList<>(java.util.Arrays.asList("en-US", "zh-CN")));
        }
        try {
            recognizer.startListening(intent);
        } catch (RuntimeException e) {
            recognizer.destroy();
            throw e;
        }
        return new Dictation() {
            void stop() {
                recognizer.stopListening();
            }

            void cancel() {
                recognizer.destroy();
            }
        };
    }
}
