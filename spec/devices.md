# Local devices protocol, version 1

Devices is an independently enabled module with its own Settings page. Networking is off until
the user enables local sharing. There is no cloud service. Version 1 uses reachable IPv4 LAN
addresses (including loopback for tests); guest-network isolation and firewalls can prevent access.

## Trust

An invitation is `qnotch-device:` followed by base64 of UTF-8 JSON with `v:1`, `id`, `name`,
`host`, `port`, `secret` (base64 of 32 random bytes) and `expires` (Unix seconds).
It expires after five minutes. Exchange it privately, outside the network connection.
Treat it as a password, never log it. Generating another invitation revokes the previous one.
Adding it is explicit consent on the joining device; the inviting device must approve the
incoming device's name before trust is stored. Invitations are single-use after approval.
The joining device generates a fresh independent 32-byte permanent pair key. Store that key in
Credential Manager / Keychain, not JSON. Each pairing is independent; unpairing removes the key.

## Wire encoding

One TCP connection per operation. The client sends a length-prefixed UTF-8 JSON hello:
`{"v":1,"id":"<sender UUID>","pair":false,"nonce":"<base64 of 32 fresh random bytes>"}`.
The client nonce prevents a recorded server challenge and acknowledgement from being replayed to
a new client connection. Lengths are unsigned 32-bit big-endian.
Hello is at most 1024 bytes. UUIDs use lowercase hyphenated strings.
The server sends a fresh random 32-byte challenge before authentication.

Derive the connection key as HMAC-SHA256(pair key or invitation secret,
`challenge || SHA256(exact hello bytes) || UTF8("qnotch-devices-v1")`).
Every subsequent frame is length-prefixed `nonce[12] || ciphertext || tag[16]`, using AES-256-GCM.
The encrypted plaintext is at most 65536 bytes. Nonces are independently random.
AAD is `challenge[32] || direction[1] || sequence[8]`, sequence unsigned big-endian,
starting at zero independently in each direction. Direction is 0 for client to server, 1 for
server to client. Wrong keys, replays on another connection, reordered frames and tampering fail
authentication. Close on malformed or unauthenticated input. Connection slots and timeouts are bounded.

JSON uses camelCase keys, UTF-8, no BOM. Unknown versions and operations are rejected.
Request and reply metadata are encrypted. Replies have `ok` and optional `error`, `id`, `name`.

- `pair`: `id`, `name`, `port`, `key` (base64 permanent key). Request id must match hello.
  Host approval stores the peer and returns its id/name. Both devices store the reachable
  remote address with the advertised listening port. No network request accepts a filesystem path.
- `text`: `text` (up to 16000 characters). Save to the receiving inbox; do not automatically
  execute it or put it on the system clipboard. Reply only after receipt is committed.
- `file`: `name`, `size` (0 through 2147483648). Receiver checks permission and replies `ok`.
  Client streams encrypted raw chunks of at most 65536 bytes until exactly `size` bytes have
  arrived. Receiver commits a uniquely named inbox file atomically and replies `ok` again.
  Empty files still get the final acknowledgement. Failures remove partial files.
- `ping`: authenticated connection check, reply `ok`.

File names must be a single portable component: reject empty names, `.`, `..`, path separators,
control characters, Windows reserved names and `<>:"|?*`, and trailing dots/spaces.
Limit names to 180 UTF-8 bytes. Files are received into Downloads/QNotch/Devices, with random
unique prefixes to preserve existing files. Never open received files automatically.

## Scope and validation

Version 1 provides explicit text and file sending. Automatic clipboard propagation, note revisions,
offline queues and deletion reconciliation need a subsequent version; sending is not synchronization.
Shared fixtures in `tests/fixtures/devices/` pin the cryptographic bytes across native implementations.
Native tests must exercise actual sockets, approvals, rejection, truncation, empty and multi-chunk files,
restarts and revoked trust. A Windows loopback test cannot establish macOS execution or LAN reachability.
