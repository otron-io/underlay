// Apple macOS icon grid: 1024 canvas, 824 body inset by 100, continuous-corner (superellipse) shape.
function squirclePath(x, y, s, n = 5, steps = 360) {
  const r = s / 2, cx = x + r, cy = y + r;
  let d = '';
  for (let i = 0; i <= steps; i++) {
    const t = (i / steps) * Math.PI * 2;
    const c = Math.cos(t), sn = Math.sin(t);
    const px = cx + r * Math.sign(c) * Math.pow(Math.abs(c), 2 / n);
    const py = cy + r * Math.sign(sn) * Math.pow(Math.abs(sn), 2 / n);
    d += (i ? 'L' : 'M') + px.toFixed(2) + ' ' + py.toFixed(2);
  }
  return d + 'Z';
}
document.querySelectorAll('[data-squircle]').forEach(el => {
  const [x, y, s] = el.dataset.squircle.split(',').map(Number);
  el.style.clipPath = `path('${squirclePath(x, y, s)}')`;
});

// ?bleed renders the artwork full-bleed (square, no mask or shadow) and lets macOS apply its own mask.
if (new URLSearchParams(location.search).has('bleed')) {
  const scale = 1024 / 824;
  document.querySelectorAll('.shadow').forEach(el => { el.style.filter = 'none'; el.style.transform = `scale(${scale})`; });
  document.querySelectorAll('[data-squircle]').forEach(el => { el.style.clipPath = 'none'; });
}
