# Dictation failure feedback — 0.3.7 (14)

A user reported a beep and no text after releasing either Siri Remote or the Mac
microphone hotkey on another Mac. The cause is unconfirmed. DictationController.fail
itself calls NSSound.beep for multiple failure paths; the sound is not proof of an
Accessibility permission failure.

The app now shows persistent, nonactivating feedback for failures, missing
Accessibility permission, no recognized speech, stopped insertion and polishing
fallback. It offers Settings and Dismiss. Starting a new hold clears the notice.
No notification authorization is needed, and no provider response body, transcript
or key appears in the new notice.

Codes:
- DICT-ACCESS: Accessibility access needed.
- DICT-MIC-PERMISSION: microphone permission needed.
- DICT-AUDIO: capture/microphone failure or no usable audio.
- DICT-CREDENTIALS: missing key or recognizable authentication/service-access failure.
- DICT-SERVICE-LIMIT: recognizable quota/rate-limit response.
- DICT-INSERT: focus/caret/insertion failure.
- DICT-RECOGNITION: other recognition/service failure; inspect Dictation settings.
- DICT-NO-SPEECH: no recognized speech.
- DICT-POLISH: polishing unavailable; recognized text retained.

Accessibility is checked before editor-targeted capture and again during typing.
Streaming completion waits briefly for readable editor text and caret to confirm
the final draft. Unsupported AX editors cannot be reliably verified. This is
diagnostic feedback, not proof that all text insertion failures are detected.
User-edit cancellation remains silent and continues preserving edits.

Validation: 439 Mac tests, one skipped, zero failures. Strict-concurrency build,
script/entitlement checks, update-configuration tests, signature validation and
arm64 bundle validation passed. The first temporary-directory test run hit
SceneKit sandbox path errors; the clean run from a canonical user-directory
checkout passed. Another-Mac dictation remains unverified.

Prepared from release commit 5c5d4e2 plus the saved source.patch, excluding the
unfinished iCloud signing changes. Personal Developer ID Q9MD524YL5, existing
com.viberemote.app identity, version0.3.7/build14. No publication or feed update.
Apple notarization is pending: notarytool reported the VVHISPER_NOTARY Keychain
profile missing. Prepared app/archive and exact source patch are retained under
Release/artifacts/0.3.7-test and Release/artifacts/vvhisper-0.3.7-14-signed-unnotarized.zip.
