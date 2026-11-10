import { AttributionControl, Map, Marker, Popup, addProtocol, setWorkerUrl, type StyleSpecification } from 'maplibre-gl';
import { PMTiles, Protocol, TileType } from 'pmtiles';
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
import fontUrl from '@fontsource/noto-sans/files/noto-sans-latin-400-normal.woff2?url';
import latinExtFontUrl from '@fontsource/noto-sans/files/noto-sans-latin-ext-400-normal.woff2?url';
import cyrillicFontUrl from '@fontsource/noto-sans/files/noto-sans-cyrillic-400-normal.woff2?url';
import 'maplibre-gl/dist/maplibre-gl.css';
import './style.css';
import { hikingLayers } from './hiking-style';
import { shortbreadLayers } from './shortbread-style';

type Bounds = [number, number, number, number];
type Region = {
  id: string;
  name: string;
  bounds: Bounds;
  mapUrl?: string;
  vectorSchema?: 'ridgewalk-hiking-v1' | 'shortbread-1.0';
  terrainUrl?: string;
  peaksUrl?: string;
  terrainEncoding?: 'mapbox' | 'terrarium';
  attribution: string;
  mapAttribution?: string;
  terrainAttribution?: string;
};
type Configuration = { regions: Region[] };
type Command =
  | { type: 'zoomIn' | 'zoomOut' | 'resetCamera' }
  | { type: 'setView'; mode: '2d' | '3d' }
  | { type: 'setExaggeration'; value: number }
  | { type: 'flyTo'; longitude: number; latitude: number }
  | { type: 'showSearchResult'; longitude: number; latitude: number }
  | { type: 'updateLocation'; longitude: number; latitude: number; accuracy: number | null; heading: number | null; follow: boolean }
  | { type: 'centerLocation' | 'clearLocation' }
  | { type: 'selectBounds' | 'cancelBounds' }
  | { type: 'showBounds'; bounds: Bounds };

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

function styleFor(region?: Region, terrainAvailable = false): StyleSpecification {
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
  if (region.mapUrl) {
    style.sources.hiking = {
      type: 'vector',
      url: `pmtiles://${region.mapUrl}`,
      attribution: region.mapAttribution ?? region.attribution,
    };
  }
  if (region.peaksUrl) style.sources.peaks = { type: 'geojson', data: region.peaksUrl };
  if (terrainAvailable && region.terrainUrl) {
    style.sources.elevation = {
      type: 'raster-dem',
      url: `pmtiles://${region.terrainUrl}`,
      encoding: region.terrainEncoding ?? 'mapbox',
      tileSize: region.vectorSchema === 'shortbread-1.0' ? 512 : 256,
      attribution: region.terrainAttribution ?? region.attribution,
    };
    style.layers.push({
      id: 'terrain-hillshade', type: 'hillshade', source: 'elevation',
      paint: { 'hillshade-exaggeration': 0.55, 'hillshade-shadow-color': '#455b59', 'hillshade-highlight-color': '#f5f1dc' },
    });
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
  if (region.mapUrl) style.layers.push(...(region.vectorSchema === 'ridgewalk-hiking-v1' ? hikingLayers() : region.vectorSchema === 'shortbread-1.0' ? shortbreadLayers() : layers));
  if (region.peaksUrl) style.layers.push(
    { id: 'sb-peaks', type: 'circle', source: 'peaks', minzoom: 9, paint: { 'circle-color': '#4e4840', 'circle-radius': 3.5, 'circle-stroke-color': '#fff9e9', 'circle-stroke-width': 1.2 } },
    { id: 'sb-peak-labels', type: 'symbol', source: 'peaks', minzoom: 10, layout: { 'text-field': ['concat', ['get', 'name'], ['case', ['has', 'ele'], ['concat', '\n', ['get', 'ele'], ' m'], '']], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 1.1] }, paint: { 'text-color': '#353633', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.6 } },
  );
  return style;
}

async function start(): Promise<void> {
  const response = await fetch('./config.json', { cache: 'no-store' });
  if (!response.ok) throw new Error(`Offline configuration returned HTTP ${response.status}`);
  const config = await response.json() as Configuration;
  const region = Array.isArray(config.regions) ? config.regions[0] : undefined;
  setWorkerUrl(workerUrl);
  const protocol = new Protocol();
  addProtocol('pmtiles', protocol.tile);
  let mapAvailable = false;
  let mapError: string | undefined;
  if (region?.mapUrl) {
    showStatus('Checking local hiking tiles…');
    try {
      const archive = new PMTiles(region.mapUrl);
      const header = await archive.getHeader();
      if (header.tileType !== TileType.Mvt || header.minZoom > header.maxZoom) {
        throw new Error('Hiking archive must contain vector tiles');
      }
      if (header.numAddressedTiles < 1) throw new Error('Hiking archive has no tiles');
      const metadata = await archive.getMetadata() as { vector_layers?: { id?: string }[] };
      if (region.vectorSchema === 'ridgewalk-hiking-v1' &&
          !['transportation', 'mountain', 'huts', 'hiking_routes'].every((layer) => metadata.vector_layers?.some((entry: { id?: string }) => entry.id === layer))) {
        throw new Error('Hiking archive is missing required schema layers');
      }
      protocol.add(archive);
      mapAvailable = true;
    } catch (error) {
      mapError = error instanceof Error ? error.message : String(error);
      bridge('error', { message: `Local hiking map validation failed: ${mapError}` });
      delete region.mapUrl;
    }
  }
  let terrainAvailable = false;
  let terrainError: string | undefined;
  let demArchive: PMTiles | undefined;
  let demMaxZoom = 0;
  if (region?.terrainUrl) {
    showStatus('Checking local elevation tiles…');
    try {
      const archive = new PMTiles(region.terrainUrl);
      const header = await archive.getHeader();
      const expectedType = region.vectorSchema === 'shortbread-1.0' ? TileType.Webp : TileType.Png;
      if (header.tileType !== expectedType || header.minZoom > header.maxZoom) {
        throw new Error('DEM archive has an incompatible tile format');
      }
      const zoom = header.maxZoom;
      const longitude = (region.bounds[0] + region.bounds[2]) / 2;
      const latitude = (region.bounds[1] + region.bounds[3]) / 2;
      const x = Math.floor((longitude + 180) / 360 * 2 ** zoom);
      const y = Math.floor((1 - Math.asinh(Math.tan(latitude * Math.PI / 180)) / Math.PI) / 2 * 2 ** zoom);
      const tile = await archive.getZxy(zoom, x, y);
      const signature = tile && new Uint8Array(tile.data).slice(0, 8);
      const valid = signature && (expectedType === TileType.Png
        ? signature.join(',') === '137,80,78,71,13,10,26,10'
        : String.fromCharCode(...signature.slice(0, 4)) === 'RIFF');
      if (!valid) {
        throw new Error('DEM tile at region center is missing or has an invalid signature');
      }
      protocol.add(archive);
      demArchive = archive;
      demMaxZoom = header.maxZoom;
      terrainAvailable = true;
    } catch (error) {
      terrainError = error instanceof Error ? error.message : String(error);
      bridge('error', { message: `Local DEM validation failed: ${terrainError}` });
    }
  }

  let mode: '2d' | '3d' = terrainAvailable ? '3d' : '2d';
  let exaggeration = 1;
  let terrainLoaded = false;
  let terrainFailed = Boolean(terrainError);
  let terrainActivated = false;
  let mapLoaded = false;
  const sendMapState = () => bridge('mapStatus', {
    status: mapError ? 'error' : mapAvailable ? (mapLoaded ? 'ready' : 'loading') : 'missing',
    message: mapError ?? (region ? 'Hiking map tiles are not installed for this region' : 'No region installed'),
  });
  const sendTerrainState = () => bridge('terrainStatus', {
    hasTerrain: terrainAvailable,
    mode,
    exaggeration,
    status: terrainFailed ? 'error' : terrainAvailable ? (terrainLoaded ? 'ready' : 'loading') : 'missing',
    message: terrainError ?? (terrainAvailable ? '' : region ? 'Elevation data is not installed for this region' : 'No region installed'),
  });

  const map = new Map({
    container: 'map',
    style: styleFor(region, terrainAvailable),
    center: region ? [(region.bounds[0] + region.bounds[2]) / 2, (region.bounds[1] + region.bounds[3]) / 2] : [24.7, 45.5],
    zoom: region ? 11 : 6,
    pitch: terrainAvailable ? 55 : 0,
    maxPitch: terrainAvailable ? 80 : 0,
    dragPan: true,
    touchZoomRotate: true,
    touchPitch: terrainAvailable,
    dragRotate: true,
    scrollZoom: true,
    attributionControl: false,
  });
  map.addControl(new AttributionControl({ compact: false }), 'bottom-left');
  let searchMarker: Marker | undefined;
  let locationMarker: Marker | undefined;
  let locationElement: HTMLDivElement | undefined;
  let currentLocation: [number, number] | undefined;
  let locationSequence = 0;
  const accuracySource = 'location-accuracy';
  const showAccuracy = (longitude: number, latitude: number, meters: number | null) => {
    const source = map.getSource(accuracySource) as import('maplibre-gl').GeoJSONSource | undefined;
    if (!source) return;
    const points: number[][] = [];
    if (meters != null && Number.isFinite(meters) && meters > 0 && meters <= 50000) {
      for (let i = 0; i <= 64; i++) {
        const angle = 2 * Math.PI * i / 64;
        const lat = latitude + meters * Math.cos(angle) / 111320;
        const lon = longitude + meters * Math.sin(angle) / (111320 * Math.max(0.01, Math.cos(latitude * Math.PI / 180)));
        points.push([lon, lat]);
      }
    }
    source.setData({ type: 'FeatureCollection', features: points.length ? [{
      type: 'Feature', properties: {}, geometry: { type: 'Polygon', coordinates: [points] },
    }] : [] });
  };

  // Read the encoded source pixel directly: MapLibre's terrain query is scaled
  // by exaggeration and is unavailable in 2D mode.
  const sampleDem = async (longitude: number, latitude: number): Promise<number | null> => {
    if (!demArchive || !region || longitude < region.bounds[0] || longitude > region.bounds[2] ||
        latitude < region.bounds[1] || latitude > region.bounds[3]) return null;
    for (let zoom = demMaxZoom; zoom >= 0; zoom--) {
      const size = 2 ** zoom;
      const x = (longitude + 180) / 360 * size;
      const y = (1 - Math.asinh(Math.tan(latitude * Math.PI / 180)) / Math.PI) / 2 * size;
      const tile = await demArchive.getZxy(zoom, Math.floor(x), Math.floor(y));
      if (!tile) continue;
      const bitmap = await createImageBitmap(new Blob([tile.data], { type: region?.vectorSchema === 'shortbread-1.0' ? 'image/webp' : 'image/png' }),
        { colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
      try {
        const canvas = document.createElement('canvas');
        canvas.width = bitmap.width; canvas.height = bitmap.height;
        const context = canvas.getContext('2d', { willReadFrequently: true });
        if (!context) return null;
        context.drawImage(bitmap, 0, 0);
        const pixel = context.getImageData(
          Math.min(bitmap.width - 1, Math.floor((x - Math.floor(x)) * bitmap.width)),
          Math.min(bitmap.height - 1, Math.floor((y - Math.floor(y)) * bitmap.height)), 1, 1).data;
        if (pixel[3] === 0) return null;
        const elevation = region.terrainEncoding === 'terrarium'
          ? pixel[0] * 256 + pixel[1] + pixel[2] / 256 - 32768
          : -10000 + (pixel[0] * 65536 + pixel[1] * 256 + pixel[2]) * 0.1;
        return elevation <= -10000 ? null : elevation;
      } finally { bitmap.close(); }
    }
    return null;
  };
  let picking = false;
  let firstCorner: [number, number] | undefined;
  const selectionSource = 'region-selection';
  const drawSelection = (bounds?: Bounds) => {
    if (!map.getSource(selectionSource)) return;
    const coordinates = bounds ? [[[bounds[0], bounds[1]], [bounds[2], bounds[1]],
      [bounds[2], bounds[3]], [bounds[0], bounds[3]], [bounds[0], bounds[1]]]] : [];
    (map.getSource(selectionSource) as import('maplibre-gl').GeoJSONSource).setData({
      type: 'FeatureCollection', features: bounds ? [{ type: 'Feature', properties: {},
        geometry: { type: 'Polygon', coordinates } }] : [],
    });
  };

  const resetCamera = () => {
    if (region) {
      map.fitBounds([[region.bounds[0], region.bounds[1]], [region.bounds[2], region.bounds[3]]], {
        padding: 35, duration: 500, bearing: 0, pitch: mode === '3d' ? 55 : 0,
      });
    } else {
      map.easeTo({ center: [24.7, 45.5], zoom: 6, pitch: 0, bearing: 0 });
    }
  };

  let initialized = false;
  map.on('style.load', () => {
    map.addSource(accuracySource, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map.addLayer({ id: 'location-accuracy-fill', type: 'fill', source: accuracySource,
      paint: { 'fill-color': '#287fd0', 'fill-opacity': 0.16 } });
    map.addLayer({ id: 'location-accuracy-outline', type: 'line', source: accuracySource,
      paint: { 'line-color': '#287fd0', 'line-opacity': 0.65, 'line-width': 1 } });
    map.addSource(selectionSource, { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map.addLayer({ id: 'selection-fill', type: 'fill', source: selectionSource,
      paint: { 'fill-color': '#e59b44', 'fill-opacity': 0.24 } });
    map.addLayer({ id: 'selection-outline', type: 'line', source: selectionSource,
      paint: { 'line-color': '#a95422', 'line-width': 3 } });
    if (terrainAvailable && mode === '3d') {
      terrainLoaded = false;
      map.setTerrain({ source: 'elevation', exaggeration });
      terrainActivated = true;
      showStatus('Loading local elevation tiles…');
    } else if (terrainAvailable) {
      hideStatus();
    } else if (terrainError) {
      showStatus('Local elevation tiles are unavailable or corrupt.', true);
    } else if (region) {
      hideStatus();
    }
    if (initialized) return;
    initialized = true;
    if (region) {
      map.fitBounds([[region.bounds[0], region.bounds[1]], [region.bounds[2], region.bounds[3]]], {
        padding: 35, duration: 0, bearing: 0, pitch: terrainAvailable ? 55 : 0,
      });
    } else {
      showStatus('No offline region installed yet');
    }
    bridge('ready', { hasRegion: Boolean(region), hasTerrain: terrainAvailable });
    sendMapState();
    sendTerrainState();
  });
  map.on('idle', () => {
    if (mapAvailable && !mapLoaded && map.isSourceLoaded('hiking')) {
      mapLoaded = true;
      sendMapState();
    }
  });
  const checkTerrainReady = () => {
    if (!terrainActivated || terrainLoaded || terrainFailed || !region ||
        !map.isSourceLoaded('elevation') || !map.areTilesLoaded()) return;
    const center: [number, number] = [(region.bounds[0] + region.bounds[2]) / 2, (region.bounds[1] + region.bounds[3]) / 2];
    const elevation = map.queryTerrainElevation(center);
    if (elevation != null && Number.isFinite(elevation)) {
      terrainLoaded = true;
      if (mapError || !mapAvailable) showStatus('Local hiking map tiles are unavailable.', true);
      else hideStatus();
      bridge('terrainSample', { elevation });
      sendTerrainState();
    }
  };
  map.on('render', checkTerrainReady);
  map.on('idle', checkTerrainReady);
  map.on('error', (event) => {
    const message = event.error?.message ?? 'Unknown MapLibre error';
    bridge('error', { message });
    if (terrainAvailable && !terrainLoaded) {
      terrainError = message;
      terrainFailed = true;
      showStatus('Elevation tiles failed to load.', true);
      sendTerrainState();
    } else {
      showStatus('Map resource error. Check the app log.', true);
    }
  });
  let lastCameraEvent = 0;
  const sendCamera = (force = false) => {
    const now = performance.now();
    if (!force && now - lastCameraEvent < 100) return;
    lastCameraEvent = now;
    bridge('camera', {
      longitude: map.getCenter().lng, latitude: map.getCenter().lat,
      zoom: map.getZoom(), pitch: map.getPitch(), bearing: map.getBearing(),
    });
  };
  map.on('move', () => sendCamera());
  map.on('moveend', () => sendCamera(true));
  for (const eventName of ['dragstart', 'zoomstart', 'rotatestart', 'pitchstart'] as const) {
    map.on(eventName, (event) => { if (event.originalEvent) bridge('userMapMove'); });
  }
  map.on('click', (event) => {
    if (picking) {
      const point: [number, number] = [event.lngLat.lng, event.lngLat.lat];
      if (!firstCorner) {
        firstCorner = point;
        bridge('selectionStatus', { message: 'Tap the opposite corner of the rectangle' });
      } else {
        const bounds: Bounds = [Math.min(firstCorner[0], point[0]), Math.min(firstCorner[1], point[1]),
          Math.max(firstCorner[0], point[0]), Math.max(firstCorner[1], point[1])];
        firstCorner = undefined;
        picking = false;
        if (bounds[2] - bounds[0] > 0.0001 && bounds[3] - bounds[1] > 0.0001) {
          drawSelection(bounds);
          bridge('selectedBounds', { bounds });
        }
      }
      return;
    }
    if (!mapAvailable) return;
    const hitLayers = ['hiking-trails', 'hiking-routes', 'hiking-mountain', 'hiking-huts', 'sb-trails', 'sb-huts', 'sb-peaks'].filter((id) => map.getLayer(id));
    const hits = map.queryRenderedFeatures(event.point, { layers: hitLayers });
    if (!hits.length) return;
    const path = hits.find((item) => item.layer.id === 'hiking-trails' || item.layer.id === 'sb-trails')?.properties;
    const route = hits.find((item) => item.layer.id === 'hiking-routes')?.properties;
    const mountain = hits.find((item) => item.layer.id === 'hiking-mountain' || item.layer.id === 'sb-peaks')?.properties;
    const hut = hits.find((item) => item.layer.id === 'hiking-huts' || item.layer.id === 'sb-huts')?.properties;
    const title = route?.name || route?.ref || path?.name || mountain?.name || hut?.name || 'Map feature';
    const panel = document.createElement('div');
    panel.className = 'feature-popup';
    const heading = document.createElement('strong');
    heading.textContent = String(title);
    panel.append(heading);
    const details: [string, unknown][] = [
      ['Path', path?.highway || path?.kind], ['SAC difficulty', path?.sac_scale], ['Trail visibility', path?.trail_visibility],
      ['Hiking route', route?.ref || route?.name], ['Trail marking', route?.['osmc:symbol'] || route?.colour],
      ['Elevation', mountain?.ele ? `${mountain.ele} m` : undefined], ['Type', hut?.tourism || hut?.amenity || mountain?.natural],
    ];
    for (const [label, value] of details) {
      if (value == null || value === '') continue;
      const row = document.createElement('div');
      row.textContent = `${label}: ${String(value).replaceAll('_', ' ')}`;
      panel.append(row);
    }
    new Popup({ closeButton: true, maxWidth: '260px' }).setLngLat(event.lngLat).setDOMContent(panel).addTo(map);
  });

  window.hikingMap = {
    handleCommand(command: Command): void {
      switch (command.type) {
        case 'zoomIn': map.zoomIn(); break;
        case 'zoomOut': map.zoomOut(); break;
        case 'resetCamera': resetCamera(); break;
        case 'updateLocation': {
          const { longitude, latitude, accuracy, heading, follow } = command;
          if (!Number.isFinite(longitude) || !Number.isFinite(latitude) ||
              Math.abs(longitude) > 180 || Math.abs(latitude) > 90) break;
          if (Math.abs(latitude) > 85) {
            bridge('locationTerrain', { longitude, latitude, elevation: null });
            bridge('notice', { message: 'This latitude is outside the map projection' });
            break;
          }
          currentLocation = [longitude, latitude];
          if (!locationMarker) {
            locationElement = document.createElement('div');
            locationElement.className = 'location-fix';
            locationElement.innerHTML = '<span class="location-course"></span><span class="location-dot"></span>';
            locationMarker = new Marker({ element: locationElement, rotationAlignment: 'map' })
              .setLngLat(currentLocation).addTo(map);
          } else locationMarker.setLngLat(currentLocation);
          locationElement?.classList.toggle('has-course', heading != null);
          locationElement?.classList.toggle('poor-accuracy', accuracy == null || accuracy > 100);
          locationMarker.setRotation(heading ?? 0);
          showAccuracy(longitude, latitude, accuracy);
          if (follow && accuracy != null && accuracy > 0 && accuracy <= 100) {
            map.easeTo({ center: currentLocation, zoom: Math.max(map.getZoom(), 13), duration: 700 });
          }
          const sequence = ++locationSequence;
          void sampleDem(longitude, latitude).then((elevation) => {
            if (sequence === locationSequence) bridge('locationTerrain', { longitude, latitude, elevation });
          }).catch((error: unknown) => {
            if (sequence === locationSequence) bridge('locationTerrain', { longitude, latitude, elevation: null,
              message: error instanceof Error ? error.message : String(error) });
          });
          break;
        }
        case 'centerLocation':
          if (currentLocation) map.easeTo({ center: currentLocation, zoom: Math.max(map.getZoom(), 13), duration: 700 });
          break;
        case 'clearLocation':
          locationSequence++; locationMarker?.remove(); locationMarker = undefined; locationElement = undefined;
          currentLocation = undefined; showAccuracy(0, 0, null); break;
        case 'selectBounds':
          picking = true; firstCorner = undefined; drawSelection();
          bridge('selectionStatus', { message: 'Tap the first corner of the rectangle' });
          break;
        case 'cancelBounds': picking = false; firstCorner = undefined; drawSelection(); break;
        case 'showBounds':
          if (command.bounds?.length === 4 && command.bounds.every(Number.isFinite)) {
            drawSelection(command.bounds);
            map.fitBounds([[command.bounds[0], command.bounds[1]], [command.bounds[2], command.bounds[3]]],
              { padding: 45, duration: 400 });
          }
          break;
        case 'setView':
          if (!terrainAvailable || (command.mode !== '2d' && command.mode !== '3d')) break;
          mode = command.mode;
          map.setTerrain(mode === '3d' ? { source: 'elevation', exaggeration } : null);
          map.setMaxPitch(mode === '3d' ? 80 : 0);
          if (mode === '3d') map.touchPitch.enable(); else map.touchPitch.disable();
          map.easeTo({ pitch: mode === '3d' ? 55 : 0 });
          sendTerrainState();
          bridge('terrainApplied', { active: Boolean(map.getTerrain()), exaggeration: map.getTerrain()?.exaggeration ?? null });
          break;
        case 'setExaggeration':
          if (!terrainAvailable || !Number.isFinite(command.value)) break;
          exaggeration = Math.min(2.5, Math.max(1, command.value));
          if (mode === '3d') map.setTerrain({ source: 'elevation', exaggeration });
          sendTerrainState();
          bridge('terrainApplied', { active: Boolean(map.getTerrain()), exaggeration: map.getTerrain()?.exaggeration ?? null });
          break;
        case 'flyTo':
          if (Number.isFinite(command.longitude) && Number.isFinite(command.latitude)) {
            if (region && (command.longitude < region.bounds[0] || command.longitude > region.bounds[2] ||
                command.latitude < region.bounds[1] || command.latitude > region.bounds[3])) {
              bridge('notice', { message: 'Location is outside the installed region' });
              break;
            }
            map.flyTo({ center: [command.longitude, command.latitude], zoom: Math.max(map.getZoom(), 12) });
          }
          break;
        case 'showSearchResult':
          if (Number.isFinite(command.longitude) && Number.isFinite(command.latitude) &&
              Math.abs(command.longitude) <= 180 && Math.abs(command.latitude) <= 85) {
            searchMarker?.remove();
            searchMarker = new Marker({ color: '#b44f2a' })
              .setLngLat([command.longitude, command.latitude]).addTo(map);
            map.flyTo({ center: [command.longitude, command.latitude],
              zoom: Math.max(map.getZoom(), 13), essential: true });
            if (region && (command.longitude < region.bounds[0] || command.longitude > region.bounds[2] ||
                command.latitude < region.bounds[1] || command.latitude > region.bounds[3])) {
              bridge('notice', { message: 'No offline map tiles cover these coordinates' });
            }
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

