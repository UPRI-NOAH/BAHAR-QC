/**
 * ARRenderer — Three.js + getUserMedia camera feed + DeviceOrientation.
 *
 * One code path for every platform (iOS Safari, Android Chrome, desktop
 * browsers with a rear camera). We use the raw camera stream as a
 * background texture and DeviceOrientationEvent for 3DOF rotation, rather
 * than WebXR — that way both iOS and Android can sample the camera feed
 * inside the water shader for reflection + refraction. WebXR immersive-ar
 * on Android didn't expose the camera feed to WebGL, so it could only ever
 * render a procedural teal fallback; this unifies both platforms on the
 * same reflective water look.
 *
 * Ground detection: fixed at camera height − 1.6 m. No positional
 * tracking (that would require ARKit / ARCore hit-test, neither of which
 * is available to WebGL fragment shaders).
 */

import * as THREE from 'https://cdn.jsdelivr.net/npm/three@0.163.0/build/three.module.js';

/* ── Vertex shader — passes world pos + clip-space pos ─────────────────────── */
const WATER_VERT = /* glsl */`
  uniform vec3 uCamPos;

  varying vec4  vClipPos;
  varying vec3  vWorldPos;
  varying float vDist;
  varying vec2  vUV;

  void main() {
    vec4 worldPos = modelMatrix * vec4(position, 1.0);
    vWorldPos = worldPos.xyz;
    vDist     = length(worldPos.xz - uCamPos.xz);
    vUV       = uv;
    vec4 clip = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    vClipPos  = clip;
    gl_Position = clip;
  }
`;

/* ── Fragment shader — refraction-only water look
   The iOS Metal shader has reflection code but uses ARKit's spherical-
   harmonic environment probe, which is a low-frequency approximation of
   ambient light — no crisp mirror. On the web we can only sample the raw
   video texture, which reads as a sharp puddle-mirror of the scene above.
   That looks wrong for floodwater. So we drop the mirrored reflection
   entirely and use refraction + a subtle Fresnel sheen — semi-transparent
   tinted water with a wet edge highlight, closer to the iOS feel. */
const WATER_FRAG = /* glsl */`
  precision highp float;

  uniform sampler2D uCameraFeed;
  uniform vec3      uCamPos;
  uniform float     uOpacity;
  uniform float     uTime;

  varying vec4  vClipPos;
  varying vec3  vWorldPos;
  varying float vDist;
  varying vec2  vUV;

  void main() {
    vec2 screenUV = vClipPos.xy / vClipPos.w * 0.5 + 0.5;

    // Multi-scale sine waves — cheap FBM-style ripple field for UV distortion.
    float t = uTime;
    float w1 = sin(vUV.x * 20.0 + t * 2.0) * cos(vUV.y * 14.0 + t * 1.4);
    float w2 = sin(vUV.x *  9.0 - t * 1.1) * cos(vUV.y * 24.0 + t * 1.8);
    float w3 = sin(vUV.x * 32.0 + t * 3.0) * cos(vUV.y *  6.0 - t * 0.9);
    vec2 wave = vec2(w1 + w2 * 0.5 + w3 * 0.30,
                     w2 + w1 * 0.4 + w3 * 0.55) * 0.024;

    // Refraction — sample the camera feed gently warped by the ripple field.
    // No mirrored reflection: the flat video texture would show a crisp
    // mirror of the person / scene, which doesn't match real floodwater.
    vec2 refractUV = clamp(screenUV + wave * 0.5, 0.0, 1.0);
    vec3 refraction = texture2D(uCameraFeed, refractUV).rgb;

    // Very light neutral tint — the ground / feet under the water dominate.
    vec3 waterTint = vec3(0.55, 0.68, 0.78);
    vec3 color = mix(refraction, waterTint, 0.15);

    // Subtle Fresnel sheen — grazing angles get a whisper of extra brightness
    // so the water still reads as a wet surface, not a flat colour overlay.
    vec3 viewDir = normalize(uCamPos - vWorldPos);
    float NdotV = max(dot(viewDir, vec3(0.0, 1.0, 0.0)), 0.0);
    float fresnel = pow(1.0 - NdotV, 3.0);
    color += vec3(0.08) * fresnel;

    // Edge + near-distance fade so the plane doesn't clip hard against the ground.
    vec2  edgeDist = min(vUV, 1.0 - vUV);
    float edgeFade = smoothstep(0.0, 0.08, edgeDist.x)
                   * smoothstep(0.0, 0.08, edgeDist.y);
    float distFade = smoothstep(0.15, 1.0, vDist);

    // Semi-transparent (~iOS 0.62) so submerged content stays visible.
    gl_FragColor = vec4(color, 0.62 * uOpacity * edgeFade * distFade);
  }
`;

export class ARRenderer {
  constructor(canvas, overlayEl) {
    this.canvas    = canvas;
    this.overlayEl = overlayEl;

    this._renderer = null;
    this._scene    = null;
    this._camera   = null;
    this._clock    = new THREE.Clock();

    this._groundY     = null;
    this._groundFound = false;

    this._waterPlane = null;
    this._waterMat   = null;

    this.floodDepth  = 0;
    this.hazardLevel = 'none';
    this.onGroundFound = null;

    this.gpsAltitude    = null;
    this.gpsAltAccuracy = null;

    this._videoStream   = null;
    this._orientation   = { alpha: 0, beta: 90, gamma: 0 };
    this._orientHandler = null;
    // Pre-allocated quaternion helpers for device orientation math
    this._dq1  = new THREE.Quaternion(-Math.SQRT1_2, 0, 0, Math.SQRT1_2);
    this._dZee = new THREE.Vector3(0, 0, 1);
  }

  /* ─── Init ──────────────────────────────────────────────────────────────── */
  init() {
    this._renderer = new THREE.WebGLRenderer({
      canvas: this.canvas,
      antialias: true,
      alpha: true,
    });
    this._renderer.setClearColor(0x000000, 0);
    this._renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this._renderer.setSize(window.innerWidth, window.innerHeight);
    this._renderer.xr.enabled = false;

    this._scene  = new THREE.Scene();
    this._camera = new THREE.PerspectiveCamera(70, window.innerWidth / window.innerHeight, 0.01, 100);

    this._scene.add(new THREE.AmbientLight(0xffffff, 0.9));
    const dir = new THREE.DirectionalLight(0xffffff, 0.4);
    dir.position.set(0, 5, 3);
    this._scene.add(dir);

    this._buildWater();
  }

  /* ─── Start AR — rear camera + device orientation ──────────────────────── */
  async startAR() {
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

    this._orientHandler = e => {
      this._orientation.alpha = e.alpha ?? 0;
      this._orientation.beta  = e.beta  ?? 90;
      this._orientation.gamma = e.gamma ?? 0;
    };
    window.addEventListener('deviceorientation', this._orientHandler);

    // Ground is fixed — onGroundFound fires on first frame
    this._groundY = -1.6;

    this._renderer.setAnimationLoop(() => this._onFrame());
  }

  /* ─── Stop ──────────────────────────────────────────────────────────────── */
  stop() {
    this._renderer.setAnimationLoop(null);

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

    this._groundY     = null;
    this._groundFound = false;
    if (this._waterPlane) this._waterPlane.visible = false;
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
      this._waterMat.uniforms.uOpacity.value = this.floodDepth > 0.2032 ? 1.0 : 0.0;
      this._waterMat.uniforms.uDepth.value   = this.floodDepth;
    }
  }

  /* ─── Apply device orientation to camera ────────────────────────────────── */
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

  /* ─── Per-frame tick ────────────────────────────────────────────────────── */
  _onFrame() {
    this._applyDeviceOrientation();

    // Camera fixed at world origin (0,0,0); ground 1.6 m below
    const camPos = new THREE.Vector3(0, 0, 0);
    if (this._waterMat) {
      this._waterMat.uniforms.uCamPos.value.copy(camPos);
      this._waterMat.uniforms.uTime.value = this._clock.getElapsedTime();
    }

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

    if (this.floodDepth > 0.2032) {
      // Clamp water plane so it never rises above camera — once depth ≥ 1.7 m
      // the body.submerged CSS overlay handles the underwater visual.
      const waterY     = Math.min(groundY + this.floodDepth, -0.05);
      const planeScale = Math.max(0.5, Math.min(this.floodDepth * 2.0 + 0.5, 3.0));
      this._waterPlane.scale.setScalar(planeScale);
      this._waterPlane.position.set(fx, waterY, fz);
      this._waterPlane.visible = true;
    } else {
      this._waterPlane.visible = false;
    }

    this._renderer.render(this._scene, this._camera);
  }

  /* ─── Build water plane ─────────────────────────────────────────────────── */
  _buildWater() {
    const geo = new THREE.PlaneGeometry(8, 8, 1, 1);
    geo.rotateX(-Math.PI / 2);

    const videoEl = document.getElementById('camera-feed');
    this._cameraTexture = new THREE.VideoTexture(videoEl);
    this._cameraTexture.minFilter = THREE.LinearFilter;
    this._cameraTexture.magFilter = THREE.LinearFilter;

    this._waterMat = new THREE.ShaderMaterial({
      uniforms: {
        uOpacity:    { value: 0 },
        uDepth:      { value: 0 },
        uTime:       { value: 0 },
        uCamPos:     { value: new THREE.Vector3() },
        uCameraFeed: { value: this._cameraTexture },
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
}
