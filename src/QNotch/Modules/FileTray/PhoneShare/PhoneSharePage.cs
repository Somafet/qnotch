namespace QNotch.Modules.FileTray;

/// <summary>
/// The page the phone opens from the QR code. Self-contained (no external requests). All URLs are relative to <c>/s/&lt;token&gt;/</c>.
/// Lists the shared files as download links and sends picked files one at a time as raw PUT bodies, with per-file progress.
/// Text from the server is only ever set with textContent. Plain HTTP rules out a service worker (secure contexts only), so the page
/// itself notices the end: it checks before every download, every 15 s while visible and on return to the tab, and swaps in a message.
/// </summary>
static class PhoneSharePage
{
    public const string Policy = "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; "
        + "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n";

    public const string Html = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>QNotch</title>
<style>
:root{--bg:#f2f2f7;--card:#fff;--text:#1c1c1e;--muted:#6e6e76;--line:#e5e5ea;--accent:#2f6bf0;--ok:#1f9d55;--bad:#d93a3a;--track:#e5e5ea}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--text:#f2f2f7;--muted:#98989f;--line:#2c2c2e;--accent:#5b8cff;--ok:#3cc47c;--bad:#ff6961;--track:#3a3a3c}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0 auto;max-width:560px;font:17px/1.35 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--text);
 padding:calc(14px + env(safe-area-inset-top)) 16px calc(28px + env(safe-area-inset-bottom))}
header{margin:6px 4px 4px}
h1{font-size:28px;margin:0;letter-spacing:-.02em}
#pc{color:var(--muted);font-size:15px;margin-top:2px}
h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);margin:26px 16px 8px}
.card{background:var(--card);border-radius:14px;overflow:hidden}
.row{display:flex;align-items:center;gap:12px;padding:12px 16px;min-height:58px;color:inherit;text-decoration:none;position:relative}
.row+.row{border-top:1px solid var(--line)}
.info{flex:1;min-width:0}
.name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sub{font-size:14px;color:var(--muted);margin-top:1px}
.sub.ok{color:var(--ok)}.sub.bad{color:var(--bad)}
.ico{flex:none;width:30px;height:30px;border-radius:50%;display:grid;place-items:center;background:var(--track);color:var(--accent)}
.ico svg{width:16px;height:16px}
a.row:active{background:var(--line)}
.empty{padding:16px;color:var(--muted);font-size:15px}
.pick{position:relative;display:block;width:100%;padding:15px;border:0;border-radius:14px;background:var(--accent);color:#fff;font:600 17px/1.2 inherit;text-align:center}
.pick input{position:absolute;inset:0;opacity:0;width:100%;height:100%}
.note{font-size:13px;color:var(--muted);margin:8px 16px 0}
.bar{position:absolute;left:16px;right:16px;bottom:6px;height:3px;border-radius:2px;background:var(--track);overflow:hidden}
.bar i{display:block;height:100%;width:0;background:var(--accent);transition:width .2s}
.x{flex:none;border:0;background:none;color:var(--muted);font-size:22px;line-height:1;padding:6px;margin-right:-6px}
#ended{display:none;background:var(--card);border-radius:14px;padding:14px 16px;margin-top:16px;color:var(--bad);font-size:15px}
body.ended #ended{display:block}
body.ended .pick{opacity:.4;pointer-events:none}
body.ended a.row{pointer-events:none;opacity:.5}
</style>
</head>
<body>
<header><h1>QNotch</h1><div id="pc">Connecting...</div></header>
<div id="ended" role="status"></div>
<h2>From your PC</h2>
<div class="card" id="files"><div class="empty">Loading...</div></div>
<h2>To your PC</h2>
<label class="pick">Choose photos or files<input id="input" type="file" multiple></label>
<p class="note">Files are saved in Downloads\QNotch on the PC. Keep this page open until they are sent.</p>
<div class="card" id="sent" style="margin-top:12px"></div>
<script>
"use strict";
const $ = id => document.getElementById(id);
const down = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v9M4 7.5 8 11.5 12 7.5M3 14h10"/></svg>';
const up = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V4M4 7.5 8 3.5 12 7.5M3 14h10" transform="translate(0 -1)"/></svg>';
function size(b) {
  if (b < 0) return "Missing on the PC";
  if (b >= 1073741824) return (b / 1073741824).toFixed(1) + " GB";
  if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB";
  if (b >= 1024) return Math.round(b / 1024) + " KB";
  return b + " B";
}
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
function row(tag, icon, name, sub) {
  const r = el(tag, "row"), i = el("div", "ico"), info = el("div", "info");
  i.innerHTML = icon;
  const n = el("div", "name", name), s = el("div", "sub", sub);
  info.append(n, s); r.append(i, info);
  r.sub = s;
  return r;
}
let ended = false, gone = false, listed = "";
function end(why) {
  ended = true;
  if (why === "gone") gone = true; // this code is dead for good: stop asking
  $("ended").textContent = why !== "unreachable"
    ? "Sharing has ended on the PC. To continue, start sharing again in QNotch and scan the new code."
    : "Can't reach the PC. Check that this phone is on the same Wi-Fi and the PC is awake. This page reconnects by itself.";
  document.body.classList.add("ended");
}

// "ok" with the list; "gone": the PC says this session is over; "closed": refused at once, so the PC is there but stopped
// listening (or this phone just went offline, so keep checking); "unreachable": no answer within a few seconds.
async function ask(ms) {
  const c = new AbortController(), t = setTimeout(() => c.abort(), ms), t0 = Date.now();
  try {
    const r = await fetch("api/files", { cache: "no-store", signal: c.signal });
    if (r.status === 410 || r.status === 404) return { state: "gone" };
    if (!r.ok) return { state: "unreachable" };
    return { state: "ok", list: await r.json() };
  } catch { return { state: !c.signal.aborted && Date.now() - t0 < 2500 ? "closed" : "unreachable" }; }
  finally { clearTimeout(t); }
}

async function load(ms = 6000) {
  if (gone) return false;
  const a = await ask(ms);
  if (a.state !== "ok") { end(a.state); return false; }
  ended = false; document.body.classList.remove("ended");
  const j = a.list, key = JSON.stringify(j.files) + j.pc;
  if (key === listed) return true; // unchanged: no re-render
  listed = key;
  $("pc").textContent = "Connected to " + j.pc;
  const box = $("files");
  box.replaceChildren();
  if (!j.files.length) { box.append(el("div", "empty", "Nothing shared from the PC. You can still send files to it.")); return true; }
  for (const f of j.files) {
    const a = row("a", down, f.name, size(f.size));
    if (f.size >= 0) { a.href = "d/" + encodeURIComponent(f.id); a.setAttribute("download", f.name); }
    box.append(a);
  }
  return true;
}

// A link to a stopped session would leave this page for the browser's error page: ask first, then download.
$("files").addEventListener("click", async e => {
  const a = e.target.closest("a[href]");
  if (!a) return;
  e.preventDefault();
  const href = a.href;
  if (await load(4000)) location.href = href;
});

const queue = [];
let busy = false;
$("input").addEventListener("change", e => {
  for (const f of e.target.files) {
    const r = row("div", up, f.name, "Waiting, " + size(f.size));
    const bar = el("div", "bar"), fill = el("i");
    bar.append(fill); r.append(bar);
    const x = el("button", "x", "×");
    x.setAttribute("aria-label", "Cancel");
    r.append(x);
    const item = { f, r, fill, x, xhr: null, cancelled: false };
    x.onclick = () => { item.cancelled = true; if (item.xhr) item.xhr.abort(); else finish(item, "Cancelled", "bad"); };
    $("sent").prepend(r);
    queue.push(item);
  }
  e.target.value = "";
  pump();
});
function finish(item, text, cls) {
  item.r.sub.textContent = text; item.r.sub.className = "sub " + (cls || "");
  item.x.remove(); item.fill.parentNode.remove();
}
function pump() {
  if (busy) return;
  const item = queue.shift();
  if (!item) return;
  if (item.cancelled) { pump(); return; }
  if (ended) { finish(item, "Not sent: the PC is not sharing", "bad"); pump(); return; }
  busy = true;
  const x = item.xhr = new XMLHttpRequest();
  x.open("PUT", "u?name=" + encodeURIComponent(item.f.name));
  x.upload.onprogress = e => {
    if (!e.lengthComputable) return;
    const p = Math.floor(e.loaded * 100 / Math.max(1, e.total));
    item.fill.style.width = p + "%";
    item.r.sub.textContent = p + "% of " + size(item.f.size);
  };
  const next = () => { busy = false; pump(); };
  x.onload = () => {
    if (x.status === 201) {
      let saved = item.f.name;
      try { saved = JSON.parse(x.responseText).name; } catch {}
      finish(item, saved === item.f.name ? "Sent" : "Sent as " + saved, "ok");
    } else {
      if (x.status === 410 || x.status === 404) end("gone");
      finish(item, "Failed: " + (x.responseText || x.status), "bad");
    }
    next();
  };
  x.onabort = () => { finish(item, "Cancelled", "bad"); next(); };
  x.onerror = () => { finish(item, "Failed: connection lost", "bad"); load(); next(); };
  x.send(item.f);
}
document.addEventListener("visibilitychange", () => { if (!document.hidden) load(); });
window.addEventListener("pageshow", e => { if (e.persisted) load(); }); // restored from the back-forward cache
// While visible and not uploading (an upload already reports a lost connection). Hidden tabs are skipped.
setInterval(() => { if (!document.hidden && !busy) load(); }, 15000);
load();
</script>
</body>
</html>
""";
}
