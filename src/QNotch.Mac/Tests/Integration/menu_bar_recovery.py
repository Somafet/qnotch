#!/usr/bin/env python3
"""Graphical integration: explicit bundle URL reopen + second-process, isolated data only.

Run after build.sh: python3 src/QNotch.Mac/Tests/Integration/menu_bar_recovery.py
The opt-in debug channel observes the test instances; recovery uses its own endpoint.
No production bundle, defaults, login item, Keychain or enabled module is used.
"""
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[4]
OUTPUT = REPO / "dist/macos/recovery-smoke"
BUNDLE = OUTPUT / "QNotchRecovery.app"
SOURCE = REPO / "dist/macos/QNotch.app"
MODULES = ["media", "stats", "timer", "volume", "search", "note", "colorpicker", "capture",
           "filetray", "clipboard", "notifications", "agents", "weather", "github", "ai", "terminal", "scheduled"]


def until(check, message, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (OSError, ValueError):
            pass
        time.sleep(0.05)
    raise AssertionError(message)


def ask(root, command, **args):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(root / "debug.sock"))
        connection.sendall(json.dumps({"cmd": command, "args": args}).encode() + b"\n")
        response = b""
        while b"\n" not in response:
            chunk = connection.recv(65536)
            assert chunk, "Connection closed without a reply"
            response += chunk
    reply = json.loads(response.split(b"\n")[0])
    assert reply["ok"], reply
    return reply["result"]


def settings_visible(root):
    return any(w["id"] == "settings" and w["visible"] for w in ask(root, "state")["windows"])


def prepare(name):
    root = OUTPUT / name
    root.mkdir(parents=True)
    (root / "general.json").write_text(json.dumps({"showMenuBarIcon": False,
        "onboardingDone": True, "disabledModules": MODULES}))
    (root / "hotkeys.json").write_text(json.dumps({"keys": {"toggle": "", "search": "", "gamemode": ""}}))
    return root


def check_locked(root):
    with (root / "instance.lock").open() as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        raise AssertionError("The live instance released its data-directory lock")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    # Each run has a unique Launch Services identity, so open cannot target a user's normal copy.
    if BUNDLE.exists():
        shutil.rmtree(BUNDLE)
    shutil.copytree(SOURCE, BUNDLE, symlinks=True)
    info_path = BUNDLE / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = "dev.qnotch.mac.recovery-test." + uuid.uuid4().hex
    info_path.write_bytes(plistlib.dumps(info))
    binary = BUNDLE / "Contents/MacOS/QNotch"
    processes = []
    logs = []
    checks = []
    try:
        def launch(name, debug=True):
            root = prepare(name)
            log = (OUTPUT / (name + ".log")).open("w")
            logs.append(log)
            args = [str(binary), "--data-dir", str(root)] + (["--debug-control"] if debug else [])
            process = subprocess.Popen(args, stdout=log, stderr=log)
            processes.append(process)
            if debug:
                until(lambda: ask(root, "ping"), "The isolated instance did not start")
            else:
                until(lambda: (root / "logs/session.log").exists(), "The instance did not become ready")
            return root, process

        a, first = launch("a-" + uuid.uuid4().hex[:6])
        ask(a, "game-mode", mode="on")
        ask(a, "settings", close=True)
        subprocess.run(["open", "-a", str(BUNDLE)], check=True, timeout=10)
        until(lambda: settings_visible(a), "Ordinary app reopen did not open Settings")
        assert ask(a, "state")["game_mode"] == "on" and first.poll() is None
        check_locked(a)
        checks.append("native_app_reopen_with_hidden_icon_forced_game_and_disabled_hotkeys=ok")

        b, other = launch("b-" + uuid.uuid4().hex[:6])
        ask(b, "game-mode", mode="on")
        ask(b, "settings", close=True)
        ask(a, "settings", close=True)
        # A real second executable process must exit after delivering to A, leaving B untouched.
        second = subprocess.run([str(binary), "--data-dir", str(a)], capture_output=True, text=True, timeout=10)
        assert second.returncode == 0, second.stderr
        until(lambda: settings_visible(a), "Second process did not recover Settings in the lock owner")
        assert not settings_visible(b), "Recovery crossed data directories"
        assert first.poll() is None and other.poll() is None
        assert ask(a, "state")["game_mode"] == "on"
        check_locked(a)
        check_locked(b)
        assert not json.loads((a / "general.json").read_text())["showMenuBarIcon"]
        assert json.loads((a / "hotkeys.json").read_text())["keys"] == {"toggle": "", "search": "", "gamemode": ""}
        assert not any(module["running"] for module in ask(a, "state")["modules"])
        checks.append("second_process_recovery_lock_retained_other_data_directory_untouched=ok")

        # Restore via the real Settings switch, then hide again; the saved value follows immediately.
        ask(a, "press", id="show-menu-bar-icon")
        assert json.loads((a / "general.json").read_text())["showMenuBarIcon"]
        ask(a, "press", id="show-menu-bar-icon")
        assert not json.loads((a / "general.json").read_text())["showMenuBarIcon"]
        ask(a, "settings", section="about")
        outline = ask(a, "outline", window="settings")["text"]
        assert "Quit QNotch" in outline and "Unavailable" in outline
        try:
            ask(a, "press", id="quit-qnotch")
        except AssertionError as error:
            # Native termination can close the observing channel before its settled reply.
            assert str(error) == "Connection closed without a reply", str(error)
        assert first.wait(timeout=10) == 0, "Quit from Settings did not terminate cleanly"
        # Relaunch with the same saved hidden choice, without debug control. The only published
        # endpoint is the Settings-only recovery socket used by a second executable process.
        log = (OUTPUT / "relaunch.log").open("w")
        logs.append(log)
        restarted = subprocess.Popen([str(binary), "--data-dir", str(a)], stdout=log, stderr=log)
        processes.append(restarted)
        until(lambda: (a / "instance.lock").exists() and restarted.poll() is None
              and (a / "logs/session.log").stat().st_mtime > (OUTPUT / "relaunch.log").stat().st_mtime,
              "Relaunch did not become ready")
        assert not (a / "debug.sock").exists(), "Recovery enabled the general debug channel"
        result = subprocess.run([str(binary), "--data-dir", str(a)], capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert not (a / "debug.sock").exists()
        assert not json.loads((a / "general.json").read_text())["showMenuBarIcon"]
        check_locked(a)
        checks.append("quit_from_settings_hidden_choice_survives_relaunch_recovery_without_debug=ok")
        checks.append("done")
        (OUTPUT / "recovery.log").write_text("\n".join(checks) + "\n")
        print("\n".join(checks))
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        for log in logs:
            log.close()
        # App termination normally removes these endpoints; SIGTERM in cleanup cannot run AppKit
        # termination callbacks. Remove only endpoints belonging to this run's own lock files.
        for lock in OUTPUT.glob("*/instance.lock"):
            info = lock.stat()
            endpoint = Path(f"/tmp/qnotch-reopen-{os.geteuid()}-{info.st_dev}-{info.st_ino}.sock")
            if endpoint.exists():
                endpoint.unlink()


if __name__ == "__main__":
    main()
