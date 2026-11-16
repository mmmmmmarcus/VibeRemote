# vvhisper app icon

The speech balloon and three voice bars represent the voice interface to the computer. The orange palette and balloon silhouette follow the [Figma reference](https://www.figma.com/design/OQL9debRkSqot7KZSiWwsU/?node-id=1405-765).

`../VibeRemote.icon` is the editable Icon Composer source. Its legacy filename is retained for the existing bundle pipeline. Both foreground SVGs use a 1024-point canvas. The balloon uses the exact Union path from Figma node 1405:767, placed at (42, 40) on the original 256-point canvas and scaled uniformly by 4. Its original stem continues beyond the canvas and is clipped at the bottom edge. The bars retain the original 20-point widths, 18-point gaps, 44/84/44-point heights, and center (128, 127). No inset or silhouette redesign is applied. The balloon receives native glass, lighting and shadow; the background and appearance variants are rendered by Apple. Groups are ordered front to back.

`../VibeRemoteAppIcon.png` is the native 1024-pixel Default export used by the audio-driver build. Regenerate it from the repository root with:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" app/VibeRemote.icon --export-image --output-file app/VibeRemoteAppIcon.png --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
```

The app bundle continues to compile the layered document using `actool`; the PNG is not its replacement. Review Default, Dark and TintedDark renditions and the compiled 16/32-pixel fallback when changing geometry. Follow [Apple app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).
