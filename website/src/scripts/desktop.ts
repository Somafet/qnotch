import { svg, type IconName } from '../icons';

/* The fake Windows around the notch: windows, taskbar, Start, calendar, tray menu, files. */

export type WinId = 'term' | 'browser' | 'files' | 'music';
export type GameSetting = 'auto' | 'on' | 'off';
export interface FileItem { name: string; size: number; kind: 'image' | 'doc' | 'zip' | 'code'; art?: string; file?: File }
export interface Media { title: string; artist: string; art: string; pos: number; len: number; playing: boolean; track: number; tracks: { title: string; artist: string; len: number }[] }

export const FILES: FileItem[] = [
  { name: 'screenshot-0927.png', size: 482_113, kind: 'image', art: 'linear-gradient(135deg,#5b9dff,#7a5cff 60%,#ff6aa2)' },
  { name: 'invoice-0925.pdf', size: 88_402, kind: 'doc' },
  { name: 'release-notes.md', size: 4_210, kind: 'code' },
  { name: 'wallpaper-bloom.jpg', size: 2_310_442, kind: 'image', art: 'linear-gradient(180deg,#0a1128,#18307a 60%,#8ec0ff)' },
  { name: 'build-artifacts.zip', size: 12_840_221, kind: 'zip' },
];

export const fmtSize = (b: number) => (b < 1024 ? `${b} B` : b < 1048576 ? `${Math.round(b / 1024)} KB` : `${(b / 1048576).toFixed(1)} MB`);
export const kindOf = (name: string): FileItem['kind'] =>
  /\.(png|jpe?g|gif|webp|svg|bmp|avif)$/i.test(name) ? 'image' : /\.(zip|7z|rar|gz|tar)$/i.test(name) ? 'zip' : /\.(md|ts|js|cs|json|txt|ps1|py|html|css)$/i.test(name) ? 'code' : 'doc';
export const fileIcon = (k: FileItem['kind']): IconName => ({ image: 'image', doc: 'file', zip: 'folder', code: 'code' } as const)[k];
const esc = (t: string) => t.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const mmss = (sec: number) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`;

// Drag and drop between the fake Explorer, the notch's file tray and the browser. Real files from the OS work too.
const MIME = 'application/x-qnotch-file';
export function setDrag(e: DragEvent, f: FileItem) {
  e.dataTransfer!.setData(MIME, JSON.stringify({ name: f.name, size: f.size, kind: f.kind, art: f.art }));
  e.dataTransfer!.setData('text/plain', f.name);
  e.dataTransfer!.effectAllowed = 'copy';
}
export const isFileDrag = (e: DragEvent) => !!e.dataTransfer && [...e.dataTransfer.types].some(t => t === MIME || t === 'Files');
export function readDrop(e: DragEvent): FileItem[] {
  const raw = e.dataTransfer?.getData(MIME);
  if (raw) return [JSON.parse(raw)];
  return [...(e.dataTransfer?.files ?? [])].map(f => ({ name: f.name, size: f.size, kind: kindOf(f.name), file: f }));
}

/** Assign markup only when it changed, so buttons are not rebuilt under the pointer. */
export const put = (el: HTMLElement, html: string) => { if (el.dataset.html !== html) { el.dataset.html = html; el.innerHTML = html; } };

interface Hooks {
  scale(): number;
  launchQNotch(): void;
  quitQNotch(): void;
  running(): boolean;
  game(): GameSetting;
  setGame(g: GameSetting): void;
  openPanel(): void;
  sound(on?: boolean): boolean;
  toTray(f: FileItem): void;
  focusChanged(): void;
}

export function initDesktop(stage: HTMLElement, hooks: Hooks) {
  const q = <T extends HTMLElement = HTMLElement>(sel: string) => stage.querySelector(sel) as T;
  const wins = new Map<WinId, HTMLElement>();
  stage.querySelectorAll<HTMLElement>('[data-win]').forEach(w => wins.set(w.dataset.win as WinId, w));
  let z = 10;
  let active: WinId | null = 'term';

  /* ---------- windows ---------- */
  const isOpen = (id: WinId) => !wins.get(id)!.classList.contains('closed');
  const isMin = (id: WinId) => wins.get(id)!.classList.contains('min');

  function focus(id: WinId) {
    const w = wins.get(id)!;
    w.style.zIndex = String(++z);
    active = id;
    syncTaskbar();
    hooks.focusChanged();
  }
  function show(id: WinId) {
    wins.get(id)!.classList.remove('closed', 'min');
    focus(id);
  }
  function hide(id: WinId, how: 'min' | 'closed') {
    wins.get(id)!.classList.add(how);
    if (active === id) active = null;
    syncTaskbar();
    hooks.focusChanged();
  }
  function syncTaskbar() {
    stage.querySelectorAll<HTMLElement>('[data-act="launch"]').forEach(b => {
      const id = b.dataset.arg as WinId;
      if (!wins.has(id)) return;
      if (!b.closest('.qn-tb-apps')) return;
      b.classList.toggle('run', isOpen(id));
      b.classList.toggle('on', isOpen(id) && !isMin(id) && active === id);
    });
    wins.forEach((w, id) => w.classList.toggle('active', id === active));
  }
  function launch(id: WinId) {
    if (!isOpen(id) || isMin(id)) show(id);
    else if (active === id) hide(id, 'min');
    else focus(id);
  }

  // Drag a window by its title bar; double-click maximizes.
  stage.addEventListener('pointerdown', e => {
    const t = e.target as HTMLElement;
    const w = t.closest<HTMLElement>('[data-win]');
    if (w) focus(w.dataset.win as WinId);
    const bar = t.closest<HTMLElement>('[data-drag]');
    if (!w || !bar || t.closest('button') || w.classList.contains('max') || e.button !== 0) return;
    const s = hooks.scale(), x0 = e.clientX, y0 = e.clientY, l0 = w.offsetLeft, t0 = w.offsetTop;
    const W = stage.offsetWidth, H = stage.offsetHeight;
    bar.setPointerCapture(e.pointerId);
    const move = (ev: PointerEvent) => {
      w.style.left = `${Math.min(W - 80, Math.max(80 - w.offsetWidth, l0 + (ev.clientX - x0) / s))}px`;
      w.style.top = `${Math.min(H - 90, Math.max(0, t0 + (ev.clientY - y0) / s))}px`;
    };
    const up = () => { bar.removeEventListener('pointermove', move); bar.removeEventListener('pointerup', up); };
    bar.addEventListener('pointermove', move);
    bar.addEventListener('pointerup', up);
  });
  stage.addEventListener('dblclick', e => {
    const t = e.target as HTMLElement;
    if (t.closest('[data-drag]') && !t.closest('button')) t.closest('[data-win]')?.classList.toggle('max');
    const row = t.closest<HTMLElement>('[data-file]');
    if (row) preview(Number(row.dataset.file));
  });

  /** Windows go back to their default places when the desktop changes size. */
  function reset() {
    wins.forEach(w => { w.style.left = ''; w.style.top = ''; w.classList.remove('max'); });
  }

  /* ---------- flyouts: Start, calendar, tray menu ---------- */
  let fly: string | null = null;
  function toggleFly(name: string | null) {
    fly = fly === name ? null : name;
    stage.querySelectorAll<HTMLElement>('[data-fly]').forEach(f => f.classList.toggle('show', f.dataset.fly === fly));
    if (fly === 'cal') renderCal();
    if (fly === 'tray') renderTray();
  }

  q('[data-fly="start"]').innerHTML = `
    <div class="fl-h">Pinned</div>
    <div class="st-grid">
      ${([['term', 'terminal', 'Terminal'], ['browser', 'globe', 'Browser'], ['files', 'folder', 'File Explorer'], ['music', 'music', 'Music'], ['qnotch', 'pill', 'QNotch']] as [string, IconName, string][])
        .map(([id, icon, label]) => `<button class="st-app" data-act="launch" data-arg="${id}"><span class="st-ico ${id}">${svg(icon)}</span>${label}</button>`).join('')}
    </div>
    <div class="st-foot"><span class="qn-avatar sm">A</span><b>Alex</b><button class="qn-icon" data-act="sleep" title="Sleep" aria-label="Sleep">${svg('power')}</button></div>`;

  let calOffset = 0;
  function renderCal() {
    const now = new Date();
    const m = new Date(now.getFullYear(), now.getMonth() + calOffset, 1);
    const lead = (m.getDay() + 6) % 7;
    const days = new Date(m.getFullYear(), m.getMonth() + 1, 0).getDate();
    const cells = [...Array(lead).fill(''), ...Array.from({ length: days }, (_, i) => i + 1)];
    const today = (d: number) => calOffset === 0 && d === now.getDate();
    q('[data-fly="cal"]').innerHTML = `
      <div class="cal-top"><b>${now.toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' })}</b></div>
      <div class="cal-head"><b>${m.toLocaleDateString('en-US', { month: 'long', year: 'numeric' })}</b>
        <button class="qn-icon" data-act="calNav" data-arg="-1" title="Previous month" aria-label="Previous month">${svg('up')}</button>
        <button class="qn-icon" data-act="calNav" data-arg="1" title="Next month" aria-label="Next month">${svg('down')}</button></div>
      <div class="cal-grid">${['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'].map(d => `<i>${d}</i>`).join('')}
        ${cells.map(d => `<span class="${d && today(d as number) ? 'today' : ''}">${d}</span>`).join('')}</div>`;
  }

  function renderTray() {
    const g = hooks.game();
    const opt = (id: GameSetting, label: string) =>
      `<button class="fl-item" data-act="gameSet" data-arg="${id}">${g === id ? svg('check', 'i acc') : '<i class="i"></i>'}${label}</button>`;
    q('[data-fly="tray"]').innerHTML = `
      <button class="fl-item" data-act="trayOpen"><i class="i"></i>Open QNotch<small>Ctrl+Alt+N</small></button>
      <div class="fl-sep"></div>
      <div class="fl-h">Game mode</div>
      ${opt('auto', 'Auto')}${opt('on', 'On')}${opt('off', 'Off')}
      <div class="fl-sep"></div>
      <button class="fl-item" data-act="quit"><i class="i"></i>Quit QNotch</button>`;
  }

  /* ---------- File Explorer ---------- */
  const filesList = q('[data-files]');
  filesList.innerHTML = FILES.map((f, i) => `
    <div class="fx-row" draggable="true" data-file="${i}" title="Drag it onto the notch">
      ${f.art ? `<span class="fx-thumb" style="background:${f.art}"></span>` : `<span class="fx-ico">${svg(fileIcon(f.kind))}</span>`}
      <span class="fx-name">${f.name}</span><span class="fx-size">${fmtSize(f.size)}</span>
    </div>`).join('');
  filesList.addEventListener('dragstart', e => {
    const row = (e.target as HTMLElement).closest<HTMLElement>('[data-file]');
    if (row) setDrag(e, FILES[Number(row.dataset.file)]);
  });
  // Touch screens have no drag and drop here, so a tap sends the file to the notch.
  filesList.addEventListener('click', e => {
    const row = (e.target as HTMLElement).closest<HTMLElement>('[data-file]');
    if (row && matchMedia('(hover: none)').matches) hooks.toTray(FILES[Number(row.dataset.file)]);
  });

  function preview(i: number) {
    const f = FILES[i];
    const p = q('[data-preview]');
    p.innerHTML = `
      <div class="fx-prev-img" style="${f.art ? `background:${f.art}` : ''}">${f.art ? '' : svg(fileIcon(f.kind))}</div>
      <b>${f.name}</b><small>${fmtSize(f.size)}</small>
      <button class="qn-btn" data-act="closePreview">Close</button>`;
    p.classList.add('show');
  }
  function flashFile(name: string) {
    show('files');
    const i = FILES.findIndex(f => f.name === name);
    const row = filesList.querySelector<HTMLElement>(`[data-file="${i}"]`);
    if (!row) return;
    row.classList.remove('flash');
    void row.offsetWidth;
    row.classList.add('flash');
  }

  /* ---------- Browser: an upload page that takes drops and the file picker ---------- */
  const drop = q('[data-upload]');
  const picker = q<HTMLInputElement>('[data-picker]');
  const got: FileItem[] = [];
  function received(files: FileItem[]) {
    got.unshift(...files);
    q('[data-received]').innerHTML = got.slice(0, 4).map(f => `<div>${svg('check', 'i ok')}<b>${esc(f.name)}</b><span>${fmtSize(f.size)}</span></div>`).join('');
  }
  drop.addEventListener('dragover', e => { if (isFileDrag(e)) { e.preventDefault(); drop.classList.add('over'); } });
  drop.addEventListener('dragleave', () => drop.classList.remove('over'));
  drop.addEventListener('drop', e => { e.preventDefault(); drop.classList.remove('over'); received(readDrop(e)); });
  picker.addEventListener('change', () => { received([...(picker.files ?? [])].map(f => ({ name: f.name, size: f.size, kind: kindOf(f.name), file: f }))); picker.value = ''; });

  /* ---------- Music ---------- */
  function renderMusic(m: Media) {
    put(q('[data-music]'), `
      <div class="mu-top"><div class="mu-art" style="background:${m.art}"></div>
        <div><b>${esc(m.title)}</b><span>${esc(m.artist)}</span></div></div>
      <div class="mu-seek" data-act="seek" title="Seek"><i style="width:${(m.pos / m.len) * 100}%"></i></div>
      <div class="mu-times"><span>${mmss(m.pos)}</span><span>${mmss(m.len)}</span></div>
      <div class="mu-ctl">
        <button class="qn-icon" data-act="prev" title="Previous" aria-label="Previous">${svg('prev')}</button>
        <button class="qn-play" data-act="play" title="Play or pause" aria-label="Play or pause">${svg(m.playing ? 'pause' : 'play')}</button>
        <button class="qn-icon" data-act="next" title="Next" aria-label="Next">${svg('next')}</button>
      </div>
      <div class="mu-list">${m.tracks.map((t, i) => `<button class="${i === m.track ? 'on' : ''}" data-act="track" data-arg="${i}">
        <span>${i === m.track && m.playing ? svg('volume', 'i acc') : i + 1}</span><b>${esc(t.title)}</b><small>${esc(t.artist)}</small><em>${mmss(t.len)}</em></button>`).join('')}</div>`);
  }

  /* ---------- clicks ---------- */
  stage.addEventListener('click', e => {
    const t = e.target as HTMLElement;
    const btn = t.closest<HTMLElement>('[data-act]');
    const arg = btn?.dataset.arg ?? '';
    if (!t.closest('[data-fly], [data-act="start"], [data-act="cal"], [data-act="trayMenu"]')) toggleFly(null);
    switch (btn?.dataset.act) {
      case 'start': toggleFly('start'); return;
      case 'cal': calOffset = 0; toggleFly('cal'); return;
      case 'calNav': calOffset += Number(arg); renderCal(); return;
      case 'trayMenu': toggleFly('tray'); return;
      case 'trayOpen': toggleFly(null); hooks.openPanel(); return;
      case 'gameSet': hooks.setGame(arg as GameSetting); renderTray(); return;
      case 'quit': toggleFly(null); hooks.quitQNotch(); return;
      case 'launch':
        toggleFly(null);
        if (arg === 'qnotch') hooks.launchQNotch();
        else launch(arg as WinId);
        return;
      case 'win': {
        const id = btn!.closest<HTMLElement>('[data-win]')!.dataset.win as WinId;
        if (arg === 'max') wins.get(id)!.classList.toggle('max');
        else hide(id, arg as 'min' | 'closed');
        return;
      }
      case 'sleep': toggleFly(null); q('[data-sleep]').classList.add('show'); return;
      case 'wake': q('[data-sleep]').classList.remove('show'); return;
      case 'upload': picker.click(); return;
      case 'closePreview': q('[data-preview]').classList.remove('show'); return;
      case 'sound': {
        const on = hooks.sound(!hooks.sound());
        btn!.classList.toggle('off', !on);
        btn!.title = on ? 'Sound on' : 'Sound off';
        return;
      }
    }
  });

  function syncTray() {
    q('[data-act="trayMenu"]').hidden = !hooks.running();
  }

  syncTaskbar();
  return { active: () => active, show, focus, launch, isOpen, reset, renderMusic, flashFile, syncTray, closeFlyouts: () => toggleFly(null) };
}
