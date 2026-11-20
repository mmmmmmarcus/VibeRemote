# vvhisper

Formerly VibeRemote. The name starts with two lowercase **v** characters: **vvhisper**.

vvhisper is a general voice interface for macOS: speak to write, or speak to get
something done. The baseline experience uses the Mac’s built-in microphone and keyboard;
no Siri Remote or other dedicated accessory is required. Siri Remote and future supported
devices enhance that experience with convenient controls and additional input options.

The four development priorities are:

- **General dictation:** improve speed, accuracy, text insertion, and feedback across Mac apps.
- **Computer Use:** make spoken tasks faster and easier to start, follow, and stop.
- **More devices:** let additional devices access the same core voice capabilities.
- **Product design:** make onboarding, navigation, and communication reflect a voice-first
  product with optional device enhancements.

See [Product direction](macos/Design/ProductDirection.md) for the intended experience,
current foundations, and implementation boundaries. Additional device support and the
product redesign are planned work, not claims about features already shipped.

| Folder | What it holds |
|---|---|
| [`macos/`](macos/) | The macOS product — SwiftPM package, build/sign scripts, tests, release tooling. Start with [macos/README.md](macos/README.md). |
| [`ios/`](ios/) | iOS companion app and custom voice keyboard. See [ios/README.md](ios/README.md). |
| [`android/`](android/) | Android system keyboard with English, offline Chinese Pinyin, and voice dictation. See [android/README.md](android/README.md). |
| [`website/`](website/) | The official static website. See [website/README.md](website/README.md). |

```bash
cd macos
./install.sh        # Developer ID signed build into /Applications
swift test
```

Download the latest build from [GitHub Releases](https://github.com/mmmmmmarcus/VibeRemote/releases/latest).

Agent and contributor guidance lives in [AGENTS.md](AGENTS.md). vvhisper is MIT licensed
([LICENSE](LICENSE)); third-party components keep their own terms
([macos/THIRD_PARTY_NOTICES.md](macos/THIRD_PARTY_NOTICES.md)).

For shared features and device updates, use the
[cross-platform delivery workflow](macos/Design/CrossPlatformDelivery.md), including
the reusable iPhone Duo polishing-setup verification flow.
