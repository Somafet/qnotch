# Notifications reference

Any app, script or agent can post a notification to QNotch. It shows as a toast under the pill, adds to the unread count, and stays in the Notifications tab. Settings, Notifications has the toast time, how long history is kept, per-app mute and the HTTP token.

## Command line

```powershell
QNotch.exe notify "Build finished" "142 tests passed" --app Build --level success --url https://example.com/report
QNotch.exe notify "Claude needs you" --app "Claude Code" --icon chat --focus       # button back to the calling terminal
QNotch.exe notify "Run the tests?" --action approve=Approve --action deny=Deny     # waits, prints the clicked id
QNotch.exe notify --help
```

Exit codes: 0 sent or answered, 1 dismissed, 2 timed out, 3 QNotch not running, 4 error.

`QNotch.exe` is a GUI program, so an interactive shell does not wait for it. Capture the output when you need the answer: `$answer = QNotch.exe notify ...`. Scripts and hooks that capture output wait as usual.

## Three ways in

All three take the same JSON payload.

| Way | How | Who can use it |
| --- | --- | --- |
| Command line | `QNotch.exe notify`, or `--json` / `--stdin` for a raw payload | anything that can start a program |
| Named pipe | `\\.\pipe\QNotch.Notify`: write one line of JSON, read one line back | programs running as your Windows user |
| HTTP | `POST http://127.0.0.1:47821/notify` (`?wait=1` to wait), `DELETE /notify/{id}` | this computer, with `Authorization: Bearer <token>` |

```bash
curl -X POST http://127.0.0.1:47821/notify -H "Authorization: Bearer <token>" -d '{"title":"Deploy done","app":"CI","level":"success"}'
```

Copy the token from Settings, Notifications. Requests from web pages (with an `Origin` header) are refused.

## Payload

Only `title` is required.

```json
{
  "id": "build-42",
  "app": "Build",
  "title": "Build finished",
  "body": "142 tests passed",
  "icon": "C:\\tools\\build.png",
  "level": "success",
  "ttl": 8,
  "wait": false,
  "timeout": 0,
  "actions": [
    { "label": "Open report", "url": "https://example.com/report" },
    { "label": "Show", "focusPid": 1234 },
    { "id": "approve", "label": "Approve" }
  ]
}
```

- `id`: posting the same id again replaces the notification, for progress updates. `{"op":"dismiss","id":"build-42"}` removes it.
- `icon`: an image, an exe or shortcut (its icon is used), or one of: bell, info, check, warning, error, chat, code, link, clock, download, bolt, person, folder, globe, mail, play, build. Local paths only.
- `level`: info, success, warning or error. An error opens the panel, except in Game mode. You can turn that off.
- `ttl`: how many seconds the toast shows. 0 means no toast.
- `actions`: up to three buttons.
  - `url` opens a link (http, https, vscode, vscode-insiders, cursor, claude).
  - `focusPid` brings that process's window forward, or its nearest parent's window (a script's terminal).
  - With neither, the button only answers a waiting request. No action can run a program.
- `wait`: keep the request open until the user clicks a button or dismisses it. The answer looks like `{"ok":true,"id":"...","result":"clicked","action":"approve"}`, where `result` is `clicked`, `dismissed` or `timeout`.
- `timeout`: seconds to wait, 0 for no limit. In Game mode a waiting request is held until the game ends.

Limits: titles 80 characters, bodies 300, messages 64 KB. Each app gets one toast per second; the rest go straight to history.

## Claude Code hook

To see every session live instead, connect Claude Code in Settings, Agents. For a toast with a button back to the session whenever Claude waits for you, add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "C:\\path\\to\\QNotch.exe notify \"Claude needs you\" --app \"Claude Code\" --icon chat --focus" }] }
    ]
  }
}
```
