package app.vvhisper.keyboard;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.text.InputType;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.Toast;
import java.io.ByteArrayOutputStream;

final class ConfigurationTransfer {
    private static final int EXPORT = 7101, IMPORT = 7102;
    private final Activity activity;
    private boolean includeKeys;
    ConfigurationTransfer(Activity activity, Bundle saved) {
        this.activity = activity; includeKeys = saved != null && saved.getBoolean("config.exportKeys", false);
    }
    void saveState(Bundle state) { state.putBoolean("config.exportKeys", includeKeys); }
    void exportFile(boolean keys) {
        includeKeys = keys;
        activity.startActivityForResult(new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/json").putExtra(Intent.EXTRA_TITLE, "vvhisper-config.json"), EXPORT);
    }
    void importFile() {
        activity.startActivityForResult(new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                .setType("application/json"), IMPORT);
    }
    boolean result(int request, int result, Intent intent) {
        if (request != EXPORT && request != IMPORT) return false;
        if (result != Activity.RESULT_OK || intent == null || intent.getData() == null) return true;
        final android.net.Uri uri = intent.getData();
        final boolean keys = includeKeys;
        askPassword(request == EXPORT, password -> new Thread(() -> {
            try {
                if (request == EXPORT) {
                    byte[] data = EncryptedConfiguration.seal(PortableConfiguration.capture(activity, keys), password);
                    try (var stream = activity.getContentResolver().openOutputStream(uri, "wt")) {
                        if (stream == null) throw new IllegalStateException(); stream.write(data);
                    }
                    onUI(() -> notice("Encrypted configuration exported."));
                } else {
                    byte[] data;
                    try (var stream = activity.getContentResolver().openInputStream(uri); var output = new ByteArrayOutputStream()) {
                        if (stream == null) throw new IllegalStateException();
                        byte[] buffer = new byte[4096]; int count;
                        while ((count = stream.read(buffer)) != -1) {
                            if (output.size() + count > EncryptedConfiguration.MAX_BYTES) throw new IllegalArgumentException();
                            output.write(buffer, 0, count);
                        }
                        data = output.toByteArray();
                    }
                    PortableConfiguration config = EncryptedConfiguration.open(data, password);
                    onUI(() -> new AlertDialog.Builder(activity).setTitle("Import configuration?")
                            .setMessage("Replace the included polishing and punctuation settings? Credentials and device settings stay unchanged.")
                            .setNegativeButton("Cancel", null).setPositiveButton("Import", (d,w) -> new Thread(() -> {
                                try { config.apply(activity); onUI(() -> { notice("Configuration imported."); activity.recreate(); }); }
                                catch (Exception error) { onUI(() -> notice("Couldn’t save the configuration. Please try again.")); }
                            }, "ConfigurationImport").start()).show());
                }
            } catch (Exception error) {
                onUI(() -> notice(request == IMPORT ? "Couldn’t unlock the file. Check the password and file format. No settings were imported."
                        : "Couldn’t export the encrypted configuration."));
            }
        }, "ConfigurationCrypto").start());
        return true;
    }
    private interface PasswordAction { void run(String password); }
    private void askPassword(boolean creating, PasswordAction action) {
        LinearLayout layout = new LinearLayout(activity); layout.setOrientation(LinearLayout.VERTICAL);
        int padding = (int)(24 * activity.getResources().getDisplayMetrics().density); layout.setPadding(padding, 0, padding, 0);
        EditText password = passwordField("Password"); layout.addView(password);
        EditText confirmation = passwordField("Confirm password"); if (creating) layout.addView(confirmation);
        AlertDialog dialog = new AlertDialog.Builder(activity).setTitle(creating ? "Protect configuration" : "Unlock configuration")
                .setMessage(creating ? "Choose a long, unique password (at least 8 characters). Keep it for your other devices; it cannot be recovered."
                        : "Enter the same password used on Mac or iOS.")
                .setView(layout).setNegativeButton("Cancel", null).setPositiveButton("Continue", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String value = password.getText().toString();
            try {
                EncryptedConfiguration.validatePassword(value);
                if (creating && !value.equals(confirmation.getText().toString())) { confirmation.setError("Passwords don’t match"); return; }
                password.setText(""); confirmation.setText(""); dialog.dismiss(); action.run(value);
            } catch (IllegalArgumentException error) { password.setError("Use at least 8 characters, up to 1024."); }
        }));
        dialog.setOnDismissListener(d -> { password.setText(""); confirmation.setText(""); });
        dialog.show();
    }
    private EditText passwordField(String hint) {
        EditText field = new EditText(activity); field.setHint(hint);
        field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        field.setSaveEnabled(false); return field;
    }
    private void onUI(Runnable action) {
        activity.runOnUiThread(() -> { if (!activity.isFinishing() && !activity.isDestroyed()) action.run(); });
    }
    private void notice(String text) { Toast.makeText(activity, text, Toast.LENGTH_LONG).show(); }
}
