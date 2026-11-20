# iOS typed keyboard references and dependencies

The keyboard UI and integration are vvhisper code. Design references:
- Hamster (MIT from v2.1.0): https://github.com/imfuxiao/Hamster
- Cantoboard (interaction reference, no source copied): https://github.com/Cantoboard/Cantoboard

## Engine

Rime 1.17.0 (BSD-3-Clause), packaged by ghostflyby/librime-xcframework,
release `1.17.0-pack.10.0.0`. `scripts/prepare-rime.py` pins the archive SHA-256
`9e9923112ee9cee9bb53c25b41e51a2d7ea2ab3d91f34c7c99682224a23718ac`.
Source and build scripts: https://github.com/ghostflyby/librime-xcframework/tree/1.17.0-pack.10.0.0
Upstream: https://github.com/rime/librime/tree/1.17.0
Full engine/dependency notices and build metadata are retained and bundled in
`Typing/Resources/Rime/Licenses/`.

## Dictionary

Chinese conversion uses the unchanged `8105`, `base`, `ext`, and `tencent` dictionaries from
[Rime Ice](https://github.com/iDvel/rime-ice/tree/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6),
commit `927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6` (GPL-3.0).
Their complete sources and upstream attribution comments are retained under
`Typing/Resources/Rime/cn_dicts/`; the full license is `RimeIce-LICENSE.txt`.
`dictionary-provenance.json` records per-file SHA-256 checksums and entry counts.
`scripts/compile-rime.py` verifies those sources and compiles the tables locally.
Both app bundles include the compiled tables, provenance and license; they omit
the build-time source YAML. Rebuild or modify the data from these retained sources
using the same script. The upstream weights are preserved. This data is separately licensed
from vvhisper's application code.

The supplemental `cn_dicts/vvhisper_design.dict.yaml` design glossary and
`EnglishWords.txt` English hints are authored for vvhisper under MIT, with the
full license in `VvhisperLexicon-LICENSE.txt`. The glossary is imported last so
duplicate words retain upstream weights. Their checksums and entry counts live
in `local_tables` and `local_resources` in the same provenance file and are
verified by the compiler script. No per-phrase runtime replacement is used.

The former minimal `Typing/Resources/Rime/pinyin_simp.dict.yaml` is retained as
the source of the syllable list only, unchanged from
https://github.com/rime/rime-pinyin-simp/tree/0c6861ef7420ee780270ca6d993d18d4101049d0
(Apache-2.0, derived upstream from Android PinyinIME).
The full license is bundled as `Typing/Resources/Rime/Pinyin-LICENSE.txt`.
`Typing/Resources/Rime/PinyinSyllables.txt` contains the 415 unique syllables
extracted from that same pinned dictionary for bilingual candidate ranking.
The `vvhisper_pinyin.schema.yaml`, `vvhisper_lexicon.dict.yaml` and `default.yaml`
files are vvhisper's configuration. Typing uses no cloud service, learning database,
telemetry, or runtime downloads. No external contextual language model is bundled.

## Local keyboard-return experiment

The Debug-only containing-app observer was informed by the UIKit event path
reported in [OpenWhispr's HostAppObserver.swift](https://github.com/OpenWhispr/openwhispr/blob/main/openwhispr-mobile/modules/app-group-storage/ios/HostAppObserver.swift).
vvhisper implements its own bounded Objective-C observer and nonce-validated
handoff coordinator; no OpenWhispr source is bundled. The unsuccessful
KeyboardHostBundleID extension hook was removed. Release excludes the observer
and private app-return implementation.

## Keyboard design reference

The iOS 27 keyboard appearance is based on the user-supplied
[iOS and iPadOS 27 community design](https://www.figma.com/design/hJpZ9njDa75F3aO9huKPUw?node-id=0-3329).
Reference nodes: `12890:27040` (Duo outer portrait), `12890:31610` (inner
portrait), `12890:31654` (inner landscape), `12890:30558` (outer landscape),
and `12740:24279` (standard iPhone). The five keyboard-switcher SVG assets in
`Keyboard/Assets.xcassets` are exports from those reference components, retained
without path edits and rendered as template images. System symbols and system
fonts are resolved on iOS; no Apple font binaries are bundled.

## 1Password shortcut mark

`Shared/Assets.xcassets/OnePassword.imageset/OnePassword.svg` is the unmodified
monochrome 1Password SVG from [Simple Icons](https://github.com/simple-icons/simple-icons/blob/develop/icons/1password.svg),
whose icons are distributed under [CC0-1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md).
The 1Password name and mark belong to 1Password. It identifies an app-opening
shortcut, not an endorsement or embedded credential-provider integration.

## Unicode emoji data

`Shared/EmojiCatalog.json` is derived from the fully-qualified sequences in
[Unicode Emoji 16.0 emoji-test.txt](https://unicode.org/Public/emoji/16.0/emoji-test.txt).
Source SHA-256: `24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697`.
Copyright Unicode, Inc. Distributed under the Unicode License V3, bundled at
`Shared/Unicode-Emoji-LICENSE.txt`. The panel renders Apple's system emoji font;
no Apple glyph images or fonts are bundled.

`Shared/EmojiKeywords.json` contains English and Simplified Chinese emoji names
and keywords from [Unicode CLDR 47.0.0](https://github.com/unicode-org/cldr-json/tree/47.0.0),
restricted to the bundled emoji catalog. The Unicode License V3 above applies.
`Shared/EmojiKeywords-Provenance.json` records source URLs and SHA-256 hashes;
`scripts/prepare-emoji-keywords.py` regenerates the index and its small preferred
everyday-symbol ordering. The keyboard performs matching locally.
