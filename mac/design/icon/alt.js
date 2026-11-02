// The two other icon ideas, for comparison with render.js (linked notes):
//   pen   = dark tile, frosted note card with blue bullets, blue pencil
//   paper = light tile, white paper with a warm top band, ruled lines, blue pencil
//   NODE_PATH=~/.npm-global/lib/node_modules node alt.js   ->  alt/<idea>/icon_<px>.png
const { chromium } = require('playwright');
const fs = require('fs');
const D = __dirname;

function squircle(cx, cy, half, n = 5, steps = 360) {
  let d = '';
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * 2 * Math.PI, c = Math.cos(t), s = Math.sin(t);
    d += (i ? 'L' : 'M') + (cx + half * Math.sign(c) * Math.abs(c) ** (2 / n)).toFixed(2) + ',' + (cy + half * Math.sign(s) * Math.abs(s) ** (2 / n)).toFixed(2);
  }
  return d + 'Z';
}
const TILE = squircle(512, 512, 412);

// A pencil lying along +x from its point at (0,0); placed with transform
function pencil(L, W, simple) {
  const h = W / 2, tipL = 120, ferr = 70, rub = 56;
  return `
  <defs>
    <linearGradient id="pBody" x1="0" y1="${-h}" x2="0" y2="${h}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#b9dcff"/><stop offset=".18" stop-color="#7cc0ff"/><stop offset=".34" stop-color="#5cb0ff"/>
      <stop offset=".36" stop-color="#3f8ff0"/><stop offset=".64" stop-color="#2f7be6"/><stop offset=".66" stop-color="#1f5fd6"/><stop offset="1" stop-color="#173f9a"/>
    </linearGradient>
    <linearGradient id="pWood" x1="0" y1="${-h}" x2="0" y2="${h}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fbe6c6"/><stop offset=".5" stop-color="#e9c48f"/><stop offset="1" stop-color="#b98a52"/></linearGradient>
    <linearGradient id="pMetal" x1="0" y1="${-h}" x2="0" y2="${h}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#f4f6fa"/><stop offset=".35" stop-color="#c3c9d4"/><stop offset=".7" stop-color="#8d95a4"/><stop offset="1" stop-color="#5d6472"/></linearGradient>
    <linearGradient id="pRub" x1="0" y1="${-h}" x2="0" y2="${h}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffd3da"/><stop offset=".5" stop-color="#f29aab"/><stop offset="1" stop-color="#c76579"/></linearGradient>
    <filter id="pShadow" filterUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000"><feGaussianBlur stdDeviation="14"/></filter>
  </defs>
  ${simple ? '' : `<rect x="20" y="${-h + 24}" width="${L}" height="${W}" rx="${h}" fill="#000" opacity=".35" filter="url(#pShadow)"/>`}
  <path d="M0,0 L${tipL},${-h} L${tipL},${h} Z" fill="url(#pWood)"/>
  <path d="M0,0 L${tipL * .3},${-h * .3} L${tipL * .3},${h * .3} Z" fill="#2a2e38"/>
  <rect x="${tipL - 1}" y="${-h}" width="${L - tipL - ferr - rub + 2}" height="${W}" fill="url(#pBody)"/>
  <path d="M${tipL},${-h} q-14,${h * .33} 0,${h * .66} q-14,${h * .67} 0,${h * 1.34}" fill="url(#pBody)"/>
  <rect x="${L - ferr - rub}" y="${-h}" width="${ferr}" height="${W}" fill="url(#pMetal)"/>
  ${simple ? '' : [0.25, 0.5, 0.75].map(f => `<rect x="${L - ferr - rub + ferr * f - 2}" y="${-h}" width="4" height="${W}" fill="#5d6472" opacity=".45"/>`).join('')}
  <path d="M${L - rub},${-h} h${rub - 18} a18,18 0 0 1 18,18 v${W - 36} a18,18 0 0 1 -18,18 h${-(rub - 18)} Z" fill="url(#pRub)"/>`;
}

// Idea "pen": dark tile + frosted note card + blue pencil
function pen(px) {
  const s = px <= 32, lw = s ? 30 : 18;
  const lines = [[0, 300, '#5cb0ff', true], [1, 230, '#5cb0ff', false], [2, 270, '#5cb0ff', false]]
    .map(([i, w, c, filled]) => {
      const y = 430 + i * 105;
      const dot = filled ? `<circle cx="336" cy="${y}" r="17" fill="${c}"/>` : `<circle cx="336" cy="${y}" r="14" fill="none" stroke="${c}" stroke-width="7"/>`;
      return `${dot}<rect x="384" y="${y - lw / 2}" width="${w}" height="${lw}" rx="${lw / 2}" fill="#fff" opacity="${i ? .55 : .85}"/>`;
    }).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="0 0 1024 1024">
  <defs>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-opacity=".32"/></filter>
    <clipPath id="tile"><path d="${TILE}"/></clipPath>
    <linearGradient id="bgG" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#262c3d"/><stop offset=".55" stop-color="#12151e"/><stop offset="1" stop-color="#06070b"/></linearGradient>
    <radialGradient id="glow" cx="470" cy="420" r="460" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#5b8cff" stop-opacity=".25"/><stop offset="1" stop-color="#5b8cff" stop-opacity="0"/></radialGradient>
    <linearGradient id="card" x1="0" y1="250" x2="0" y2="780" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity=".07"/></linearGradient>
    <linearGradient id="cardRim" x1="0" y1="250" x2="0" y2="780" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".5" stop-color="#fff" stop-opacity=".12"/><stop offset="1" stop-color="#fff" stop-opacity=".05"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity=".3"/><stop offset=".18" stop-color="#fff" stop-opacity=".06"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <filter id="cardSh" filterUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000"><feGaussianBlur stdDeviation="22"/></filter>
  </defs>
  <path d="${TILE}" fill="#06070b" filter="url(#drop)"/>
  <g clip-path="url(#tile)">
    <rect x="100" y="100" width="824" height="824" fill="url(#bgG)"/><rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
    <g transform="rotate(-6 490 520)">
      ${s ? '' : '<rect x="270" y="280" width="470" height="520" rx="56" fill="#000" opacity=".45" filter="url(#cardSh)"/>'}
      <rect x="260" y="250" width="470" height="520" rx="56" fill="url(#card)" stroke="url(#cardRim)" stroke-width="${s ? 8 : 4}"/>
      ${lines}
    </g>
    <g transform="translate(560 690) rotate(-50)">${pencil(470, 74, s)}</g>
  </g>
  <path d="${TILE}" fill="none" stroke="url(#rim)" stroke-width="${s ? 10 : 5}" clip-path="url(#tile)"/>
  </svg>`;
}

// Idea "paper": light tile + white paper sheet, warm top band, ruled lines, blue pencil
// mode: 'mac' = the tile; 'bg' / 'fg' = Android adaptive layers (108 dp canvas, 72 dp visible = the 824 tile)
function paper(px, mode = 'mac') {
  const s = px <= 32;
  const rules = [0, 1, 2, 3].map(i => {
    const y = 470 + i * 80;
    return `<rect x="296" y="${y}" width="${[380, 380, 380, 250][i]}" height="${s ? 14 : 5}" rx="3" fill="#c9ced8"/>` +
      (i < 3 && !s ? `<rect x="296" y="${y - 34}" width="${[300, 340, 200][i]}" height="16" rx="8" fill="#3a4152" opacity=".72"/>` : '');
  }).join('');
  const mac = mode === 'mac', box = mac ? '0 0 1024 1024' : '-106 -106 1236 1236';
  const sheet = `
    ${s ? '' : '<rect x="262" y="236" width="480" height="600" rx="44" fill="#1d2433" opacity=".22" filter="url(#sheetSh)"/>'}
    <rect x="250" y="210" width="480" height="600" rx="44" fill="url(#sheetG)"/>
    <g clip-path="url(#sheet)">
      <rect x="250" y="210" width="480" height="150" fill="url(#band)"/>
      ${s ? '' : '<rect x="250" y="356" width="480" height="4" fill="#c98a12" opacity=".35"/>'}
      ${s ? '' : Array.from({ length: 9 }, (_, i) => `<circle cx="${296 + i * 49}" cy="380" r="5" fill="#d6dae2"/>`).join('')}
      ${rules}
    </g>
    <rect x="250" y="210" width="480" height="600" rx="44" fill="none" stroke="#000" stroke-opacity=".06" stroke-width="2"/>
    <g transform="translate(590 660) rotate(-48)">${pencil(420, 74, s)}</g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${px}" height="${px}" viewBox="${box}">
  <defs>
    <filter id="drop" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-opacity=".28"/></filter>
    <clipPath id="tile"><path d="${TILE}"/></clipPath>
    <clipPath id="sheet"><rect x="250" y="210" width="480" height="600" rx="44"/></clipPath>
    <linearGradient id="bgG" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fdfdfe"/><stop offset="1" stop-color="#d9dde5"/></linearGradient>
    <linearGradient id="band" x1="0" y1="210" x2="0" y2="360" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffdf6b"/><stop offset="1" stop-color="#f7b52c"/></linearGradient>
    <linearGradient id="sheetG" x1="0" y1="210" x2="0" y2="810" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#f3f4f7"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset=".2" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#9aa1ae" stop-opacity=".35"/></linearGradient>
    <filter id="sheetSh" filterUnits="userSpaceOnUse" x="-2000" y="-2000" width="5000" height="5000"><feGaussianBlur stdDeviation="20"/></filter>
  </defs>
  ${mode === 'bg' ? '<rect x="-106" y="-106" width="1236" height="1236" fill="url(#bgG)"/>' : ''}
  ${mode === 'fg' ? `<g transform="translate(512 512) scale(.9) translate(-512 -512)">${sheet}</g>` : ''}
  ${mac ? `<path d="${TILE}" fill="#d9dde5" filter="url(#drop)"/>
  <g clip-path="url(#tile)">
    <rect x="100" y="100" width="824" height="824" fill="url(#bgG)"/>${sheet}
  </g>
  <path d="${TILE}" fill="none" stroke="url(#rim)" stroke-width="${s ? 10 : 5}" clip-path="url(#tile)"/>` : ''}
  </svg>`;
}

(async () => {
  const b = await chromium.launch();
  const pg = await b.newPage();
  for (const [name, fn] of [['pen', pen], ['paper', paper]]) {
    fs.mkdirSync(`${D}/alt/${name}`, { recursive: true });
    for (const px of [16, 32, 64, 128, 256, 512, 1024]) {
      await pg.setViewportSize({ width: px, height: px });
      await pg.setContent(`<html><body style="margin:0;background:transparent">${fn(px)}</body></html>`);
      await pg.screenshot({ path: `${D}/alt/${name}/icon_${px}.png`, omitBackground: true, clip: { x: 0, y: 0, width: px, height: px } });
    }
  }
  fs.mkdirSync(`${D}/alt/paper/android`, { recursive: true });
  for (const m of ['bg', 'fg']) {
    await pg.setViewportSize({ width: 432, height: 432 });
    await pg.setContent(`<html><body style="margin:0;background:transparent">${paper(432, m)}</body></html>`);
    await pg.screenshot({ path: `${D}/alt/paper/android/${m}-432.png`, omitBackground: true, clip: { x: 0, y: 0, width: 432, height: 432 } });
  }
  await b.close();
})();
