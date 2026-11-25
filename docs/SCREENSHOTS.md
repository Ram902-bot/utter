# Screenshots

The images in `docs/screenshots/` are rendered by the app itself, from dummy data, so they always match the current UI.

Debug builds include a render mode (`Utter/DocsRenderer.swift`). It uses a throwaway data folder, skips the speech model, update checks and usage counts, opens each screen in a window for about a second, saves it as a PNG and quits. Release builds don't include it.

## Regenerate

1. Put dummy data in a folder: `history.json` (list of entries) and `vocabulary.json` (`terms` and `replacements`). The formats match what Utter writes to `~/Library/Application Support/Utter`.
2. Build Debug, then run:

```bash
APP=$(ls -td ~/Library/Developer/Xcode/DerivedData/Utter-*/Build/Products/Debug/Utter.app | head -1)
UTTER_DOCS_RENDER=1 UTTER_SUPPORT_DIR=/path/to/dummy-data UTTER_DOCS_OUT=/path/to/output \
  "$APP/Contents/MacOS/Utter"
```

Add `UTTER_DOCS_DARK=1` for dark mode. Quit the installed Utter first so its window doesn't flicker.

Use fictional names and companies in dummy data, never real customers.

## Files

| File | Shows |
|---|---|
| `history.png` | Main window, History page |
| `history-search.png` | Search with highlighted matches |
| `history-update.png` | Update banner |
| `vocabulary.png` | Vocabulary page |
| `fix-word.png` | Fix a word sheet |
| `import-review.png` | Review step after importing a Markdown file |
| `setup.png` | Setup page with ticks and the Updates card |
| `settings.png` | Settings page |
| `pill-*.png` | Floating indicator: idle, recording, transcribing, pasted, copied |
