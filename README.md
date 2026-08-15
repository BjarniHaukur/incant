<h1 align="center">Incant</h1>

<p align="center">
  <img src="docs/orb.webp" width="300" alt="The Incant orb: luminous dye folding through a dark glass sphere">
</p>

<p align="center">
  <em>A tiny native macOS push-to-dictate app using OpenAI Realtime transcription.</em>
</p>

Press **Command-Shift-Space** to start recording. Press it again to commit the
audio and stop. Transcript deltas are inserted continuously at the focused
cursor while you speak; stopping never pastes a completed transcript.

## The orb

The floating window above is a live fluid simulation, not a video. Dye sheets are
folded by a divergence-free velocity field, and the result is integrated
front-to-back through seven parallax depth planes inside a glass shell. Your
voice feeds energy into the flow and the projection pressure then lights the gas,
so the orb brightens because it is being stirred rather than because an
amplitude meter turned the palette up. Dragging the window accelerates the shell
while the fluid lags behind it. Connecting, finishing, success and error only
re-tint the same simulation.

Every session rolls a new 32-bit salt, and the shader derives the whole character
of the fluid from it — where the dye sheets lie, how thick they are, which way
they drift, how fast the dye dissipates, and the random swirl the fluid starts
from. No two dictations open the same way.

## Build

```sh
./build-app.sh
open dist/Incant.app
```

The API key is stored in macOS Keychain. Incant needs Microphone permission
and Accessibility permission for text insertion in apps that do not expose a
writable accessibility text selection.

## Handing it to someone else

```sh
./make-dmg.sh
```

`dist/Incant.dmg` holds the app, an Applications folder to drag it onto, and a
note explaining the two permissions and the API key.

Both scripts sign and notarize properly as soon as a Developer ID certificate
exists in the keychain, and fall back to ad-hoc signing when it does not — so
they work either way and say which one happened. Ad-hoc means `spctl --assess`
rejects the app, and every recipient has to right-click it and choose Open, or
approve it under System Settings → Privacy & Security. One time only, but it is
the step that loses non-technical users, and it looks identical to what a
genuinely malicious download asks of them.

Three things have to be done by hand, once, to make it open silently:

1. **Join the Apple Developer Program** — $99/year. There is no free path;
   notarization is not available to free Apple IDs.
2. **Create a Developer ID Application certificate** at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates),
   using a certificate request from Keychain Access → Certificate Assistant, and
   install it. `security find-identity -v -p codesigning` should then list it.
3. **Store notarization credentials** under the profile name the scripts expect,
   using an [app-specific password](https://support.apple.com/102654):

   ```sh
   xcrun notarytool store-credentials incant-notary \
     --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>
   ```

After that `./build-app.sh && ./make-dmg.sh` signs the app with the hardened
runtime and the microphone entitlement, signs the image, submits it, waits, and
staples the ticket so it opens even offline. `notarytool` and `stapler` ship with
the Command Line Tools; Xcode is not needed.

## Rendering the orb animation

`docs/orb.webp` is rendered headlessly, reading the Metal source straight out of
`Sources/Incant/MetalFluidOrbView.swift` and driving it with the same synthetic
voice envelope as the app's own visual preview, so the README cannot drift away
from what ships. The trailing number is the session salt, held fixed here so the
committed animation is reproducible — pass another to shop for a composition:

```sh
swift Resources/make-orb-animation.swift docs/orb.webp 11
```

WebP because its alpha channel stays lossless, which keeps the soft glow and the
antialiased limb at roughly a GIF's file size; it needs `img2webp` from
`brew install webp`. Writing `.png` instead produces an APNG with the same
transparency and no dependencies, at about five times the size, and `.gif` works
but has only one transparent palette index, so the glow disappears and the edge
goes hard.
