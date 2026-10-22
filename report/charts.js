(function () {
  const D = JSON.parse(document.getElementById('data').textContent);
  const has = id => document.getElementById(id) != null;
  // The English page (D.lang "en") has sections 1-6 only: just the time chart's words differ.
  const EN = D.lang === 'en';
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
        roundedBar(svg, bx, y(cfg.min || 0), bw, y(Math.max(v, cfg.min || 0)), s.color, grp.label + ' · ' + s.label + '：' + cfg.fmt(v, true));
        if (cfg.labels !== false) txt(svg, bx + bw / 2, y(Math.max(v, cfg.min || 0)) - 5, cfg.short ? cfg.short(v) : cfg.fmt(v), 'val', 'middle');
      });
    });
  }
  // Scatter: our gain (x) vs a competitor's (y), with the y = x line.
  function scatter(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 420, H = 380, left = 46, right = 14, top = 14, bottom = 44;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const max = cfg.max, min = cfg.min || 0;
    const x = v => left + (v - min) / (max - min) * (W - left - right);
    const y = v => H - bottom - (v - min) / (max - min) * (H - top - bottom);
    cfg.ticks.forEach(t => {
      el('line', { x1: x(t), x2: x(t), y1: top, y2: H - bottom, class: 'grid' }, svg);
      el('line', { x1: left, x2: W - right, y1: y(t), y2: y(t), class: 'grid' }, svg);
      txt(svg, x(t), H - bottom + 16, t, 'ax', 'middle');
      txt(svg, left - 8, y(t) + 4, t, 'ax', 'end');
    });
    el('line', { x1: x(min), y1: y(min), x2: x(max), y2: y(max), class: 'diag' }, svg);
    txt(svg, (left + W - right) / 2, H - 6, cfg.xLabel || '本模组标准档的加成', 'ax-l', 'middle');
    const ty = txt(svg, 14, (top + H - bottom) / 2, cfg.yLabel, 'ax-l', 'middle');
    ty.setAttribute('transform', 'rotate(-90 14 ' + ((top + H - bottom) / 2) + ')');
    // Jitter identical points a little so stacked scenarios stay visible.
    const seen = {};
    cfg.points.forEach(p => {
      const k = p.x + ',' + p.y;
      const n = seen[k] = (seen[k] || 0) + 1;
      const off = (n - 1) * 3.2;
      const c = el('circle', { cx: x(p.x) + off, cy: y(p.y) - off * 0.6, r: 5, class: 'ring',
        style: 'fill: var(' + (p.bad ? '--bad' : cfg.color) + ')' }, svg);
      hover(c, p.label);
    });
  }
  // A horizontal bar from x0, rounded at its data end.
  function hpath(x0, by, w, bh) {
    const rr = Math.min(4, w / 2, bh / 2);
    return 'M' + x0 + ',' + by + ' L' + (x0 + w - rr) + ',' + by + ' Q' + (x0 + w) + ',' + by + ' ' + (x0 + w) + ',' + (by + rr) +
      ' L' + (x0 + w) + ',' + (by + bh - rr) + ' Q' + (x0 + w) + ',' + (by + bh) + ' ' + (x0 + w - rr) + ',' + (by + bh) + ' L' + x0 + ',' + (by + bh) + ' Z';
  }
  // One labelled horizontal bar per row, linear scale from 0.
  function hlist(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = 210, right = 50, top = 8, rowH = 30;
    const H = top + cfg.rows.length * rowH + 28;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const x = v => left + v / cfg.max * (W - left - right);
    cfg.ticks.forEach(t => {
      el('line', { x1: x(t), x2: x(t), y1: top, y2: H - 24, class: t === 0 ? 'base' : 'grid' }, svg);
      txt(svg, x(t), H - 8, cfg.fmt(t), 'ax', 'middle');
    });
    cfg.rows.forEach((r, i) => {
      const y0 = top + i * rowH, bh = 16, by = y0 + 7;
      txt(svg, left - 10, y0 + 19, r.label, 'ax-l', 'end');
      const w = Math.max(2, x(r.value) - left);
      const p = el('path', { d: hpath(left, by, w, bh), style: 'fill: var(' + r.color + ')' }, svg);
      hover(p, r.tip);
      txt(svg, left + w + 6, by + 12, cfg.fmt(r.value), 'val', 'start');
    });
  }
  // Paired comparison as a point with its 95% interval, against a reference line.
  function forest(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = 150, right = 24, top = 8, rowH = 32;
    const H = top + cfg.rows.length * rowH + 28;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const x = v => left + (v - cfg.min) / (cfg.max - cfg.min) * (W - left - right);
    cfg.ticks.forEach(t => {
      el('line', { x1: x(t), x2: x(t), y1: top, y2: H - 24, class: t === cfg.ref ? 'diag' : 'grid' }, svg);
      txt(svg, x(t), H - 8, t + '%', 'ax', 'middle');
    });
    cfg.rows.forEach((r, i) => {
      const cy = top + i * rowH + rowH / 2;
      txt(svg, left - 12, cy + 4, r.label, 'ax-l', 'end');
      const st = 'stroke: var(' + r.color + '); stroke-width: 2';
      el('line', { x1: x(r.lo), x2: x(r.hi), y1: cy, y2: cy, style: st }, svg);
      el('line', { x1: x(r.lo), x2: x(r.lo), y1: cy - 5, y2: cy + 5, style: st }, svg);
      el('line', { x1: x(r.hi), x2: x(r.hi), y1: cy - 5, y2: cy + 5, style: st }, svg);
      const c = el('circle', { cx: x(r.value), cy: cy, r: 6, class: 'ring', style: 'fill: var(' + r.color + ')' }, svg);
      hover(c, r.tip);
    });
  }
  // One row per planner, one dot per scenario, a tick at the mean.
  function strip(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = 150, right = 86, top = 8, rowH = 46;
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
      txt(svg, W - right + 12, cy + 4, '平均 ' + r.mean.toFixed(1) + '%', 'val', 'start');
    });
  }
  // One stacked bar per comparison: how many scenarios came out better, the
  // same, a trade-off or worse on two measures together (counts inside).
  function outcomes(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = 190, right = 16, top = 8, rowH = 32;
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
        hover(rect, r.label + '：' + p.label + ' ' + v + ' 个场景（共 ' + r.n + ' 个）');
        if (x1 - x0 >= 16) {
          const t = txt(svg, (x0 + x1) / 2, by + 13, String(v), 'val', 'middle');
          t.setAttribute('style', 'fill: var(' + (p.ink || '--surface') + '); pointer-events: none');
        }
        acc += v;
      });
    });
  }
  // Log-scale horizontal bars for the median times.
  function timeBars(id, cfg) {
    if (!has(id)) return;
    const host = document.getElementById(id);
    const W = 640, left = 150, right = 60, top = 8, rowH = 26;
    const H = top + cfg.rows.length * rowH + 30;
    const svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, role: 'img', 'aria-label': cfg.aria }, host);
    const lo = Math.log10(cfg.min), hi = Math.log10(cfg.max);
    const x = v => left + (Math.log10(v) - lo) / (hi - lo) * (W - left - right);
    cfg.ticks.forEach(t => {
      el('line', { x1: x(t), x2: x(t), y1: top, y2: H - 24, class: 'grid' }, svg);
      txt(svg, x(t), H - 8, t + (EN ? ' s' : ' 秒'), 'ax', 'middle');
    });
    cfg.rows.forEach((r, i) => {
      const y0 = top + i * rowH;
      txt(svg, left - 10, y0 + 17, r.label, 'ax-l', 'end');
      const w = Math.max(2, x(Math.max(r.value, cfg.min)) - left);
      const bh = 14, by = y0 + 6, rr = Math.min(4, w / 2);
      const d = 'M' + left + ',' + by + ' L' + (left + w - rr) + ',' + by + ' Q' + (left + w) + ',' + by + ' ' + (left + w) + ',' + (by + rr) +
        ' L' + (left + w) + ',' + (by + bh - rr) + ' Q' + (left + w) + ',' + (by + bh) + ' ' + (left + w - rr) + ',' + (by + bh) + ' L' + left + ',' + (by + bh) + ' Z';
      const p = el('path', { d: d, style: 'fill: var(' + r.color + ')' }, svg);
      hover(p, EN ? r.label + ': median ' + r.value.toFixed(1) + ' s (offline)' : r.label + '：中位 ' + r.value.toFixed(1) + ' 秒（离线）');
      txt(svg, left + w + 5, by + 11, r.value < 10 ? r.value.toFixed(1) : r.value.toFixed(0), 'val', 'start');
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

  table('tb-overview', ['规划器', '达到最高', '平均质量', '最差', '合法方案', '漏放区域', '中位耗时（离线）'],
    D.overview.map(r => [r.label, r.best, r.quality, r.worst, r.legal, r.missing, r.time]));

  legend('lg-best', main);
  bars('ch-best', { groups: D.byStage.best, series: main, max: 100, ticks: [0, 25, 50, 75, 100],
    fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0),
    aria: '按阶段达到最高加成的场景比例' });
  legend('lg-quality', main);
  bars('ch-quality', { groups: D.byStage.quality, series: main, min: D.byStage.qMin, max: 100,
    ticks: D.byStage.qTicks, fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0),
    aria: '按阶段的平均质量' });

  scatter('ch-scatter-amt', { points: D.scatter.amt, max: D.scatter.max, ticks: D.scatter.ticks, color: '--amt',
    yLabel: 'AMT r49 的加成', aria: '本模组与 AMT 的逐场景加成对比' });
  scatter('ch-scatter-ep', { points: D.scatter.ep, max: D.scatter.max, ticks: D.scatter.ticks, color: '--ep',
    yLabel: 'Empire Planner 的加成', aria: '本模组与 Empire Planner 的逐场景加成对比' });
  if (has('cap-scatter-amt')) document.getElementById('cap-scatter-amt').textContent = D.scatter.capAmt;
  if (has('cap-scatter-ep')) document.getElementById('cap-scatter-ep').textContent = D.scatter.capEp;

  table('tb-correct', ['规划器', '违规方案', '压掉玩家的钉', '漏放区域', '其中有位置却没放', '同输入两次一致'],
    D.correct.map(r => [r.label, r.illegal, r.pins, r.missing, r.placeable, r.det]));
  const intFmt = v => String(Math.round(v));
  const pctFmt = v => v.toFixed(0) + '%';
  if (D.missing && D.missing.length) {
    const mx = Math.max(10, ...D.missing.map(r => r.value));
    const step = mx > 60 ? 20 : 10;
    const top = Math.ceil(mx / step) * step;
    const ticks = []; for (let t = 0; t <= top; t += step) ticks.push(t);
    hlist('ch-missing', { rows: D.missing, max: top, ticks: ticks, fmt: intFmt, aria: '各规划器有位置却没放的区域数' });
  }
  const pairHead = ['场景集', '对手', '拿到最高 本模组 / 对手', '本模组 胜 / 平 / 负', '平均差 [95% 区间]', 'p'];
  const pairRow = r => [r.set, r.vs, r.best, r.wtl, r.mean, r.p];
  if (D.robust && D.robust.length) table('tb-robust', pairHead, D.robust.map(pairRow), 2);
  if (D.robustMulti && D.robustMulti.length) table('tb-robust-multi', pairHead, D.robustMulti.map(pairRow), 2);
  if (D.robustGroups && D.robustGroups.length) {
    legend('lg-robust', main);
    bars('ch-robust', { groups: D.robustGroups, series: main, max: 100, ticks: [0, 25, 50, 75, 100], width: 640,
      fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0), aria: '各场景集拿到最高加成的比例' });
  }
  if (D.robustMultiGroups && D.robustMultiGroups.length) {
    legend('lg-mrobust', main);
    bars('ch-mrobust', { groups: D.robustMultiGroups, series: main, max: 100, ticks: [0, 25, 50, 75, 100], width: 640, height: 230,
      fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0), aria: '多城开发集与留出集拿到最高加成的比例' });
  }
  const crossHead = ['场景集', '打分用', '本模组', 'AMT', 'EP', '本模组 vs 打分方 胜 / 平 / 负', '平均差 [95% 区间]', 'p'];
  const crossRow = r => [r.set, r.scorer, r.sdp, r.amt, r.ep, r.wtl, r.mean, r.p];
  if (D.cross && D.cross.length) table('tb-cross', crossHead, D.cross.map(crossRow), 2);
  if (D.crossMulti && D.crossMulti.length) table('tb-cross-multi', crossHead, D.crossMulti.map(crossRow), 2);
  const scorers = [{ key: 'amt', label: '按 AMT 的目标函数', color: '--amt', square: true }, { key: 'ep', label: '按 EP 的目标函数', color: '--ep', square: true }];
  if (D.forest && D.forest.rows.length) {
    legend('lg-forest', scorers);
    forest('ch-forest', { rows: D.forest.rows, min: D.forest.min, max: D.forest.max, ticks: D.forest.ticks, ref: 100,
      aria: '单城：按对手自己的目标函数，本模组方案得分占对手自己方案得分的百分比' });
  }
  if (D.forestMulti && D.forestMulti.rows.length) {
    legend('lg-forest-multi', scorers);
    forest('ch-forest-multi', { rows: D.forestMulti.rows, min: D.forestMulti.min, max: D.forestMulti.max, ticks: D.forestMulti.ticks, ref: 100,
      aria: '多城：按对手自己的目标函数，本模组方案得分占对手自己方案得分的百分比' });
  }
  if (D.wonders && D.wonders.length) {
    table('tb-wonders', ['规划器', '奇观放下', '合法方案', '达到最高加成', '平均质量', '总产出最高'],
      D.wonders.map(r => [r.label, r.wonders, r.legal, r.best, r.quality, r.outBest]));
  }
  if (D.wonderGroups && D.wonderGroups.length) {
    legend('lg-wonders', main);
    bars('ch-wonders', { groups: D.wonderGroups, series: main, max: 100, ticks: [0, 25, 50, 75, 100], width: 640, height: 240,
      fmt: (v, l) => (l ? v.toFixed(1) : v.toFixed(0)) + '%', short: v => v.toFixed(0), aria: '奇观放下的比例与拿到最高加成的比例' });
  }
  if (D.sites && D.sites.length) {
    table('tb-sites', ['规划器', '合法方案', '城址总值', '地块产出', '区域潜力', '淡水城址', '新奢侈种类', '重叠格'],
      D.sites.map(r => [r.label, r.legal, r.value, r.tiles, r.districts, r.water, r.lux, r.overlap]));
  }
  if (D.sitesScatter && D.sitesScatter.points.length) {
    scatter('ch-sites', { points: D.sitesScatter.points, min: D.sitesScatter.min, max: D.sitesScatter.max, ticks: D.sitesScatter.ticks,
      color: '--ep', xLabel: '本模组的城址总值', yLabel: 'EP 的城址总值', aria: '本模组与 EP 的逐场景城址总值' });
  }
  if (D.output && D.output.length) {
    table('tb-output', ['规划器', '拿到最高', '本模组（计入地块）高 / 平 / 低：开发集', '留出集'],
      D.output.map(r => [r.label, r.best, r.vs, r.ho]));
  }
  if (D.outputChart && D.outputChart.length) {
    hlist('ch-output', { rows: D.outputChart, max: 100, ticks: [0, 25, 50, 75, 100], fmt: pctFmt, aria: '拿到最高城市总产出的场景比例' });
  }

  strip('ch-multi', { rows: D.strip.rows, min: D.strip.min, max: D.strip.max, ticks: D.strip.ticks,
    aria: '多城场景各规划器的加成占该场景最高值的百分比' });
  if (D.coverage && D.coverage.rows.length) {
    const parts = [{ key: 'better', label: '没有一项更差、至少一项更好', color: '--good' }, { key: 'same', label: '两项都相同', color: '--opt' },
      { key: 'tradeoff', label: '一项更好、一项更差', color: '--warn' }, { key: 'worse', label: '没有一项更好、至少一项更差', color: '--bad' },
      { key: 'excluded', label: '对手放了清单外的区域，不比', color: '--line', ink: '--fg' }];
    legend('lg-coverage', parts.map(p => ({ label: p.label, color: p.color, square: true })));
    outcomes('ch-coverage', { rows: D.coverage.rows, parts: parts, step: 2,
      aria: '覆盖范围场景：覆盖城数与相邻加成两项一起比较的结果' });
    table('tb-coverage', D.coverage.head, D.coverage.table, 1);
  }

  legend('lg-time', D.time.legend.map(k => ({ key: k, label: P[k].label, color: P[k].color, square: true })));
  timeBars('ch-time', { rows: D.time.rows, min: D.time.min, max: D.time.max, ticks: D.time.ticks,
    aria: EN ? 'Median time offline' : '离线中位耗时对比' });
})();
