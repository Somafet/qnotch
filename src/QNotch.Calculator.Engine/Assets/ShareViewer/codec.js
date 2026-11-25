// Calc share-link decoder. Classic script (works from file://), no DOM access, no network.
// Format and limits mirror src/Calc.Documents/ShareLink.cs; tests/fixtures/share-links-v1.json binds both.
(function (root) {
  'use strict';

  const LIMITS = Object.freeze({
    fragmentCharacters: 65536,
    payloadBytes: 1048576,
    lines: 20000,
    sourceCharacters: 200000,
    title: 80,
    result: 8192,
    explanation: 32768,
    description: 1024,
    label: 64,
    items: 512,
    points: 512,
    plotGrid: 4096,
  });
  const PREFIX = 'c1.';

  class ShareError extends Error {
    constructor(message) { super(message); this.name = 'ShareError'; }
  }
  const damaged = () => new ShareError('Damaged link');

  function base64UrlBytes(text) {
    if (text.length === 0 || text.length % 4 === 1 || !/^[A-Za-z0-9_-]+$/.test(text)) throw damaged();
    const padded = text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - text.length % 4) % 4);
    let binary;
    try { binary = atob(padded); } catch { throw damaged(); }
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // Streams the inflation and stops as soon as the output passes the limit, so a small link cannot expand without bound.
  async function inflate(bytes, limit) {
    if (typeof DecompressionStream !== 'function') throw new ShareError('This browser cannot open shared calculator sheets');
    let stream;
    try { stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw')); }
    catch { throw new ShareError('This browser cannot open shared calculator sheets'); }
    const reader = stream.getReader();
    const chunks = [];
    let total = 0;
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > limit) {
          reader.cancel().catch(() => {});
          throw new ShareError('Link expands beyond the size limit');
        }
        chunks.push(value);
      }
    } catch (error) {
      if (error instanceof ShareError) throw error;
      throw damaged();
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.byteLength; }
    return out;
  }

  const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  function keys(value, allowed, required) {
    if (!isObject(value)) throw damaged();
    for (const key of Object.keys(value)) if (!allowed.includes(key)) throw damaged();
    for (const key of required) if (!Object.prototype.hasOwnProperty.call(value, key)) throw damaged();
  }
  function text(value, limit) {
    if (typeof value !== 'string' || value.length > limit) throw damaged();
    return value;
  }
  function optionalText(owner, key, limit) {
    return Object.prototype.hasOwnProperty.call(owner, key) ? text(owner[key], limit) : null;
  }
  const integer = (value, low, high) => {
    if (!Number.isInteger(value) || value < low || value > high) throw damaged();
    return value;
  };

  function figure(value) {
    if (!isObject(value)) throw damaged();
    const kind = value.kind;
    if (kind === 'plot') {
      keys(value, ['kind', 'desc', 'frame', 'pts', 'seg'], ['kind', 'desc', 'frame', 'pts', 'seg']);
      if (!Array.isArray(value.frame) || value.frame.length !== 4) throw damaged();
      if (!Array.isArray(value.pts) || value.pts.length === 0 || value.pts.length > LIMITS.points) throw damaged();
      if (!Array.isArray(value.seg) || value.seg.length > LIMITS.points) throw damaged();
      const g = LIMITS.plotGrid;
      const points = value.pts.map(point => {
        if (!Array.isArray(point) || point.length !== 2) throw damaged();
        return Object.freeze([integer(point[0], -g, 2 * g), integer(point[1], -g, 2 * g)]);
      });
      const segments = value.seg.map(start => integer(start, 0, points.length - 1));
      for (let i = 1; i < segments.length; i++) if (segments[i] <= segments[i - 1]) throw damaged();
      return Object.freeze({ kind, description: text(value.desc, LIMITS.description), frame: Object.freeze(value.frame.map(item => text(item, LIMITS.label))),
        points: Object.freeze(points), segments: Object.freeze(segments) });
    }
    if (kind !== 'bar' && kind !== 'pie' && kind !== 'trend') throw damaged();
    keys(value, ['kind', 'desc', 'total', 'items'], ['kind', 'desc', 'items']);
    if (!Array.isArray(value.items) || value.items.length === 0 || value.items.length > LIMITS.items) throw damaged();
    const items = value.items.map(item => {
      if (!Array.isArray(item) || item.length !== 3 || typeof item[1] !== 'number' || !Number.isFinite(item[1])) throw damaged();
      return Object.freeze({ label: text(item[0], LIMITS.label), magnitude: item[1], display: text(item[2], LIMITS.label) });
    });
    return Object.freeze({ kind, description: text(value.desc, LIMITS.description), total: optionalText(value, 'total', LIMITS.label), items: Object.freeze(items) });
  }

  /** Validates a parsed payload and returns a frozen, normalized snapshot. Unknown keys, types or versions are rejected. */
  function validate(payload) {
    keys(payload, ['v', 'title', 'theme', 'date', 'lines'], ['v', 'title', 'theme', 'lines']);
    if (payload.v !== 1) throw new ShareError('Unsupported link version');
    const title = text(payload.title, LIMITS.title);
    if (title.length === 0) throw damaged();
    if (payload.theme !== 'light' && payload.theme !== 'dark') throw damaged();
    const date = optionalText(payload, 'date', 10);
    if (date !== null && !validDate(date)) throw damaged();
    if (!Array.isArray(payload.lines) || payload.lines.length === 0 || payload.lines.length > LIMITS.lines) throw damaged();
    let sourceCharacters = 0;
    const lines = payload.lines.map(line => {
      keys(line, ['s', 'r', 'err', 'x', 'fig'], ['s']);
      const source = text(line.s, LIMITS.sourceCharacters);
      if (/[\r\n]/.test(source)) throw damaged();
      sourceCharacters += source.length;
      const result = optionalText(line, 'r', LIMITS.result);
      if (Object.prototype.hasOwnProperty.call(line, 'err') && line.err !== true) throw damaged();
      const error = line.err === true;
      const explanation = optionalText(line, 'x', LIMITS.explanation);
      const shown = Object.prototype.hasOwnProperty.call(line, 'fig') ? figure(line.fig) : null;
      if (result === null && (error || explanation !== null || shown !== null)) throw damaged();
      if (error && (explanation !== null || shown !== null)) throw damaged();
      return Object.freeze({ source, result, error, explanation, figure: shown });
    });
    if (sourceCharacters > LIMITS.sourceCharacters) throw damaged();
    return Object.freeze({ version: 1, title, theme: payload.theme, date, lines: Object.freeze(lines) });
  }
  function validDate(value) {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (!match) return false;
    const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
    const date = new Date(Date.UTC(year, month - 1, day));
    return year >= 1 && date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day;
  }

  /** Decodes a location hash ("#c1.…"), a bare fragment or a full link. */
  async function decode(link) {
    if (typeof link !== 'string') throw damaged();
    const hash = link.indexOf('#');
    const fragment = hash >= 0 ? link.slice(hash + 1) : link;
    if (fragment.length === 0) throw new ShareError('No sheet in this link');
    if (fragment.length > LIMITS.fragmentCharacters) throw new ShareError('Link too large');
    if (!fragment.startsWith(PREFIX)) throw new ShareError('Unsupported link version');
    const json = await inflate(base64UrlBytes(fragment.slice(PREFIX.length)), LIMITS.payloadBytes);
    let payload;
    try { payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(json)); } catch { throw damaged(); }
    return validate(payload);
  }

  // Only absolute http(s) URLs become links; trailing sentence punctuation stays text. Everything else is plain text.
  const URL_PATTERN = /\bhttps?:\/\/[^\s<>"'`]+/gi;
  function linkTokens(value) {
    const tokens = [];
    let last = 0;
    for (const match of value.matchAll(URL_PATTERN)) {
      let candidate = match[0];
      while (/[.,;:!?)\]}]$/.test(candidate)) candidate = candidate.slice(0, -1);
      const href = safeHref(candidate);
      if (href === null) continue;
      if (match.index > last) tokens.push({ text: value.slice(last, match.index) });
      tokens.push({ text: candidate, href });
      last = match.index + candidate.length;
    }
    if (last < value.length || tokens.length === 0) tokens.push({ text: value.slice(last) });
    return tokens;
  }
  function safeHref(candidate) {
    let url;
    try { url = new URL(candidate); } catch { return null; }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    if (url.username || url.password) return null;
    return url.href;
  }

  root.CalcShare = Object.freeze({ LIMITS, PREFIX, ShareError, decode, validate, linkTokens, safeHref });
})(globalThis);
