/* Which app the page describes: Windows or Mac. Base.astro picks one before the first paint (a ?os= link,
   then this tab's earlier choice, then the visitor's OS) and stores it as <html data-os>. Elements with
   .os-win or .os-mac show only for theirs; scripts listen for the 'qnotch:os' event. */

export type OS = 'win' | 'mac';

export const STORAGE_KEY = 'qnotch-os';

export const currentOS = (): OS => (document.documentElement.dataset.os === 'mac' ? 'mac' : 'win');
export const isMac = () => currentOS() === 'mac';

export function setOS(os: OS) {
  if (os === currentOS()) return;
  document.documentElement.dataset.os = os;
  try { sessionStorage.setItem(STORAGE_KEY, os); } catch { /* Switching still works without storage. */ }
  document.dispatchEvent(new CustomEvent<OS>('qnotch:os', { detail: os }));
}

export const onOS = (fn: (os: OS) => void) => document.addEventListener('qnotch:os', e => fn((e as CustomEvent<OS>).detail));
