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


/* ── Platform detection ────────────────────────────────────────────────────── */
function isIOS() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.userAgent.includes('Mac') && 'ontouchend' in document);
}

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
    elElevBarVal.textContent = altitude.toFixed(1);
    elElevBar.classList.remove('hidden');
    renderer.setElevation(altitude, altitudeAccuracy);
  } else {
    elElevBar.classList.add('hidden');
  }

  const modelDepth = await flood.getDepth(lat, lon);

  if (modelDepth === null) {
    elDepthVal.textContent   = '--';
    elDepthBadge.textContent = 'OUTSIDE COVERAGE AREA';
    elDepthBadge.className   = 'badge-none';
    renderer.setFlood(0, 'none');
    document.body.classList.remove('submerged');
    elFloodFilter.classList.remove('active');
    elFloodFilter.style.height = '0%';
    elWaterLevel.classList.add('hidden');
    return;
  }

  // Depths below 0.10 m are below NOAH's minimum low-hazard threshold and
  // do not appear on NOAH's visual flood maps — treat as no flood.
  const depth = modelDepth >= 0.10 ? modelDepth : 0;

  currentDepth  = depth;
  currentHazard = flood.hazardLevel(depth);

  elDepthVal.textContent   = depth > 0 ? depth.toFixed(2) : '0.00';
  elDepthBadge.textContent = flood.hazardLabel(depth);
  elDepthBadge.className   = `badge-${currentHazard}`;

  renderer.setFlood(depth, currentHazard);

  if (depth > 0) {
    const pct = Math.min((depth / 1.7) * 72, 88);
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

// Depth thresholds based on average Filipino height 5'6" (1.68 m)
function waterLevelLabel(depth) {
  if (depth <= 0)   return '';
  if (depth < 0.5)  return '🦶 Ankle deep';
  if (depth < 1.5)  return '🦵 Knee deep';
  if (depth < 1.7)  return '💪 Shoulder deep';
  return '🌊 Above head — danger!';
}

/* ── Run ───────────────────────────────────────────────────────────────────── */
boot();
