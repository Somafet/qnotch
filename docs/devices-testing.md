# Manual Devices test

The automated suite covers Windows transport peers, native Mac peers, and native Swift/.NET
interoperability in both directions. This checklist covers actual computer-to-computer reachability.
The user chose to run that check later; it has not been reported as passing.

## Run the current build

Windows: quit the old QNotch copy, then launch `dist/QNotch.exe` through Explorer. The executable
is freshly published after Windows changes. `dist/QNotch-before-devices.exe` preserves the
executable that was present before this work.

Mac: from your QNotch checkout, fetch and switch to the feature branch without discarding
local changes, then build and launch:

```sh
git fetch origin
git switch feat/98-local-devices
git pull --ff-only
bash scripts/macos/build.sh
open dist/macos/QNotch.app
```

Quit the previously running Mac copy first. These are development builds, not a public Mac
release; the [Mac guide](macos/README.md) explains Xcode requirements and signing status.

## Pair and share

1. Open Settings, Devices on both computers. Turn on Local sharing. On a LAN, select the
   reachable adapter address. Across networks using Tailscale, select the `100.x.x.x` Tailscale
   address. The other computer must be online in the same tailnet, with ACL/firewall access to
   the listening port (45874 by default).
2. Create an invitation on one computer. Copy it privately to the other and choose Add device.
   Approve the incoming request on the first computer. Check connection should succeed on both.
3. Send text with an emoji, non-ASCII characters and a newline in each direction. Find the
   resulting text files in Downloads/QNotch/Devices and verify the exact content.
4. Right-click a Clipboard text entry and choose Send to device. Verify Devices is prefilled
   and no data transfers before you choose Send. Repeat for a file in Files.
5. Transfer an empty file and a file larger than 64 KiB in both directions. Compare SHA-256
   checksums. Send the same name twice and verify neither received copy replaces the other.
6. Cancel a large transfer and disconnect during another. Partial `.part` files should disappear,
   the original file should remain unchanged, and another transfer should work after reconnecting.
7. Turn off receiving for the selected device. Incoming sends and sync should be refused.
   Restore the permission, restart both apps, and verify the saved pairing works again.
8. Remove the pairing. New requests must fail. Remove the stale row on the other computer
   before pairing again. Turning Local sharing off must close its listener and active transfers.

## Sync

1. Enable Sync notes with this device separately on both computers. If existing notes differ,
   verify that Devices preserves both versions and shows resolution controls. Choose a version.
2. Edit the note on one computer, then the other. Each edit should arrive automatically.
3. Take one device offline, edit both notes independently, then reconnect. Both versions must
   remain available for resolution; neither should silently overwrite the other.
4. Resolve the conflict and clear the note. Restart both apps and reconnect. An older copy must
   not restore the cleared text.
5. Enable Automatically share clipboard text separately on both computers. Copy text on each
   and paste it on the other. Receiving a copy must not repeatedly bounce it between devices.
6. Turn clipboard sync off on either computer and verify new copies stop arriving there.
   Turning note sync off must not stop explicit file or text sends.

Run the pair/share/sync checks for Windows → Mac, Mac → Windows, Windows → Windows and
Mac → Mac when those pairs of computers are available. Record the build commit, OS, connection
type, direction and any failure. Never include invitation codes, pair keys or personal note/
clipboard content in a public report.
