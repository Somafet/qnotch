// Phone sharing's QR code, for the demo and the feature card. In the app the code opens a page served by your PC; the site
// has no PC to serve from, so its code goes somewhere else.
// Made with the app's encoder: dotnet run --project tests/QNotch.PhoneShareTests -- --dump "https://www.youtube.com/watch?v=dQw4w9WgXcQ" -1
// One word per row, in hex: 33 modules padded to 36 bits.
const MODULES = 'fe5a3d3f8 82392c208 ba9316ae8 bae025ae8 ba87ca2e8 82ae53a08 feaaaabf8 00aa9f000 be6e533e0 34f6fb370 23bfc2cb0 ' +
  'a514796e0 c36b9fc50 ccf564a38 a2038e670 750f06fe0 af0f62dc8 bc26b7f68 37152c5b0 e5158f7f0 d691244d8 e5cfce568 ' +
  '8322564d0 919c9de38 9af0d2fc8 00f0db8b8 fe5bc3aa0 82ab718e8 bad98efd0 baab254e8 baf3cff20 8225062e0 fee743950';

/** Dark modules on white with the four-module quiet zone, one rectangle per dark run, like QrImage in the app. */
function qrSvg(hexRows: string) {
  const words = hexRows.split(' '), n = words.length, full = n + 8;
  let d = '';
  words.forEach((word, y) => {
    const row = [...word].map(h => parseInt(h, 16).toString(2).padStart(4, '0')).join('').slice(0, n);
    for (const run of row.matchAll(/1+/g)) d += `M${run.index + 4} ${y + 4}h${run[0].length}v1h-${run[0].length}z`;
  });
  return `<svg viewBox="0 0 ${full} ${full}" shape-rendering="crispEdges" role="img" aria-label="QR code with the sharing link">` +
    `<rect width="${full}" height="${full}" fill="#fff"/><path d="${d}" fill="#000"/></svg>`;
}

export const shareQr = qrSvg(MODULES);
