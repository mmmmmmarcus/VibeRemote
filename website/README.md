# VibeRemote website

The official site: one static page, no build step.

```
website/
  index.html      content and inline SVG (remote drawing, Advanced Menu glyphs)
  styles.css      tokens, light/dark themes, layout
  assets/         paint texture and icons derived from the app's resources
```

Preview locally:

```bash
python3 -m http.server 8000 --directory website
```

Then open http://localhost:8000. Opening `index.html` directly also works.

## Design notes

- A single narrow column (640 px) framed by two hairlines, like a drafting sheet.
- Paper background, uppercase grotesk headings (Geist), mono annotations (Geist Mono)
  and one serif italic accent (Instrument Serif), loaded from Google Fonts.
- The sky-blue oil-paint texture from the onboarding guide is the canvas for the
  figures. Text on paint uses the fixed `--on-paint` ink in both themes.
- Accent orange is the app icon's Siri button.
- The key map tabs are pure CSS (radio inputs); the page ships no JavaScript.

## Regenerating assets

The texture and icons are downsized copies of files in `app/`:

```bash
sips -s format jpeg -s formatOptions 62 -Z 1400 app/Resources/OnboardingSky.png --out website/assets/paint-sky.jpg
sips -Z 256 app/VibeRemoteAppIcon.png --out website/assets/icon-256.png
sips -Z 180 app/VibeRemoteAppIcon.png --out website/assets/apple-touch-icon.png
sips -Z 64  app/VibeRemoteAppIcon.png --out website/assets/favicon.png
```

## Content upkeep

Download buttons point at `releases/latest`, so new releases need no site change.
When button mappings change in the app, update the hero callouts, the feature list
and both key-map tables in `index.html` together.
