# Sharing with devices

Settings, **Devices** shares text and files directly between QNotch computers. Native Windows
and macOS implementations use a common [versioned protocol](../spec/devices.md).

## Connect two computers

1. Enable **Local sharing** in Settings, Devices on both computers. Enable the Devices feature
   in Settings, Features if the page is missing.
2. On the first computer, choose its reachable IPv4 address and select **Create invitation**.
3. Send the invitation privately to the second computer. It is a temporary password: do not
   post it publicly. It expires after five minutes and is single-use.
4. Paste it into the second computer's Devices page and choose **Add device**.
5. Approve the incoming device on the first computer. Only approve requests you initiated.

Pair keys live in Windows Credential Manager or macOS Keychain. Settings store names,
addresses and preferences, not keys. Pairings are excluded from setup codes.

## Send and receive

Choose a paired device, then **Send text** or **Send file**. Items arrive in
`Downloads/QNotch/Devices`. **Show in folder** locates received items. Text is saved as a text
file; nothing is executed, opened or copied to the clipboard automatically. Unique file name
prefixes preserve existing files.

Receiving controls refuse new transfers from a peer. **Remove device** revokes trust and ends
active connections; remove it on both computers to clear both lists. **Cancel** ends the current
outgoing transfer. Turning sharing off closes the listener and active transfers.

Files are limited to 2 GiB, with a two-minute connection deadline. Interrupted partial files are
removed. A completed receipt followed by a lost acknowledgement can produce a duplicate when
retried; this version does not promise exactly-once delivery.

## Reachability

Computers must be reachable over the local network or Tailscale. Ethernet and Wi-Fi can be mixed. Allow
QNotch's listening port (45874 by default) for private networks in your firewall. macOS may also
ask for local-network permission. Guest Wi-Fi often isolates devices. This version supports
private/link-local IPv4 addresses and Tailscale IPv4 addresses, with manual pairing; it does not discover peers, relay over
the internet, or support IPv6-only networks. Change the listening port while sharing is off if
another app uses it.

**Check connection** tests the authenticated connection. Saved addresses are fixed; if DHCP
changes an address, remove that pairing and add it again.

## Optional synchronization

Select a paired device and enable **Sync notes with this device** or **Automatically share
clipboard text** separately on both computers. These switches start off. Clipboard sync shares
future captured text and can include sensitive content. Synced clipboard text stays in memory;
the disk journal stores only its replay-prevention stamp. Images are not synchronized.

Notes keep local edits while the other computer is offline and retry when it reconnects.
Concurrent edits preserve both versions: inspect them in Devices and choose **Use version**
to resolve the conflict. Clearing a note is synchronized as an edit, so replaying an older note
does not restore its text. A mismatch between the note file and sync journal after restart is
also preserved for resolution. Corrupt journals pause sync without replacing the files.

Sync supports notes up to 100000 UTF-16 code units, eight concurrent versions and 64 causal
authors. Resolve current conflicts before adding more versions. Disabling incoming transfers
from a device also stops synchronization with it. Turning local sharing off keeps pending note
edits locally until sharing is enabled again.

## Checks

Run `dotnet run --project tests/QNotch.DeviceTests -c Release` on Windows or macOS to test
the exact transport compiled into Windows. Native Mac tests cover shared cryptographic fixtures
and actual Mac-to-Mac sockets. For native Swift/.NET interoperability, build that .NET project
and set `QNOTCH_DEVICE_TEST_DLL` to its absolute `bin/Release/net10.0/QNotch.DeviceTests.dll`
path before `bash scripts/macos/test.sh`. CI sets this automatically. Loopback compatibility
does not establish firewall permissions or physical Windows/Mac LAN reachability.
