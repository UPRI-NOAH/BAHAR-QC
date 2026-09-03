/**
 * BAHAR — app.js
 * Main controller: wires FloodData + ARRenderer + GPS + UI.
 * One code path for every platform (iOS Safari and Chrome Android):
 * getUserMedia camera feed + DeviceOrientationEvent for 3DOF rotation.
 */

import { FloodData }  from './flood-data-ios.js';
import { ARRenderer } from './ar-renderer-ios.js';
import { initMiniMap, initExpandedMap } from './mini-map.js';

const flood    = new FloodData();
const renderer = new ARRenderer(
  document.getElementById('ar-canvas'),
  document.getElementById('ar-overlay')
);

/* ── UI elements ───────────────────────────────────────────────────────────── */
const elStatus      = document.getElementById('status-msg');
const elBtnStart    = document.getElementById('btn-start');
const elBtnExit     = document.getElementById('btn-exit');
const elGpsDot      = document.getElementById('gps-dot');
const elGpsText     = document.getElementById('gps-text');
const elDepthEmoji  = document.getElementById('depth-emoji');
const elDepthLabel  = document.getElementById('depth-label');
const elDepthVal    = document.getElementById('depth-value');
const elDepthSub    = document.getElementById('depth-sub');
const elDepthCat    = document.getElementById('depth-category');
const elDepthCatRow = document.getElementById('depth-category-row');
const elDepthCatName = document.getElementById('depth-category-name');
const elScanHint    = document.getElementById('scan-hint');
const elLanding     = document.getElementById('screen-landing');
const elOverlay     = document.getElementById('ar-overlay');
const elCanvas      = document.getElementById('ar-canvas');
const elFloodFilter = document.getElementById('flood-filter');
const elDisclaimer  = document.querySelector('.disclaimer');

/* Mini-map + advisory */
const elMiniMapBtn      = document.getElementById('mini-map-btn');
const elBtnAdvisory     = document.getElementById('btn-advisory');
const elAdvisoryIcon    = document.getElementById('advisory-icon');
const elAdvisoryPop     = document.getElementById('advisory-popover');
const elAdvisoryPopIcon = document.getElementById('advisory-popover-icon');
const elAdvisoryPopText = document.getElementById('advisory-popover-text');
const elExpandedMap     = document.getElementById('expanded-map-overlay');
const elBtnCloseMap     = document.getElementById('btn-close-map');
const elMapBackdrop     = document.getElementById('expanded-map-backdrop');

let miniMap = null;
let expandedMap = null;
let currentCoord = null;
let currentCategory = 'none';

let gpsWatchId   = null;
let currentDepth = 0;
let currentHazard = 'none';

// Demo mode: append `?demo=<meters>` to the URL to force a flood depth so
// the AR water can be shown outside flood-prone areas (e.g. `?demo=0.95`
// for waist-level). No param → real GPS + Metro Manila tilequery.
//   Knee ~0.5, Waist ~0.95, Chest ~1.35
const DEBUG_DEPTH_OVERRIDE = (() => {
  const raw = new URLSearchParams(location.search).get('demo');
  const v = parseFloat(raw);
  return Number.isFinite(v) ? v : null;
})();


/* ── Boot sequence ─────────────────────────────────────────────────────────── */
async function boot() {
  setStatus('Initialising…');

  try {
    await flood.load();
  } catch (e) {
    setStatus('Could not initialise flood data. Check console.', 'err');
    console.error(e);
    return;
  }

  // Same code path on every platform: rear camera as background + device
  // orientation for rotation. WebXR is no longer used — dropping it lets
  // Android sample the camera feed inside the water shader too (WebXR
  // immersive-ar hides it from WebGL).
  if (!navigator.mediaDevices?.getUserMedia) {
    setStatus('Camera not available. Use Safari (iOS 14.5+) or Chrome.', 'err');
    return;
  }

  elDisclaimer.innerHTML =
    'Requires modern mobile browser (iOS 14.5+ Safari or Chrome Android).<br>Allow camera &amp; motion access when prompted.';
  elScanHint.textContent = 'Point camera at yourself, a person, or the ground';

  renderer.init();
  setStatus('Ready — tap Start AR!', 'ok');
  elBtnStart.disabled = false;
}

/* ── Start AR ─────────────────────────────────────────────────────────────── */
elBtnStart.addEventListener('click', async () => {
  elBtnStart.disabled = true;

  // iOS 13+ requires a user-gesture to unlock DeviceOrientationEvent.
  // Android exposes the events without requesting permission — the
  // requestPermission function only exists on iOS.
  if (typeof DeviceOrientationEvent !== 'undefined' &&
      typeof DeviceOrientationEvent.requestPermission === 'function') {
    try {
      const perm = await DeviceOrientationEvent.requestPermission();
      if (perm !== 'granted') {
        alert('Motion sensor permission denied. AR requires device orientation.');
        elBtnStart.disabled = false;
        return;
      }
    } catch (e) {
      console.warn('[BAHAR] DeviceOrientationEvent.requestPermission failed:', e);
    }
  }

  try {
    await renderer.startAR();
  } catch (e) {
    alert(`AR Error: ${e.message}`);
    elBtnStart.disabled = false;
    return;
  }

  // Switch screens
  elLanding.style.display = 'none';
  elCanvas.style.display  = 'block';
  elOverlay.classList.add('active');

  startGPS();

  // Boot the mini-map — non-blocking; if it fails the AR still runs.
  initMiniMap('mini-map', currentCoord ?? undefined)
    .then(instance => {
      miniMap = instance;
      if (currentCoord) miniMap.setCoordinate(currentCoord);
    })
    .catch(err => console.warn('[BAHAR] mini-map init failed:', err.message));

  renderer.onGroundFound = () => {
    elScanHint.classList.add('hidden');
  };
});

/* ── Exit AR ──────────────────────────────────────────────────────────────── */
elBtnExit.addEventListener('click', stopAR);

function stopAR() {
  renderer.stop();
  stopGPS();

  // Close expanded map if it's open, dismiss advisory popover.
  hideExpandedMap();
  elAdvisoryPop.classList.add('hidden');

  // Tear down the mini-map so the WebGL context is released; recreated on next AR start.
  if (miniMap) { miniMap.destroy(); miniMap = null; }

  elCanvas.style.display  = 'none';
  elOverlay.classList.remove('active');
  elLanding.style.display = '';
  document.body.classList.remove('submerged');
  elFloodFilter.classList.remove('active');
  elFloodFilter.style.height = '0%';
  elBtnStart.disabled = false;
  elScanHint.classList.remove('hidden');
}

/* ── GPS ──────────────────────────────────────────────────────────────────── */
function startGPS() {
  if (!navigator.geolocation) {
    elGpsText.textContent = 'GPS not available';
    return;
  }

  gpsWatchId = navigator.geolocation.watchPosition(
    onPosition,
    onGPSError,
    { enableHighAccuracy: true, maximumAge: 3000, timeout: 10000 }
  );
}

function stopGPS() {
  if (gpsWatchId !== null) {
    navigator.geolocation.clearWatch(gpsWatchId);
    gpsWatchId = null;
  }
}

async function onPosition(pos) {
  const { latitude: lat, longitude: lon, accuracy, altitude, altitudeAccuracy } = pos.coords;

  elGpsText.textContent = `${lat.toFixed(5)}, ${lon.toFixed(5)}  ±${Math.round(accuracy)}m`;
  elGpsDot.className = accuracy <= 50 ? 'ok' : accuracy <= 100 ? '' : 'err';

  currentCoord = [lon, lat];
  miniMap?.setCoordinate(currentCoord);
  expandedMap?.setCoordinate(currentCoord);

  if (altitude !== null && altitude !== undefined) {
    renderer.setElevation(altitude, altitudeAccuracy);
  }

  const modelDepth = DEBUG_DEPTH_OVERRIDE !== null
    ? DEBUG_DEPTH_OVERRIDE
    : await flood.getDepth(lat, lon);

  if (modelDepth === null) {
    elDepthEmoji.textContent = '📍';
    elDepthLabel.textContent = 'OUTSIDE COVERAGE';
    elDepthVal.textContent   = '';
    elDepthSub.textContent   = 'No flood data for this location';
    elDepthCatRow.classList.add('hidden');
    elDepthSub.style.display = '';
    setAdvisory('none');
    renderer.setFlood(0, 'none');
    document.body.classList.remove('submerged');
    elFloodFilter.classList.remove('active');
    elFloodFilter.style.height = '0%';
    return;
  }

  const depth = modelDepth >= 0.10 ? modelDepth : 0;
  currentDepth  = depth;
  currentHazard = flood.hazardLevel(depth);

  const MMDA_THRESHOLD = 0.2032;

  if (depth < MMDA_THRESHOLD) {
    elDepthEmoji.textContent = '💧';
    elDepthLabel.textContent = 'LITTLE TO NONE';
    elDepthVal.textContent   = depthDisplay(depth);
    elDepthSub.textContent   = 'Below NOAH flood threshold';
    elDepthSub.style.display = '';
    elDepthCatRow.classList.add('hidden');
    setAdvisory('none');
  } else {
    elDepthEmoji.textContent = humanScaleEmoji(depth);
    elDepthLabel.textContent = humanScaleLabel(depth);
    elDepthVal.textContent   = depthDisplay(depth);
    elDepthSub.textContent   = '';
    elDepthSub.style.display = 'none';
    const cat = mmdaClass(depth);
    elDepthCat.textContent   = mmdaCategory(depth);
    elDepthCat.className     = cat;
    elDepthCatName.textContent = mmdaFullName(depth);
    elDepthCatRow.classList.remove('hidden');
    setAdvisory(cat);
  }

  renderer.setFlood(depth, currentHazard);

  if (depth > 0) {
    const pct = Math.min((depth / 1.7) * 72, 88);
    elFloodFilter.classList.add('active');
    elFloodFilter.style.height = pct.toFixed(1) + '%';
  } else {
    elFloodFilter.classList.remove('active');
    elFloodFilter.style.height = '0%';
  }

  document.body.classList.toggle('submerged', depth >= 1.7);
}

function onGPSError(err) {
  elGpsText.textContent = `GPS error: ${err.message}`;
  elGpsDot.className = 'err';
}

/* ── Helpers ──────────────────────────────────────────────────────────────── */
function setStatus(msg, cls = '') {
  elStatus.textContent = msg;
  elStatus.className   = `status ${cls}`;
}

function humanScaleLabel(depth) {
  const i = depth * 39.3700787;
  if (i < 10) return 'GUTTER LEVEL';
  if (i < 13) return 'HALF-KNEE LEVEL';
  if (i < 19) return 'CALF LEVEL';
  if (i < 26) return 'KNEE LEVEL';
  if (i < 37) return 'THIGH LEVEL';
  if (i < 45) return 'WAIST LEVEL';
  return 'CHEST LEVEL';
}

function humanScaleEmoji(depth) {
  const i = depth * 39.3700787;
  if (i < 10) return '🥾';
  if (i < 26) return '🦵';
  if (i < 37) return '🚴';
  if (i < 45) return '🧍';
  return '👤';
}

function depthDisplay(depth) {
  const inches = Math.round(depth * 39.3700787);
  return `${inches}" / ~${depth.toFixed(2)} m / ${depth.toFixed(4)}`;
}

function mmdaCategory(depth) {
  const i = depth * 39.3700787;
  if (i < 13) return 'PATV';
  if (i < 26) return 'NPLV';
  return 'NPATV';
}

function mmdaClass(depth) {
  const i = depth * 39.3700787;
  if (i < 13) return 'patv';
  if (i < 26) return 'nplv';
  return 'npatv';
}

/// MMDA-verbose category name — matches MMDAGauge.Category.fullName on iOS.
function mmdaFullName(depth) {
  const i = depth * 39.3700787;
  if (i < 13) return 'Passable to all types of vehicles';
  if (i < 26) return 'Not passable to light vehicles';
  return 'Not passable to all types of vehicles';
}

/* ── Advisory (warning) button state ──────────────────────────────────────── */
const ADVISORY = {
  none:  { icon: '✓',  text: 'Safe — no flooding expected at this location for the 100-year return period.' },
  patv:  { icon: '⚠',  text: 'Proceed slowly. Keep distance from trucks and large vehicles.' },
  nplv:  { icon: '⛔', text: 'Warning: light vehicles must detour immediately. Avoid wading.' },
  npatv: { icon: '✕',  text: 'CRITICAL: do not attempt driving or wading. Seek higher ground.' },
};

function setAdvisory(category) {
  currentCategory = category;
  const info = ADVISORY[category] ?? ADVISORY.none;
  elAdvisoryIcon.textContent = info.icon;
  elAdvisoryIcon.className   = category;
  elAdvisoryPopIcon.textContent = info.icon;
  elAdvisoryPopIcon.className   = category;
  elAdvisoryPopText.textContent = info.text;
}

elBtnAdvisory.addEventListener('click', () => {
  elAdvisoryPop.classList.toggle('hidden');
});

/* ── Mini-map → expanded map ──────────────────────────────────────────────── */
elMiniMapBtn.addEventListener('click', showExpandedMap);
elBtnCloseMap.addEventListener('click', hideExpandedMap);
elMapBackdrop.addEventListener('click', hideExpandedMap);

function showExpandedMap() {
  elExpandedMap.classList.remove('hidden');
  // Lazy-init on first open; recreate every time so the map resizes to the
  // new container dimensions cleanly. Cheap: NOAH style is already cached.
  if (expandedMap) { expandedMap.destroy(); expandedMap = null; }
  initExpandedMap('expanded-map', currentCoord ?? undefined)
    .then(instance => { expandedMap = instance; })
    .catch(err => console.warn('[BAHAR] expanded map failed:', err.message));
}

function hideExpandedMap() {
  elExpandedMap.classList.add('hidden');
  if (expandedMap) { expandedMap.destroy(); expandedMap = null; }
}

/* ── Run ───────────────────────────────────────────────────────────────────── */
boot();
