# vvhisper for Android

> Personal-build update (2026-11-24): credentials are bundled at build time; no API-key
> setup or backend is required. Settings transfer now carries preferences only.
> Older credential setup instructions below are historical. See the repository's
> `macos/Design/PrivateBuilds.md`. Do not distribute these private app archives.


vvhisper is a native Android input method and companion settings app for Android 10 and later. Enable it in **vvhisper → Enable vvhisper**, select it with **Choose keyboard**, then open **Try keyboard** or a text field in another app. Dictation runs in the active keyboard and keeps the current editor on screen. If microphone permission is missing, tap the keyboard’s **Settings** action to grant it, then retry. Typing works offline.

### Mobile parity update — 2026-11-20

- Compact mode is one row: Expand, Dictate, Delete Word, Enter; mode choice persists.
- Left shortcut pill expands to Paste, newly copied Code, 1Password, Messages and
  Phone and Clipboard History. App shortcuts never call or send a message.
- Right gesture pill: left deletes a word, right restores it, down inserts a line
  separator and up moves to the end. Editing swipes were removed from ordinary
  keys; Space dragging, held Delete, pinch and dictation slides remain.
- Double-Space produces `. ` or `。`. Chinese symbols retain a dedicated period.
  Symbol holds show alternatives; punctuation returns to letters. Keys have press previews.
- The local Unicode Emoji 16.0 panel has categories and skin tones, using the shared
  iOS catalog/license. It does not change the selected input method or save history.
- Center-out white key illumination follows voice level; text legends disappear while
  listening and functional labels remain. Empty recognition has no error notice.
- Release over Language requests polish plus translation into the opposite spoken
  language. The separate Ark credential and existing text ownership guards still apply.
  Dictation slide-to-Send invokes only an advertised Send action; other fields keep
  the final text and ask for the app's Send button, without inserting a newline.
- Local typing assistance adds conservative English correction (including `im` →
  `I'm`), spacing, bounded Pinyin transposition/repeated-key repair and an optional
  More English Suggestions experiment. Existing exact Chinese dictionary order stays.

Android captures only during a hold, so iOS's background-ready lifetime and app-return
workaround are unnecessary here. Native Android autofill remains supported. Dictionary
and editor capabilities differ from iOS; this is feature parity, not identical platform
behavior. No microphone output/audio focus ducking is requested.

Validation: debug APK and instrumentation APK build, Android lint and six Robolectric
regressions pass. They cover dictionary/correction, emoji, translation request, owned
polish replacement, single-row mini and shortcut controls. Physical installation,
speech/volume/haptic feel and third-party app integration are pending a connected device.

### Using the keyboard

- Tap **EN / 中** beside **?123** for direct English or Simplified Chinese Pinyin. Type `nihao` and press Space for **你好**. Swipe the strip for more candidates or expand it. Return accepts the original spelling while composing.
- Hold a letter or a gap for 380 ms to dictate. Release to finish, slide onto Delete or outside the keys to cancel, or slide onto Enter to finish and invoke the field’s action. The mini Dictate key also exposes start/stop to accessibility activation.
- Swipe up on a top-row letter to enter its displayed digit. The smiley opens the local emoji panel and the numeric keypad is available from the symbol page. The symbol page includes the comma. The full-size letter keyboard shows suggestions as you type and keeps a stable strip with the shortcut and editing pills between words.
- Hold Space and drag to move the caret. Use the right gesture pill to swipe left to delete a word, right to restore it, down for a line break or up to the end of text. Hold Delete to repeat, then drag left to clear the field.
- Pinch in for the compact keyboard and out for full size. In compact mode, hold the microphone to dictate. Landscape phones show a movable floating keyboard. Wide tablet layouts split the letters and spacebar. System colors follow appearance and wallpaper on Android 12 and newer.
- Expand the shortcut pill to paste; Paste Code appears only for a newly copied code and expires after two minutes. Android 11 and newer can show inline suggestions from the selected autofill provider. The keyboard uses the host editor’s action for Next, Search, Send and Done.
- Key feedback follows system haptics by default. Settings also offers adjustable strength and sharpness where supported by the phone’s vibrator.

### Speech and privacy

The default backend uses the device's Android speech recognition service. Availability, offline operation and language switching depend on the provider and installed language models. The keyboard asks for English/Chinese switching on Android 14 and newer.

An optional Seed API key enables Volcengine streaming recognition and a parallel final refinement, matching the iOS two-stream approach. The key is encrypted with Android Keystore. Only an explicit dictation session captures audio. The keyboard uses the editor’s composing span for partial text and commits the final result in place. It skips voice in password fields. vvhisper does not save recordings or transcripts. Clipboard history is retained locally as described below.

### Build and test

Use a JDK 17 or 21, Android SDK Platform 35 and Python 3.9 or later. Run from this folder.

```sh
./gradlew assembleDebug lintDebug testDebugUnitTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

For the instrumented tests, select vvhisper on an unlocked test device and run:

```sh
./gradlew assembleDebugAndroidTest
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w app.vvhisper.keyboard.test/androidx.test.runner.AndroidJUnitRunner
```

The keyboard test injects taps into the actual IME and checks the text in the companion app. The Seed transport test uses synthetic PCM and scripted WebSocket replies to check live text, refinement and cancellation. Live recognition accuracy, autofill-provider integration and physical haptic feel require separate device checks.

### Dictionary

The Gradle build generates a read-only SQLite asset from the shared Rime Ice dictionaries and vvhisper glossary in [the iOS resource directory](../ios/Typing/Resources/Rime/). The build preserves explicit readings and weights. For entries supplied without a pronunciation it derives the spelling from the highest-weight available character readings. Android ranks exact spellings by frequency and tries longest matching segments as a fallback. Polyphonic phrases, segmentation and rankings can differ from librime on iOS.

The APK includes the dictionary provenance and full Rime Ice GPL-3.0 and vvhisper lexicon MIT license texts. Regenerate the database with [the dictionary compiler](scripts/dictionary.py). See the [shared dictionary attribution](../ios/THIRD_PARTY_NOTICES.md).

The bundled monochrome 1Password mark matches the iOS asset; see the shared
[third-party notices](../ios/THIRD_PARTY_NOTICES.md). Unicode Emoji 16.0 and Unicode
License V3 are copied into generated assets from ios/Shared at build time.

The key legends use a regular-weight subset of Google Sans from [Google Fonts](https://github.com/google/fonts/tree/main/ofl/googlesans). Its [SIL Open Font License](app/src/main/assets/licenses/GoogleSans-OFL.txt) ships in the APK.

### Polish dictation

Typing or deleting during polishing cancels the pending request and preserves
the visible transcript plus your edits. Late responses cannot replace the edited
text. This applies to touch keys, direct editing actions and hardware key input.

In vvhisper → Dictation, save a Volcengine Ark API Key. Polishing uses Seed 2.0 Mini with thinking disabled. Its key is stored separately from the Seed speech-recognition credential. Polish dictation defaults on. Only the final recognized transcript is sent for editing. The key is encrypted with Android Keystore. Missing credentials, a failed request, or the 15-second timeout leave the recognition result in place. The keyboard keeps the draft in Android’s native composing range while polishing. Each host editor controls its underline appearance. Editors that cannot confirm the draft range keep the recognition result locally.

**Sentence Punctuation** defaults on. For a short, single-sentence dictation, it preserves the spoken ending or adds a period (。 for text containing Han characters). Turning it off removes terminal sentence punctuation. The setting applies after optional polishing. Longer passages, multiple sentences and ambiguous dotted text keep their recognized or polished endings.

## Local clipboard history — 2026-11-20

The shortcut pill includes Clipboard History: the last five unique text clips
observed while the keyboard is visible or explicitly pasted through vvhisper.
Repeated copies move to the top; saved-item selection does not reorder the list
or replace the system clipboard. Clear History deletes only our stored list.
This is vvhisper-owned history going forward, not recovery of an OS history list.
Copies while inactive may be unavailable. Clips explicitly marked sensitive by
the source app, non-text clips and secure-field observations are excluded.

Exact text is bounded to 20,000 UTF-16 units per item. History is AES-GCM encrypted
with a dedicated Android Keystore key in no-backup storage; encryption failures
retain only the bounded in-memory list, never a plaintext disk fallback. Nothing
is logged or sent to speech/polishing providers. Selection rechecks the focused
connection, selection and surrounding context before insertion.
