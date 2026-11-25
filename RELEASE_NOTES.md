**3.0.1**: fixes how future updates work for people who came from Evertalk, so an update can never leave you without the app. If you're on Evertalk, you go straight to 3.0.1.

Evertalk is now **Utter**: a full Mac app instead of a menu bar app.

## New
- **History**: every dictation is saved on your Mac. Search it (matches highlighted), copy it again, fix a word, or delete it. Nothing is lost if a paste fails.
- **Vocabulary**: teach Utter your words. Click Fix on a History entry, or import a glossary `.md` file and pick the terms to keep. Saved fixes apply every time.
- **Setup checklist**: microphone, Accessibility (with the Make Me Admin step on Everstage laptops), model download and a first dictation, each ticking green when done. Reopen it from Setup in the sidebar.
- **Updates you'll notice**: a notification and a banner, then one click.
- **Recording indicator**: live voice level, timer, cancel, and "Pasted" or "Copied" when it's done.
- **Settings page** with Light, Dark and System appearance.
- **Anonymous usage counts** (random ID and version numbers only), switchable off in Settings > Privacy.

## Coming from Evertalk
Run Make Me Admin first on an Everstage laptop, then click **Update to 3.0.0** in the Evertalk menu bar (or `brew upgrade --cask evertalk`). Your speech model and settings come with you; allow the microphone and Accessibility once more. Details in the README.

## Fixes
- A silent or failed dictation no longer wipes your clipboard.
- No crash when there's no microphone or access is denied.
- Launch at login works after the rename.
- The shortcut recovers by itself when another app releases it.

New installs:
```
brew trust --tap ram902-bot/tap
brew install --cask ram902-bot/tap/utter
```
