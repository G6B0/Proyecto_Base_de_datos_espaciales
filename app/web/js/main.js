// Arranque de la interfaz y cambio de modo (Explorar / Anatomía).
// El modo y la secuencia abierta quedan en la URL (#anatomia/23734) para
// poder volver directo a una pantalla durante la presentación.

import { getJSON } from './api.js';
import { createMap, fitChile } from './map.js';
import { setupFilters } from './filters.js';
import { enableClicks, loadHistogram, loadSummary, restoreSelection, selectedEvent, showEvent } from './modes/explorar.js';
import { enterAnatomia, exitAnatomia, openSequence, setupAnatomia, setupOmoriHover, showOmori } from './modes/anatomia.js';

const map = createMap();
const $ = (id) => document.getElementById(id);
const MODES = ['explorar', 'anatomia'];
let mode = null;
let sequenceEvent = null; // sismo con que se abrió la última secuencia

$('btn-zoom-in').addEventListener('click', () => map.zoomIn());
$('btn-zoom-out').addEventListener('click', () => map.zoomOut());
$('btn-home').addEventListener('click', () => fitChile(map));

async function checkHealth() {
  try {
    await getJSON('/api/health');
  } catch {
    $('live-dot').classList.add('live-down');
    $('live-text').textContent = 'Base apagada';
  }
}

function renderNav() {
  document.querySelectorAll('button[data-mode]').forEach((b) => {
    const on = b.dataset.mode === mode;
    const ready = MODES.includes(b.dataset.mode);
    b.className = `px-5 py-2 rounded-full text-sm ${on ? 'bg-white text-black font-medium' : ready ? 'text-fg-2 hover:text-white' : 'text-fg-3 cursor-not-allowed'}`;
    if (!ready) b.title = 'Próximamente';
  });
}

async function setMode(next, { eventId } = {}) {
  if (!MODES.includes(next)) return;
  const leaving = mode;
  mode = next;
  document.body.dataset.mode = next;
  document.querySelectorAll('.mode-explorar').forEach((el) => el.classList.toggle('hidden', next !== 'explorar'));
  document.querySelectorAll('.mode-anatomia').forEach((el) => el.classList.toggle('hidden', next !== 'anatomia'));
  $('map-controls').classList.toggle('controls-raised', next === 'anatomia');
  renderNav();

  if (next === 'anatomia') {
    if (leaving !== 'anatomia') enterAnatomia();
    const id = eventId ?? sequenceEvent ?? selectedEvent()?.id
      ?? (await getJSON('/api/events/largest?date=2010-02-27')).id;
    try {
      const seq = await openSequence(id);
      if (seq) {
        sequenceEvent = seq.mainshock.id;
        history.replaceState(null, '', `#anatomia/${seq.mainshock.id}`);
      }
    } catch (error) {
      console.error(error);
      $('a-subtitle').textContent = 'Ese sismo no forma parte de una secuencia.';
    }
    showOmori();
  } else {
    if (leaving === 'anatomia') {
      exitAnatomia();
      restoreSelection(map);
    }
    history.replaceState(null, '', location.pathname);
  }
}

map.on('load', async () => {
  // Los botones se conectan cuando el mapa ya cargó sus fuentes y capas.
  document.querySelectorAll('button[data-mode]').forEach((b) => b.addEventListener('click', () => {
    if (b.dataset.mode !== mode) setMode(b.dataset.mode);
  }));
  $('d-anatomy').addEventListener('click', () => {
    const e = selectedEvent();
    if (e) setMode('anatomia', { eventId: e.id });
  });
  enableClicks(map);
  setupAnatomia(map, { onOpen: (id) => setMode('anatomia', { eventId: id }) });
  setupOmoriHover();
  checkHealth();
  loadSummary().then((summary) => setupFilters(map, summary)).catch(console.error);
  loadHistogram().catch(console.error);

  const [, hashMode, hashId] = location.hash.match(/^#(\w+)(?:\/(\d+))?/) ?? [];
  // La ficha de Explorar se abre con el Maule 2010 seleccionado, como en el diseño.
  try {
    const { id } = await getJSON('/api/events/largest?date=2010-02-27');
    await showEvent(map, id);
  } catch (error) {
    console.error(error);
  }
  if (hashMode === 'anatomia') {
    setMode('anatomia', { eventId: hashId ? Number(hashId) : undefined });
  } else {
    setMode('explorar');
  }
});

window.sismosMap = map; // para depurar desde la consola
