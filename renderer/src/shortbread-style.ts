import type { StyleSpecification } from 'maplibre-gl';

// BBBike Shortbread 1.0 has no SAC, route-relation, or peak fields.
export function shortbreadLayers(): StyleSpecification['layers'] {
  const trails: any = ['in', ['get', 'kind'], ['literal', ['path', 'footway', 'pedestrian', 'track', 'steps', 'bridleway']]];
  return [
    { id: 'sb-land', type: 'fill', source: 'hiking', 'source-layer': 'land', paint: { 'fill-color': ['match', ['get', 'kind'], 'forest', '#70a56f', 'grassland', '#b5ce83', 'grass', '#b5ce83', 'meadow', '#c6da91', 'scrub', '#a7c68a', 'heath', '#c5bd8d', 'farmland', '#e5d89f', 'residential', '#d9c8b6', 'bare_rock', '#c6baa5', 'scree', '#c9b99d', '#bfd29a'], 'fill-opacity': 0.88 } },
    { id: 'sb-water', type: 'fill', source: 'hiking', 'source-layer': 'water_polygons', paint: { 'fill-color': '#6eb9d3' } },
    { id: 'sb-water-lines', type: 'line', source: 'hiking', 'source-layer': 'water_lines', paint: { 'line-color': '#438cab', 'line-width': 1.5 } },
    { id: 'sb-roads', type: 'line', source: 'hiking', 'source-layer': 'streets', filter: ['!', trails], paint: { 'line-color': '#f8f2e4', 'line-width': ['interpolate', ['linear'], ['zoom'], 9, 1, 14, 3] } },
    { id: 'sb-trails', type: 'line', source: 'hiking', 'source-layer': 'streets', filter: trails, paint: { 'line-color': '#8d4a31', 'line-width': ['interpolate', ['linear'], ['zoom'], 10, 1, 14, 2], 'line-dasharray': [2, 1] } },
    { id: 'sb-huts', type: 'circle', source: 'hiking', 'source-layer': 'pois', filter: ['any', ['in', ['get', 'tourism'], ['literal', ['alpine_hut', 'wilderness_hut', 'camp_site']]], ['==', ['get', 'amenity'], 'shelter']], paint: { 'circle-color': '#9b4332', 'circle-radius': 5, 'circle-stroke-color': '#fff8e5', 'circle-stroke-width': 1.5 } },
    { id: 'sb-hut-labels', type: 'symbol', source: 'hiking', 'source-layer': 'pois', filter: ['any', ['in', ['get', 'tourism'], ['literal', ['alpine_hut', 'wilderness_hut', 'camp_site']]], ['==', ['get', 'amenity'], 'shelter']], layout: { 'text-field': ['coalesce', ['get', 'name'], ''], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 1.2] }, paint: { 'text-color': '#53382f', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.5 } },
    { id: 'sb-places', type: 'symbol', source: 'hiking', 'source-layer': 'place_labels', layout: { 'text-field': ['coalesce', ['get', 'name'], ''], 'text-font': ['Noto Sans Regular'], 'text-size': ['interpolate', ['linear'], ['zoom'], 7, 11, 14, 16] }, paint: { 'text-color': '#34443f', 'text-halo-color': '#fff9e9', 'text-halo-width': 1.5 } },
  ];
}
