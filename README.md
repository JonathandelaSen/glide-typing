# GlideBoard

A floating **glide/swipe typing** keyboard for macOS. Type words by sliding your mouse or trackpad across an on-screen keyboard, much like an Android keyboard. Designed for one-handed typing.

## Build and Run

```sh
./build.sh
open build/GlideBoard.app
```

Requires Xcode Command Line Tools (Swift). On first launch, macOS will request **Accessibility** permission (System Settings → Privacy & Security → Accessibility), which is required for the app to type into other applications.

> The app is signed with a stable self-signed certificate ("GlideBoard Signing" in your login keychain), allowing Accessibility permission to persist across rebuilds. If the certificate is unavailable, `build.sh` falls back to ad-hoc signing, which requires granting permission again after each build. Running `tccutil reset Accessibility com.jon.glideboard` can help clear stale permission state.

## Usage

- Press **⌥⌘G** to show or hide the floating keyboard. You can also use the ⌨︎ menu bar icon.
- The keyboard **does not steal focus**: text is sent to the app where you are currently typing, such as Notes, Safari, or Slack.
- **Glide** across the letters of a word without releasing the button, then release when finished. The best prediction is inserted, with automatic spacing between words. While gliding, the top bar displays the word being formed in real time.
- The **top bar** displays up to four candidates. Click another candidate to replace the word that was just inserted.
- An *italicized* row above the candidates displays **next-word predictions**, updated after every word using a bigram model based on the bundled corpus and your typing history. Your history is stored in `~/Library/Application Support/GlideBoard/`. Click a prediction to insert it; chain clicks together to build complete sentences.
- A **short click** on a key performs a regular key press: letter, space, `.`, `,`, or Return.
- Pressing **⌫** immediately after a glide deletes the entire word. Subsequent presses delete one character at a time.
- Use the **ES/EN** button or menu bar menu to switch languages. Spanish includes `ñ` and approximately 30,000 words; English includes approximately 10,000 words.
- Open **Settings…** from the ⌨︎ menu bar menu to change the show/hide shortcut, default language, and keyboard size (70–160%). Preferences are saved automatically.
- Drag the top handle to move the keyboard. Click **✕** to hide it.

## How It Works

- Uses an `NSPanel` with `.nonactivatingPanel` to float without activating the app.
- Uses **SHARK2-style** gesture recognition: the path is resampled and compared against each candidate word's ideal polyline using position, shape, and word frequency, with first/last-letter pruning.
- Injects text using `CGEvent`, which is why Accessibility permission is required.
- Registers the global shortcut with Carbon `RegisterEventHotKey`, which does not require permission.

## Limitations (v0.1)

- Lowercase only, with no Shift support. Accented characters are inserted as they appear in the selected candidate; the Spanish dictionary includes accented words.
- The word dictionary is fixed and does not learn new words, although next-word predictions do learn from your usage.
