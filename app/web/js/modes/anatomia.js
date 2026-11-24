// Modo Anatomía: una secuencia sísmica completa según Gardner-Knopoff.
// Réplicas en el mapa (con reproducción en el tiempo), ventana circular del
// método, elipse de desviación estándar de las réplicas y curva de Omori.
// Todo sale de GET /api/sequences/{id} (vistas v_sequence_ellipse y v_sequence_omori).

import { fmt, getJSON } from '../api.js';
import { OPACITY, setSelected } from '../map.js';
import { createRange } from '../ui/range.js';
import { MMI_COLORS, ROMAN, eventTitle } from './explorar.js';

const $ = (id) => document.getElementById(id);
const EMPTY = { type: 'FeatureCollection', features: [] };
const T0 = 0.01; // días (14 minutos): inicio de la escala de tiempo
const PLAY_MS = 12000;
const PADDING = { top: 120, bottom: 130, left: 440, right: 400 };

export const PRESETS = [
  { date: '2010-02-27', name: 'Maule 2010' },
  { date: '2015-09-16', name: 'Illapel 2015' },
  { date: '2014-04-01', name: 'Iquique 2014' },
  { date: '1985-03-03', name: 'Valparaíso 1985' },
  { date: '1995-07-30', name: 'Antofagasta 1995' },
];

const nf2 = new Intl.NumberFormat('es-CL', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

let map = null;
let data = null;            // respuesta de la API para la secuencia abierta
let slider = null;
let u = 1000;               // posición del deslizador (0..1000, tiempo logarítmico)
let playing = null;         // id de requestAnimationFrame
let intensity = undefined;  // módulo de Ignacio (app/web/js/intensity.js), si existe
let requestId = 0;

// --- Tiempo -----------------------------------------------------------------
const tEnd = () => Math.max(1, data?.counts.last_aftershock_days ?? 1);
const timeAt = (pos) => 10 ** (Math.log10(T0) + (pos / 1000) * (Math.log10(tEnd()) - Math.log10(T0)));

export function duration(days) {
  const d = Math.abs(days);
  if (d < 1 / 24) return `${fmt.int(Math.max(1, d * 1440))} min`;
  if (d < 1) return `${fmt.int(d * 24)} h`;
  if (d < 730) return `${fmt.int(d)} ${Math.round(d) === 1 ? 'día' : 'días'}`;
  return `${fmt.one(d / 365.25)} años`;
}

// --- Montaje ----------------------------------------------------------------
export function setupAnatomia(theMap, { onOpen } = {}) {
  map = theMap;
  slider = createRange($('a-time'), {
    min: 0, max: 1000, step: 1, values: [u], fill: 'before',
    onInput: ([v]) => { stop(); u = v; renderTime(); },
    onChange: ([v]) => { u = v; renderTime(); },
  });
  $('a-play').addEventListener('click', () => (playing ? stop() : play()));

  $('a-presets').innerHTML = PRESETS.map((p) => `<button class="chip" data-date="${p.date}">${p.name}</button>`).join('');
  $('a-presets').querySelectorAll('[data-date]').forEach((b) => b.addEventListener('click', async () => {
    const { id } = await getJSON(`/api/events/largest?date=${b.dataset.date}`);
    onOpen?.(id);
  }));

  // Clic en una réplica: su ficha corta. Clic en otro sismo: abre su secuencia.
  map.on('click', (ev) => {
    if (document.body.dataset.mode !== 'anatomia') return;
    const member = map.queryRenderedFeatures(ev.point, { layers: ['seq-events'] });
    if (member.length) {
      const f = member.reduce((a, b) => ((b.properties.mw ?? 0) > (a.properties.mw ?? 0) ? b : a));
      popup(ev.lngLat, memberText(f.properties));
      return;
    }
    const others = map.queryRenderedFeatures(ev.point, { layers: ['events'] });
    if (!others.length) return;
    const f = others.reduce((a, b) => ((b.properties.mw ?? 0) > (a.properties.mw ?? 0) ? b : a));
    getJSON(`/api/sequences/${f.id}`)
      .then(() => onOpen?.(f.id))
      .catch(() => popup(ev.lngLat, `Mw ${fmt.one(f.properties.mw)} · ${f.properties.year}<br><span class="text-fg-3">Independiente: no forma parte de ninguna secuencia.</span>`));
  });
  map.on('mouseenter', 'seq-events', () => { map.getCanvas().style.cursor = 'pointer'; });
  map.on('mouseleave', 'seq-events', () => { map.getCanvas().style.cursor = ''; });

  window.addEventListener('resize', () => { if (data && document.body.dataset.mode === 'anatomia') drawOmori(); });
}

let openPopup = null;
function popup(lngLat, html) {
  openPopup?.remove();
  openPopup = new maplibregl.Popup({ closeButton: true, maxWidth: '260px', offset: 12 })
    .setLngLat(lngLat).setHTML(html).addTo(map);
}

function memberText(p) {
  const role = { mainshock: 'Sismo principal', aftershock: 'Réplica', foreshock: 'Precursor' }[p.role];
  const when = p.role === 'mainshock' ? '' : ` · ${duration(p.d)} ${p.d < 0 ? 'antes' : 'después'} · ${fmt.int(p.km)} km`;
  return `<b>${role}</b> · Mw ${fmt.one(p.mw)}<br><span class="text-fg-3">${when.slice(3)}</span>`;
}

// --- Entrar / salir del modo -------------------------------------------------
export async function openSequence(eventId) {
  const id = ++requestId;
  stop();
  $('a-subtitle').textContent = 'Cargando…';
  const seq = await getJSON(`/api/sequences/${eventId}`);
  if (id !== requestId) return null;
  data = seq;
  render();
  return seq;
}

export function enterAnatomia() {
  map.setPaintProperty('events', 'circle-opacity', 0.1);
  map.setLayoutProperty('events-halo', 'visibility', 'none');
  ['seq-window', 'seq-events', 'seq-ellipse'].forEach((l) => map.setLayoutProperty(l, 'visibility', 'visible'));
}

export function exitAnatomia() {
  stop();
  openPopup?.remove();
  map.setPaintProperty('events', 'circle-opacity', OPACITY);
  map.setLayoutProperty('events-halo', 'visibility', 'visible');
  ['seq-window', 'seq-events', 'seq-ellipse'].forEach((l) => map.setLayoutProperty(l, 'visibility', 'none'));
  intensity?.clearIntensity?.(map);
}

// --- Dibujo -------------------------------------------------------------------
function azimuthText(az) {
  const a = Math.round(az) % 180;
  if (a === 0) return 'N–S';
  if (a === 90) return 'E–O';
  return a < 90 ? `N${a}°E` : `N${180 - a}°O`;
}

function render() {
  const { mainshock: m, counts: c, window: w, ellipse: x, omori, st_dbscan: db } = data;
  const day = m.occurred_at.slice(0, 10);
  const preset = PRESETS.find((p) => p.date === day);
  $('a-presets').querySelectorAll('[data-date]').forEach((b) => b.classList.toggle('on', b.dataset.date === day));
  $('a-title').textContent = preset ? preset.name : eventTitle(m);
  $('a-subtitle').textContent = `${fmt.date(m.occurred_at)} · Mw ${fmt.one(m.mw)} · ${m.depth_km === null ? '—' : fmt.int(m.depth_km)} km`;

  $('a-aftershocks').textContent = fmt.int(c.aftershocks);
  $('a-foreshocks').textContent = c.foreshocks ? `+ ${fmt.int(c.foreshocks)} precursores` : 'sin precursores';
  $('a-firstday').textContent = fmt.int(c.first_day);
  $('a-firstday-share').textContent = c.aftershocks ? `${fmt.int((100 * c.first_day) / c.aftershocks)} % del total` : '';
  const big = c.largest_aftershock;
  $('a-largest').textContent = big ? `Mw ${fmt.one(big.mw)}` : '—';
  $('a-largest-when').textContent = big ? `${duration(big.days)} después · ${fmt.int(big.km)} km` : '';
  $('a-omori-p').textContent = omori.fit ? nf2.format(omori.fit.p) : '—';
  $('a-omori-r2').textContent = omori.fit ? `R² ${nf2.format(omori.fit.r2)} · decaimiento` : 'pocas réplicas para ajustar';
  $('a-omori-law').innerHTML = omori.fit ? `n(t) ∝ t<sup>−${nf2.format(omori.fit.p)}</sup>` : '';

  $('a-window').textContent = `${fmt.int(w.radius_km)} km · ${fmt.int(w.days)} días`;
  $('a-ellipse').textContent = x ? `${fmt.int(x.major_axis_km)} × ${fmt.int(x.minor_axis_km)} km · ${azimuthText(x.azimuth_deg)}` : 'menos de 5 réplicas';
  $('a-dbscan').textContent = db ? `${fmt.int(db.aftershock_count)} réplicas${db.major_axis_km ? ` · ${fmt.int(db.major_axis_km)} × ${fmt.int(db.minor_axis_km)} km` : ''}` : 'sismo independiente';

  renderNote();
  renderImpact();

  // Mapa.
  map.getSource('seq-events').setData(data.events);
  map.getSource('seq-window').setData({ type: 'Feature', geometry: w.geometry, properties: {} });
  map.getSource('seq-ellipse').setData(x ? { type: 'Feature', geometry: x.geometry, properties: {} } : EMPTY);
  setSelected(map, m.lon, m.lat);
  const ring = w.geometry.coordinates[0];
  const lons = ring.map((p) => p[0]);
  const lats = ring.map((p) => p[1]);
  map.fitBounds([[Math.min(...lons), Math.min(...lats)], [Math.max(...lons), Math.max(...lats)]],
    { padding: PADDING, duration: 1200, maxZoom: 9 });

  drawOmori();
  $('a-span').textContent = `14 min → ${duration(tEnd())}`;
  u = 1000;
  slider.set([u]);
  renderTime();
}

function renderNote() {
  const note = $('a-note');
  const o = data.outside[0];
  if (!o) { note.classList.add('hidden'); return; }
  const w = data.window;
  const x = data.ellipse;
  const where = o.commune_name ? `frente a ${o.commune_name}` : 'cercano';
  const d = o.occurred_at.slice(0, 10).split('-').reverse().join('-');
  const as = { mainshock: 'quedó como una secuencia aparte', independent: 'quedó como sismo independiente', aftershock: 'quedó en otra secuencia', foreshock: 'quedó en otra secuencia' }[o.role];
  let text = `El Mw <span class="text-white">${fmt.one(o.mw)}</span> ${where} (${d}) ${as}: está a ${fmt.int(o.km)} km del epicentro y la ventana circular cubre ${fmt.int(w.radius_km)} km.`;
  // Solo si ese sismo está en la dirección del eje mayor de la elipse (±25°):
  // entonces la ventana circular corta una ruptura alargada.
  const m = data.mainshock;
  const bearing = (Math.atan2((o.lon - m.lon) * Math.cos((m.lat * Math.PI) / 180), o.lat - m.lat) * 180) / Math.PI;
  const off = Math.abs((((bearing - (x?.azimuth_deg ?? 0)) % 180) + 180) % 180);
  if (x && x.axis_ratio < 0.75 && (off <= 25 || off >= 155)) {
    text += ` Está en la dirección en que se alinean las réplicas (${azimuthText(x.azimuth_deg)}): la ventana circular no sigue una ruptura alargada.`;
  }
  note.innerHTML = text;
  note.classList.remove('hidden');
}

async function renderImpact() {
  const { impact, mainshock } = data;
  const chip = $('a-mmi-chip');
  if (impact.max_mmi) {
    const level = Math.round(impact.max_mmi);
    $('a-mmi').textContent = fmt.one(impact.max_mmi);
    chip.textContent = ROMAN[level];
    chip.style.background = MMI_COLORS[Math.min(10, level)];
    chip.style.color = '#000';
    chip.classList.remove('hidden');
  } else {
    $('a-mmi').textContent = '—';
    chip.classList.add('hidden');
  }
  $('a-cdi').textContent = impact.max_cdi ? fmt.one(impact.max_cdi) : '—';

  // Módulo de intensidad de Ignacio (pasos 6 y 7 del plan). Contrato:
  //   export function showIntensity(map, eventId, container) -> Promise<boolean>
  //   export function clearIntensity(map)
  if (intensity === undefined) {
    intensity = await import('../intensity.js').catch(() => null);
  }
  intensity?.clearIntensity?.(map);
  const shown = intensity ? await intensity.showIntensity(map, mainshock.id, $('a-intensity')).catch(() => false) : false;
  if (!shown) {
    $('a-intensity-status').textContent = impact.has_shakemap
      ? 'El USGS publicó un ShakeMap para este sismo. Los contornos de intensidad y la población expuesta llegan con el módulo de intensidad (pasos 6 y 7).'
      : 'El USGS no publicó un ShakeMap para este sismo.';
  }
}

// --- Reproducción ------------------------------------------------------------
function renderTime() {
  const t = timeAt(u);
  const atEnd = u >= 1000;
  map.setFilter('seq-events', atEnd ? null : ['<=', ['get', 'd'], t]);
  // Durante la reproducción, las réplicas recientes brillan más.
  map.setPaintProperty('seq-events', 'circle-opacity', atEnd || !playing ? 0.9
    : ['interpolate', ['linear'], ['get', 'd'], t / 3, 0.3, t, 1]);
  $('a-time-label').textContent = atEnd ? 'todas' : duration(t);
  const visible = data.events.features.filter((f) => f.properties.role === 'aftershock' && (atEnd || f.properties.d <= t)).length;
  $('a-time-count').textContent = `${fmt.int(visible)} réplicas`;
  drawCursor(atEnd ? null : t);
}

function play() {
  if (u >= 1000) u = 0;
  const start = performance.now() - (u / 1000) * PLAY_MS;
  $('a-play-icon').setAttribute('icon', 'lucide:pause');
  const step = (now) => {
    u = Math.min(1000, ((now - start) / PLAY_MS) * 1000);
    slider.set([u]);
    renderTime();
    if (u < 1000) playing = requestAnimationFrame(step);
    else stop();
  };
  playing = requestAnimationFrame(step);
}

function stop() {
  if (playing) cancelAnimationFrame(playing);
  playing = null;
  $('a-play-icon').setAttribute('icon', 'lucide:play');
  if (data) map.setPaintProperty('seq-events', 'circle-opacity', 0.9);
}

// --- Curva de Omori (SVG, escala log-log) ------------------------------------
let scales = null;

function drawOmori() {
  const svg = $('a-omori-chart');
  const W = svg.clientWidth || 480;
  const H = svg.clientHeight || 190;
  const M = { l: 46, r: 10, t: 8, b: 30 };
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);
  const bins = data.omori.bins;
  const fit = data.omori.fit;
  if (!bins.length) {
    svg.innerHTML = `<text x="${W / 2}" y="${H / 2}" text-anchor="middle" class="omori-axis">Menos de 20 réplicas: no alcanza para la curva</text>`;
    scales = null;
    return;
  }
  const lx0 = Math.log10(T0);
  const lx1 = Math.log10(tEnd()) + 0.05;
  const rates = bins.map((b) => b.per_day);
  const ly0 = Math.floor(Math.log10(Math.min(...rates)) - 0.1);
  const ly1 = Math.ceil(Math.log10(Math.max(...rates)) + 0.1);
  const x = (d) => M.l + ((Math.log10(d) - lx0) / (lx1 - lx0)) * (W - M.l - M.r);
  const y = (r) => H - M.b - ((Math.log10(r) - ly0) / (ly1 - ly0)) * (H - M.t - M.b);
  scales = { x, y, M, H };

  const parts = [];
  // Grilla y ejes.
  for (let e = Math.ceil(lx0); e <= Math.floor(lx1); e += 1) {
    const d = 10 ** e;
    parts.push(`<line x1="${x(d)}" x2="${x(d)}" y1="${M.t}" y2="${H - M.b}" class="omori-grid"/>`);
    parts.push(`<text x="${x(d)}" y="${H - M.b + 14}" text-anchor="middle" class="omori-axis">${d < 1 ? String(d).replace('.', ',') : fmt.int(d)}</text>`);
  }
  for (let e = ly0; e <= ly1; e += 1) {
    const r = 10 ** e;
    parts.push(`<line x1="${M.l}" x2="${W - M.r}" y1="${y(r)}" y2="${y(r)}" class="omori-grid"/>`);
    parts.push(`<text x="${M.l - 6}" y="${y(r) + 3}" text-anchor="end" class="omori-axis">${r < 1 ? String(r).replace('.', ',') : fmt.int(r)}</text>`);
  }
  parts.push(`<text x="${W - M.r}" y="${H - 3}" text-anchor="end" class="omori-axis">días desde el terremoto</text>`);
  // Recta ajustada desde 0,05 días.
  if (fit) {
    const f = (d) => 10 ** (fit.log10_k - fit.p * Math.log10(d));
    const a = 0.05;
    const b = tEnd();
    parts.push(`<line x1="${x(a)}" y1="${y(f(a))}" x2="${x(b)}" y2="${y(f(b))}" class="omori-fit"/>`);
  }
  // Cursor de la reproducción.
  parts.push(`<line id="a-omori-cursor" x1="0" x2="0" y1="${M.t}" y2="${H - M.b}" class="omori-cursor" visibility="hidden"/>`);
  // Puntos: llenos los que entran en el ajuste (desde 0,05 días), huecos los primeros.
  bins.forEach((bin, i) => {
    const used = bin.center_days > 0.05;
    parts.push(`<circle cx="${x(bin.center_days)}" cy="${y(bin.per_day)}" r="4.5" class="${used ? 'omori-pt' : 'omori-pt-open'}" data-i="${i}"/>`);
  });
  svg.innerHTML = parts.join('');
}

function drawCursor(t) {
  const cursor = document.getElementById('a-omori-cursor');
  if (!cursor || !scales) return;
  if (t === null) { cursor.setAttribute('visibility', 'hidden'); return; }
  const cx = scales.x(Math.max(T0, t));
  cursor.setAttribute('x1', cx);
  cursor.setAttribute('x2', cx);
  cursor.setAttribute('visibility', 'visible');
}

export function setupOmoriHover() {
  const svg = $('a-omori-chart');
  const tip = $('a-omori-tip');
  svg.addEventListener('mousemove', (ev) => {
    if (!scales || !data?.omori.bins.length) return;
    const box = svg.getBoundingClientRect();
    const px = ((ev.clientX - box.left) / box.width) * svg.viewBox.baseVal.width;
    let best = null;
    data.omori.bins.forEach((b) => {
      const dx = Math.abs(scales.x(b.center_days) - px);
      if (!best || dx < best.dx) best = { dx, b };
    });
    if (!best || best.dx > 30) { tip.classList.add('hidden'); return; }
    const b = best.b;
    svg.querySelectorAll('circle').forEach((c) => c.classList.toggle('omori-hover', Number(c.dataset.i) === data.omori.bins.indexOf(b)));
    tip.innerHTML = `<span class="font-mono">${duration(b.from_days)} – ${duration(b.to_days)}</span><br>${fmt.int(b.aftershocks)} réplicas · <span class="font-mono">${b.per_day >= 10 ? fmt.int(b.per_day) : fmt.one(b.per_day)}</span> por día`;
    const scale = box.width / svg.viewBox.baseVal.width;
    tip.style.left = `${scales.x(b.center_days) * scale}px`;
    tip.style.top = `${scales.y(b.per_day) * scale}px`;
    tip.classList.remove('hidden');
  });
  svg.addEventListener('mouseleave', () => {
    tip.classList.add('hidden');
    svg.querySelectorAll('circle').forEach((c) => c.classList.remove('omori-hover'));
  });
}

export function showOmori() {
  if (data) { drawOmori(); renderTime(); }
}
