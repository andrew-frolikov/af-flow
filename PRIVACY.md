# AF Flow privacy policy

Last updated 10 September 2026. This describes AF Flow for macOS from version 1.0.1 (build 3), the first version on the Mac App Store.

## The short version

AF Flow does not collect any data. It has no account, no analytics, no advertising, no crash reporting and no tracking. What you say is turned into text on your Mac, and it stays on your Mac.

## What happens to your voice

While you hold your shortcut, AF Flow records from your microphone. A speech model that ships inside the app turns the recording into text on your Mac, and a small language model, also on your Mac, tidies the text up. The result goes on your clipboard for you to paste.

The audio of a dictation is not kept, unless you turn on "Also keep the audio of each dictation" in History, which keeps recordings on your Mac so a dictation that came back wrong can be checked again.

## What is stored on your Mac

- **Your transcripts,** in History, for up to a year.
- **Your settings,** such as your shortcuts and the words you want spelled a particular way.
- **A diagnostic log** of what the app did, kept for 30 days: for example when a recording started and stopped, which shortcut keys did it, and which model loaded. While you have the Debug log open, it also records each press of a shortcut key and the text of each dictation, and those lines are kept for the same 30 days. The Clear button in the Debug log deletes all of it.

All of it lives inside AF Flow's own sandboxed folder on your Mac. None of it is sent anywhere.

## Network access

AF Flow itself has no network access. The permission is absent from the app, so macOS blocks any connection it could attempt.

One small helper inside the app is allowed to download files, and it does one thing: when you choose a larger model in Settings, it downloads that model from Hugging Face (huggingface.co) and checks it against a fingerprint built into the app. As with any download, Hugging Face receives the request, including your IP address. Nothing about you, your voice or your text is sent. The helper has no access to your microphone or your transcripts.

## Permissions AF Flow asks for

- **Microphone,** to hear you while you dictate.
- **Input Monitoring,** so it can notice your shortcut while you work in another app. It looks only for the keys in your shortcuts and does not record what you type.

AF Flow does not ask for Accessibility, Screen Recording, your contacts or your location, and it opens no files except ones you choose yourself.

## Children

AF Flow collects no data from anyone, including children.

## Changes

If this policy changes, the new version will be published at this address with a new date.

## Contact

Questions about privacy: open an issue at https://github.com/andrew-frolikov/af-flow/issues
