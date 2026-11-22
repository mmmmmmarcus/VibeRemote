# Encrypted configuration files (2026-11-22)

Mac and iOS synchronize a user-selected encrypted JSON file in iCloud Drive.
Android imports and exports the identical file format through its document picker.
Existing local Seed ASR and Ark polishing key services remain the operational store;
no keys are moved or deleted when linking or disconnecting. The abandoned iCloud
Keychain sync entitlement and Mac provisioning-profile requirement are removed.

## Setup

In Sync and Transfer, choose Create Sync File, enter and confirm a password, and
save vvhisper-config.json in iCloud Drive. On the other Apple device, choose Link
Existing File, select that same file, and enter its password. Creating/linking sync
includes both API keys and the Polish Dictation / Sentence Punctuation settings.
Use a unique, strong password; there is no recovery of an encrypted file without it.
The password is remembered only in a device-local Keychain item. Existing API keys
continue working without cloud access. Disconnect keeps the local keys and file.

Mac checks every 15 seconds while running. iOS checks while its host app runs and
when it becomes active; open the host app to receive updates before dictating.
The keyboard does not access cloud files. Delivery depends on iCloud Drive and
is not immediate. File-provider errors are shown in the transfer screen.

Export/import is available on all three platforms. Settings-only export is the
default; including API keys is an explicit action. All exports are encrypted.
Import authenticates and validates the whole document before asking to replace
included values. Missing fields never erase keys. Plaintext JSON is not accepted.
Android does not automatically synchronize iCloud Drive: transfer the file through
a provider available on Android, then import it with the same password.

## Conflict and storage behavior

The Apple apps remember a security-scoped bookmark, a random password-item ID,
and hashes of the last merged fields in preferences. No plaintext keys or password
are stored there. File operations are coordinated, bounded, and writes are atomic;
sync compares the exact previously read ciphertext under the coordination lock
before overwriting. Unresolved provider file versions stop synchronization.

Nonoverlapping field edits merge. Different existing keys on initial linking,
or simultaneous edits to the same field, pause for Keep This Device / Keep File
Values. Provider version conflicts must be resolved in Files/Finder. Missing keys
are restored from the file; disconnect before intentionally clearing a local key.
Edits during asynchronous reads/encryption are rechecked before applying results.
Storage failures attempt to restore every included local value and report failures.

Device-specific microphones, gains, shortcuts, permissions, keyboard preferences,
Computer Use keys and other provider keys stay local. Only two shared settings
are currently included. A local key/password stays in the existing secure store.
iOS temporary export copies contain ciphertext only and are removed on picker
completion/cancellation or next entry to the transfer screen.

## Wire format v1

Outer JSON fields:

| Field | Value |
|---|---|
| format | vvhisper.encrypted |
| version | 1 |
| kdf | pbkdf2-sha256 |
| iterations | 600000 |
| cipher | aes-256-gcm |
| salt | Base64, 16 random bytes |
| nonce | Base64, 12 random bytes |
| ciphertext | Base64, ciphertext followed by the 16-byte authentication tag |

Derive a 32-byte key with PBKDF2-HMAC-SHA256. Password encoding is exact UTF-8,
without normalization or trimming, 8–256 Unicode scalars. AAD is the exact UTF-8
string `vvhisper-config:v1`. Generate fresh salt and nonce for every write.
Algorithms, versions, iteration count and lengths are checked before deriving.
Wrong passwords and modified files fail authentication without changing settings.
Maximum outer file size is 128 KiB; decrypted payload is at most 64 KiB.

The inner JSON has format `vvhisper`, version `1`, required object `settings`
with optional boolean `polishDictation` and `sentencePunctuation`, plus optional
`credentials` with optional strings `seedASR` and `polishing`. Keys must be nonempty,
whitespace-free and at most 8192 UTF-8 bytes. Null/missing values are ignored.
No endpoint URL or executable instruction is imported. Do not log either payload.

## Verification boundary

Shared tests cover independent Node.js crypto vectors with a non-ASCII password,
Apple/Java interoperability, randomized encryption, tampering, malformed/oversized
files, merge conflicts, missing keys, stale writes and local storage rollback.
Mac lifecycle tests exercise a real local bookmark and a temporary local Keychain
password. Build/test success does not establish iCloud delivery: actual two-device
file-provider synchronization and native file-picker acceptance remain to be tested
with a user-selected file and password. Android device UI is likewise unverified.

Validation on 2026-11-22: full Mac suite 444 tests (one skipped, no failures),
then six configuration tests passed after final lifecycle changes with strict
concurrency enabled. Five configuration tests passed on the Duo iOS simulator.
Android's 13 unit tests, debug assembly and lint passed. Java decrypted an actual
Apple export, Apple decrypted an actual Java export, and independent Node crypto
decrypted both; all fixtures used fake keys. The iOS signed build passed.
The final Mac Developer ID signed bundle also passed strict signature verification,
without the former sync profile. It is not notarized, installed or released by this
change. Completed builds are macos/vvhisper.app, ios/build/vvhisper.app and
android/app/build/outputs/apk/debug/app-debug.apk. Temporary Mac compilation caches
were removed after validation.
