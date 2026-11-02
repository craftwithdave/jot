// Icon idea A (NOT used; the user picked "paper" in alt.js on 2026-10-18): three linked notes (blue, white, purple), drawn Apple-style.
// Renders every PNG from the same SVG (no downscaling), so small sizes stay sharp:
//   NODE_PATH=~/.npm-global/lib/node_modules node render.js
// Out: png/icon_<px>.png (Mac sizes), android/bg-432.png + fg-432.png, preview.png
// Then: python3 mkicns.py  ->  ../../Resources/AppIcon.icns
const { chromium } = require('playwright');
const fs = require('fs');
const D = __dirname;

// Notes in Android "dp" space (108 x 108, same triangle as the old vector icon)
const NOTES = [
  { x: 54, y: 37, r: 9.2, hi: '#d4ecff', base: '#5cb0ff', lo: '#1f5fd6' },   // blue (top)
  { x: 37.5, y: 67, r: 7.4, hi: '#ffffff', base: '#eef1f6', lo: '#9aa3b4' },  // white (bottom left)
  { x: 72, y: 63, r: 6.6, hi: '#f6e8ff', base: '#c792ea', lo: '#7a4bc4' },    // purple (bottom right)
];
const LINKS = [[0, 1], [0, 2], [1, 2]];

// macOS-style continuous corner: superellipse, n = 5
function squircle(cx, cy, half, n = 5, steps = 360) {
  let d = '';
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * 2 * Math.PI, c = Math.cos(t), s = Math.sin(t);
    const x = cx + half * Math.sign(c) * Math.abs(c) ** (2 / n);
    const y = cy + half * Math.sign(s) * Math.abs(s) ** (2 / n);
    d += (i ? 'L' : 'M') + x.toFixed(2) + ',' + y.toFixed(2);
  }
  return d + 'Z';
}

// The background, filling the box (x, y, w) in canvas units
function bg(x, y, w, clip) {
  return `
  <defs>
    <linearGradient id="bgG" x1="0" y1="${y}" x2="0" y2="${y + w}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#262c3d"/><stop offset=".55" stop-color="#12151e"/><stop offset="1" stop-color="#06070b"/>
    </linearGradient>
    <radialGradient id="glow" cx="${x + w * .5}" cy="${y + w * .38}" r="${w * .55}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#5b8cff" stop-opacity=".22"/><stop offset="1" stop-color="#5b8cff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="${y}" x2="0" y2="${y + w}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity=".30"/><stop offset=".18" stop-color="#fff" stop-opacity=".06"/>
      <stop offset=".85" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#fff" stop-opacity=".08"/>
    </linearGradient>
    <filter id="noise" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="7"/>
      <feColorMatrix values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 .05 0"/>
    </filter>
    ${clip ? `<clipPath id="tile"><path d="${clip}"/></clipPath>` : ''}
  </defs>
  <g ${clip ? 'clip-path="url(#tile)"' : ''}>
    <rect x="${x}" y="${y}" width="${w}" height="${w}" fill="url(#bgG)"/>
    <rect x="${x}" y="${y}" width="${w}" height="${w}" fill="url(#glow)"/>
    <rect x="${x}" y="${y}" width="${w}" height="${w}" filter="url(#noise)"/>
  </g>`;
}

// The notes + links; k = canvas units per dp, (ox, oy) = where dp (0,0) lands; simple = small-size version
function notes(k, ox, oy, simple) {
  const P = n => [ox + n.x * k, oy + n.y * k, n.r * k];
  let defs = '', body = '';
  // links: coloured from one note to the other, a soft glow under a crisp line
  const lw = (simple ? 4.2 : 2.4) * k;
  LINKS.forEach(([a, b], i) => {
    const [x1, y1] = P(NOTES[a]), [x2, y2] = P(NOTES[b]);
    defs += `<linearGradient id="l${i}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${NOTES[a].base}"/><stop offset="1" stop-color="${NOTES[b].base}"/></linearGradient>`;
    if (!simple) body += `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="url(#l${i})" stroke-width="${lw * 3}" stroke-linecap="round" opacity=".35" filter="url(#blur)"/>`;
    body += `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="url(#l${i})" stroke-width="${lw}" stroke-linecap="round" opacity="${simple ? .9 : .8}"/>`;
  });
  NOTES.forEach((n, i) => {
    const [cx, cy, r] = P(n);
    defs += `<radialGradient id="s${i}" cx="${cx - r * .32}" cy="${cy - r * .38}" r="${r * 1.45}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${n.hi}"/><stop offset=".45" stop-color="${n.base}"/><stop offset="1" stop-color="${n.lo}"/></radialGradient>`;
    if (!simple) {
      body += `<circle cx="${cx}" cy="${cy}" r="${r * 1.9}" fill="${n.base}" opacity="${i === 1 ? .1 : .26}" filter="url(#halo)"/>`;          // coloured glow
      body += `<ellipse cx="${cx}" cy="${cy + r * .55}" rx="${r * .95}" ry="${r * .7}" fill="#000" opacity=".55" filter="url(#blur)"/>`; // contact shadow
    }
    body += `<circle cx="${cx}" cy="${cy}" r="${r}" fill="url(#s${i})"/>`;
    if (!simple) {
      defs += `<radialGradient id="h${i}" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>`;
      body += `<ellipse cx="${cx - r * .3}" cy="${cy - r * .42}" rx="${r * .46}" ry="${r * .3}" fill="url(#h${i})" transform="rotate(-25 ${cx - r * .3} ${cy - r * .42})"/>`; // specular
      body += `<circle cx="${cx}" cy="${cy}" r="${r - k * .25}" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="${k * .5}"/>`;  // edge light
    }
  });
  return `<defs>${defs}
    <filter id="blur" filterUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000"><feGaussianBlur stdDeviation="${1.4 * k}"/></filter>
    <filter id="halo" filterUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000"><feGaussianBlur stdDeviation="${3 * k}"/></filter></defs>${body}`;
}

// The Mac icon at `px` pixels (1024 grid: 824 tile at offset 100, shadow inside the canvas)
function mac(px) {
  const simple = px <= 32;
  const tile = squircle(512, 512, 412);
  const k = 11.2, ox = 512 - 54.5 * k, oy = 512 - 55.5 * k;   // triangle centred on the tile
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
    <defs><filter id="drop" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".32"/></filter></defs>
    <path d="${tile}" fill="#06070b" filter="url(#drop)"/>
    ${bg(100, 100, 824, tile)}
    <g clip-path="url(#tile)">${notes(k, ox, oy, simple)}</g>
    <path d="${tile}" fill="none" stroke="url(#rim)" stroke-width="${simple ? 10 : 5}" clip-path="url(#tile)"/>
  </svg>`;
}

// Android adaptive layers, 432 px = 108 dp; notes stay inside the 66 dp safe circle
const andBg = () => `<svg xmlns="http://www.w3.org/2000/svg" width="432" height="432" viewBox="0 0 432 432">${bg(0, 0, 432)}</svg>`;
const andFg = () => `<svg xmlns="http://www.w3.org/2000/svg" width="432" height="432" viewBox="0 0 432 432">${notes(4, 216 - 54.5 * 4, 216 - 55.5 * 4, false)}</svg>`;

(async () => {
  for (const d of ['png', 'android']) fs.mkdirSync(`${D}/${d}`, { recursive: true });
  const b = await chromium.launch();
  const pg = await b.newPage();
  const shot = async (svg, px, path) => {
    await pg.setViewportSize({ width: px, height: px });
    await pg.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    await pg.screenshot({ path, omitBackground: true, clip: { x: 0, y: 0, width: px, height: px } });
  };
  for (const px of [16, 32, 64, 128, 256, 512, 1024]) await shot(mac(px), px, `${D}/png/icon_${px}.png`);
  await shot(andBg(), 432, `${D}/android/bg-432.png`);
  await shot(andFg(), 432, `${D}/android/fg-432.png`);

  // contact sheet: Mac sizes on a light and a dark desktop, Android circle + squircle masks
  const uri = f => 'data:image/png;base64,' + fs.readFileSync(f).toString('base64');
  const img = px => `<img src="${uri(`${D}/png/icon_${px}.png`)}" width="${px}" height="${px}" style="margin:0 14px;vertical-align:bottom">`;
  const row = (bgc, fg) => `<div style="background:${bgc};padding:24px;color:${fg};font:13px -apple-system,sans-serif">
    ${img(512)}${[256, 128, 64, 32, 16].map(img).join('')}</div>`;
  const and = r => `<div style="width:192px;height:192px;border-radius:${r};overflow:hidden;display:inline-block;margin:20px;position:relative">
    <img src="${uri(`${D}/android/bg-432.png`)}" style="position:absolute;width:288px;left:-48px;top:-48px">
    <img src="${uri(`${D}/android/fg-432.png`)}" style="position:absolute;width:288px;left:-48px;top:-48px"></div>`;
  await pg.setViewportSize({ width: 1240, height: 800 });
  await pg.setContent(`<html><body style="margin:0">${row('linear-gradient(135deg,#e9e4f0,#c9d6ea)')}${row('linear-gradient(135deg,#1d2433,#3a2f4a)')}
    <div style="background:#202124;padding:10px">${and('50%')}${and('30%')}</div></body></html>`);
  await pg.waitForLoadState('load');
  await pg.screenshot({ path: `${D}/preview.png`, fullPage: true });
  await b.close();
})();
