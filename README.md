<h1 align="center">Incant</h1>

<p align="center">
  <img src="docs/orb.webp" width="300" alt="The Incant orb: luminous dye folding through a dark glass sphere">
</p>

<p align="center">
  <em>A tiny native macOS push-to-dictate app using OpenAI Realtime transcription.</em>
</p>

Press **Command-Shift-Space** to start recording. Press it again to commit the
audio and stop. In Direct mode, transcript deltas are inserted continuously at
the focused cursor while you speak. Incantation mode does that too, then uses the
complete delivery to refine those words with audible emphasis after you stop.

The **Incantation mode** setting has two choices. **Direct** uses `gpt-live-transcribe`
and streams a literal transcript while you speak. **Incantation** also streams a
live draft, then asks `gpt-realtime-2.1` for text only and replaces that draft
with punctuation and restrained Markdown emphasis informed by the full audio.
Its instructions
forbid answers, paraphrase, commentary and invented emotion: it is still a
transcription mode, just one allowed to hear how the words were delivered.

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

It also answers the room, quietly. Swinging the MacBook lid throws the fluid up or
down the inside of the sphere: the hinge has an angle sensor, reachable as an
ordinary HID device that reports whenever it moves. Nothing has to be granted for
it, and nothing tells you it is there.

## Build

```sh
./build-app.sh
cp -R dist/Incant.app /Applications/
open /Applications/Incant.app
```

Install it rather than running it out of `dist/`. Both are complete apps carrying
the same bundle identifier, and macOS records Accessibility approval per app — so
two copies split the approval in two, and granting it to one leaves the other
running untrusted with a switch that appears to do nothing. Ad-hoc signing makes
this worse: every rebuild is a new code identity, so approval has to be granted
again. Allow, in the settings row, clears the record before it asks, which is what
gets a state that will not budge to budge; `tccutil reset Accessibility
com.bjarni.Incant` is the same move from a terminal.

The API key is stored in macOS Keychain. Incant needs Microphone permission
and Accessibility permission for text insertion in apps that do not expose a
writable accessibility text selection.

## Handing it to someone else

```sh
./make-dmg.sh
```

`dist/Incant.dmg` holds the app, an Applications folder to drag it onto, and a
note explaining the two permissions and the API key.

It also explains Gatekeeper, because this build is **ad-hoc signed** and
`spctl --assess` rejects it. On any Mac but the one that built it, macOS will
refuse to open the app until the recipient right-clicks it and chooses Open, or
approves it under System Settings → Privacy & Security. That is a one-time step,
but it is exactly the kind of step that loses non-technical users, and it looks
identical to what a genuinely malicious download would ask of them.

Removing it takes a paid Apple Developer account: sign with a Developer ID
Application certificate, enable the hardened runtime with the
`com.apple.security.device.audio-input` entitlement for the microphone, submit
the image to `notarytool`, and staple the ticket to it. Then the DMG opens with
no warning at all. Nothing else about the app has to change.

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
