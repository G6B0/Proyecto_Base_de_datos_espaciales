// Arranque de la interfaz.

import { getJSON } from './api.js';
import { createMap, fitChile } from './map.js';
import { setupFilters } from './filters.js';
import { enableClicks, loadHistogram, loadSummary, showEvent } from './modes/explorar.js';

const map = createMap();

document.getElementById('btn-zoom-in').addEventListener('click', () => map.zoomIn());
document.getElementById('btn-zoom-out').addEventListener('click', () => map.zoomOut());
document.getElementById('btn-home').addEventListener('click', () => fitChile(map));

async function checkHealth() {
  try {
    await getJSON('/api/health');
  } catch {
    document.getElementById('live-dot').classList.add('live-down');
    document.getElementById('live-text').textContent = 'Base apagada';
  }
}

map.on('load', async () => {
  enableClicks(map);
  checkHealth();
  loadSummary().then((summary) => setupFilters(map, summary)).catch(console.error);
  loadHistogram().catch(console.error);
  // Se abre con el Maule 2010 seleccionado, como en el diseño.
  try {
    const { id } = await getJSON('/api/events/largest?date=2010-02-27');
    await showEvent(map, id);
  } catch (error) {
    console.error(error);
  }
});

window.sismosMap = map; // para depurar desde la consola
