# Private builds (2026-11-24)

vvhisper is a personal-use app. macOS, iOS (host and keyboard) and Android bundle
fixed provider credentials and connect directly to the providers. No backend or
user-facing credential setup is required. These binaries contain extractable
credentials and must not be published to GitHub releases, Sparkle or app stores.

`build.sh`, `ios/build.sh`, and Android Gradle's `preBuild` run
`macos/scripts/prepare-private-credentials.py`. On this Mac it reads the existing
Seed and Ark Keychain items without changing them. Optional OpenAI/OpenRouter
items are included when available. Seed must be a new-console API key, not a
legacy token paired with an App ID. Missing Seed/Ark credentials stop the build.

For another build machine, set `VVHISPER_PRIVATE_CREDENTIALS` to an external,
private JSON file containing string fields `seed`, `ark`, and optionally
`openai` and `openrouter`. Never place values in shell arguments, logs or Git.
The script creates a mode-0600 ignored resource. Android uses its ignored build
folder. Apple targets copy the PrivateCredentials folder into their resources.
Direct SwiftPM tests and Xcode builds need the preparation script run first.
Rebuild to rotate credentials; the running app never downloads them.

Existing credential stores are retained for compatibility, but runtime reads use
only bundled credentials. Settings transfer exports/imports preferences only;
legacy encrypted sync files retain their existing credential fields without
applying those fields to the app. Polishing and punctuation remain configurable.
OpenAI/Computer Use cloud calls report unavailable if their optional key is absent.

Build checks do not prove live speech recognition or real keyboard insertion.

Validation for this change: macOS strict-concurrency build and 447 tests (one skipped),
iOS signed device build and 280 simulator tests, Android debug APK/lint and 14 unit
tests, and three credential-preparation tests passed. Resource contents were checked
without logging values. Installed apps were not replaced; live dictation was not tested.
The local Seed and Ark keys were available; OpenAI and OpenRouter keys were absent.
