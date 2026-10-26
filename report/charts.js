(function () {
  const D = JSON.parse(document.getElementById('data').textContent);
  const has = id => document.getElementById(id) != null;
  // Every word the charts show comes from D.words (build.py CHART_WORDS), in the page's language.
  const T = D.words;
  // fill(T.outcomeTip, a, b, …): the arguments in place of {0}, {1}, …
  const fill = (s, ...a) => s.replace(/\{(\d)\}/g, (m, i) => a[+i]);
  // Room for the row labels left of a horizontal chart: about 7 px a Latin letter, 12.5 px a Chinese one.
  const labelRoom = (labels, min) => Math.max(min, 16 + Math.max(0, ...labels.map(s =>
    [...String(s)].reduce((w, c) => w + (c.charCodeAt(0) > 0x2e80 ? 12.5 : 6.9), 0))));
  const NS = 'http://www.w3.org/2000/svg';
  const tip = document.getElementById('tip');
  function el(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function txt(parent, x, y, s, cls, anchor) {
    const t = el('text', { x: x, y: y, class: cls || 'ax', 'text-anchor': anchor || 'start' }, parent);
    t.textContent = s;
    return t;
  }
  function showTip(e, s) {
    tip.textContent = s;
    tip.hidden = false;
    const r = tip.getBoundingClientRect();
    let x = (e.clientX || 0) + 14, y = (e.clientY || 0) + 14;
    if (e.type === 'focus') { const b = e.target.getBoundingClientRect(); x = b.right + 8; y = b.top; }
    if (x + r.width > window.innerWidth - 8) x = window.innerWidth - r.width - 8;
    if (y + r.height > window.innerHeight - 8) y = y - r.height - 24;
    tip.style.left = x + 'px';
    tip.style.top = y + 'px';
  }
  function hideTip() { tip.hidden = true; }
  function hover(node, s) {
    node.setAttribute('tabindex', '0');
    node.setAttribute('aria-label', s);
    node.classList.add('mark');
    node.addEventListener('mousemove', e => showTip(e, s));
    node.addEventListener('mouseleave', hideTip);
    node.addEventListener('focus', e => showTip(e, s));
    node.addEventListener('blur', hideTip);
  }
  function legend(id, series) {
    const host = document.getElementById(id);
    if (!host) return;
    series.forEach(s => {
      const span = document.createElement('span');
      const i = document.createElement('i');
      if (s.square) i.className = 'sq';
      i.style.background = 'var(' + s.color + ')';
      span.appendChild(i);
      span.appendChild(document.createTextNode(s.label));
      host.appendChild(span);
    });
  }
  function table(id, head, rows, numFrom) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const t = document.createElement('table');
    const tr = document.createElement('tr');
    head.forEach((h, i) => { const th = document.createElement('th'); th.textContent = h; if (i >= (numFrom || 1)) th.className = 'num'; tr.appendChild(th); });
    const thead = document.createElement('thead'); thead.appendChild(tr); t.appendChild(thead);
    const tb = document.createElement('tbody');
    rows.forEach(r => {
      const row = document.createElement('tr');
      r.forEach((c, i) => {
        const td = document.createElement('td');
        if (c && typeof c === 'object') { td.textContent = c.text; if (c.cls) td.className = c.cls; }
        else td.textContent = c;
        if (i >= (numFrom || 1)) td.classList.add('num');
        row.appendChild(td);
      });
      tb.appendChild(row);
    });
    t.appendChild(tb);
    host.appendChild(t);
  }
  function roundedBar(svg, x, y0, w, y1, color, label) {
    const top = Math.min(y0, y1), h = Math.abs(y0 - y1);
    const r = Math.min(4, h, w / 2);
    const d = 'M' + x + ',' + y0 + ' L' + x + ',' + (top + r) + ' Q' + x + ',' + top + ' ' + (x + r) + ',' + top +
      ' L' + (x + w - r) + ',' + top + ' Q' + (x + w) + ',' + top + ' ' + (x + w) + ',' + (top + r) + ' L' + (x + w) + ',' + y0 + ' Z';
    const p = el('path', { d: d, style: 'fill: var(' + color + ')' }, svg);
    if (label) hover(p, label);
    return p;
  }
  // Grouped vertical bars from zero; values labelled above.
  function bars(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = cfg.width || 520, H = cfg.height || 260, left = 44, right = 10, top = 20, bottom = 40;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const y = v => H - bottom - (v - (cfg.min || 0)) / (cfg.max - (cfg.min || 0)) * (H - top - bottom);
    cfg.ticks.forEach(t => {
      el('line', { x1: left, x2: W - right, y1: y(t), y2: y(t), class: t === (cfg.min || 0) ? 'base' : 'grid' }, svg);
      txt(svg, left - 8, y(t) + 4, cfg.fmt(t), 'ax', 'end');
    });
    const g = cfg.groups.length, k = cfg.series.length;
    const gw = (W - left - right) / g;
    const bw = Math.min(26, (gw - 18) / k), gap = 2;
    cfg.groups.forEach((grp, i) => {
      const x0 = left + i * gw + (gw - (k * bw + (k - 1) * gap)) / 2;
      txt(svg, left + i * gw + gw / 2, H - bottom + 20, grp.label, 'ax-l', 'middle');
      cfg.series.forEach((s, j) => {
        const v = grp.values[s.key];
        if (v == null) return;
        const bx = x0 + j * (bw + gap);
        roundedBar(svg, bx, y(cfg.min || 0), bw, y(Math.max(v, cfg.min || 0)), s.color, grp.label + ' · ' + s.label + T.colon + cfg.fmt(v, true));
        if (cfg.labels !== false) txt(svg, bx + bw / 2, y(Math.max(v, cfg.min || 0)) - 5, cfg.short ? cfg.short(v) : cfg.fmt(v), 'val', 'middle');
      });
    });
  }
  // One row per planner, one dot per scenario, a tick at the mean.
  function strip(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = labelRoom(cfg.rows.map(r => r.label), 150), right = 86, top = 8, rowH = 46;
    const H = top + cfg.rows.length * rowH + 28;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const x = v => left + (v - cfg.min) / (cfg.max - cfg.min) * (W - left - right);
    cfg.ticks.forEach(t => {
      el('line', { x1: x(t), x2: x(t), y1: top, y2: H - 24, class: 'grid' }, svg);
      txt(svg, x(t), H - 8, t + '%', 'ax', 'middle');
    });
    cfg.rows.forEach((r, i) => {
      const y0 = top + i * rowH, cy = y0 + rowH / 2;
      txt(svg, left - 12, cy + 4, r.label, 'ax-l', 'end');
      // Dots at (nearly) the same value spread up and down so each stays visible.
      const placed = [];
      r.points.forEach(p => {
        const near = placed.filter(q => Math.abs(q - p.v) < 0.8).length;
        placed.push(p.v);
        const off = (near % 2 ? -1 : 1) * Math.ceil(near / 2) * 3;
        const c = el('circle', { cx: x(Math.max(p.v, cfg.min)), cy: cy + off, r: 4.5, class: 'ring', style: 'fill: var(' + r.color + ')' }, svg);
        hover(c, p.tip);
      });
      el('line', { x1: x(r.mean), x2: x(r.mean), y1: y0 + 4, y2: y0 + rowH - 4, style: 'stroke: var(--fg); stroke-width: 2' }, svg);
      txt(svg, W - right + 12, cy + 4, T.mean + r.mean.toFixed(1) + '%', 'val', 'start');
    });
  }
  // One stacked bar per comparison: how many scenarios came out better, the
  // same, a trade-off or worse on two measures together (counts inside).
  function outcomes(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = labelRoom(cfg.rows.map(r => r.label), 190), right = 16, top = 8, rowH = 32;
    const H = top + cfg.rows.length * rowH + 28;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const max = Math.max.apply(null, cfg.rows.map(r => r.n));
    const x = v => left + v / max * (W - left - right);
    for (let t = 0; t <= max; t += cfg.step) {
      el('line', { x1: x(t), x2: x(t), y1: top, y2: H - 24, class: t === 0 ? 'base' : 'grid' }, svg);
      txt(svg, x(t), H - 8, String(t), 'ax', 'middle');
    }
    cfg.rows.forEach((r, i) => {
      const y0 = top + i * rowH, bh = 18, by = y0 + 7;
      txt(svg, left - 10, y0 + 20, r.label, 'ax-l', 'end');
      let acc = 0;
      cfg.parts.forEach(p => {
        const v = r[p.key] || 0;
        if (!v) return;
        const x0 = x(acc) + (acc ? 1 : 0), x1 = x(acc + v) - 1;
        const rect = el('rect', { x: x0, y: by, width: Math.max(1, x1 - x0), height: bh, rx: 3, style: 'fill: var(' + p.color + ')' }, svg);
        hover(rect, fill(T.outcomeTip, r.label, p.label, v, r.n));
        if (x1 - x0 >= 16) {
          const t = txt(svg, (x0 + x1) / 2, by + 13, String(v), 'val', 'middle');
          t.setAttribute('style', 'fill: var(' + (p.ink || '--surface') + '); pointer-events: none');
        }
        acc += v;
      });
    });
  }
  // Hero stats.
  const hs = document.getElementById('hero-stats');
  D.hero.forEach(s => {
    const d = document.createElement('div'); d.className = 'stat';
    const b = document.createElement('b'); b.textContent = s.value;
    const sp = document.createElement('span'); sp.textContent = s.label;
    d.append(b, sp); hs.appendChild(d);
  });

  const P = D.planners; // key -> { label, color }
  const main = D.mainSeries.map(k => ({ key: k, label: P[k].label, color: P[k].color, square: true }));
  // The series a grouped bar chart actually has data for.
  const present = groups => main.filter(s => groups.some(g => g.values[s.key] != null));
  const pctBars = (id, lg, groups, aria, extra) => {
    const series = present(groups);
    legend(lg, series);
    bars(id, Object.assign({ groups: groups, series: series, max: 100, ticks: [0, 25, 50, 75, 100],
      fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0), aria: aria }, extra || {}));
  };

  table('tb-overview', T.headOverview,
    D.overview.map(r => [r.label, r.best, r.quality, r.worst, r.legal, r.missing, r.time]));

  pctBars('ch-best', 'lg-best', D.byStage.best, T.ariaBest);
  const qs = present(D.byStage.quality);
  legend('lg-quality', qs);
  bars('ch-quality', { groups: D.byStage.quality, series: qs, min: D.byStage.qMin, max: 100,
    ticks: D.byStage.qTicks, fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0),
    aria: T.ariaQuality });

  table('tb-correct', T.headCorrect,
    D.correct.map(r => [r.label, r.illegal, r.pins, r.missing, r.placeable, r.det]));
  if (D.robust && D.robust.length) table('tb-robust', T.headRobust, D.robust);
  if (D.robustGroups && D.robustGroups.length) pctBars('ch-robust', 'lg-robust', D.robustGroups, T.ariaRobust, { width: 640 });
  if (D.robustMultiGroups && D.robustMultiGroups.length) {
    pctBars('ch-mrobust', 'lg-mrobust', D.robustMultiGroups, T.ariaMRobust, { width: 640, height: 230 });
  }
  if (D.wonders && D.wonders.length) {
    table('tb-wonders', T.headWonders,
      D.wonders.map(r => [r.label, r.wonders, r.legal, r.best, r.quality]));
  }
  if (D.wonderGroups && D.wonderGroups.length) {
    pctBars('ch-wonders', 'lg-wonders', D.wonderGroups, T.ariaWonders, { width: 640, height: 240 });
  }

  strip('ch-multi', { rows: D.strip.rows, min: D.strip.min, max: D.strip.max, ticks: D.strip.ticks,
    aria: T.ariaStrip });
  if (D.coverage && D.coverage.rows.length) {
    const parts = [{ key: 'better', label: T.better, color: '--good' }, { key: 'same', label: T.same, color: '--opt' },
      { key: 'tradeoff', label: T.tradeoff, color: '--warn' }, { key: 'worse', label: T.worse, color: '--bad' }];
    legend('lg-coverage', parts.map(p => ({ label: p.label, color: p.color, square: true })));
    outcomes('ch-coverage', { rows: D.coverage.rows, parts: parts, step: 2,
      aria: T.ariaCoverage });
    table('tb-coverage', D.coverage.head, D.coverage.table, 1);
  }
})();
