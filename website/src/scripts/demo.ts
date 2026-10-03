import { svg, type IconName } from '../icons';
import { initDesktop, put, fmtSize, fileIcon, setDrag, isFileDrag, readDrop, FILES, type FileItem, type GameSetting } from './desktop';

type Mode = 'collapsed' | 'open' | 'game';
type OpenedBy = 'hover' | 'scenario' | 'keys';
type Tab = 'home' | 'search' | 'clipboard' | 'agents' | 'files' | 'notifications';
type Tone = 'accent' | 'warn' | 'ok' | 'danger';
type Scenario = 'open' | 'agent' | 'notify' | 'files' | 'clipboard' | 'search' | 'game';

interface Clip { id: number; kind: 'link' | 'code' | 'image' | 'text' | 'color'; text: string; at: number; pinned?: boolean }
interface Agent { id: string; status: 'working' | 'needs' | 'done'; since: number; procs?: [string, string, string][]; cost: string; tokens: string; expanded?: boolean }
interface Action { id: string; label: string; url?: string; focus?: boolean }
interface Note { id: number; title: string; body: string; app: string; at: number; icon: IconName; tone: Tone; actions?: Action[]; answered?: string; answerVar?: string }
interface TrayFile extends FileItem { id: number; at: number }

const TRACKS = [
  { title: 'Midnight City', artist: 'M83', len: 243, art: 'linear-gradient(140deg,#ff6aa2,#8a5cff 50%,#1e2a6e)' },
  { title: 'Teardrop', artist: 'Massive Attack', len: 330, art: 'linear-gradient(140deg,#e9c46a,#7a4e1d 60%,#24160a)' },
  { title: 'Intro', artist: 'The xx', len: 127, art: 'linear-gradient(140deg,#f2f2f2,#9b9b9b 55%,#3a3a3a)' },
];

const TABS: [Tab, IconName, string][] = [
  ['home', 'home', 'Home'],
  ['search', 'search', 'Search'],
  ['clipboard', 'copy', 'Clipboard'],
  ['agents', 'terminal', 'Agents'],
  ['files', 'folder', 'Files'],
  ['notifications', 'bell', 'Notifications'],
];

const SETTINGS = ['General', 'Features', 'Hotkeys', 'Appearance', 'Game mode', 'Clipboard', 'AI', 'GitHub', 'Notifications'];
const NOTE_TEXT = 'Deploy checklist: tag, release notes, then the game bar screenshots.';
const PS = `<span class="t-acc">PS C:\\code\\api&gt;</span> `;
const LEVELS: Record<string, [IconName, Tone]> = { success: ['check', 'ok'], error: ['xcircle', 'danger'], warning: ['bolt', 'warn'], info: ['bell', 'accent'] };

const touch = typeof matchMedia === 'function' && !matchMedia('(hover: hover)').matches;
const CAPTIONS: Record<Scenario | 'idle', string> = {
  idle: touch ? 'It is live, and every button works. Tap the pill, or pick a moment below.' : 'It is live, and every button works. Hover the pill, or pick a moment below.',
  open: touch ? 'Tap the pill and it opens. Tap outside and it tucks back in.' : 'Hover the pill and it opens. Move away and it tucks back in.',
  agent: 'Claude stops to ask. The pill widens and chimes, whatever app you are in.',
  notify: 'Any script can post to the notch, with buttons, and wait for your answer. Type your own in the pwsh tab.',
  files: touch ? 'Tap a file in Downloads to drop it on the notch. It stays within reach on the Files tab.' : 'Drag a file from Downloads onto the pill. The notch keeps it within reach on the Files tab.',
  clipboard: 'Copy any text on this page and it lands here. Click an entry to copy it again.',
  search: 'One box searches your clipboard, notifications, notes, tabs and settings.',
  game: 'A game goes fullscreen and the notch shrinks to one quiet line. Esc quits the game.',
};

const esc = (t: string) => t.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
const mmss = (sec: number) => `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`;
const ago = (ms: number) => {
  const m = Math.floor((Date.now() - ms) / 60000);
  return m < 1 ? 'just now' : m < 60 ? `${m}m ago` : `${Math.floor(m / 60)}h ago`;
};
const dur = (ms: number) => {
  const m = Math.max(1, Math.floor((Date.now() - ms) / 60000));
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
};
const clock = () => new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
const hhmm = (ms: number) => new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const rand = (a: number, b: number) => a + Math.random() * (b - a);

/** Splits a command line like PowerShell would for simple cases: quotes group words, key="a b" stays one token. */
function tokenize(line: string) {
  const out: string[] = [];
  let cur = '', quote = '', has = false;
  for (const ch of line) {
    if (quote) { if (ch === quote) quote = ''; else cur += ch; }
    else if (ch === '"' || ch === "'") { quote = ch; has = true; }
    else if (/\s/.test(ch)) { if (cur || has) out.push(cur); cur = ''; has = false; }
    else cur += ch;
  }
  if (cur || has) out.push(cur);
  return out;
}

export function initDemo(root: HTMLElement) {
  const q = <T extends HTMLElement = HTMLElement>(sel: string) => root.querySelector(sel) as T;
  const frame = q('[data-frame]');
  const stage = q('[data-stage]');
  const notch = q('[data-notch]');
  const shell = q('[data-shell]');
  const pill = q('[data-pill]');
  const peekEl = q('[data-peek]');
  const bar = q('[data-bar]');
  const glance = q('[data-glance]');
  const toast = q('[data-toast]');
  const term = q('[data-term]');
  const termIn = q<HTMLInputElement>('[data-termin]');
  const caption = q('[data-caption]');
  const tabBody = (t: Tab) => q(`[data-tab="${t}"]`);
  const T0 = Date.now();

  const s = {
    running: true,
    mode: 'collapsed' as Mode,
    openedBy: 'hover' as OpenedBy,
    pinned: false,
    tab: 'home' as Tab,
    game: 'auto' as GameSetting,
    gaming: false,
    peek: null as null | { icon: IconName; text: string; tone: Tone; tab?: Tab },
    cpu: 13, gpu: 0, ram: 21.3, down: 8, up: 7,
    track: 0, pos: 72, playing: true,
    volume: 62, muted: false,
    timer: { len: 25 * 60, left: 18 * 60 + 42, running: false },
    swatches: ['#4CD98C', '#1ED760', '#FF453A', '#3B82F6', '#F59E0B'],
    swatchNote: '',
    picking: false,
    clipFilter: 'all' as 'all' | 'text' | 'code' | 'image',
    copied: -1,
    clips: [
      { id: 1, kind: 'link', text: 'https://github.com/Somafet/qnotch', at: T0 - 3 * 60e3, pinned: true },
      { id: 2, kind: 'code', text: 'npm run deploy -- --prod', at: T0 - 6 * 60e3 },
      { id: 3, kind: 'image', text: 'Image · 320 x 180', at: T0 - 9 * 60e3 },
      { id: 4, kind: 'text', text: 'Meeting notes: ship the clipboard module, then polish the settings page.', at: T0 - 14 * 60e3 },
      { id: 5, kind: 'color', text: '#5B9DFF', at: T0 - 31 * 60e3 },
    ] as Clip[],
    agents: [] as Agent[],
    leftover: [
      { cmd: 'node astro.mjs dev', meta: 'docs · 210 MB · 0.1% · :4321' },
      { cmd: 'vite', meta: 'ledge · 96 MB · 0% · :5173' },
    ],
    notes: [
      { id: 2, title: 'Build finished', body: '142 tests passed in 38 s.', app: 'Build', at: T0 - 6 * 60e3, icon: 'check', tone: 'ok' },
      { id: 1, title: 'Deploy to staging failed', body: 'Health check timed out after 60 s.', app: 'Deploy', at: T0 - 29 * 60e3, icon: 'xcircle', tone: 'danger' },
    ] as Note[],
    tray: [] as TrayFile[],
    unread: 0,
    toastId: 0,
    query: '',
    sound: true,
    termTab: 'claude' as 'claude' | 'pwsh',
    claude: [
      `<span class="t-dim">Claude Code · ~/code/api</span>`,
      `<span class="t-user">&gt; add rate limiting to the upload endpoint</span>`,
      `<span class="t-dot">●</span> I'll add a token-bucket limiter in <span class="t-acc">src/middleware</span>.`,
      `<span class="t-dot">●</span> <b>Update</b>(src/middleware/limit.ts)`,
      `<span class="t-dim">  ⎿  Added 42 lines</span>`,
      `<span class="t-warn">✻</span> Running the test suite…`,
    ],
    prompt: false,
    pwsh: [`<span class="t-dim">PowerShell 7.5. Try: QNotch.exe notify "Hello" "From my terminal" --action ok=Nice</span>`],
    vars: {} as Record<string, string>,
    sides: {} as Record<string, number>,
    history: [] as string[],
    histAt: 0,
  };

  const newApi = (status: Agent['status'] = 'working'): Agent => ({
    id: 'api', status, since: Date.now() - 3 * 60e3, cost: '$2.14', tokens: '820K',
    procs: [['node server.js', ':8080', '212 MB'], ['tsc --watch', '', '89 MB']],
  });
  s.agents = [
    newApi(),
    { id: 'web', status: 'working', since: T0 - 6 * 60e3, cost: '$1.72', tokens: '610K',
      procs: [['next dev', ':3000', '312 MB'], ['node (worker)', '', '98 MB'], ['esbuild', '', '44 MB'], ['playwright chrome', '', '30 MB']] },
    { id: 'ledge', status: 'done', since: T0 - 12 * 60e3, cost: '$0.35', tokens: '470K' },
  ];
  const api = () => s.agents.find(a => a.id === 'api') ?? (s.agents.unshift(newApi()), s.agents[0]);
  const procLine = (a: Agent) => a.procs ? `${a.procs.length} processes · ${a.procs.reduce((n, p) => n + parseInt(p[2]), 0)} MB${a.procs.map(p => p[1] ? ` · ${p[1]}` : '').join('')}` : '';

  const desk = initDesktop(stage, {
    scale: () => Number(stage.style.getPropertyValue('--s')) || 1,
    launchQNotch: () => (s.running ? open(s.tab, 'scenario') : start()),
    quitQNotch: quit,
    running: () => s.running,
    game: () => s.game,
    setGame: g => { s.game = g; render(); flashCaption(`Game mode: ${g === 'auto' ? 'Auto' : g === 'on' ? 'On' : 'Off'}`); },
    openPanel: () => open(s.tab, 'scenario'),
    sound: on => (on === undefined ? s.sound : (s.sound = on)),
    toTray: f => addToTray([f]),
    focusChanged: () => layout(),
  });

  /* ---------- terminal ---------- */
  function renderTerm() {
    term.querySelectorAll<HTMLElement>('[data-act="term"]').forEach(b => b.classList.toggle('on', b.dataset.arg === s.termTab));
    const claude = s.termTab === 'claude';
    q('[data-lines]').innerHTML = (claude ? s.claude : s.pwsh).map(l => `<div>${l}</div>`).join('') + (claude && s.prompt
      ? `<div class="t-box"><div class="t-warn"><b>Bash command</b></div><div>  npm test</div><div class="t-dim">  Run the test suite</div>` +
        `<div style="margin-top:6px">Do you want to proceed?</div>` +
        `<button class="t-opt" data-act="answer" data-arg="yes">❯ 1. Yes</button>` +
        `<button class="t-opt" data-act="answer" data-arg="no">  2. No, and tell Claude what to do differently</button></div>`
      : '');
    q('[data-ps]').innerHTML = claude ? '<span class="t-user">&gt; </span>' : PS;
    q('[data-inline]').hidden = claude && s.prompt;
    termIn.placeholder = claude ? 'Ask Claude something' : '';
    const body = q('[data-termbody]');
    body.scrollTop = body.scrollHeight;
  }

  function runClaude(text: string) {
    s.claude.push(`<span class="t-user">&gt; ${esc(text)}</span>`, `<span class="t-dot">●</span> On it. I'll make the change, then run the tests.`, `<span class="t-warn">✻</span> Running the test suite…`);
    const a = api();
    a.status = 'working';
    renderTerm();
    render();
    window.setTimeout(askPermission, 1100);
  }

  function askPermission() {
    if (s.prompt) return;
    s.prompt = true;
    api().status = 'needs';
    renderTerm();
    if (term.contains(document.activeElement)) q<HTMLElement>('.t-opt')?.focus();
    if (s.running) {
      peek('terminal', 'api: Needs you', 'warn', 4000, 'agents');
      chime([659.3, 880]);
    }
    if (s.tab === 'agents') renderAgents();
    render();
  }

  function out(...lines: string[]) { s.pwsh.push(...lines); }
  function runPwsh(line: string) {
    out(PS + esc(line));
    const assign = line.match(/^\$(\w+)\s*=\s*(.+)$/);
    const varName = assign?.[1];
    const t = tokenize(assign ? assign[2] : line);
    const cmd = (t[0] ?? '').toLowerCase().replace(/^\.[\\/]/, '');
    const err = (msg: string) => out(`<span class="t-err">${esc(msg)}</span>`);
    if (!cmd) return;
    if (/^\$\w+$/.test(cmd)) { const v = s.vars[cmd.slice(1)]; if (v !== undefined) out(esc(v)); return; }
    switch (cmd) {
      case 'cls': case 'clear': s.pwsh = []; return;
      case 'help': case 'get-help':
        out('Try these:', '  QNotch.exe notify "Build finished" "142 tests passed" --level success',
          '  $answer = QNotch.exe notify "Ship it?" --action yes=Ship --action no="Not yet"', '  $answer', '  ls, echo, npm test, ./deploy.ps1, claude, cls, exit');
        return;
      case 'echo': case 'write-host': case 'write-output': out(esc(t.slice(1).join(' '))); return;
      case 'ls': case 'dir': case 'get-childitem': out('src    tests    deploy.ps1    package.json    README.md'); return;
      case 'claude': setTermTab('claude'); return;
      case 'exit': desk.launch('term'); return;
      case 'npm':
        if (t[1] === 'test' || t[1] === 't') out('<span class="t-ok">✓ 142 passed</span> <span class="t-dim">in 38 s</span>');
        else err(`npm: unknown command "${t[1] ?? ''}". Try npm test.`);
        return;
      case 'deploy.ps1':
        out('Deploying main to production…');
        window.setTimeout(() => { out('<span class="t-ok">Deployed main to production in 41 s.</span>'); renderTerm(); }, 1200);
        return;
      case 'qnotch.exe': case 'qnotch':
        if (t[1]?.toLowerCase() !== 'notify') { err(`Unknown verb "${t[1] ?? ''}". Try QNotch.exe notify --help.`); return; }
        notifyCli(t.slice(2), varName);
        return;
      default:
        err(`${t[0]}: The term '${t[0]}' is not recognized as a name of a cmdlet, function, script file, or executable program.`);
    }
  }

  function notifyCli(args: string[], varName?: string) {
    if (args.includes('--help') || !args.length) {
      out('Usage: QNotch.exe notify "title" ["body"] [--app name] [--level info|success|warning|error]',
        '                         [--action id=Label]... [--url address] [--focus]');
      return;
    }
    if (!s.running) { out('<span class="t-err">QNotch is not running. (exit code 3)</span>'); return; }
    const pos: string[] = [], actions: Action[] = [];
    let app = 'Terminal', level = 'info';
    for (let i = 0; i < args.length; i++) {
      const a = args[i];
      if (!a.startsWith('--')) { pos.push(a); continue; }
      const v = args[++i] ?? '';
      if (a === '--app') app = v;
      else if (a === '--level') level = v in LEVELS ? v : 'info';
      else if (a === '--action') { const [id, ...rest] = v.split('='); actions.push({ id, label: rest.join('=') || id }); }
      else if (a === '--url') actions.push({ id: 'open', label: 'Open', url: v });
      else if (a === '--focus') { actions.push({ id: 'show', label: 'Show', focus: true }); i--; }
      else if (a === '--icon') continue;
      else { out(`<span class="t-err">Unknown option ${esc(a)}. Try QNotch.exe notify --help.</span>`); return; }
    }
    const asks = actions.some(x => !x.url && !x.focus);
    const [icon, tone] = asks ? ['chat', 'accent'] as [IconName, Tone] : LEVELS[level];
    post({ title: pos[0] ?? 'Notification', body: pos[1] ?? '', app, icon, tone, actions: actions.length ? actions : undefined, answerVar: asks ? varName : undefined });
  }

  termIn.addEventListener('keydown', e => {
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      s.histAt = Math.max(0, Math.min(s.history.length, s.histAt + (e.key === 'ArrowUp' ? -1 : 1)));
      termIn.value = s.history[s.histAt] ?? '';
      return;
    }
    if (e.key !== 'Enter') return;
    const line = termIn.value.trim();
    termIn.value = '';
    if (line) { s.history.push(line); s.histAt = s.history.length; }
    run++;
    if (s.termTab === 'claude') { if (line) runClaude(line); }
    else { if (line) runPwsh(line); else out(PS); }
    renderTerm();
  });
  term.addEventListener('keydown', e => {
    if (s.termTab === 'claude' && s.prompt && (e.key === '1' || e.key === '2')) { e.preventDefault(); answer(e.key === '1'); }
  });
  q('[data-termbody]').addEventListener('click', () => {
    if (!getSelection()?.toString() && !q('[data-inline]').hidden) termIn.focus({ preventScroll: true });
  });

  /* ---------- static scaffold ---------- */
  q('[data-head]').innerHTML = `
    <div class="qn-me"><div class="qn-avatar">A</div><div><b>Alex</b><span data-k="date"></span></div></div>
    <nav class="qn-tabstrip">${TABS.map(([id, icon, label]) =>
      `<button class="qn-tabbtn" data-act="tab" data-arg="${id}" title="${label}" aria-label="${label}">${svg(icon)}<i class="qn-badge" data-badge="${id}"></i></button>`).join('')}</nav>
    <div class="qn-headbtns"><button class="qn-icon" data-act="pin" title="Keep open" aria-label="Keep open">${svg('pin')}</button></div>`;

  tabBody('home').innerHTML = `
    <div class="qn-grid">
      <div class="qn-card"><h4>System</h4>
        <div class="qn-stat"><span>CPU</span><b data-k="cpu"></b></div><div class="qn-track"><i data-w="cpu"></i></div>
        <div class="qn-stat"><span>RAM</span><b data-k="ram"></b></div><div class="qn-track"><i data-w="ram"></i></div>
        <div class="qn-stat"><span>GPU</span><b data-k="gpu"></b></div>
        <div class="qn-stat"><span>NET</span><b data-k="net"></b></div>
      </div>
      <div class="qn-card span2"><h4>Now playing</h4>
        <div class="qn-media">
          <div class="qn-art" data-art></div>
          <div class="qn-media-mid">
            <b data-k="title"></b><span data-k="artist"></span>
            <div class="qn-track seek" data-act="seek" title="Seek"><i data-w="pos"></i></div>
            <div class="qn-times"><span data-k="pos"></span><span data-k="len"></span></div>
          </div>
          <div class="qn-media-ctl">
            <button class="qn-icon" data-act="prev" title="Previous" aria-label="Previous">${svg('prev')}</button>
            <button class="qn-play" data-act="play" data-play title="Play or pause" aria-label="Play or pause"></button>
            <button class="qn-icon" data-act="next" title="Next" aria-label="Next">${svg('next')}</button>
          </div>
        </div>
      </div>
      <div class="qn-card"><h4>Volume</h4>
        <div class="qn-vol"><button class="qn-icon" data-act="mute" title="Mute" aria-label="Mute">${svg('volume')}</button><b data-k="vol"></b></div>
        <input class="qn-range" type="range" min="0" max="100" data-vol aria-label="Volume" />
      </div>
      <div class="qn-card"><h4>Timer</h4>
        <div class="qn-timer"><b data-k="timer"></b><span data-k="timerState"></span>
          <button class="qn-icon" data-act="timer" data-timerbtn title="Start or pause" aria-label="Start or pause"></button>
          <button class="qn-icon" data-act="timerReset" title="Restart" aria-label="Restart">${svg('restart')}</button></div>
        <div class="qn-presets">${[5, 15, 25, 50].map(m => `<button data-act="preset" data-arg="${m}">${m}</button>`).join('')}</div>
      </div>
      <div class="qn-card"><h4>Color picker</h4>
        <button class="qn-btn wide" data-act="pick">${svg('pipette')} <span data-k="pickLabel">Pick a color</span></button>
        <div class="qn-swatches" data-swatches></div>
        <div class="qn-swatch-note" data-k="swatchNote"></div>
      </div>
    </div>`;

  tabBody('search').innerHTML = `
    <div class="qn-search"><span>${svg('search')}</span><input data-search placeholder="Search clipboard, notes, notifications, tabs and settings" aria-label="Search" /></div>
    <div class="qn-results" data-results></div>`;

  /* ---------- binds ---------- */
  const set = (k: string, v: string) => root.querySelectorAll<HTMLElement>(`[data-k="${k}"]`).forEach(e => { if (e.textContent !== v) e.textContent = v; });
  const w = (k: string, pct: number) => root.querySelectorAll<HTMLElement>(`[data-w="${k}"]`).forEach(e => (e.style.width = `${Math.max(0, Math.min(100, pct))}%`));

  function binds() {
    const t = TRACKS[s.track];
    set('date', new Date().toLocaleDateString('en-US', { weekday: 'long', month: 'long', day: 'numeric' }));
    set('shortdate', new Date().toLocaleDateString([], { day: 'numeric', month: 'numeric', year: 'numeric' }));
    set('cpu', `${Math.round(s.cpu)}%`); w('cpu', s.cpu);
    set('ram', `${s.ram.toFixed(1)}/31.9 GB`); w('ram', (s.ram / 31.9) * 100);
    set('gpu', `${Math.round(s.gpu)}%`);
    set('net', `↓ ${Math.round(s.down)} KB/s  ↑ ${Math.round(s.up)} KB/s`);
    set('title', t.title); set('artist', t.artist);
    set('pos', mmss(s.pos)); set('len', mmss(t.len)); w('pos', (s.pos / t.len) * 100);
    q('[data-art]').style.background = t.art;
    put(q('[data-play]'), svg(s.playing ? 'pause' : 'play'));
    set('vol', s.muted ? 'Muted' : `${s.volume}%`);
    const vol = q<HTMLInputElement>('[data-vol]');
    if (document.activeElement !== vol) vol.value = String(s.volume);
    vol.style.setProperty('--v', `${s.muted ? 0 : s.volume}%`);
    set('timer', mmss(s.timer.left));
    set('timerState', s.timer.running ? '' : s.timer.left === 0 ? 'Done' : 'Paused');
    put(q('[data-timerbtn]'), svg(s.timer.running ? 'pause' : 'play'));
    root.querySelectorAll<HTMLElement>('[data-act="preset"]').forEach(b => b.classList.toggle('on', Number(b.dataset.arg) * 60 === s.timer.len));
    put(q('[data-swatches]'), s.swatches.map(c => `<button data-act="swatch" data-arg="${c}" style="background:${c}" title="Copy ${c}" aria-label="Copy ${c}"></button>`).join(''));
    set('swatchNote', s.swatchNote);
    set('pickLabel', s.picking ? 'Click anything…' : 'Pick a color');
    set('clock', clock());
    root.querySelectorAll<HTMLElement>('[data-since]').forEach(e => {
      const since = Number(e.dataset.since);
      e.textContent = e.dataset.fmt === 'done' ? `Done ${ago(since)}` : `Working for ${dur(since)}`;
    });
    desk.renderMusic({ ...t, pos: s.pos, playing: s.playing, track: s.track, tracks: TRACKS });
  }

  /* ---------- pill, peek, glance, toast, game bar ---------- */
  function agentSeg() {
    const needs = s.agents.find(a => a.status === 'needs');
    const working = s.agents.filter(a => a.status === 'working').length;
    if (needs) return `<span class="seg warn"><i class="dot"></i>${needs.id} needs you</span>`;
    if (working) return `<span class="seg"><i class="dot"></i>${working} working</span>`;
    return '';
  }
  function timerSeg(game = false) {
    const show = s.timer.running || (!game && s.timer.left < s.timer.len && s.timer.left > 0);
    return show ? `<span class="seg">${svg('timer', 'i acc')}<b>${mmss(s.timer.left)}</b></span>` : '';
  }

  function renderPill() {
    const t = TRACKS[s.track];
    put(pill, `
      <span class="seg media"><span class="qn-mi">${svg('music')}</span><b>${t.title}</b><span class="dim">${t.artist}</span></span>
      <span class="sp"></span>
      ${agentSeg()}
      ${s.unread ? `<span class="seg">${svg('bell', 'i acc')}<b>${s.unread}</b></span>` : ''}
      ${timerSeg()}
      <span class="seg"><span class="dim">CPU</span>${Math.round(s.cpu)}%</span>
      <span class="seg"><span class="dim">GPU</span>${Math.round(s.gpu)}%</span>
      <span class="seg"><span class="dim">RAM</span>${s.ram.toFixed(1)}/31.9 GB</span>
      <span class="seg"><b>${clock()}</b></span>`);
    put(bar, `
      <span class="seg"><b>${t.title}</b>&nbsp;·&nbsp;${t.artist}</span>
      ${agentSeg()}
      ${s.unread ? `<span class="seg">${svg('bell', 'i acc')}${s.unread}</span>` : ''}
      <span class="seg"><span class="dim">CPU</span>${Math.round(s.cpu)}%</span>
      <span class="seg"><span class="dim">GPU</span>${Math.round(s.gpu)}% 48°C</span>
      <span class="seg"><span class="dim">RAM</span>${s.ram.toFixed(1)}/31.9 GB</span>
      <span class="seg"><span class="dim">↓</span>${Math.round(s.down)} KB/s <span class="dim">↑</span>${Math.round(s.up)} KB/s</span>
      ${timerSeg(true)}
      <span class="seg"><b>${clock()}</b></span>`);
  }

  function renderPeek() {
    if (s.peek) put(peekEl, `${svg(s.peek.icon, `i ${s.peek.tone}`)}<b>${esc(s.peek.text)}</b>`);
  }

  function renderGlance() {
    const n = s.notes[0];
    const show = s.mode === 'collapsed' && s.unread > 0 && !!n && !visibleToast();
    const t = TRACKS[s.track];
    glance.classList.toggle('show', show);
    if (show) put(glance, `${svg('music', 'i acc')}<span>${t.title} · ${t.artist}</span>${svg(n.icon, `i ${n.tone}`)}<span>${esc(n.app)}: ${esc(n.title)}</span>`);
  }

  function visibleToast() {
    const n = s.notes.find(x => x.id === s.toastId);
    return s.mode === 'collapsed' && n ? n : null;
  }

  function noteHtml(n: Note, inToast = false) {
    const waiting = n.actions && !n.answered;
    return `
      <div class="qn-ico ${n.tone}">${svg(n.icon)}</div>
      <div class="qn-row-mid">
        <b>${esc(n.title)}</b>${n.body ? `<span>${esc(n.body)}</span>` : ''}
        ${waiting ? `<div class="qn-actions">${n.actions!.map(a => `<button class="qn-btn" data-act="noteAction" data-arg="${n.id}:${esc(a.id)}">${esc(a.label)}</button>`).join('')}</div>` : ''}
        <small class="${waiting && n.answerVar !== undefined ? 'acc' : ''}">${esc(n.app)} · ${hhmm(n.at)}${waiting && n.answerVar !== undefined ? ' · Waiting for your answer' : n.answered ? ` · You chose ${esc(n.answered)}` : ''}</small>
      </div>
      <button class="qn-icon" data-act="${inToast ? 'closeToast' : 'dismissNote'}" data-arg="${n.id}" title="Dismiss" aria-label="Dismiss">${svg('x')}</button>`;
  }

  function renderToast() {
    const n = visibleToast();
    toast.classList.toggle('show', !!n);
    if (n) put(toast, noteHtml(n, true));
  }

  /* ---------- tabs ---------- */
  function renderAgents() {
    const rows = s.agents.map(a => {
      const needs = a.status === 'needs', done = a.status === 'done';
      return `<div class="qn-row">
        <div class="qn-ico ${needs ? 'warn' : 'ok'}">${svg(done ? 'check' : 'terminal')}</div>
        <div class="qn-row-mid"><b>${a.id}</b>
          ${needs ? `<span class="warn">Claude needs your permission to use Bash</span>`
            : `<span data-since="${a.since}" data-fmt="${a.status}"></span>`}
          ${a.procs && !done ? `<button class="qn-chip" data-act="procs" data-arg="${a.id}" aria-expanded="${!!a.expanded}">${svg(a.expanded ? 'down' : 'chevron')} ${procLine(a)}</button>` : ''}
          ${a.procs && !done && a.expanded ? `<div class="qn-procs">${a.procs.map(p => `<div><span>${p[0]}</span><em>${p[1]}</em><small>${p[2]}</small></div>`).join('')}</div>` : ''}
        </div>
        <div class="qn-cost"><b>${a.cost}</b><small>${a.tokens} tokens</small></div>
        ${needs ? `<button class="qn-btn warn" data-act="goterm">Answer</button>`
          : `<button class="qn-icon" data-act="goterm" title="Open terminal" aria-label="Open terminal">${svg('external')}</button>`}
        ${done ? `<button class="qn-icon" data-act="dismissAgent" data-arg="${a.id}" title="Dismiss" aria-label="Dismiss">${svg('x')}</button>` : ''}
      </div>`;
    }).join('');
    const left = s.leftover.length
      ? s.leftover.map((p, i) => `<div class="qn-row slim"><div class="qn-row-mid"><b>${p.cmd}</b><span>${p.meta}</span></div><button class="qn-btn" data-act="stop" data-arg="${i}">Stop</button></div>`).join('')
      : `<p class="qn-empty-line">${svg('check', 'i ok')} Nothing left running.</p>`;
    tabBody('agents').innerHTML = `
      <div class="qn-sum">Today <b>1.9M tokens</b> · <b>$4.21</b> at API list prices</div>
      ${rows || `<p class="qn-empty-line">No Claude Code sessions right now. Type in the claude tab to start one.</p>`}
      <div class="qn-sub"><b>Left running</b><span>Started by agents whose session has ended. Nothing will stop these for you.</span></div>
      ${left}`;
    binds();
  }

  function renderClipboard() {
    const kinds = { all: 'All', text: 'Text', code: 'Code', image: 'Images' } as const;
    const list = s.clips.filter(c => s.clipFilter === 'all' || c.kind === s.clipFilter || (s.clipFilter === 'text' && (c.kind === 'link' || c.kind === 'color')));
    const icon: Record<Clip['kind'], IconName> = { link: 'link', code: 'code', image: 'image', text: 'file', color: 'pipette' };
    const meta = (c: Clip) => ({ link: `Link · ${c.text.replace(/^https?:\/\//, '').split('/')[0]}`, code: 'Code', image: c.text, text: `Text · ${c.text.length} chars`, color: 'Color' })[c.kind];
    tabBody('clipboard').innerHTML = `
      <div class="qn-filters">${Object.entries(kinds).map(([k, l]) => `<button class="${s.clipFilter === k ? 'on' : ''}" data-act="clipFilter" data-arg="${k}">${l}</button>`).join('')}
        <span class="sp"></span><small>${list.length} items</small><button class="qn-btn" data-act="clipClear">Clear all</button></div>
      ${list.map(c => `<div class="qn-row clip" data-act="clipCopy" data-arg="${c.id}" role="button" tabindex="0">
        <div class="qn-ico acc">${svg(icon[c.kind])}</div>
        <div class="qn-row-mid">
          ${c.kind === 'image' ? `<div class="qn-img"></div>`
            : c.kind === 'color' ? `<b><i class="qn-sw" style="background:${c.text}"></i>${c.text}</b>`
            : `<b class="${c.kind}">${esc(c.text)}</b>`}
          <small>${s.copied === c.id ? '<span class="ok">Copied</span>' : `${meta(c)} · ${ago(c.at)}`}</small>
        </div>
        <button class="qn-icon ${c.pinned ? 'acc' : 'ghost'}" data-act="clipPin" data-arg="${c.id}" title="Pin" aria-label="Pin">${svg('pin')}</button>
      </div>`).join('') || `<p class="qn-empty-line">Nothing copied yet. Copy some text on this page.</p>`}`;
  }

  function renderFiles() {
    tabBody('files').innerHTML = s.tray.length
      ? `<div class="qn-filters"><small>${s.tray.length} ${s.tray.length === 1 ? 'file' : 'files'} · drag one out to use it</small><span class="sp"></span><button class="qn-btn" data-act="trayClear">Clear all</button></div>
        ${s.tray.map(f => `<div class="qn-row file" draggable="true" data-tray="${f.id}">
          ${f.art ? `<div class="qn-thumb" style="background:${f.art}"></div>` : `<div class="qn-ico acc">${svg(fileIcon(f.kind))}</div>`}
          <div class="qn-row-mid"><b>${esc(f.name)}</b><small>${fmtSize(f.size)} · ${f.file ? 'from your computer' : 'Downloads'} · ${ago(f.at)}</small></div>
          <button class="qn-icon" data-act="trayOpen" data-arg="${f.id}" title="Open" aria-label="Open">${svg('external')}</button>
          <button class="qn-icon" data-act="trayRemove" data-arg="${f.id}" title="Remove" aria-label="Remove">${svg('x')}</button>
        </div>`).join('')}`
      : `<div class="qn-dropzone">${svg('folder')}<b>Drop files on the notch</b><span>They stay within reach here. Nothing is copied or uploaded.</span>
          <button class="qn-btn" data-act="showFiles">Open Downloads</button></div>`;
  }

  function renderNotes() {
    tabBody('notifications').innerHTML = `
      <div class="qn-filters"><small>${s.notes.length} notifications</small><span class="sp"></span><button class="qn-btn" data-act="notesClear">Clear all</button></div>
      ${s.notes.map(n => `<div class="qn-row">${noteHtml(n)}</div>`).join('') || `<p class="qn-empty-line">${svg('bell', 'i')} You are all caught up.</p>`}`;
  }

  let hits: (() => void)[] = [];
  function renderResults() {
    const box = q('[data-results]');
    const query = s.query.trim().toLowerCase();
    hits = [];
    if (!query) {
      box.innerHTML = `<p class="qn-empty-line">Try “deploy”, “github” or “game”.</p>`;
      return;
    }
    const groups: [string, IconName, { title: string; run: () => void }[]][] = [
      ['Clipboard', 'copy', s.clips.filter(c => c.text.toLowerCase().includes(query)).map(c => ({ title: c.text, run: () => { selectTab('clipboard'); copyClip(c.id); } }))],
      ['File tray', 'folder', s.tray.filter(f => f.name.toLowerCase().includes(query)).map(f => ({ title: f.name, run: () => selectTab('files') }))],
      ['Note', 'note', [NOTE_TEXT].filter(t => t.toLowerCase().includes(query)).map(t => ({ title: t, run: () => { copyText(t); addClip(t); flashCaption('Note copied.'); } }))],
      ['Notifications', 'bell', s.notes.filter(n => `${n.title} ${n.body}`.toLowerCase().includes(query)).map(n => ({ title: n.title, run: () => selectTab('notifications') }))],
      ['Tabs', 'tabs', TABS.filter(([, , l]) => l.toLowerCase().includes(query)).map(([id, , l]) => ({ title: l, run: () => selectTab(id) }))],
      ['Settings', 'sliders', SETTINGS.filter(l => l.toLowerCase().includes(query)).map(l => ({ title: `Settings, ${l}`, run: () => flashCaption(`Settings, ${l} opens in its own window in the app.`) }))],
    ];
    const html = groups.filter(([, , h]) => h.length).map(([name, icon, h]) => h.slice(0, 5).map(hit => {
      hits.push(hit.run);
      return `<button class="qn-hit" data-act="hit" data-arg="${hits.length - 1}">${svg(icon, 'i acc')}<span>${esc(hit.title)}</span><small>${name}</small></button>`;
    }).join('')).join('');
    box.innerHTML = html || `<p class="qn-empty-line">Nothing found for “${esc(s.query)}”.</p>`;
  }

  /* ---------- shell geometry ---------- */
  function syncMode() {
    const game = s.running && (s.game === 'on' || (s.game === 'auto' && s.gaming));
    if (game && s.mode !== 'game') { s.mode = 'game'; s.peek = null; s.pinned = false; }
    if (!game && s.mode === 'game') s.mode = 'collapsed';
  }

  let dragX: number | null = null;
  const maxOffset = () => Math.max(0, (stage.offsetWidth - parseFloat(shell.style.width || '0')) / 2 - 10);

  function layout() {
    stage.dataset.mode = s.mode;
    stage.classList.toggle('gaming', s.gaming);
    stage.classList.toggle('quit', !s.running);
    shell.classList.toggle('peeking', !!s.peek && s.mode === 'collapsed');
    let width: number, height: number;
    if (s.mode === 'open') { width = 720; height = 400; }
    else if (s.mode === 'game') { width = bar.offsetWidth + 36; height = 28; }
    else { width = pill.offsetWidth + 28; height = 38; if (s.peek) width += 64; }
    shell.style.width = `${width}px`;
    shell.style.height = `${height}px`;
    const max = maxOffset();
    const nx = dragX ?? (s.sides[desk.active() ?? 'desktop'] ?? 0) * max;
    notch.style.setProperty('--nx', `${Math.max(-max, Math.min(max, nx))}px`);
    root.querySelectorAll<HTMLElement>('.qn-tabbtn').forEach(b => b.classList.toggle('on', b.dataset.arg === s.tab));
    root.querySelectorAll<HTMLElement>('[data-tab]').forEach(t => (t.hidden = t.dataset.tab !== s.tab));
    q('.qn-panel').inert = s.mode !== 'open';
    notch.inert = !s.running;
    q('[data-act="pin"]').classList.toggle('on', s.pinned);
    q('[data-badge="notifications"]').textContent = s.unread ? String(s.unread) : '';
    q('[data-badge="files"]').textContent = s.tray.length ? String(s.tray.length) : '';
    desk.syncTray();
  }

  function render() {
    syncMode();
    renderPill();
    renderPeek();
    renderGlance();
    renderToast();
    binds();
    layout();
  }

  /* ---------- actions ---------- */
  function open(tab: Tab = s.tab, by: OpenedBy = 'scenario') {
    if (!s.running || s.mode === 'game') return;
    s.mode = 'open';
    s.openedBy = by;
    s.peek = null;
    selectTab(tab);
  }
  function stopPicking() {
    if (!s.picking) return;
    s.picking = false;
    stage.classList.remove('picking');
    render();
  }
  function close() {
    if (s.mode !== 'open') return;
    s.mode = 'collapsed';
    s.pinned = false;
    if (q('.qn-panel').contains(document.activeElement)) (document.activeElement as HTMLElement).blur();
    render();
  }
  function selectTab(tab: Tab) {
    s.tab = tab;
    if (tab === 'notifications') s.unread = 0;
    if (tab === 'agents') renderAgents();
    if (tab === 'clipboard') renderClipboard();
    if (tab === 'files') renderFiles();
    if (tab === 'notifications') renderNotes();
    if (tab === 'search') renderResults();
    render();
  }

  function quit() {
    close();
    s.running = false;
    s.peek = null;
    s.toastId = 0;
    render();
    flashCaption('QNotch quit. Start it again from the Start menu.');
  }
  function start() {
    if (s.running) return;
    s.running = true;
    stage.classList.remove('ready');
    render();
    window.setTimeout(() => stage.classList.add('ready'), 30);
  }

  let peekTimer = 0;
  function peek(icon: IconName, text: string, tone: Tone, ms = 4000, tab?: Tab) {
    if (s.mode === 'game' || !s.running) return;
    s.peek = { icon, text, tone, tab };
    render();
    clearTimeout(peekTimer);
    peekTimer = window.setTimeout(() => { s.peek = null; render(); }, ms);
  }

  let ac: AudioContext | null = null;
  function chime(freqs: number[]) {
    if (!s.sound || s.mode === 'game' || !s.running) return;
    try {
      ac ??= new AudioContext();
      const t0 = ac.currentTime;
      freqs.forEach((f, i) => {
        const o = ac!.createOscillator(), g = ac!.createGain(), t = t0 + i * 0.13;
        o.type = 'sine';
        o.frequency.value = f;
        g.gain.setValueAtTime(0, t);
        g.gain.linearRampToValueAtTime(0.07, t + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, t + 0.7);
        o.connect(g).connect(ac!.destination);
        o.start(t);
        o.stop(t + 0.75);
      });
    } catch { /* no audio */ }
  }

  const copyText = (t: string) => { navigator.clipboard?.writeText(t).catch(() => {}); };
  let copiedTimer = 0;
  function copyClip(id: number) {
    const c = s.clips.find(x => x.id === id);
    if (!c) return;
    copyText(c.text);
    s.copied = id;
    renderClipboard();
    clearTimeout(copiedTimer);
    copiedTimer = window.setTimeout(() => { s.copied = -1; if (s.tab === 'clipboard') renderClipboard(); }, 1400);
  }
  let clipId = 100;
  function addClip(text: string) {
    text = text.trim().slice(0, 200);
    if (!text) return;
    s.clips = s.clips.filter(c => c.text !== text);
    const kind: Clip['kind'] = /^https?:\/\//.test(text) ? 'link' : /^#[0-9a-f]{6}$/i.test(text) ? 'color' : /[{};=]|^\$|^npm |^dotnet /.test(text) ? 'code' : 'text';
    s.clips.unshift({ id: clipId++, kind, text, at: Date.now() });
    if (s.tab === 'clipboard') renderClipboard();
  }

  let fileId = 1;
  function addToTray(files: FileItem[]) {
    const fresh = files.filter(f => !s.tray.some(t => t.name === f.name));
    s.tray.unshift(...fresh.map(f => ({ ...f, id: fileId++, at: Date.now() })));
    open('files', 'scenario');
    if (fresh.length) flashCaption(`${fresh.map(f => f.name).join(', ')} is in the file tray. Drag it out to the browser to use it.`);
  }

  function setTimer(len: number) {
    s.timer = { len, left: len, running: true };
    render();
  }

  function toHex(c: string) {
    const m = c.match(/\d+(\.\d+)?/g);
    if (!m) return null;
    const [r, g, b, a] = m.map(Number);
    if (a === 0) return null;
    return '#' + [r, g, b].map(v => Math.round(v).toString(16).padStart(2, '0')).join('').toUpperCase();
  }
  function addSwatch(hex: string) {
    s.swatches = [hex, ...s.swatches.filter(x => x !== hex)].slice(0, 5);
    s.swatchNote = `Copied ${hex}`;
    copyText(hex);
    addClip(hex);
  }
  async function pick() {
    const ED = (window as unknown as { EyeDropper?: new () => { open(): Promise<{ sRGBHex: string }> } }).EyeDropper;
    if (ED) {
      try {
        const r = await new ED().open();
        addSwatch(r.sRGBHex.toUpperCase());
      } catch { /* cancelled */ }
      render();
      return;
    }
    s.picking = true;
    stage.classList.add('picking');
    render();
  }

  /* ---------- scenarios ---------- */
  let run = 0;
  let active: Scenario | null = null;
  function setCaption(text: string) { caption.textContent = text; }
  let capTimer = 0;
  function flashCaption(text: string) {
    setCaption(text);
    clearTimeout(capTimer);
    capTimer = window.setTimeout(() => setCaption(CAPTIONS[active ?? 'idle']), 4000);
  }
  function setActive(name: Scenario | null) {
    active = name;
    root.querySelectorAll<HTMLElement>('[data-scenario]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.scenario === name)));
    setCaption(CAPTIONS[name ?? 'idle']);
  }

  function setTermTab(tab: 'claude' | 'pwsh') { s.termTab = tab; renderTerm(); }
  function goTerm(tab: 'claude' | 'pwsh' = 'claude') {
    desk.show('term');
    setTermTab(tab);
    term.classList.remove('flash');
    void term.offsetWidth;
    term.classList.add('flash');
  }

  function answer(yes: boolean) {
    const a = api();
    if (!s.prompt) return;
    s.prompt = false;
    if (yes) {
      s.claude.push(`<span class="t-dot">●</span> <b>Bash</b>(npm test)`, `<span class="t-dim">  ⎿  142 passed in 38 s</span>`);
      a.status = 'working';
      window.setTimeout(() => {
        if (s.prompt) return;
        s.claude.push(`<span class="t-ok">●</span> Done, and every test passes.`);
        a.status = 'done';
        a.since = Date.now();
        a.cost = '$2.31';
        peek('check', 'api: Done', 'ok', 3200, 'agents');
        chime([880, 1174.7]);
        renderTerm();
        if (s.tab === 'agents') renderAgents();
        render();
      }, 2600);
    } else {
      s.claude.push(`<span class="t-dim">  ⎿  Waiting for your instructions</span>`);
      a.status = 'done';
      a.since = Date.now();
    }
    s.peek = null;
    renderTerm();
    if (term.contains(document.activeElement)) termIn.focus({ preventScroll: true });
    if (s.tab === 'agents') renderAgents();
    render();
  }

  let noteId = 10;
  function post(n: Omit<Note, 'id' | 'at'>) {
    const note = { ...n, id: noteId++, at: Date.now() };
    s.notes.unshift(note);
    s.unread++;
    s.toastId = note.id;
    chime([659.3]);
    if (s.tab === 'notifications' && s.mode === 'open') { s.unread = 0; renderNotes(); }
    render();
    window.setTimeout(() => { if (s.toastId === note.id) { s.toastId = 0; render(); } }, note.actions ? 60000 : 7000);
    return note;
  }

  function noteAction(arg: string) {
    const i = arg.indexOf(':');
    const n = s.notes.find(x => x.id === Number(arg.slice(0, i)));
    const act = arg.slice(i + 1);
    const a = n?.actions?.find(x => x.id === act);
    if (!n || !a || n.answered) return;
    if (a.url) { window.open(/^https?:\/\//.test(a.url) ? a.url : `https://${a.url}`, '_blank', 'noopener'); return; }
    if (a.focus) { goTerm('pwsh'); return; }
    n.answered = a.label;
    if (s.toastId === n.id) s.toastId = 0;
    s.unread = Math.max(0, s.unread - 1);
    if (n.answerVar) {
      s.vars[n.answerVar] = act;
      flashCaption(`$${n.answerVar} is now "${act}". Type $${n.answerVar} in the pwsh tab to read it.`);
      if (n.app === 'Deploy' && act === 'ship') runPwsh('./deploy.ps1 -Prod');
      renderTerm();
    }
    renderNotes();
    render();
  }

  async function typeInto(input: HTMLInputElement, text: string, alive: () => boolean, step = 2, ms = 16) {
    for (let i = 1; i <= text.length; i += step) {
      input.value = text.slice(0, i);
      input.scrollLeft = input.scrollWidth;
      await sleep(ms);
      if (!alive()) return false;
    }
    input.value = text;
    return true;
  }

  async function scenario(name: Scenario) {
    const id = ++run;
    const alive = () => id === run;
    stopPicking();
    desk.closeFlyouts();
    q('[data-sleep]').classList.remove('show');
    setActive(name);
    if (name !== 'game' && s.gaming) { s.gaming = false; render(); }
    if (!s.running) { start(); await sleep(400); if (!alive()) return; }

    if (name === 'open') { open('home'); return; }
    if (name === 'clipboard') { open('clipboard'); return; }
    if (name === 'game') { close(); s.gaming = true; render(); return; }
    if (name === 'files') { close(); desk.show('files'); desk.flashFile(FILES[0].name); return; }
    if (name === 'search') {
      open('search', 'keys');
      const input = q<HTMLInputElement>('[data-search]');
      input.value = s.query = '';
      renderResults();
      input.focus({ preventScroll: true });
      for (const ch of 'deploy') {
        await sleep(110);
        if (!alive()) return;
        input.value = s.query += ch;
        renderResults();
      }
      return;
    }
    if (name === 'agent') {
      close();
      goTerm('claude');
      if (s.prompt) { askPermissionAgain(); return; }
      if (!await typeInto(termIn, 'now add a test for the 429 response', alive, 1, 28)) { termIn.value = ''; return; }
      termIn.value = '';
      s.history.push('now add a test for the 429 response');
      runClaude('now add a test for the 429 response');
      return;
    }
    if (name === 'notify') {
      close();
      goTerm('pwsh');
      const cmd = '$answer = QNotch.exe notify "Deploy to production?" "main passed CI in 4m 12s" --app Deploy --action ship=Deploy --action later="Not now"';
      if (!await typeInto(termIn, cmd, alive)) { termIn.value = ''; return; }
      await sleep(200);
      if (!alive()) return;
      termIn.value = '';
      s.history.push(cmd);
      runPwsh(cmd);
      renderTerm();
    }
  }
  function askPermissionAgain() {
    peek('terminal', 'api: Needs you', 'warn', 4000, 'agents');
    chime([659.3, 880]);
  }

  /* ---------- events ---------- */
  root.querySelectorAll<HTMLElement>('[data-scenario]').forEach(b => b.addEventListener('click', () => {
    const name = b.dataset.scenario as Scenario;
    if (name === 'game' && s.gaming) { s.gaming = false; setActive(null); render(); return; }
    scenario(name);
  }));

  stage.addEventListener('click', e => {
    const target = e.target as HTMLElement;
    if (justDragged) { e.stopPropagation(); return; }
    if (s.picking) {
      e.preventDefault();
      e.stopPropagation();
      let el: HTMLElement | null = target, hex: string | null = null;
      while (el && el !== root && !hex) { hex = toHex(getComputedStyle(el).backgroundColor); el = el.parentElement; }
      s.picking = false;
      stage.classList.remove('picking');
      addSwatch(hex ?? '#3A3F8F');
      render();
      return;
    }
    const btn = target.closest<HTMLElement>('[data-act]');
    const arg = btn?.dataset.arg ?? '';
    const num = Number(arg);
    switch (btn?.dataset.act) {
      case 'tab': selectTab(arg as Tab); return;
      case 'pin': s.pinned = !s.pinned; layout(); return;
      case 'play': s.playing = !s.playing; render(); return;
      case 'prev': s.pos > 3 ? (s.pos = 0) : (s.track = (s.track + TRACKS.length - 1) % TRACKS.length, s.pos = 0); render(); return;
      case 'next': s.track = (s.track + 1) % TRACKS.length; s.pos = 0; s.playing = true; render(); return;
      case 'track': s.track = num; s.pos = 0; s.playing = true; render(); return;
      case 'seek': {
        const r = btn!.getBoundingClientRect();
        s.pos = Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * TRACKS[s.track].len);
        render();
        return;
      }
      case 'mute': s.muted = !s.muted; render(); return;
      case 'timer': if (s.timer.left === 0) s.timer.left = s.timer.len; s.timer.running = !s.timer.running; render(); return;
      case 'timerReset': s.timer.left = s.timer.len; s.timer.running = false; render(); return;
      case 'preset': setTimer(num * 60); return;
      case 'pick': pick(); return;
      case 'swatch': addSwatch(arg); render(); return;
      case 'clipFilter': s.clipFilter = arg as typeof s.clipFilter; renderClipboard(); return;
      case 'clipClear': s.clips = s.clips.filter(c => c.pinned); renderClipboard(); return;
      case 'clipPin': { e.stopPropagation(); const c = s.clips.find(x => x.id === num); if (c) c.pinned = !c.pinned; renderClipboard(); return; }
      case 'clipCopy': copyClip(num); return;
      case 'notesClear': s.notes = s.notes.filter(n => n.actions && !n.answered && n.answerVar !== undefined); s.unread = 0; renderNotes(); render(); return;
      case 'noteAction': noteAction(arg); return;
      case 'closeToast': s.toastId = 0; render(); return;
      case 'dismissNote': s.notes = s.notes.filter(n => n.id !== num); renderNotes(); render(); return;
      case 'openNotes': s.toastId = 0; open('notifications', 'scenario'); return;
      case 'hit': hits[num]?.(); return;
      case 'goterm': close(); goTerm('claude'); return;
      case 'procs': { const a = s.agents.find(x => x.id === arg); if (a) a.expanded = !a.expanded; renderAgents(); return; }
      case 'dismissAgent': s.agents = s.agents.filter(a => a.id !== arg); renderAgents(); render(); return;
      case 'stop': s.leftover.splice(num, 1); renderAgents(); return;
      case 'answer': answer(arg === 'yes'); return;
      case 'term': setTermTab(arg as 'claude' | 'pwsh'); termIn.focus({ preventScroll: true }); return;
      case 'trayOpen': {
        const f = s.tray.find(x => x.id === num);
        if (f?.file) window.open(URL.createObjectURL(f.file), '_blank', 'noopener');
        else if (f) { close(); desk.flashFile(f.name); }
        return;
      }
      case 'trayRemove': s.tray = s.tray.filter(x => x.id !== num); renderFiles(); render(); return;
      case 'trayClear': s.tray = []; renderFiles(); render(); return;
      case 'showFiles': close(); desk.show('files'); return;
      case 'openPill':
        if (s.mode === 'collapsed') open(s.peek?.tab ?? s.tab, 'scenario');
        return;
    }
    if (s.mode === 'open' && !s.pinned && !target.closest('[data-notch]')) close();
  }, true);

  // Files dragged onto the notch: it opens on the Files tab and keeps them.
  let dragTimer = 0;
  notch.addEventListener('dragenter', e => {
    if (!isFileDrag(e) || s.mode === 'game') return;
    clearTimeout(dragTimer);
    if (s.mode === 'collapsed') dragTimer = window.setTimeout(() => open('files', 'scenario'), 250);
    else if (s.tab !== 'files') selectTab('files');
  });
  notch.addEventListener('dragover', e => { if (isFileDrag(e) && s.mode !== 'game') { e.preventDefault(); e.dataTransfer!.dropEffect = 'copy'; } });
  notch.addEventListener('drop', e => {
    e.preventDefault();
    clearTimeout(dragTimer);
    const files = readDrop(e);
    if (files.length) addToTray(files);
  });
  tabBody('files').addEventListener('dragstart', e => {
    const row = (e.target as HTMLElement).closest<HTMLElement>('[data-tray]');
    const f = s.tray.find(x => x.id === Number(row?.dataset.tray));
    if (f) setDrag(e, f);
  });

  // Drag the pill (or the open panel's header) sideways: it snaps to the center or an edge, remembered per app.
  // A quick fling carries it further. Double-click centers it again.
  let drag: { x0: number; nx0: number; moved: boolean; last: number; t: number; v: number } | null = null;
  let justDragged = false;
  const APP_NAMES: Record<string, string> = { term: 'Terminal', browser: 'the browser', files: 'File Explorer', music: 'Music', desktop: 'the desktop' };
  shell.addEventListener('pointerdown', e => {
    const t = e.target as HTMLElement;
    if (e.button !== 0 || s.mode === 'game' || !(t.closest('[data-pill]') || (t.closest('.qn-head') && !t.closest('button')))) return;
    drag = { x0: e.clientX, nx0: parseFloat(notch.style.getPropertyValue('--nx')) || 0, moved: false, last: e.clientX, t: performance.now(), v: 0 };
  });
  window.addEventListener('pointermove', e => {
    if (!drag) return;
    const scale = Number(stage.style.getPropertyValue('--s')) || 1;
    const dx = (e.clientX - drag.x0) / scale;
    if (!drag.moved && Math.abs(dx) < 5) return;
    if (!drag.moved) { drag.moved = true; clearTimeout(hoverTimer); stage.classList.add('dragging'); }
    const now = performance.now();
    drag.v = (e.clientX - drag.last) / scale / Math.max(1, now - drag.t);
    drag.last = e.clientX;
    drag.t = now;
    dragX = drag.nx0 + dx;
    layout();
  });
  window.addEventListener('pointerup', () => {
    if (!drag) return;
    if (drag.moved) {
      const max = maxOffset(), aim = (dragX ?? 0) + drag.v * 160;
      const app = desk.active() ?? 'desktop';
      s.sides[app] = aim < -max / 2 ? -1 : aim > max / 2 ? 1 : 0;
      dragX = null;
      stage.classList.remove('dragging');
      justDragged = true;
      window.setTimeout(() => (justDragged = false));
      layout();
      flashCaption(s.sides[app] ? `Moved aside while ${APP_NAMES[app]} is in front. Switch windows and it springs back. Double-click to center it.` : 'Back in the center.');
    }
    drag = null;
  });
  shell.addEventListener('dblclick', e => {
    const t = e.target as HTMLElement;
    if (t.closest('button, input') || !(t.closest('[data-pill]') || t.closest('.qn-head'))) return;
    s.sides[desk.active() ?? 'desktop'] = 0;
    layout();
  });

  // Pointer: hover the pill to open, leave the notch to close.
  let hoverTimer = 0;
  shell.addEventListener('pointerenter', e => {
    if (e.pointerType !== 'mouse') return;
    clearTimeout(hoverTimer);
    if (s.mode === 'collapsed') hoverTimer = window.setTimeout(() => open(s.peek?.tab ?? s.tab, 'hover'), 140);
    else if (s.mode === 'open' && s.openedBy === 'scenario') s.openedBy = 'hover';
  });
  notch.addEventListener('pointerenter', e => {
    if (e.pointerType === 'mouse' && s.mode === 'open') clearTimeout(hoverTimer);
  });
  notch.addEventListener('pointerleave', e => {
    if (e.pointerType !== 'mouse') return;
    clearTimeout(hoverTimer);
    if (s.mode === 'open' && s.openedBy === 'hover' && !s.pinned && !s.picking) hoverTimer = window.setTimeout(close, 450);
  });

  // A click anywhere else on the page closes a panel opened from the keyboard or a scenario.
  // composedPath, not contains: a click that re-renders its own button (the clipboard filters) leaves e.target detached.
  document.addEventListener('click', e => {
    if (e.composedPath().includes(root)) return;
    stopPicking();
    desk.closeFlyouts();
    if (s.mode === 'open' && !s.pinned) close();
  });

  q<HTMLInputElement>('[data-search]').addEventListener('input', e => {
    run++;
    s.query = (e.target as HTMLInputElement).value;
    renderResults();
  });
  q<HTMLInputElement>('[data-vol]').addEventListener('input', e => {
    s.volume = Number((e.target as HTMLInputElement).value);
    s.muted = false;
    binds();
  });
  root.addEventListener('keydown', e => {
    const el = e.target as HTMLElement;
    if (e.key !== 'Enter' && e.key !== ' ') return;
    if (el.dataset.act === 'clipCopy') { e.preventDefault(); copyClip(Number(el.dataset.arg)); }
    if (el.dataset.act === 'openPill') { e.preventDefault(); open(s.tab, 'keys'); }
    if (el.dataset.act === 'openNotes') { e.preventDefault(); open('notifications', 'keys'); }
  });

  // Text copied anywhere on the page lands in the demo clipboard.
  document.addEventListener('copy', () => {
    const t = document.getSelection()?.toString() ?? '';
    if (t.trim()) { addClip(t); flashCaption('Copied. It is in the demo clipboard now.'); }
  });

  // The real hotkeys work while the demo is on screen.
  const inView = () => { const r = frame.getBoundingClientRect(); return r.bottom > innerHeight * 0.25 && r.top < innerHeight * 0.75; };
  document.addEventListener('keydown', e => {
    if (!inView()) return;
    if (e.key === 'Escape') {
      if (s.picking) stopPicking();
      else if (s.mode === 'open') close();
      else if (s.gaming) { s.gaming = false; setActive(null); render(); }
      return;
    }
    if (!e.ctrlKey || !e.altKey || e.getModifierState('AltGraph') || !s.running) return;
    const el = e.target as HTMLElement;
    if (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) return;
    const k = e.key.toLowerCase();
    if (k === 'n') { e.preventDefault(); s.mode === 'open' ? close() : open(s.tab, 'keys'); }
    else if (k === 'f') { e.preventDefault(); open('search', 'keys'); q<HTMLInputElement>('[data-search]').focus({ preventScroll: true }); }
    else if (k === 'g') {
      e.preventDefault();
      s.game = s.game === 'auto' ? 'on' : s.game === 'on' ? 'off' : 'auto';
      render();
      flashCaption(`Game mode: ${s.game === 'auto' ? 'Auto' : s.game === 'on' ? 'On' : 'Off'}`);
    }
  });

  // Fit the fixed-size desktop into the frame.
  let wasCompact: boolean | null = null;
  function fit() {
    const compact = frame.clientWidth < 720;
    const W = compact ? 780 : 1200, H = compact ? 620 : 675;
    if (wasCompact !== null && wasCompact !== compact) desk.reset();
    wasCompact = compact;
    stage.classList.toggle('compact', compact);
    stage.style.width = `${W}px`;
    stage.style.height = `${H}px`;
    frame.style.aspectRatio = `${W} / ${H}`;
    stage.style.setProperty('--s', String(frame.clientWidth / W));
  }
  new ResizeObserver(fit).observe(frame);
  fit();

  // One tick a second, like the app's Fast cadence.
  let lap = 102.318;
  setInterval(() => {
    s.cpu = Math.min(42, Math.max(4, s.cpu + rand(-4, 4)));
    s.gpu = Math.random() < 0.2 ? rand(0, 6) : s.gpu * 0.5;
    s.ram = Math.min(22.4, Math.max(20.9, s.ram + rand(-0.1, 0.1)));
    s.down = Math.max(1, s.down + rand(-5, 5));
    s.up = Math.max(1, s.up + rand(-4, 4));
    if (s.playing) s.pos++;
    if (s.pos >= TRACKS[s.track].len) { s.track = (s.track + 1) % TRACKS.length; s.pos = 0; }
    if (s.timer.running && --s.timer.left <= 0) { s.timer.left = 0; s.timer.running = false; peek('timer', 'Time is up', 'accent', 3000); chime([784, 1046.5, 784]); }
    if (s.gaming) { lap += 1; set('lap', `${String(Math.floor(lap / 60)).padStart(2, '0')}:${(lap % 60).toFixed(3).padStart(6, '0')}`); }
    if (inView()) render();
  }, 1000);

  renderTerm();
  render();
  setCaption(CAPTIONS.idle);
  requestAnimationFrame(() => stage.classList.add('ready'));
}
