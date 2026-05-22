/**
 * FloodData — Mapbox Tilequery-backed flood depth lookup
 *
 * Queries the upri-noah.mm_fh_100yr_tls vector tileset at the user's GPS
 * position via the Mapbox Tilequery REST API.  Results are cached per ~55 m
 * grid cell so the API is not hit on every GPS ping.
 *
 * getDepth(lat, lon) → Promise<number|null>
 *   null  = outside Metro Manila coverage
 *   0     = inside coverage, no flood polygon at this point
 *   >0    = flood depth in metres (the `Var` property from the tileset)
 */

const TILEQUERY_ENDPOINT = '/api/tilequery';

// Metro Manila bounding box — return null (outside coverage) beyond this
const MM_BOUNDS = { north: 14.82, south: 14.35, west: 120.90, east: 121.20 };

export class FloodData {
  constructor() {
    this.ready  = true;
    this._cache = new Map();   // cacheKey → depth (metres)
  }

  async load() {
    // Data is fetched on demand — nothing to preload
    this.ready = true;
    console.log('[FloodData] Mapbox Tilequery mode — data fetched on demand');
  }

  // Round to ~55 m grid (0.0005 ° ≈ 55 m) to reuse cached results
  _cacheKey(lat, lon) {
    return `${(lat * 2000).toFixed(0)},${(lon * 2000).toFixed(0)}`;
  }

  async getDepth(lat, lon) {
    if (lat < MM_BOUNDS.south || lat > MM_BOUNDS.north ||
        lon < MM_BOUNDS.west  || lon > MM_BOUNDS.east) return null;

    const key = this._cacheKey(lat, lon);
    if (this._cache.has(key)) return this._cache.get(key);

    const url = `${TILEQUERY_ENDPOINT}?lat=${lat}&lon=${lon}`;

    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();

      let depth = 0;
      if (data.features?.length > 0) {
        // Take the maximum depth across all overlapping polygons
        for (const f of data.features) {
          const v = parseFloat(f.properties?.Var ?? 0) || 0;
          if (v > depth) depth = v;
        }
      }

      this._cache.set(key, depth);
      return depth;
    } catch (e) {
      console.warn('[FloodData] Tilequery failed:', e.message);
      // On error stay inside coverage — return last cached value or 0
      return this._cache.get(key) ?? 0;
    }
  }

  hazardLevel(depth) {
    if (depth <= 0)  return 'none';
    if (depth < 0.5) return 'low';
    if (depth < 1.5) return 'med';
    return 'high';
  }

  hazardLabel(depth) {
    return {
      none: 'NO FLOOD IN THIS AREA',
      low:  'LOW HAZARD',
      med:  'MED HAZARD',
      high: 'HIGH HAZARD',
    }[this.hazardLevel(depth)];
  }
}
