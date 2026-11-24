// Mapa base propio (sin servicios externos): océano, países vecinos, regiones
// de la DPA desde PostGIS y sismos como teselas vectoriales generadas con ST_AsMVT.

const CHILE_BOUNDS = [[-76.5, -56.5], [-66.0, -17.0]];
const PADDING = { top: 96, bottom: 136, left: 380, right: 380 };

// Rampa de magnitud y tamaños del sistema de diseño (igual que scripts/render_ui_basemap.py).
const MW = ['coalesce', ['get', 'mw'], 3];
export const MW_COLOR = ['interpolate', ['linear'], MW,
  3, '#3b1c4a', 4, '#8a2be2', 5, '#c2185b', 5.6, '#f4511e',
  6.5, '#ffa726', 7.5, '#ffe082', 8.5, '#fffde7', 9.6, '#ffffff'];
// radio base (px) = 0,6 + 0,18 * (Mw - 3)^2   -> Mw 5: 1,3 · Mw 8: 5,1
const BASE_RADIUS = ['+', 0.6, ['*', 0.18, ['^', ['-', ['max', MW, 3], 3], 2]]];
// MapLibre solo acepta ['zoom'] en el nivel superior: cada factor va dentro de la interpolación.
const radius = (k) => ['interpolate', ['linear'], ['zoom'],
  3, ['*', BASE_RADIUS, 1.0 * k], 6, ['*', BASE_RADIUS, 2.0 * k], 9, ['*', BASE_RADIUS, 3.5 * k]];
const RADIUS = radius(1);
export const OPACITY = ['step', MW, 0.25, 4, 0.45, 5, 0.7, 6, 0.92];
export { radius };
const EMPTY = { type: 'FeatureCollection', features: [] };

export function eventTilesUrl(filters = {}) {
  const params = new URLSearchParams(Object.entries(filters).filter(([, v]) => v !== null && v !== undefined && v !== ''));
  const query = params.toString();
  return `${location.origin}/tiles/events/{z}/{x}/{y}.pbf${query ? `?${query}` : ''}`;
}

export function createMap() {
  const map = new maplibregl.Map({
    container: 'map',
    attributionControl: false,
    renderWorldCopies: false,
    bounds: CHILE_BOUNDS,
    fitBoundsOptions: { padding: PADDING },
    minZoom: 2.5,
    maxZoom: 12,
    style: {
      version: 8,
      sources: {
        paises: { type: 'geojson', data: '/data/paises.geojson' },
        regiones: { type: 'geojson', data: '/api/areas?level=region' },
        events: { type: 'vector', tiles: [eventTilesUrl()], minzoom: 0, maxzoom: 10 },
        selected: { type: 'geojson', data: EMPTY },
        // Modo Anatomía: miembros de la secuencia, ventana de Gardner-Knopoff y elipse.
        'seq-events': { type: 'geojson', data: EMPTY },
        'seq-window': { type: 'geojson', data: EMPTY },
        'seq-ellipse': { type: 'geojson', data: EMPTY },
      },
      layers: [
        { id: 'ocean', type: 'background', paint: { 'background-color': '#030405' } },
        { id: 'paises-fill', type: 'fill', source: 'paises', paint: { 'fill-color': '#0b0d10' } },
        { id: 'paises-line', type: 'line', source: 'paises', paint: { 'line-color': 'rgba(255,255,255,0.08)', 'line-width': 0.6 } },
        { id: 'regiones-fill', type: 'fill', source: 'regiones', paint: { 'fill-color': '#111419' } },
        { id: 'regiones-line', type: 'line', source: 'regiones', paint: { 'line-color': 'rgba(255,255,255,0.18)', 'line-width': 0.6 } },
        {
          id: 'events-halo', type: 'circle', source: 'events', 'source-layer': 'events',
          filter: ['>=', MW, 7.5],
          paint: { 'circle-color': MW_COLOR, 'circle-radius': radius(3), 'circle-opacity': 0.12, 'circle-blur': 0.8 },
        },
        {
          id: 'events', type: 'circle', source: 'events', 'source-layer': 'events',
          paint: { 'circle-color': MW_COLOR, 'circle-radius': RADIUS, 'circle-opacity': OPACITY },
        },
        {
          id: 'seq-window', type: 'line', source: 'seq-window',
          paint: { 'line-color': 'rgba(255,255,255,0.35)', 'line-width': 1, 'line-dasharray': [1, 3] },
        },
        {
          id: 'seq-events', type: 'circle', source: 'seq-events',
          paint: {
            'circle-color': ['case', ['==', ['get', 'role'], 'foreshock'], 'rgba(0,0,0,0)', MW_COLOR],
            'circle-radius': radius(1.7),
            'circle-opacity': 0.9,
            'circle-stroke-color': '#ffffff',
            'circle-stroke-width': ['case', ['==', ['get', 'role'], 'foreshock'], 1.2, 0],
            'circle-stroke-opacity': 0.9,
          },
        },
        {
          id: 'seq-ellipse', type: 'line', source: 'seq-ellipse',
          paint: { 'line-color': '#ffffff', 'line-width': 1.8, 'line-dasharray': [3, 2] },
        },
        {
          id: 'selected-outer', type: 'circle', source: 'selected',
          paint: { 'circle-radius': 28, 'circle-color': 'rgba(0,0,0,0)', 'circle-stroke-color': 'rgba(255,255,255,0.25)', 'circle-stroke-width': 1 },
        },
        {
          id: 'selected-ring', type: 'circle', source: 'selected',
          paint: { 'circle-radius': 14, 'circle-color': 'rgba(0,0,0,0)', 'circle-stroke-color': '#ffffff', 'circle-stroke-width': 2 },
        },
      ],
    },
  });
  return map;
}

export function fitChile(map) {
  map.fitBounds(CHILE_BOUNDS, { padding: PADDING, duration: 900 });
}

export function setSelected(map, lon, lat) {
  map.getSource('selected').setData({
    type: 'FeatureCollection',
    features: lon === null ? [] : [{ type: 'Feature', geometry: { type: 'Point', coordinates: [lon, lat] }, properties: {} }],
  });
}
