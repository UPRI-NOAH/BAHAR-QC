/**
 * ARRenderer — Three.js + WebXR (Android/ARCore) or Camera+DeviceOrientation (iOS).
 *
 * Auto-detects the platform:
 *  • iOS  → getUserMedia camera feed as background + DeviceOrientationEvent for 3DOF rotation.
 *  • Other → immersive-ar WebXR session (existing ARCore path).
 *
 * Ground detection:
 *  Android: hit-test (optional feature) → camera-height fallback.
 *  iOS:     camera-height fixed at 1.6 m — no positional tracking available.
 */

import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.163.0/build/three.module.js';

function _isIOS() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.userAgent.includes('Mac') && 'ontouchend' in document);
}

/* ── Vertex shader ─────────────────────────────────────────────────────────── */
const WATER_VERT = /* glsl */`
  uniform vec3 uCamPos;

  varying vec3  vWorldPos;
  varying float vDist;
  varying vec2  vUV;

  void main() {
    vec4 worldPos = modelMatrix * vec4(position, 1.0);
    vWorldPos = worldPos.xyz;
    vDist     = length(worldPos.xz - uCamPos.xz);
    vUV       = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

/* ── Fragment shader ───────────────────────────────────────────────────────── */
const WATER_FRAG = /* glsl */`
  precision highp float;

  uniform float uOpacity;
  uniform float uDepth;
  uniform vec3  uCamPos;

  varying vec3  vWorldPos;
  varying float vDist;
  varying vec2  vUV;

  void main() {
    float distFactor = smoothstep(0.3, 3.5, vDist);
    float depthScale = clamp(uDepth * 1.5 + 0.60, 0.60, 1.0);

    vec2  edgeDist  = min(vUV, 1.0 - vUV);
    float edgeFade  = smoothstep(0.0, 0.08, edgeDist.x)
                    * smoothstep(0.0, 0.08, edgeDist.y);

    vec3 col = vec3(0.25, 0.65, 1.00);

    float alpha = mix(0.22, 0.62, distFactor) * depthScale * edgeFade * uOpacity;
    alpha = clamp(alpha, 0.0, 0.70);

    gl_FragColor = vec4(col, alpha);
  }
`;

export class ARRenderer {
  constructor(canvas, overlayEl) {
    this.canvas    = canvas;
    this.overlayEl = overlayEl;

    this._renderer = null;
    this._scene    = null;
    this._camera   = null;
    this._session  = null;
    this._clock    = new THREE.Clock();

    this._htSource    = null;
    this._groundY     = null;
    this._groundFound = false;

    this._waterPlane = null;
    this._waterMat   = null;
    this._gauge      = null;
    this._gaugeTicks = null;
    this._reticle    = null;

    this.floodDepth  = 0;
    this.hazardLevel = 'none';
    this.onGroundFound = null;

    this.gpsAltitude    = null;
    this.gpsAltAccuracy = null;

    // iOS-specific
    this._iosMode       = false;
    this._videoStream   = null;
    this._orientation   = { alpha: 0, beta: 90, gamma: 0 };
    this._orientHandler = null;
    // Pre-allocated quaternion helpers for device orientation math
    this._dq1  = new THREE.Quaternion(-Math.SQRT1_2, 0, 0, Math.SQRT1_2);
    this._dZee = new THREE.Vector3(0, 0, 1);
  }

  /* ─── Init ──────────────────────────────────────────────────────────────── */
  init() {
    this._iosMode = _isIOS();

    this._renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      alpha: true,
    });
    this._renderer.setClearColor(0x000000, 0);
    this._renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this._renderer.setSize(window.innerWidth, window.innerHeight);
    this._renderer.xr.enabled = !this._iosMode;

    this._scene  = new THREE.Scene();
    this._camera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.01, 100);

    this._scene.add(new THREE.AmbientLight(0xffffff, 0.9));
    const dir = new THREE.DirectionalLight(0xffffff, 0.4);
    dir.position.set(0, 5, 3);
    this._scene.add(dir);

    this._buildWater();
    this._buildGauge();
    if (!this._iosMode) this._buildReticle();
  }

  /* ─── Start AR (routes to iOS or Android) ───────────────────────────────── */
  async startAR() {
    if (this._iosMode) {
      return this._startARiOS();
    }

    if (!navigator.xr) throw new Error('WebXR not available.');
    const ok = await navigator.xr.isSessionSupported('immersive-ar').catch(() => false);
    if (!ok) throw new Error('immersive-ar not supported. Use Android Chrome with ARCore.');

    this._session = await navigator.xr.requestSession('immersive-ar', {
      requiredFeatures: [],
      optionalFeatures: ['hit-test', 'dom-overlay'],
      domOverlay: { root: this.overlayEl },
    });

    this._renderer.xr.setReferenceSpaceType('local');
    await this._renderer.xr.setSession(this._session);

    this._session.requestReferenceSpace('viewer')
      .then(vs => this._session.requestHitTestSource({ space: vs }))
      .then(src => {
        this._htSource = src;
        console.log('[BAHAR] Hit-test active.');
      })
      .catch(e => {
        console.warn('[BAHAR] Hit-test unavailable, using height fallback.', e.message);
      });

    this._renderer.setAnimationLoop((t, frame) => this._onFrame(t, frame));
  }

  /* ─── iOS AR start ──────────────────────────────────────────────────────── */
  async _startARiOS() {
    // Start rear camera
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
      audio: false,
    });
    this._videoStream = stream;

    const videoEl = document.getElementById('camera-feed');
    videoEl.srcObject = stream;
    videoEl.style.display = 'block';
    await new Promise(resolve => { videoEl.onloadedmetadata = resolve; });
    videoEl.play().catch(() => {});

    // Listen for device orientation
    this._orientHandler = e => {
      this._orientation.alpha = e.alpha ?? 0;
      this._orientation.beta  = e.beta  ?? 90;
      this._orientation.gamma = e.gamma ?? 0;
    };
    window.addEventListener('deviceorientation', this._orientHandler);

    // Ground is fixed — will trigger onGroundFound on first frame
    this._groundY = -1.6;

    this._renderer.setAnimationLoop(t => this._onFrame(t, null));
  }

  /* ─── Stop ──────────────────────────────────────────────────────────────── */
  stop() {
    this._renderer.setAnimationLoop(null);

    if (this._iosMode) {
      if (this._orientHandler) {
        window.removeEventListener('deviceorientation', this._orientHandler);
        this._orientHandler = null;
      }
      if (this._videoStream) {
        this._videoStream.getTracks().forEach(t => t.stop());
        this._videoStream = null;
      }
      const videoEl = document.getElementById('camera-feed');
      if (videoEl) { videoEl.srcObject = null; videoEl.style.display = 'none'; }
    } else {
      if (this._htSource) { this._htSource.cancel?.(); this._htSource = null; }
      if (this._session)  { this._session.end().catch(() => {}); this._session = null; }
    }

    this._groundY        = null;
    this._groundFound    = false;
    this._gpsAltAtInit   = undefined;
    this._arGroundAtInit = undefined;
    if (this._waterPlane) this._waterPlane.visible = false;
    if (this._gauge)      this._gauge.visible      = false;
    if (this._reticle)    this._reticle && (this._reticle.visible = false);
  }

  /* ─── Update GPS elevation ──────────────────────────────────────────────── */
  setElevation(altMetres, accuracy) {
    this.gpsAltitude    = altMetres;
    this.gpsAltAccuracy = accuracy;
  }

  /* ─── Update flood depth ────────────────────────────────────────────────── */
  setFlood(depth, hazardLevel) {
    this.floodDepth  = depth      ?? 0;
    this.hazardLevel = hazardLevel ?? 'none';
    if (this._waterMat) {
      this._waterMat.uniforms.uOpacity.value = this.floodDepth > 0 ? 1.0 : 0.0;
      this._waterMat.uniforms.uDepth.value   = this.floodDepth;
    }
    this._updateGaugeTicks();
  }

  /* ─── Apply device orientation to camera (iOS) ──────────────────────────── */
  _applyDeviceOrientation() {
    const { alpha, beta, gamma } = this._orientation;
    const orient = window.screen?.orientation?.angle ?? 0;

    const euler = new THREE.Euler(
      THREE.MathUtils.degToRad(beta),
      THREE.MathUtils.degToRad(alpha),
      THREE.MathUtils.degToRad(-gamma),
      'YXZ'
    );

    const q = this._camera.quaternion;
    q.setFromEuler(euler);
    q.multiply(this._dq1);

    const q0 = new THREE.Quaternion();
    q0.setFromAxisAngle(this._dZee, THREE.MathUtils.degToRad(-orient));
    q.multiply(q0);
  }

  /* ─── Per-frame ─────────────────────────────────────────────────────────── */
  _onFrame(_timestamp, frame) {
    if (this._iosMode) {
      this._tickIOS();
    } else {
      if (!frame) return;
      this._tickAR(frame);
    }
    this._renderer.render(this._scene, this._camera);
  }

  /* ─── iOS frame tick ────────────────────────────────────────────────────── */
  _tickIOS() {
    this._applyDeviceOrientation();

    // Camera is fixed at world origin (0,0,0); ground is 1.6 m below
    const camPos = new THREE.Vector3(0, 0, 0);
    if (this._waterMat) this._waterMat.uniforms.uCamPos.value.copy(camPos);

    // Horizontal forward direction from camera orientation
    const camDir = new THREE.Vector3(0, 0, -1);
    camDir.applyQuaternion(this._camera.quaternion);
    camDir.y = 0;
    if (camDir.lengthSq() > 0.001) camDir.normalize();
    else camDir.set(0, 0, -1);

    const groundY = this._groundY; // -1.6
    const fx = camDir.x * 2.5;
    const fz = camDir.z * 2.5;

    if (!this._groundFound) {
      this._groundFound = true;
      if (typeof this.onGroundFound === 'function') this.onGroundFound(groundY);
    }

    if (this.floodDepth > 0) {
      // Clamp water plane so it never rises above camera — once depth ≥ 1.7 m
      // the body.submerged CSS overlay handles the underwater visual.
      const waterY     = Math.min(groundY + this.floodDepth, -0.05);
      const planeScale = Math.max(0.5, Math.min(this.floodDepth * 2.0 + 0.5, 3.0));
      this._waterPlane.scale.setScalar(planeScale);
      this._waterPlane.position.set(fx, waterY, fz);
      this._waterPlane.visible = true;
      this._gauge.position.set(fx + 0.7, groundY, fz);
      this._gauge.visible = true;
    } else {
      this._waterPlane.visible = false;
      this._gauge.visible      = false;
    }
  }

  /* ─── Android WebXR frame tick ──────────────────────────────────────────── */
  _tickAR(frame) {
    const refSpace = this._renderer.xr.getReferenceSpace();
    const xrCam  = this._renderer.xr.getCamera();
    const camPos = new THREE.Vector3();
    xrCam.getWorldPosition(camPos);

    if (this._waterMat) this._waterMat.uniforms.uCamPos.value.copy(camPos);

    const camDir = new THREE.Vector3();
    xrCam.getWorldDirection(camDir);
    camDir.y = 0;
    if (camDir.lengthSq() > 0.001) camDir.normalize();
    else camDir.set(0, 0, -1);

    /* Hit-test */
    if (this._htSource && refSpace) {
      const hits = frame.getHitTestResults(this._htSource);
      if (hits.length > 0) {
        const pose = hits[0].getPose(refSpace);
        if (pose) {
          const hitY = pose.transform.position.y;
          this._groundY = this._groundY === null
            ? hitY
            : this._groundY * 0.85 + hitY * 0.15;

          this._reticle.visible = true;
          this._reticle.position.set(
            pose.transform.position.x,
            this._groundY,
            pose.transform.position.z
          );

          if (!this._groundFound) {
            this._groundFound = true;
            if (typeof this.onGroundFound === 'function') this.onGroundFound(this._groundY);
          }
        }
      } else {
        this._reticle.visible = false;
      }
    } else {
      /* Camera-height fallback with GPS drift correction */
      const cameraEstimate = camPos.y - 1.6;
      let estimated = cameraEstimate;

      if (this.gpsAltitude !== null &&
          (this.gpsAltAccuracy === null || this.gpsAltAccuracy < 15)) {
        if (this._groundY === null) {
          this._gpsAltAtInit   = this.gpsAltitude;
          this._arGroundAtInit = cameraEstimate;
        } else if (this._gpsAltAtInit !== undefined) {
          const gpsDrift = this.gpsAltitude - this._gpsAltAtInit;
          estimated = this._arGroundAtInit + gpsDrift;
        }
      }

      this._groundY = this._groundY === null
        ? estimated
        : this._groundY * 0.95 + estimated * 0.05;

      if (!this._groundFound) {
        this._groundFound = true;
        if (typeof this.onGroundFound === 'function') this.onGroundFound(this._groundY);
      }
    }

    const groundY = this._groundY ?? (camPos.y - 1.6);
    const fx = camPos.x + camDir.x * 2.5;
    const fz = camPos.z + camDir.z * 2.5;

    if (this.floodDepth > 0) {
      const waterY     = Math.min(groundY + this.floodDepth, camPos.y - 0.05);
      const planeScale = Math.max(0.5, Math.min(this.floodDepth * 2.0 + 0.5, 3.0));
      this._waterPlane.scale.setScalar(planeScale);
      this._waterPlane.position.set(fx, waterY, fz);
      this._waterPlane.visible = true;
      this._gauge.position.set(fx + 0.7, groundY, fz);
      this._gauge.visible = true;
    } else {
      this._waterPlane.visible = false;
      this._gauge.visible      = false;
    }
  }

  /* ─── Build water plane ─────────────────────────────────────────────────── */
  _buildWater() {
    const geo = new THREE.PlaneGeometry(8, 8, 1, 1);
    geo.rotateX(-Math.PI / 2);

    this._waterMat = new THREE.ShaderMaterial({
      uniforms: {
        uOpacity: { value: 0 },
        uDepth:   { value: 0 },
        uCamPos:  { value: new THREE.Vector3() },
      },
      vertexShader:   WATER_VERT,
      fragmentShader: WATER_FRAG,
      transparent: true,
      depthWrite:  false,
      side: THREE.DoubleSide,
    });

    this._waterPlane = new THREE.Mesh(geo, this._waterMat);
    this._waterPlane.visible = false;
    this._scene.add(this._waterPlane);
  }

  /* ─── Build depth gauge ─────────────────────────────────────────────────── */
  _buildGauge() {
    this._gauge = new THREE.Group();

    const pole = new THREE.Mesh(
      new THREE.CylinderGeometry(0.015, 0.015, 5, 8),
      new THREE.MeshBasicMaterial({ color: 0xdddddd })
    );
    pole.position.y = 2.5;
    this._gauge.add(pole);

    this._gaugeTicks = new THREE.Group();
    this._gauge.add(this._gaugeTicks);
    this._updateGaugeTicks();

    this._gauge.visible = false;
    this._scene.add(this._gauge);
  }

  /* ─── Build placement reticle (Android only) ────────────────────────────── */
  _buildReticle() {
    const geo = new THREE.RingGeometry(0.06, 0.08, 32);
    geo.rotateX(-Math.PI / 2);
    this._reticle = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({
      color: 0xffffff, side: THREE.DoubleSide,
    }));
    this._reticle.visible = false;
    this._scene.add(this._reticle);
  }

  /* ─── Refresh gauge tick marks ──────────────────────────────────────────── */
  _updateGaugeTicks() {
    if (!this._gaugeTicks) return;
    this._gaugeTicks.clear();

    const maxMark = Math.max(this.floodDepth + 1, 3);
    for (let h = 0; h <= maxMark; h += 0.5) {
      const major = h % 1 === 0;
      const w   = major ? 0.12 : 0.07;
      const col = h === 0 ? 0xaaaaaa
                : h <= 0.5 ? 0xffd166
                : h <= 1.5 ? 0xef8c1a
                :             0xd62828;

      const tick = new THREE.Mesh(
        new THREE.BoxGeometry(w, 0.012, 0.012),
        new THREE.MeshBasicMaterial({ color: col })
      );
      tick.position.set(w / 2, h, 0);
      this._gaugeTicks.add(tick);
    }

    if (this.floodDepth > 0) {
      const ring = new THREE.Mesh(
        new THREE.TorusGeometry(0.07, 0.013, 8, 24),
        new THREE.MeshBasicMaterial({ color: 0x00b4d8 })
      );
      ring.rotation.x = Math.PI / 2;
      ring.position.y = this.floodDepth;
      this._gaugeTicks.add(ring);
    }
  }
}
