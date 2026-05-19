/**
 * BAHAR — app.js
 * Main controller: wires FloodData + ARRenderer + GPS + UI.
 * Supports both iOS (camera stream + DeviceOrientation) and Android (WebXR/ARCore).
 */

import { FloodData }  from './flood-data-ios.js';
import { ARRenderer } from './ar-renderer-ios.js';

const flood    = new FloodData();
const renderer = new ARRenderer(
  document.getElementById('ar-canvas'),
  document.getElementById('ar-overlay')
);

/* ── UI elements ───────────────────────────────────────────────────────────── */
const elStatus      = document.getElementById('status-msg');
const elBtnStart    = document.getElementById('btn-start');
const elBtnExit     = document.getElementById('btn-exit');
const elDepthVal    = document.getElementById('depth-value');
const elDepthBadge  = document.getElementById('depth-badge');
const elGpsText     = document.getElementById('gps-text');
const elElevBar     = document.getElementById('elev-bar');
const elElevBarVal  = document.getElementById('elev-bar-value');
const elElevRow     = document.getElementById('elevation-row');
const elElevVal     = document.getElementById('elevation-value');
const elElevAcc     = document.getElementById('elevation-accuracy');
const elScanHint    = document.getElementById('scan-hint');
const elLanding     = document.getElementById('screen-landing');
const elOverlay     = document.getElementById('ar-overlay');
const elCanvas      = document.getElementById('ar-canvas');
const elFloodFilter = document.getElementById('flood-filter');
const elWaterLevel  = document.getElementById('water-level-label');
const elDisclaimer  = document.querySelector('.disclaimer');

let gpsWatchId   = null;
let currentDepth = 0;
let currentHazard = 'none';

/* ── Terrain elevation cache ───────────────────────────────────────────────── */
let _terrainElev    = null;
let _terrainLatLon  = null;

async function getTerrainElevation(lat, lon) {
  if (_terrainLatLon) {
    const dlat = lat - _terrainLatLon.lat;
    const dlon = lon - _terrainLatLon.lon;
    if (Math.sqrt(dlat * dlat + dlon * dlon) < 0.005) return _terrainElev; // ~500 m cache
  }

  const coords = `${lat.toFixed(5)},${lon.toFixed(5)}`;
  const apis = [
    `https://api.opentopodata.org/v1/srtm30m?locations=${coords}`,
    `https://api.open-elevation.com/api/v1/lookup?locations=${coords}`,
  ];

  for (const url of apis) {
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 5000);
      const res  = await fetch(url, { signal: ctrl.signal });
      clearTimeout(timer);
      if (!res.ok) continue;
      const data = await res.json();
      const elev = data?.results?.[0]?.elevation;
      if (elev != null) {
        _terrainElev   = elev;
        _terrainLatLon = { lat, lon };
        console.log(`[BAHAR] Terrain: ${elev.toFixed(1)} m (${url.includes('opentopodata') ? 'OpenTopo' : 'OpenElev'})`);
        return _terrainElev;
      }
    } catch { /* try next */ }
  }
  return _terrainElev; // stale cache or null
}

/* ── Platform detection ────────────────────────────────────────────────────── */
function isIOS() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.userAgent.includes('Mac') && 'ontouchend' in document);
}

/* ── Boot sequence ─────────────────────────────────────────────────────────── */
async function boot() {
  setStatus('Loading flood data…');

  try {
    await flood.load('./qc_flood_header.json');
  } catch (e) {
    setStatus('Could not load flood data. Check console.', 'err');
    console.error(e);
    return;
  }

  if (isIOS()) {
    // iOS: needs camera and motion access; no WebXR required
    if (!navigator.mediaDevices?.getUserMedia) {
      setStatus('Camera not available. Use Safari on iOS 14.5+.', 'err');
      return;
    }
    elDisclaimer.innerHTML =
      'Requires iOS 14.5+ Safari.<br>Allow camera &amp; motion access when prompted.';
    elScanHint.textContent = 'Tilt your phone to view the flood visualization';

    renderer.init();
    setStatus('Ready — tap Start AR!', 'ok');
    elBtnStart.disabled = false;
  } else {
    // Android / other: WebXR immersive-ar
    if (!navigator.xr) {
      setStatus('WebXR not available. Use Android Chrome.', 'err');
      return;
    }
    const supported = await navigator.xr.isSessionSupported('immersive-ar').catch(() => false);
    if (!supported) {
      setStatus('immersive-ar not supported. Use Android + ARCore.', 'err');
      return;
    }

    renderer.init();
    setStatus('Ready — tap Start AR!', 'ok');
    elBtnStart.disabled = false;
  }
}

/* ── Start AR ─────────────────────────────────────────────────────────────── */
elBtnStart.addEventListener('click', async () => {
  elBtnStart.disabled = true;

  // iOS 13+ requires a user-gesture to unlock DeviceOrientationEvent
  if (isIOS() &&
      typeof DeviceOrientationEvent !== 'undefined' &&
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

  renderer.onGroundFound = () => {
    elScanHint.classList.add('hidden');
  };
});

/* ── Exit AR ──────────────────────────────────────────────────────────────── */
elBtnExit.addEventListener('click', stopAR);

function stopAR() {
  renderer.stop();
  stopGPS();

  elCanvas.style.display  = 'none';
  elOverlay.classList.remove('active');
  elLanding.style.display = '';
  document.body.classList.remove('submerged');
  elFloodFilter.classList.remove('active');
  elFloodFilter.style.height = '0%';
  elWaterLevel.classList.add('hidden');
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

  elGpsText.textContent =
    `${lat.toFixed(5)}°N  ${lon.toFixed(5)}°E  (±${Math.round(accuracy)}m)`;

  if (altitude !== null && altitude !== undefined) {
    const altM = altitude.toFixed(1);
    elElevBarVal.textContent = altM;
    elElevBar.classList.remove('hidden');

    elElevVal.textContent = altM;
    elElevAcc.textContent = altitudeAccuracy !== null
      ? `±${Math.round(altitudeAccuracy)}m`
      : '';
    elElevRow.classList.remove('hidden');

    renderer.setElevation(altitude, altitudeAccuracy);
  } else {
    elElevBar.classList.add('hidden');
    elElevRow.classList.add('hidden');
  }

  const modelDepth = flood.getDepth(lat, lon);

  if (modelDepth === null) {
    elDepthVal.textContent   = '--';
    elDepthBadge.textContent = 'NO FLOOD IN THIS AREA';
    elDepthBadge.className   = 'badge-none';
    renderer.setFlood(0, 'none');
    document.body.classList.remove('submerged');
    return;
  }

  /* ── Elevation correction ──────────────────────────────────────────────────
     The flood model gives depth above the terrain surface (ground level).
     If the user is elevated (e.g. 2nd floor, elevated walkway), their GPS
     altitude will be above the water surface, so effective depth is less.

     Formula:
       waterSurfaceElev = terrainElev + modelDepth
       effectiveDepth   = waterSurfaceElev − userAltitude

     If effectiveDepth ≤ 0 the user is above the water — show no flood.
     Falls back to modelDepth when altitude or terrain data is unavailable.
  ──────────────────────────────────────────────────────────────────────────── */
  let depth = modelDepth;
  let aboveWater = false;

  const altAvailable = altitude !== null && altitude !== undefined;
  if (altAvailable && modelDepth > 0) {
    const terrainElev = await getTerrainElevation(lat, lon);
    if (terrainElev !== null) {
      const waterSurface = terrainElev + modelDepth;
      depth = Math.max(0, waterSurface - altitude);
      if (depth === 0) aboveWater = true;
      console.log(
        `[BAHAR] terrain=${terrainElev.toFixed(1)}m  model=${modelDepth.toFixed(2)}m` +
        `  userAlt=${altitude.toFixed(1)}m  acc=±${altitudeAccuracy ?? '?'}m  effective=${depth.toFixed(2)}m`
      );
    }
    // If terrain API unavailable, fall back to raw model depth — better to show
    // flood on a high floor than suppress flood for a ground-floor user on high terrain.
  }

  currentDepth  = depth;
  currentHazard = flood.hazardLevel(depth);

  elDepthVal.textContent   = depth > 0 ? depth.toFixed(2) : '0.00';
  elDepthBadge.textContent = aboveWater ? 'NO FLOOD — ELEVATED AREA' : flood.hazardLabel(depth);
  elDepthBadge.className   = `badge-${currentHazard}`;

  renderer.setFlood(depth, currentHazard);

  if (depth > 0) {
    const pct = Math.min((depth / 1.6) * 72, 88);
    elFloodFilter.classList.add('active');
    elFloodFilter.style.height = pct.toFixed(1) + '%';
  } else {
    elFloodFilter.classList.remove('active');
    elFloodFilter.style.height = '0%';
  }

  elWaterLevel.textContent = waterLevelLabel(depth);
  elWaterLevel.classList.toggle('hidden', depth <= 0);

  document.body.classList.toggle('submerged', depth >= 1.7);
}

function onGPSError(err) {
  elGpsText.textContent = `GPS error: ${err.message}`;
}

/* ── Helpers ──────────────────────────────────────────────────────────────── */
function setStatus(msg, cls = '') {
  elStatus.textContent = msg;
  elStatus.className   = `status ${cls}`;
}

function waterLevelLabel(depth) {
  if (depth <= 0)    return '';
  if (depth < 0.10)  return '💧 Wet ground';
  if (depth < 0.25)  return '🦶 Ankle deep';
  if (depth < 0.50)  return '🦵 Knee deep';
  if (depth < 0.80)  return '🩱 Waist deep';
  if (depth < 1.20)  return '👕 Chest deep';
  if (depth < 1.60)  return '😬 Neck deep';
  return '🌊 Above head — danger!';
}

/* ── Run ───────────────────────────────────────────────────────────────────── */
boot();
