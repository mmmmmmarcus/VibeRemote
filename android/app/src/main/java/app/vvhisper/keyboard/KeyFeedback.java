package app.vvhisper.keyboard;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.*;
import android.provider.Settings;
import android.view.*;

final class KeyFeedback {
    static void play(View key, int gesture) {
        Context context = key.getContext();
        SharedPreferences prefs = context.getSharedPreferences("keyboard", 0);
        if (!prefs.getBoolean("customHaptics", false)) {
            key.performHapticFeedback(gesture);
            return;
        }
        if (Settings.System.getInt(
                        context.getContentResolver(), Settings.System.HAPTIC_FEEDBACK_ENABLED, 1)
                == 0) return;
        int strength = prefs.getInt("strength", 50), sharpness = prefs.getInt("sharpness", 65);
        if (strength == 0) return;
        Vibrator vibrator = context.getSystemService(Vibrator.class);
        if (vibrator == null || !vibrator.hasVibrator()) return;
        int duration = 6 + (100 - sharpness) / 6;
        vibrator.vibrate(
                VibrationEffect.createOneShot(
                        duration,
                        vibrator.hasAmplitudeControl()
                                ? Math.max(1, 255 * strength / 100)
                                : VibrationEffect.DEFAULT_AMPLITUDE),
                new android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .build());
    }
}
