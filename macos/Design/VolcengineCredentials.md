# Volcengine dictation credentials

Recorded: 2026-11-19 (Asia/Shanghai). Applies to macOS, iOS, and Android.

## Current setup: two keys

| Purpose | Credential | Where to find/manage it |
| --- | --- | --- |
| Speech recognition (ASR) | Existing Doubao Speech API key | [Doubao Speech → API Key management, default project](https://console.volcengine.com/speech/new/setting/apikeys?projectName=default) |
| Text polishing | New IAM API key, named `vvhisper-shared-asr-polish`, belonging to IAM user `vvhisper` | [IAM → vvhisper user](https://console.volcengine.com/iam/identitymanage/user/vvhisper/) → **密钥** → **API Key** |

Sign in to the same Volcengine account used during setup. Speech keys are project-specific; select the appropriate project if the existing key is not shown. IAM-created keys are managed in IAM, not in the Ark API Key list. The IAM key's name reflects the intended shared setup; it does not mean shared ASR authentication has been verified.

No API key values are recorded in this document. Do not put credentials in source control, screenshots, logs, or chat messages.

## Why two keys remain necessary in the current setup

The intended setup was one IAM API key for both Speech and Ark. With explicit user approval, we created the `vvhisper` IAM user and attached:

- `ArkInferenceFullAccess`: `ark:SendInference` on `*` (verified policy contents at setup).
- Custom `vvhisperSpeechAccess`: `speech_saas_prod:*` on `*`.

No global administrator permission or `iam:CreateServiceLinkedRole` permission was granted. Console login and Access Key/Secret Key creation were not enabled for this user.

Live checks on 2026-11-19:

- **Ark passed:** the new IAM key returned HTTP 200 with a complete JSON text response from `doubao-seed-2-0-mini-260428`, with `thinking.type=disabled`, in approximately 0.8 seconds for a synthetic grammar test.
- **Speech failed:** both `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async` and `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream` rejected the new key through `X-Api-Key` with HTTP 401, `Invalid X-Api-Key`.
- Trying `Authorization: Bearer …` on the streaming Speech endpoint returned HTTP 400, `app key not found in header or query`.
- A later check still returned HTTP 401. The underlying compatibility/configuration issue remains unresolved; this is not proof that all Speech APIs lack IAM support.

The existing Speech credentials were therefore preserved. Do not replace them with the IAM key until the actual ASR endpoints pass authentication and recognition checks. The earlier existing Speech key also failed an Ark request with HTTP 401, so it is not a verified replacement for the polishing key.

## Platform provisioning status

| Platform | Polishing key | ASR key | Verification boundary |
| --- | --- | --- | --- |
| macOS | Saved in Keychain, service `com.viberemote.dictation.ark`, account `api-key` | Existing key unchanged | Direct Ark service request passed; full spoken dictation through the installed Mac app was not verified in this provisioning session. |
| Android | Saved in the app's encrypted Ark credential store on device 0043 | Existing key unchanged | Installed app's polisher passed a live synthetic grammar test. Full microphone → ASR → polish → editor insertion remains unverified for this setup. |
| iOS | Saved in the app's Keychain on Duo; Polish Dictation enabled | Existing key unchanged | Latest source rebuilt and installed on 2026-11-19; UI confirms Saved, enabled, and Seed 2.0 Mini. Full spoken dictation through polishing remains unverified in this provisioning session. |

The intended cross-platform arrangement is the same pair of credentials, stored separately for ASR and polishing. This does not mean every device is already configured.

## References and follow-up

- [Volcengine IAM API Key best practices](https://docs.volcengine.com/docs/ark/iam-api-key-best-practices?lang=zh): documents cross-product IAM keys and mentions Doubao Speech as a supported product.
- [IAM API credential management](https://docs.volcengine.com/docs/iam/api-access-key-management?lang=zh): credential management and supported products.
- [Doubao Speech API Key usage](https://docs.volcengine.com/docs/doubao-voice/api-key-usage?lang=en): Speech-specific API keys and the `X-Api-Key` header.

Next steps: verify a full spoken dictation on Duo; resolve the documented IAM support versus observed ASR rejection before attempting a shared-key migration. Keep the two-key setup working in the meantime.
