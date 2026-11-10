import type { FilterSpecification, StyleSpecification } from 'maplibre-gl';

/** Style for the deliberately small Ridgewalk v1 OSM vector tile schema. */
export function hikingLayers(): StyleSpecification['layers'] {
  const trail: FilterSpecification = ['in', ['get', 'highway'], ['literal', ['path', 'footway', 'pedestrian', 'track', 'bridleway', 'steps']]];
  const named: FilterSpecification = ['all', ['has', 'name'], ['!=', ['get', 'name'], '']];
  return [
    { id: 'hiking-landcover', type: 'fill', source: 'hiking', 'source-layer': 'landcover',
      paint: { 'fill-color': ['match', ['get', 'natural'], 'wood', '#81a87c', 'grassland', '#bad19b', 'scrub', '#abc395', 'heath', '#c8c69c', 'wetland', '#a5bfae', ['match', ['get', 'landuse'], 'forest', '#81a87c', 'residential', '#d7d0bd', 'farmland', '#d6d3a1', '#bbd19d']], 'fill-opacity': 0.7 } },
    { id: 'hiking-water', type: 'fill', source: 'hiking', 'source-layer': 'water', paint: { 'fill-color': '#6dabc1', 'fill-opacity': 0.9 } },
    { id: 'hiking-waterway', type: 'line', source: 'hiking', 'source-layer': 'waterway',
      paint: { 'line-color': '#438cab', 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 0.7, 14, 2.4] } },
    { id: 'hiking-roads-casing', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: ['!', trail],
      paint: { 'line-color': '#9b9586', 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 1.8, 14, 5] } },
    { id: 'hiking-roads', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: ['!', trail],
      paint: { 'line-color': '#f9f3e4', 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 1.1, 14, 3.5] } },
    { id: 'hiking-trails-casing', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: trail,
      paint: { 'line-color': '#fff5db', 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 2, 14, 5] } },
    { id: 'hiking-routes', type: 'line', source: 'hiking', 'source-layer': 'hiking_routes', minzoom: 10,
      paint: { 'line-color': ['match', ['get', 'route_color'], 'red', '#ca3732', 'blue', '#2c68ac', 'yellow', '#b88a16', 'green', '#43804b', '#a95036'], 'line-opacity': 0.86, 'line-width': ['interpolate', ['linear'], ['zoom'], 10, 1.8, 14, 4] } },
    { id: 'hiking-trails', type: 'line', source: 'hiking', 'source-layer': 'transportation', filter: trail,
      paint: { 'line-color': ['match', ['get', 'sac_scale'], 'mountain_hiking', '#7f4a39', 'demanding_mountain_hiking', '#8e3736', 'alpine_hiking', '#992e36', 'demanding_alpine_hiking', '#992e36', 'difficult_alpine_hiking', '#992e36', '#715c40'], 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 0.8, 14, 1.7], 'line-dasharray': [2, 1.5] } },
    { id: 'hiking-path-labels', type: 'symbol', source: 'hiking', 'source-layer': 'transportation', minzoom: 13, filter: ['all', trail, named],
      layout: { 'symbol-placement': 'line', 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 11 },
      paint: { 'text-color': '#574631', 'text-halo-color': '#f9f5e8', 'text-halo-width': 1.4 } },
    { id: 'hiking-route-labels', type: 'symbol', source: 'hiking', 'source-layer': 'hiking_routes', minzoom: 12,
      filter: ['any', ['has', 'ref'], ['has', 'name']],
      layout: { 'symbol-placement': 'line', 'symbol-spacing': 400, 'text-field': ['coalesce', ['get', 'ref'], ['get', 'name']], 'text-font': ['Noto Sans Regular'], 'text-size': 10 },
      paint: { 'text-color': '#34312e', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.5 } },
    { id: 'hiking-huts', type: 'circle', source: 'hiking', 'source-layer': 'huts',
      paint: { 'circle-color': ['match', ['get', 'tourism'], 'camp_site', '#506f55', '#9b4332'], 'circle-radius': ['interpolate', ['linear'], ['zoom'], 9, 3.5, 14, 6], 'circle-stroke-color': '#fff8e5', 'circle-stroke-width': 1.8 } },
    { id: 'hiking-hut-labels', type: 'symbol', source: 'hiking', 'source-layer': 'huts', minzoom: 11, filter: named,
      layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 1.2], 'text-optional': true },
      paint: { 'text-color': '#53382f', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.5 } },
    { id: 'hiking-mountain', type: 'circle', source: 'hiking', 'source-layer': 'mountain',
      paint: { 'circle-color': ['match', ['get', 'natural'], 'peak', '#4e4840', 'saddle', '#735c44', '#785641'], 'circle-radius': 3.5, 'circle-stroke-color': '#fff9e9', 'circle-stroke-width': 1.2 } },
    { id: 'hiking-mountain-labels', type: 'symbol', source: 'hiking', 'source-layer': 'mountain', minzoom: 10, filter: ['any', named, ['has', 'ele']],
      layout: { 'text-field': ['concat', ['coalesce', ['get', 'name'], ''], ['case', ['has', 'ele'], ['concat', ['case', ['has', 'name'], '\n', ''], ['get', 'ele'], ' m'], '']], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 1.1] },
      paint: { 'text-color': '#353633', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.6 } },
    { id: 'hiking-places', type: 'symbol', source: 'hiking', 'source-layer': 'places',
      layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': ['interpolate', ['linear'], ['zoom'], 9, 11, 14, 16] },
      paint: { 'text-color': '#34443f', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.8 } },
  ];
}
