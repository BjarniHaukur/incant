# Incant

A tiny native macOS push-to-dictate app using OpenAI Realtime transcription.

Press **Command-Shift-Space** to start recording. Press it again to commit the
audio and stop. Transcript deltas are inserted continuously at the focused
cursor while you speak; stopping never pastes a completed transcript.

## Build

```sh
./build-app.sh
open dist/Incant.app
```

The API key is stored in macOS Keychain. Incant needs Microphone permission
and Accessibility permission for text insertion in apps that do not expose a
writable accessibility text selection.
