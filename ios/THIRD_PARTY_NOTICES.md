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

Chinese conversion uses the unchanged `8105`, `base`, and `ext` dictionaries from
[Rime Ice](https://github.com/iDvel/rime-ice/tree/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6),
commit `927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6` (GPL-3.0).
Their complete sources and upstream attribution comments are retained under
`Typing/Resources/Rime/cn_dicts/`; the full license is `RimeIce-LICENSE.txt`.
`dictionary-provenance.json` records per-file SHA-256 checksums and entry counts.
`scripts/compile-rime.py` verifies those sources and compiles the tables locally.
Both app bundles include the compiled tables, provenance and license; they omit
the build-time source YAML. Rebuild or modify the data from these retained sources
using the same script. The upstream weights are preserved; there is no hand-coded
replacement for an individual reported phrase. This data is separately licensed
from vvhisper's application code.

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
