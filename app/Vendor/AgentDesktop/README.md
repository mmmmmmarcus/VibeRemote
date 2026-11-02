# agent-desktop (vendored)

Unmodified macOS arm64 release binaries of
[vercel-labs/agent-desktop](https://github.com/vercel-labs/agent-desktop), Apache-2.0
(see `LICENSE`). VibeRemote's computer-use agent drives the Mac through this CLI.

- Release: `v1.0.2` (CLI 1.0.2, JSON envelope 2.5)
- Archive: `agent-desktop-v1.0.2-aarch64-apple-darwin.tar.gz`, SHA-256
  `7bee385196d7b478de80cf05ca4304aaa38f0eba593b3406ad3c247c1773be19` (matches the
  release's `checksums.txt`)
- `agent-desktop` SHA-256 `bf0a3c9256512f2f57288d37ccd17d7f03665fccc53c2f74011a49b98e61ba59`
- `agent-desktop-macos-helper` SHA-256 `522829116cb006b5770c6a82b361f466a4775f794d6af4083e75231a2d6bb551`

`create_app_bundle.sh` copies both files to `Contents/Helpers/AgentDesktop/` and re-signs
them with the app's identity. To update, download the new release archive, verify it
against `checksums.txt`, replace both binaries and update the values above.
