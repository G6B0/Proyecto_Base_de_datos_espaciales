// Modo Explorar: contadores, histograma de la línea de tiempo y ficha del sismo.

import { fmt, getJSON } from '../api.js';
import { setSelected } from '../map.js';

const $ = (id) => document.getElementById(id);
const BIG_YEARS = new Set([1906, 1922, 1939, 1943, 1960, 1985, 1995, 2010, 2014, 2015]);
const MMI_COLORS = { 1: '#ffffff', 2: '#bfccff', 3: '#bfccff', 4: '#a0e6ff', 5: '#80ffff', 6: '#7aff93', 7: '#ffff00', 8: '#ffc800', 9: '#ff9100', 10: '#ff0000' };
const ROMAN = ['', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 'XI', 'XII'];
const ROLE = { mainshock: 'Sismo principal', aftershock: 'Réplica', foreshock: 'Precursor', independent: 'Independiente' };
const FAMOUS = { '1960-05-22': 'Valdivia 1960', '2010-02-27': 'Maule 2010', '2014-04-01': 'Iquique 2014', '2015-09-16': 'Illapel 2015', '1985-03-03': 'Valparaíso 1985' };

export async function loadSummary() {
  const s = await getJSON('/api/stats/summary');
  $('count-unique').textContent = fmt.int(s.unique_events);
  $('count-years').textContent = `${s.first_year}–${s.last_year}`;
  $('count-records').textContent = fmt.int(s.records);
  $('count-pairs').textContent = fmt.int(s.pairs);
}

export async function loadHistogram() {
  const rows = await getJSON('/api/stats/years?mw_min=4&year_min=1906');
  const peak = Math.sqrt(Math.max(...rows.map((r) => r.events)));
  $('histogram').innerHTML = rows.map((r) => {
    const h = Math.max(3, Math.round((Math.sqrt(r.events) / peak) * 100));
    const op = BIG_YEARS.has(r.year) ? 0.9 : 0.4;
    return `<div class="flex-1 rounded-t-sm bg-white" style="height:${h}%;opacity:${op}" title="${r.year}: ${fmt.int(r.events)} sismos Mw ≥ 4"></div>`;
  }).join('');
  const first = rows[0].year;
  const last = rows[rows.length - 1].year;
  const span = last - first;
  $('histogram-ticks').innerHTML = [first, 1930, 1960, 1990, last].map((y) => {
    const pct = ((y - first) / span) * 100;
    const tr = y === first ? 'translateX(0)' : y === last ? 'translateX(-100%)' : 'translateX(-50%)';
    return `<span class="absolute font-mono text-[10px] text-fg-3" style="left:${pct.toFixed(2)}%;transform:${tr}">${y}</span>`;
  }).join('');
  $('histogram-range').textContent = `${first} – ${last}`;
}

function titleFor(e) {
  const day = e.occurred_at.slice(0, 10);
  if (FAMOUS[day] && e.mw >= 7.5) return FAMOUS[day];
  return e.commune_name ? `${e.commune_name} ${day.slice(0, 4)}` : `Sismo ${day.slice(0, 4)}`;
}

export async function showEvent(map, id) {
  const e = await getJSON(`/api/events/${id}`);
  setSelected(map, e.lon, e.lat);
  $('d-title').textContent = titleFor(e);
  $('d-date').textContent = fmt.date(e.occurred_at);
  $('d-mw').textContent = fmt.one(e.mw);
  $('d-depth').textContent = e.depth_km === null ? '—' : fmt.int(e.depth_km);

  const chip = $('d-mmi-chip');
  if (e.max_mmi) {
    const level = Math.round(e.max_mmi);
    $('d-mmi').textContent = fmt.one(e.max_mmi);
    chip.textContent = ROMAN[level];
    chip.style.background = MMI_COLORS[Math.min(10, level)];
    chip.style.color = '#000';
    chip.classList.remove('hidden');
  } else {
    $('d-mmi').textContent = '—';
    chip.classList.add('hidden');
  }

  $('d-commune').textContent = e.commune_name ? `${e.commune_name} (${e.region_name})` : '—';
  $('d-commune-km').textContent = e.assignment_method === 'covers'
    ? 'epicentro dentro de la comuna'
    : `${fmt.one(e.commune_km)} km fuera de la costa o del límite`;
  $('d-urban').textContent = e.urban_name ? e.urban_name.toLowerCase().replace(/(^|[\s-])\S/g, (c) => c.toUpperCase()) : '—';
  $('d-urban-km').textContent = e.urban_km === null ? '' : `${fmt.one(e.urban_km)} km`;
  $('d-pop25').textContent = fmt.people(e.population_25km);
  $('d-pop50').textContent = fmt.people(e.population_50km);
  $('d-pop100').textContent = fmt.people(e.population_100km);
  $('d-published').textContent = e.magnitude === null ? '—' : `${fmt.one(e.magnitude)} ${e.magnitude_type ?? ''}`;
  $('d-role').textContent = e.sequence_role ? ROLE[e.sequence_role] : 'pendiente (paso 3)';

  const chips = [];
  if (e.also_in_usgs) chips.push(`También publicado por USGS${e.usgs_mw ? ` · Mw ${fmt.one(e.usgs_mw)}` : ''}`);
  if (e.source === 'usgs') chips.push('Solo en USGS');
  if (e.pager_alert) chips.push(`Alerta PAGER ${e.pager_alert}`);
  $('d-chips').innerHTML = chips.map((c) => `<span class="px-3 py-1 rounded-full border border-white/15 text-xs text-fg-2">${c}</span>`).join('');
}

export function enableClicks(map) {
  map.on('mouseenter', 'events', () => { map.getCanvas().style.cursor = 'pointer'; });
  map.on('mouseleave', 'events', () => { map.getCanvas().style.cursor = ''; });
  map.on('click', 'events', (ev) => {
    // Entre los puntos bajo el cursor, el de mayor Mw.
    const feature = ev.features.reduce((a, b) => ((b.properties.mw ?? 0) > (a.properties.mw ?? 0) ? b : a));
    showEvent(map, feature.id).catch(console.error);
  });
}
