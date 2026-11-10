import { AttributionControl, Map, addProtocol, setWorkerUrl, type StyleSpecification } from 'maplibre-gl';
import { Protocol } from 'pmtiles';
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
import fontUrl from '@fontsource/noto-sans/files/noto-sans-latin-400-normal.woff2?url';
import latinExtFontUrl from '@fontsource/noto-sans/files/noto-sans-latin-ext-400-normal.woff2?url';
import cyrillicFontUrl from '@fontsource/noto-sans/files/noto-sans-cyrillic-400-normal.woff2?url';
import 'maplibre-gl/dist/maplibre-gl.css';
import './style.css';

type Bounds = [number, number, number, number];
type Region = {
  id: string;
  name: string;
  bounds: Bounds;
  mapUrl: string;
  terrainUrl?: string;
  terrainEncoding?: 'mapbox' | 'terrarium';
  attribution: string;
};
type Configuration = { regions: Region[] };
type Command =
  | { type: 'zoomIn' | 'zoomOut' | 'resetBearing' | 'toggleTerrain' }
  | { type: 'flyTo'; longitude: number; latitude: number };

declare global {
  interface Window {
    HikingBridge?: { postMessage(message: string): void };
    hikingMap?: { handleCommand(command: Command): void };
  }
}

const status = document.getElementById('status');
const bridge = (type: string, details: Record<string, unknown> = {}) => {
  window.HikingBridge?.postMessage(JSON.stringify({ type, ...details }));
};
const showStatus = (message: string, isError = false) => {
  if (!status) return;
  status.textContent = message;
  status.classList.toggle('error', isError);
  status.classList.remove('hidden');
};
const hideStatus = () => status?.classList.add('hidden');

window.addEventListener('error', (event) => {
  bridge('error', { message: event.message });
  showStatus('Map renderer error. Check the app log.', true);
});
window.addEventListener('unhandledrejection', (event) => {
  const message = String(event.reason);
  bridge('error', { message });
  showStatus('Map renderer error. Check the app log.', true);
});

function styleFor(region?: Region): StyleSpecification {
  const style: StyleSpecification = {
    version: 8,
    name: 'Ridgewalk offline',
    sources: {},
    layers: [{ id: 'background', type: 'background', paint: { 'background-color': '#dce6dc' } }],
  };
  if (!region) return style;

  // A local WOFF2 file is bundled by Vite; no font or glyph CDN is needed.
  Object.assign(style, {
    'font-faces': {
      'Noto Sans Regular': [
        { url: new URL(fontUrl, location.href).href, 'unicode-range': ['U+0000-00FF'] },
        { url: new URL(latinExtFontUrl, location.href).href, 'unicode-range': ['U+0100-024F', 'U+1E00-1EFF'] },
        { url: new URL(cyrillicFontUrl, location.href).href, 'unicode-range': ['U+0400-052F'] },
      ],
    },
  });
  style.sources = {
    hiking: {
      type: 'vector',
      url: `pmtiles://${region.mapUrl}`,
      attribution: region.attribution,
    },
  };
  if (region.terrainUrl) {
    style.sources.elevation = {
      type: 'raster-dem',
      url: `pmtiles://${region.terrainUrl}`,
      encoding: region.terrainEncoding ?? 'mapbox',
      tileSize: 256,
    };
  }
  const layers: StyleSpecification['layers'] = [
    { id: 'landcover', type: 'fill', source: 'hiking', 'source-layer': 'landcover', paint: { 'fill-color': '#abc99d', 'fill-opacity': 0.65 } },
    { id: 'forest', type: 'fill', source: 'hiking', 'source-layer': 'landuse', filter: ['==', ['get', 'class'], 'forest'], paint: { 'fill-color': '#81ae82', 'fill-opacity': 0.55 } },
    { id: 'water', type: 'fill', source: 'hiking', 'source-layer': 'water', paint: { 'fill-color': '#7cbbcd' } },
    { id: 'roads', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: ['!', ['in', ['get', 'class'], ['literal', ['path', 'footway', 'track', 'bridleway', 'steps']]]], paint: { 'line-color': '#f7f4e8', 'line-width': ['interpolate', ['linear'], ['zoom'], 8, 0.7, 14, 2.8] } },
    { id: 'trails-casing', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: ['in', ['get', 'class'], ['literal', ['path', 'footway', 'track', 'bridleway', 'steps']]], paint: { 'line-color': '#fff5d7', 'line-width': ['interpolate', ['linear'], ['zoom'], 8, 1.5, 14, 4] } },
    { id: 'trails', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: ['in', ['get', 'class'], ['literal', ['path', 'footway', 'track', 'bridleway', 'steps']]], paint: { 'line-color': '#a75839', 'line-width': ['interpolate', ['linear'], ['zoom'], 8, 0.8, 14, 2], 'line-dasharray': [2, 1] } },
    { id: 'trail-names', type: 'symbol', source: 'hiking', 'source-layer': 'transportation_name', layout: { 'symbol-placement': 'line', 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 11 }, paint: { 'text-color': '#704c39', 'text-halo-color': '#f8f5e8', 'text-halo-width': 1 } },
    { id: 'huts', type: 'circle', source: 'hiking', 'source-layer': 'poi', filter: ['in', ['get', 'class'], ['literal', ['alpine_hut', 'wilderness_hut', 'shelter']]], paint: { 'circle-color': '#a05235', 'circle-radius': 5, 'circle-stroke-color': '#fff8e8', 'circle-stroke-width': 1.5 } },
    { id: 'hut-names', type: 'symbol', source: 'hiking', 'source-layer': 'poi', filter: ['in', ['get', 'class'], ['literal', ['alpine_hut', 'wilderness_hut', 'shelter']]], layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 1.2] }, paint: { 'text-color': '#563b31', 'text-halo-color': '#f8f5e8', 'text-halo-width': 1 } },
    { id: 'peaks', type: 'circle', source: 'hiking', 'source-layer': 'mountain_peak', paint: { 'circle-color': '#554b40', 'circle-radius': 3 } },
    { id: 'peak-names', type: 'symbol', source: 'hiking', 'source-layer': 'mountain_peak', layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 1] }, paint: { 'text-color': '#443c37', 'text-halo-color': '#f8f5e8', 'text-halo-width': 1 } },
    { id: 'places', type: 'symbol', source: 'hiking', 'source-layer': 'place', layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': ['interpolate', ['linear'], ['zoom'], 7, 11, 13, 15] }, paint: { 'text-color': '#34463f', 'text-halo-color': '#f8f5e8', 'text-halo-width': 1.5 } },
  ];
  style.layers.push(...layers);
  return style;
}

async function start(): Promise<void> {
  const response = await fetch('./config.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`Offline configuration returned HTTP ${response.status}`);
  const config = await response.json() as Configuration;
  const region = config.regions[0];
  setWorkerUrl(workerUrl);
  addProtocol('pmtiles', new Protocol().tile);
  const map = new Map({
    container: 'map',
    style: styleFor(region),
    center: region ? [(region.bounds[0] + region.bounds[2]) / 2, (region.bounds[1] + region.bounds[3]) / 2] : [24.7, 45.5],
    zoom: region ? 10 : 6,
    pitch: region?.terrainUrl ? 55 : 0,
    maxPitch: 80,
    attributionControl: false,
  });
  map.addControl(new AttributionControl({ compact: false }), 'bottom-left');

  map.on('load', () => {
    if (region) {
      map.fitBounds([[region.bounds[0], region.bounds[1]], [region.bounds[2], region.bounds[3]]], { padding: 35, duration: 0 });
      if (region.terrainUrl) map.setTerrain({ source: 'elevation', exaggeration: 1 });
      hideStatus();
    } else {
      showStatus('No offline region installed yet');
    }
    bridge('ready', { hasRegion: Boolean(region), hasTerrain: Boolean(region?.terrainUrl) });
  });
  map.on('error', (event) => {
    const message = event.error?.message ?? 'Unknown MapLibre error';
    bridge('error', { message });
    showStatus('Map resource error. Check the app log.', true);
  });
  map.on('moveend', () => bridge('camera', { longitude: map.getCenter().lng, latitude: map.getCenter().lat, zoom: map.getZoom(), pitch: map.getPitch() }));

  window.hikingMap = {
    handleCommand(command: Command): void {
      switch (command.type) {
        case 'zoomIn': map.zoomIn(); break;
        case 'zoomOut': map.zoomOut(); break;
        case 'resetBearing': map.easeTo({ bearing: 0, pitch: region?.terrainUrl ? 55 : 0 }); break;
        case 'toggleTerrain':
          if (region?.terrainUrl) map.setTerrain(map.getTerrain() ? null : { source: 'elevation', exaggeration: 1 });
          break;
        case 'flyTo':
          if (Number.isFinite(command.longitude) && Number.isFinite(command.latitude)) {
            map.flyTo({ center: [command.longitude, command.latitude], zoom: Math.max(map.getZoom(), 12) });
          }
          break;
      }
    },
  };
}

start().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  bridge('error', { message });
  showStatus('Could not start the offline map.', true);
});

