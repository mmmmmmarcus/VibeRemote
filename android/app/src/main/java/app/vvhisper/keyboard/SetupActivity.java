package app.vvhisper.keyboard;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.widget.*;

public final class SetupActivity extends Activity {
    private ConfigurationTransfer configurationTransfer;
    private LinearLayout form;
    private Button enable, microphone;

    @Override protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state); configurationTransfer.saveState(state);
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        configurationTransfer.result(request, result, data);
    }

    private int dp(int n) {
        return Math.round(n * getResources().getDisplayMetrics().density);
    }

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        configurationTransfer = new ConfigurationTransfer(this, state);
        ScrollView scroll = new ScrollView(this);
        form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        form.setFocusableInTouchMode(true);
        form.setPadding(dp(20), dp(16), dp(20), dp(24));
        scroll.addView(form);
        setContentView(scroll);
        scroll.setOnApplyWindowInsetsListener(
                (v, i) -> {
                    v.setPadding(0, i.getSystemWindowInsetTop(), 0, i.getSystemWindowInsetBottom());
                    return i.consumeSystemWindowInsets();
                });
        heading("Sync and Transfer");
        button("Export encrypted JSON (settings)", v -> configurationTransfer.exportFile(false));
        button("Import encrypted JSON", v -> configurationTransfer.importFile());
        heading("Keyboard");
        enable =
                button(
                        "Enable vvhisper",
                        v -> startActivity(new Intent(Settings.ACTION_INPUT_METHOD_SETTINGS)));
        button(
                "Choose keyboard",
                v -> getSystemService(InputMethodManager.class).showInputMethodPicker());
        microphone =
                button(
                        "Allow microphone",
                        v ->
                                requestPermissions(
                                        new String[] {Manifest.permission.RECORD_AUDIO}, 1));
        heading("Try keyboard");
        EditText test = new EditText(this);
        test.setMinLines(2);
        test.setHint("Type here, or hold a letter to dictate");
        test.setInputType(
                InputType.TYPE_CLASS_TEXT
                        | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                        | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        form.addView(test);
        heading("Dictation");
        android.content.SharedPreferences prefs = getSharedPreferences("keyboard", 0);
        for (String[] setting : new String[][] {{"autoCorrection", "Auto-Correction"}, {"smartSpacing", "Smart Spacing"}, {"mixedTyping", "More English Suggestions (experimental)"}}) {
            Switch toggle = new Switch(this); toggle.setText(setting[1]);
            toggle.setChecked(prefs.getBoolean(setting[0], !setting[0].equals("mixedTyping")));
            toggle.setOnCheckedChangeListener((v, checked) -> prefs.edit().putBoolean(setting[0], checked).apply()); form.addView(toggle);
        }
        Switch punctuation = new Switch(this);
        punctuation.setText("Sentence Punctuation");
        punctuation.setChecked(prefs.getBoolean("sentencePunctuation", true));
        punctuation.setOnCheckedChangeListener((v, checked) ->
                prefs.edit().putBoolean("sentencePunctuation", checked).apply());
        form.addView(punctuation);
        Switch polish = new Switch(this);
        polish.setText("Polish dictation");
        polish.setChecked(prefs.getBoolean("polish", true));
        polish.setOnCheckedChangeListener((v, checked) -> prefs.edit().putBoolean("polish", checked).apply());
        form.addView(polish);
        heading("Key feedback");
        Switch custom = new Switch(this);
        custom.setText("Customize haptics");
        custom.setChecked(prefs.getBoolean("customHaptics", false));
        form.addView(custom);
        LinearLayout controls = new LinearLayout(this);
        controls.setOrientation(LinearLayout.VERTICAL);
        form.addView(controls);
        slider(controls, "Strength", "strength", 50);
        slider(controls, "Sharpness", "sharpness", 65);
        Button preview = new Button(this);
        preview.setText("Test tap");
        preview.setOnClickListener(
                v -> KeyFeedback.play(preview, android.view.HapticFeedbackConstants.KEYBOARD_TAP));
        controls.addView(preview);
        controls.setVisibility(custom.isChecked() ? View.VISIBLE : View.GONE);
        custom.setOnCheckedChangeListener(
                (button, on) -> {
                    prefs.edit().putBoolean("customHaptics", on).apply();
                    controls.setVisibility(on ? View.VISIBLE : View.GONE);
                });
        update();
    }

    private void slider(LinearLayout controls, String name, String key, int initial) {
        android.content.SharedPreferences prefs = getSharedPreferences("keyboard", 0);
        TextView label = new TextView(this);
        SeekBar bar = new SeekBar(this);
        bar.setMax(100);
        bar.setProgress(prefs.getInt(key, initial));
        bar.setContentDescription(name);
        controls.addView(label);
        controls.addView(bar);
        label.setText(name + " · " + bar.getProgress() + "%");
        bar.setOnSeekBarChangeListener(
                new SeekBar.OnSeekBarChangeListener() {
                    public void onStartTrackingTouch(SeekBar bar) {}

                    public void onStopTrackingTouch(SeekBar bar) {}

                    public void onProgressChanged(SeekBar bar, int level, boolean user) {
                        label.setText(name + " · " + level + "%");
                        if (user) prefs.edit().putInt(key, level).apply();
                    }
                });
    }

    private void heading(String title) {
        TextView view = new TextView(this);
        view.setText(title);
        view.setTextSize(22);
        view.setPadding(0, dp(16), 0, dp(8));
        form.addView(view);
    }

    private Button button(String label, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(label);
        b.setAllCaps(false);
        b.setOnClickListener(listener);
        form.addView(b);
        return b;
    }

    private void update() {
        boolean enabled =
                getSystemService(InputMethodManager.class).getEnabledInputMethodList().stream()
                        .anyMatch(i -> i.getPackageName().equals(getPackageName()));
        enable.setText(enabled ? "Manage enabled keyboards" : "Enable vvhisper");
        boolean granted =
                checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                        == PackageManager.PERMISSION_GRANTED;
        microphone.setText(granted ? "Microphone allowed" : "Allow microphone");
        microphone.setEnabled(!granted);

    }

    @Override
    public void onResume() {
        super.onResume();
        update();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        update();
        if (code == 1 && !microphone.isEnabled()) return;
        if (code == 1 && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO))
            startActivity(
                    new Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.parse("package:" + getPackageName())));
    }
}
