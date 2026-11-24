// Renders a decoded Calc snapshot. Every string from the link reaches the page through textContent or a validated
// http(s) href; nothing is parsed as HTML and nothing is requested from a network.
(function () {
  'use strict';
  const { decode, linkTokens } = globalThis.CalcShare;
  const SVG = 'http://www.w3.org/2000/svg';
  const MAX_SLICES = 8;
  let generation = 0;

  function element(name, className, content) {
    const node = document.createElement(name);
    if (className) node.className = className;
    if (content !== undefined) node.textContent = content;
    return node;
  }
  function svg(name, attributes) {
    const node = document.createElementNS(SVG, name);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, String(value));
    return node;
  }
  function linked(className, value) {
    const node = element('span', className);
    for (const token of linkTokens(value)) {
      if (!token.href) { node.append(token.text); continue; }
      const anchor = element('a', '', token.text);
      anchor.href = token.href;
      anchor.rel = 'noopener noreferrer nofollow';
      anchor.target = '_blank';
      node.append(anchor);
    }
    return node;
  }

  function figure(shown) {
    const box = element('figure', 'figure figure-' + shown.kind);
    box.setAttribute('role', 'img');
    box.setAttribute('aria-label', shown.description);
    if (shown.kind === 'bar') bars(box, shown);
    else if (shown.kind === 'pie') pie(box, shown);
    else if (shown.kind === 'trend') curve(box, [shown.items.map((item, index) => [index, item.magnitude])], 0, shown.items.length - 1,
      shown.items, [shown.items[0].label || '1', shown.items[shown.items.length - 1].label || String(shown.items.length)]);
    else plot(box, shown);
    return box;
  }
  function bars(box, shown) {
    const largest = Math.max(...shown.items.map(item => Math.abs(item.magnitude))) || 1;
    for (const item of shown.items) {
      const row = element('div', 'bar-row');
      row.append(element('span', 'bar-label', item.label));
      const track = element('span', 'bar-track');
      const bar = element('span', item.magnitude < 0 ? 'bar negative' : 'bar');
      bar.style.width = (Math.abs(item.magnitude) / largest * 100).toFixed(2) + '%';
      track.append(bar);
      row.append(track, element('span', 'bar-value', item.display));
      box.append(row);
    }
  }
  function pie(box, shown) {
    const sorted = shown.items.map(item => ({ ...item, size: Math.max(0, item.magnitude) })).sort((a, b) => b.size - a.size);
    const kept = sorted.slice(0, MAX_SLICES - (sorted.length > MAX_SLICES ? 1 : 0));
    const rest = sorted.slice(kept.length);
    if (rest.length > 0) kept.push({ label: rest.length + ' more', display: '', size: rest.reduce((sum, item) => sum + item.size, 0) });
    const total = kept.reduce((sum, item) => sum + item.size, 0) || 1;
    const chart = svg('svg', { viewBox: '-1 -1 2 2', class: 'pie-chart', 'aria-hidden': 'true', focusable: 'false' });
    let angle = -Math.PI / 2;
    kept.forEach((item, index) => {
      const sweep = item.size / total * 2 * Math.PI;
      const shade = 'slice-' + (index % MAX_SLICES);
      if (sweep >= 2 * Math.PI - 1e-9) chart.append(svg('circle', { cx: 0, cy: 0, r: 1, class: shade }));
      else if (sweep > 0) {
        const [x1, y1, x2, y2] = [Math.cos(angle), Math.sin(angle), Math.cos(angle + sweep), Math.sin(angle + sweep)];
        chart.append(svg('path', { d: `M0 0L${x1.toFixed(4)} ${y1.toFixed(4)}A1 1 0 ${sweep > Math.PI ? 1 : 0} 1 ${x2.toFixed(4)} ${y2.toFixed(4)}Z`, class: shade }));
      }
      angle += sweep;
    });
    const legend = element('ul', 'legend');
    kept.forEach((item, index) => {
      const entry = element('li');
      entry.append(element('span', 'swatch slice-' + (index % MAX_SLICES)), element('span', 'bar-label', item.label),
        element('span', 'bar-value', item.display || Math.round(item.size / total * 100) + '%'));
      legend.append(entry);
    });
    box.append(chart, legend);
  }
  // A line chart in a stretched viewBox; text stays in HTML so it never distorts.
  function curve(box, segments, xLow, xHigh, items, ends, yLabels) {
    const ys = segments.flat().map(point => point[1]);
    const low = yLabels ? 0 : Math.min(...ys), high = yLabels ? 1 : Math.max(...ys);
    const span = high - low || 1, width = xHigh - xLow || 1;
    const frame = element('div', 'plot');
    const values = element('div', 'plot-y');
    values.append(element('span', '', yLabels ? yLabels[1] : items.reduce((a, b) => (b.magnitude > a.magnitude ? b : a)).display),
      element('span', '', yLabels ? yLabels[0] : items.reduce((a, b) => (b.magnitude < a.magnitude ? b : a)).display));
    const area = svg('svg', { viewBox: '0 0 1000 1000', preserveAspectRatio: 'none', class: 'plot-area', 'aria-hidden': 'true', focusable: 'false' });
    if (low < 0 && high > 0) {
      const zero = (1000 - (0 - low) / span * 1000).toFixed(1);
      area.append(svg('line', { x1: 0, x2: 1000, y1: zero, y2: zero, class: 'rule' }));
    }
    for (const segment of segments) {
      if (segment.length === 0) continue;
      const points = segment.map(([x, y]) => ((x - xLow) / width * 1000).toFixed(1) + ',' + (1000 - (y - low) / span * 1000).toFixed(1)).join(' ');
      area.append(svg(segment.length === 1 ? 'circle' : 'polyline', segment.length === 1
        ? { cx: points.split(',')[0], cy: points.split(',')[1], r: 6, class: 'dot' } : { points, class: 'stroke' }));
    }
    const x = element('div', 'plot-x');
    x.append(element('span', '', ends[0]), element('span', '', ends[1]));
    frame.append(values, area, x);
    box.append(frame);
  }
  function plot(box, shown) {
    const g = globalThis.CalcShare.LIMITS.plotGrid;
    const starts = shown.segments.length > 0 && shown.segments[0] === 0 ? shown.segments : [0, ...shown.segments];
    const segments = starts.map((start, index) => shown.points.slice(start, starts[index + 1] ?? shown.points.length)
      .map(([x, y]) => [x, Math.max(-0.02 * g, Math.min(1.02 * g, y)) / g]));
    curve(box, segments, 0, g, null, [shown.frame[0], shown.frame[1]], [shown.frame[2], shown.frame[3]]);
  }

  function line(entry, index) {
    const row = element('li', 'line' + (entry.result === null ? '' : ' answered'));
    row.append(entry.source.length === 0 ? element('span', 'source empty') : linked('source', entry.source));
    if (entry.result !== null) {
      const answer = element('span', 'answer');
      if (entry.explanation !== null) {
        const id = 'explanation-' + index;
        const button = element('button', 'result', entry.result);
        button.type = 'button';
        button.setAttribute('aria-expanded', 'false');
        button.setAttribute('aria-controls', id);
        button.title = 'Show explanation';
        const details = element('div', 'explanation', entry.explanation);
        details.id = id;
        details.hidden = true;
        details.setAttribute('role', 'region');
        details.setAttribute('aria-label', 'Line ' + (index + 1) + ' explanation');
        button.addEventListener('click', () => toggle(button, details));
        answer.append(button);
        row.append(answer, details);
      } else {
        answer.append(element('span', entry.error ? 'result error' : 'result', entry.result));
        row.append(answer);
      }
    }
    if (entry.figure !== null) row.append(figure(entry.figure));
    return row;
  }
  function toggle(button, details, open = details.hidden) {
    details.hidden = !open;
    button.setAttribute('aria-expanded', String(open));
    button.title = open ? 'Hide explanation' : 'Show explanation';
  }

  function notice(message) {
    const sheet = document.getElementById('sheet');
    sheet.replaceChildren(element('p', 'notice', message));
    document.getElementById('title').textContent = 'Calculator';
    document.getElementById('date').textContent = '';
    document.title = 'Calculator sheet';
  }
  function render(snapshot) {
    document.documentElement.dataset.theme = snapshot.theme;
    document.getElementById('title').textContent = snapshot.title;
    const date = document.getElementById('date');
    date.textContent = snapshot.date === null ? '' : 'Snapshot ' + snapshot.date;
    if (snapshot.date !== null) date.dateTime = snapshot.date;
    document.title = snapshot.title + ' · Calculator';
    const list = element('ol', 'lines');
    snapshot.lines.forEach((entry, index) => list.append(line(entry, index)));
    document.getElementById('sheet').replaceChildren(list);
  }
  async function load() {
    const current = ++generation;
    if (location.hash.length <= 1) { notice('No sheet in this link.'); return; }
    try {
      const snapshot = await decode(location.hash);
      if (current === generation) render(snapshot);
    } catch (error) {
      if (current !== generation) return;
      notice(error instanceof globalThis.CalcShare.ShareError ? error.message + '.' : 'Damaged link.');
    }
  }

  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    const open = document.activeElement?.closest?.('.line')?.querySelector('.result[aria-expanded="true"]');
    if (!open) return;
    toggle(open, document.getElementById(open.getAttribute('aria-controls')), false);
    open.focus();
  });
  window.addEventListener('hashchange', load);
  load();
})();
