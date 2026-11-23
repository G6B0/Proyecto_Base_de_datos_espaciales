// Filtros del modo Explorar: años, Mw, profundidad, región y fuente.
// Cada cambio actualiza las teselas de sismos, el contador y el histograma.

import { fmt, getJSON } from './api.js';
import { createRange } from './ui/range.js';
import { eventTilesUrl, fitChile } from './map.js';
import { loadHistogram } from './modes/explorar.js';

const $ = (id) => document.getElementById(id);
const YEAR_FLOOR = 1900; // el control izquierdo en 1900 = sin límite (incluye 1513–1899)
const DEPTH_MAX = 700;

export function setupFilters(map, summary) {
  const lastYear = summary.last_year;
  const state = { years: [YEAR_FLOOR, lastYear], mw: 0, depth: [0, DEPTH_MAX], region: null, source: 'ambas' };
  let regions = [];

  const query = () => {
    const q = {};
    if (state.years[0] > YEAR_FLOOR) q.year_min = state.years[0];
    if (state.years[1] < lastYear) q.year_max = state.years[1];
    if (state.mw > 0) q.mw_min = state.mw;
    if (state.depth[0] > 0) q.depth_min = state.depth[0];
    if (state.depth[1] < DEPTH_MAX) q.depth_max = state.depth[1];
    if (state.region) q.region = state.region;
    if (state.source !== 'ambas') q.source = state.source;
    return q;
  };
  const isFiltered = () => Object.keys(query()).length > 0;

  // --- Etiquetas -----------------------------------------------------------
  function renderLabels() {
    $('f-years-label').textContent = state.years[0] === YEAR_FLOOR && state.years[1] === lastYear
      ? `todo · ${summary.first_year}–${lastYear}`
      : `${state.years[0] === YEAR_FLOOR ? summary.first_year : state.years[0]} – ${state.years[1]}`;
    $('f-mw-label').textContent = state.mw > 0 ? `≥ ${fmt.one(state.mw)}` : 'todas';
    $('f-depth-label').textContent = `${state.depth[0]} – ${state.depth[1] === DEPTH_MAX ? '700+' : state.depth[1]} km`;
    $('f-reset').classList.toggle('hidden', !isFiltered());
  }

  // --- Aplicar (con espera para no pedir teselas en cada píxel del arrastre) ---
  let timer = null;
  let requestId = 0;
  function apply() {
    renderLabels();
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const q = query();
      map.getSource('events').setTiles([eventTilesUrl(q)]);
      const id = ++requestId;
      const params = new URLSearchParams(q).toString();
      const { events } = await getJSON(`/api/events/count${params ? `?${params}` : ''}`);
      if (id !== requestId) return; // llegó una respuesta más nueva
      $('count-unique').textContent = fmt.int(events);
      $('count-caption').textContent = isFiltered() ? 'Sismos con estos filtros' : 'Sismos únicos';
      const { year_min, year_max, ...rest } = q; // el histograma muestra todos los años
      loadHistogram(rest, state.years[0] === YEAR_FLOOR ? null : state.years[0], state.years[1]).catch(console.error);
    }, 220);
  }

  // --- Controles ----------------------------------------------------------
  const years = createRange($('f-years'), {
    min: YEAR_FLOOR, max: lastYear, step: 1, values: state.years,
    onInput: (v) => { state.years = v; renderLabels(); }, onChange: (v) => { state.years = v; apply(); },
  });
  const mw = createRange($('f-mw'), {
    min: 0, max: 8, step: 0.1, values: [state.mw],
    // 0 = todas (incluye los sismos sin Mw); el primer valor útil es 3,0.
    onInput: ([v]) => { state.mw = v > 0 && v < 3 ? 3 : v; renderLabels(); },
    onChange: ([v]) => { state.mw = v > 0 && v < 3 ? 3 : v; mw.set([state.mw]); apply(); },
  });
  const depth = createRange($('f-depth'), {
    min: 0, max: DEPTH_MAX, step: 10, values: state.depth,
    onInput: (v) => { state.depth = v; renderLabels(); }, onChange: (v) => { state.depth = v; apply(); },
  });

  // Fuente.
  const sourceButtons = document.querySelectorAll('[data-source]');
  function renderSource() {
    sourceButtons.forEach((b) => {
      const on = b.dataset.source === state.source;
      b.className = `flex-1 py-1.5 rounded-full text-xs ${on ? 'bg-white text-black font-medium' : 'text-fg-2 border border-white/15 hover:text-white'}`;
    });
  }
  sourceButtons.forEach((b) => b.addEventListener('click', () => { state.source = b.dataset.source; renderSource(); apply(); }));

  // Región: menú desplegable de vidrio, de norte a sur.
  const menu = $('f-region-menu');
  function renderRegionMenu() {
    const item = (code, name) => `<button class="w-full text-left px-3 py-1.5 rounded-xl text-sm ${state.region === code ? 'bg-white text-black' : 'text-fg-2 hover:bg-white/10 hover:text-white'}" data-region="${code ?? ''}">${name}</button>`;
    menu.innerHTML = item(null, 'Todas las regiones') + regions.map((r) => item(r.code, r.name)).join('');
    menu.querySelectorAll('[data-region]').forEach((b) => b.addEventListener('click', () => selectRegion(b.dataset.region || null)));
  }
  function selectRegion(code) {
    state.region = code;
    const region = regions.find((r) => r.code === code);
    $('f-region-label').textContent = region ? region.name : 'Todas las regiones';
    menu.classList.add('hidden');
    if (region) {
      map.fitBounds([[region.west, region.south], [region.east, region.north]],
        { padding: { top: 110, bottom: 150, left: 400, right: 400 }, duration: 900, maxZoom: 8 });
    } else {
      fitChile(map);
    }
    apply();
  }
  $('f-region').addEventListener('click', (ev) => {
    ev.stopPropagation();
    renderRegionMenu();
    menu.classList.toggle('hidden');
  });
  document.addEventListener('click', (ev) => { if (!menu.contains(ev.target)) menu.classList.add('hidden'); });
  getJSON('/api/regions').then((r) => { regions = r; }).catch(console.error);

  // Limpiar.
  $('f-reset').addEventListener('click', () => {
    state.years = [YEAR_FLOOR, lastYear]; years.set(state.years);
    state.mw = 0; mw.set([0]);
    state.depth = [0, DEPTH_MAX]; depth.set(state.depth);
    state.source = 'ambas'; renderSource();
    if (state.region) selectRegion(null); else apply();
  });

  renderSource();
  renderLabels();
}
