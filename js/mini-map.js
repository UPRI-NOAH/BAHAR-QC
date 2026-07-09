/**
 * NOAH mini-map + expanded map — Mapbox GL JS port of MiniMapView.swift.
 * Same style URI, same mm_fh_100yr_tls source, same Flow_Legend_v2 ramp.
 */

const NOAH_STYLE = 'mapbox://styles/upri-noah/ckupb1t4ybxq517s530madpso';
const FLOOD_SOURCE_ID = 'mm-flood-depth';
const FLOOD_TILESET = 'mapbox://upri-noah.mm_fh_100yr_tls';
const FLOOD_SUFFIXES = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'j'];

// Flow_Legend_v2 step expression — mirrors MiniMapView.addFloodLayers.
const FLOOD_COLOR_EXPR = [
  'step',
  ['to-number', ['get', 'Var'], 0],
  'rgba(0,0,0,0)',
  0.20, '#FFFF00',
  0.51, '#FF8C00',
  1.01, '#FF00AA',
  2.01, '#8B008B',
  5.01, '#0047AB',
];

const DEFAULT_CENTER = [121.0685, 14.6539]; // UPRI, fallback until GPS locks
let cachedToken = null;

async function fetchToken() {
  if (cachedToken) return cachedToken;
  const res = await fetch('/api/config');
  if (!res.ok) throw new Error(`config: HTTP ${res.status}`);
  const { mapboxToken } = await res.json();
  if (!mapboxToken) throw new Error('config: missing mapboxToken');
  cachedToken = mapboxToken;
  return mapboxToken;
}

function addFloodLayers(map) {
  if (map.getSource(FLOOD_SOURCE_ID)) return;
  map.addSource(FLOOD_SOURCE_ID, { type: 'vector', url: FLOOD_TILESET });
  for (const suffix of FLOOD_SUFFIXES) {
    map.addLayer({
      id: `mm-flood-depth-${suffix}`,
      type: 'fill',
      source: FLOOD_SOURCE_ID,
      'source-layer': `mm_fh_100yr_${suffix}`,
      paint: {
        'fill-color': FLOOD_COLOR_EXPR,
        'fill-opacity': 0.65,
      },
    });
  }
}

async function createMap({ container, coordinate, interactive }) {
  const token = await fetchToken();
  // eslint-disable-next-line no-undef
  mapboxgl.accessToken = token;

  const center = coordinate ?? DEFAULT_CENTER;
  const zoom = interactive ? 16 : 15;

  // eslint-disable-next-line no-undef
  const map = new mapboxgl.Map({
    container,
    style: NOAH_STYLE,
    center,
    zoom,
    interactive,
    attributionControl: interactive, // hide attribution on the tiny map
    pitchWithRotate: false,
    dragRotate: false,
    touchPitch: false,
  });

  if (interactive) {
    map.touchZoomRotate.disableRotation();
  } else {
    map.scrollZoom.disable();
    map.boxZoom.disable();
    map.dragPan.disable();
    map.dragRotate.disable();
    map.keyboard.disable();
    map.doubleClickZoom.disable();
    map.touchZoomRotate.disable();
  }

  await new Promise(resolve => {
    if (map.isStyleLoaded()) resolve();
    else map.once('style.load', resolve);
  });

  addFloodLayers(map);

  // Blue location puck via GeolocateControl-style marker — simple dot marker
  // is enough here since the mini-map just needs "you are here".
  let marker = null;
  if (coordinate) {
    // eslint-disable-next-line no-undef
    marker = new mapboxgl.Marker({ color: '#007AFF' })
      .setLngLat(coordinate)
      .addTo(map);
  }

  return {
    map,
    setCoordinate(next) {
      if (!next) return;
      // eslint-disable-next-line no-undef
      if (!marker) marker = new mapboxgl.Marker({ color: '#007AFF' }).setLngLat(next).addTo(map);
      else marker.setLngLat(next);
      if (interactive) return; // let the user pan freely once opened
      map.easeTo({ center: next, duration: 400 });
    },
    destroy() {
      marker?.remove();
      map.remove();
    },
  };
}

export function initMiniMap(containerId, coordinate) {
  return createMap({ container: containerId, coordinate, interactive: false });
}

export function initExpandedMap(containerId, coordinate) {
  return createMap({ container: containerId, coordinate, interactive: true });
}
