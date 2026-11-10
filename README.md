# VibeRemote

The one app that turns your Siri Remote into the best AI inputer: a macOS menu-bar app
that maps every remote button to the keys AI agent apps need — per app, with profiles —
and turns the remote's microphone into dictation that types your prompt as you speak.

| Folder | What it holds |
|---|---|
| [`app/`](app/) | The macOS product — SwiftPM package, build/sign scripts, tests, release tooling. Start with [app/README.md](app/README.md). |
| [`website/`](website/) | The official static website. See [website/README.md](website/README.md). |

```bash
cd app
./install.sh        # Developer ID signed build into /Applications
swift test
```

Download the latest build from [GitHub Releases](https://github.com/mmmmmmarcus/VibeRemote/releases/latest).

Agent and contributor guidance lives in [AGENTS.md](AGENTS.md). VibeRemote is MIT licensed
([LICENSE](LICENSE)); third-party components keep their own terms
([app/THIRD_PARTY_NOTICES.md](app/THIRD_PARTY_NOTICES.md)).
