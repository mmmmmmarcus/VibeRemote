# Mobile keyboard delivery — 2026-11-20

Source/build, installation and physical verification are separate. No transcript,
credential or clipboard history is retained by this delivery checklist.

| Behavior | iOS / iPadOS | Android |
|---|---|---|
| Media playback while voice is ready | Default audio mode, mixing, A2DP; removed measurement attenuation | Capture exists only during an explicit hold; no ready-session audio focus |
| No recognized speech | Silent final reply | Empty Seed/native recognition completes silently |
| Shortcut pill | Left; Paste, new copied Code, 1Password, Messages, Phone | Same; native app intents |
| Clipboard history | Five unique observed/pasted text clips, protected local file, no backup | Same cap; Keystore AES-GCM, no-backup file; excludes sensitive clips |
| Editing pill | Right; word delete/restore, line separator, end-of-text | Same with Android caret APIs |
| Ordinary keys | No editing swipe callbacks; hold, Space trackpad, Delete hold, pinch preserved | Same; existing top-row digit flick remains |
| Double-Space | English `. ` / Chinese `。`, owned-context/time guards | Same language rule with editor/time guards |
| Chinese punctuation | Dedicated period; quotes remain separate | Dedicated period and Chinese symbol mapping |
| Mini | One row; Expand, Dictate, Delete Word, Enter | Same; persisted mode and resize transition |
| Emoji | Local Unicode 16.0 categories and tones | Same bundled catalog, native grid |
| Symbol alternatives | Hold/slide chooser, return to letters after punctuation | Hold/slide chooser, return to letters after punctuation |
| Voice feedback | Center-out white illumination; functional icons retained | Center-out PCM/native-RMS white illumination; functional labels retained |
| Release-to-translate | Opposite spoken language, explicit gesture; independent of typing mode | Same, separate Ark credential |
| Send gesture | Only host-advertised Send; otherwise finalized text without newline | Only IME_ACTION_SEND; otherwise manual-send hint |
| Typing assistance | UIKit/English hints + librime single-slip repairs | Conservative bundled-English correction + SQLite single-slip repairs |
| Tablet layout | >=600-point iPad idiom: continuous number/Tab/Return/arrows five-row layout | Existing native Android wide layout preserved |

## Boundaries and pending checks

- iOS publicly exposes no universal external-app Send action. Phone may reject an
  empty `tel:` URL; the shortcut falls back to a manual-open hint, never a fake number.
- End-of-text depends on host editor cooperation. iOS walks acknowledged context
  chunks with a bound; Android uses extracted text or a native Ctrl-End request.
- iOS/iPadOS deployment baseline stays 27.0. The available 27.1 runtime supports
  only iPhone Duo. iPad layouts have UIKit geometry/render coverage, not actual
  iPad runtime/physical acceptance. The physical iPad is unavailable; the Duo update is installed.
- Android system speech recognition, autofill and dictionary ranking differ from
  iOS providers. Feature parity does not mean identical linguistic results.
- 241 iOS tests passed, then 10 pill and nine candidate/tablet tests covered final
  strip changes. The signed app verifies and declares device families 1 and 2. The clipboard addition passed 18 focused iOS tests and nine Android
  Robolectric tests; debug app/instrumentation APK and lint pass. The signed build is installed and launches on the physical Duo. Try Keyboard and the new shortcut pill were visible on the Duo, but
  automation still could not activate the pill reliably after rotation. Clipboard
  menu interaction and the media-volume comparison remain physically unverified. Android/iPad installation, haptic
  feel, live speech/translation and app shortcut handling remain unverified.

Build products: `ios/build/vvhisper.app` and
`android/app/build/outputs/apk/debug/app-debug.apk`. Install over existing data.
