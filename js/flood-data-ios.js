/**
 * FloodData — GeoBits-inspired binary grid loader
 *
 * Data format (GeoBits / DSHA approach):
 *   Header : tiny JSON with grid metadata
 *   Binary : Uint8Array, 1 byte per cell
 *            0       = no flood
 *            1–254   = depth in steps of `header.step` metres
 *
 * Point query is O(1):
 *   col = floor((lon - west)  / cellDeg)
 *   row = floor((north - lat) / cellDeg)
 *   depth = grid[row * cols + col] * step
 *
 * File size: ~269 KB binary vs 1,110 KB JSON (4× smaller, ~80 KB gzipped)
 */
export class FloodData {
  constructor() {
    this.ready  = false;
    this._hdr   = null;   // header JSON
    this._grid  = null;   // Uint8Array
  }

  async load(headerUrl = './qc_flood_header.json') {
    // 1. Fetch tiny header
    const hRes = await fetch(headerUrl);
    if (!hRes.ok) throw new Error(`Cannot load flood header: ${hRes.status}`);
    this._hdr = await hRes.json();

    // 2. Fetch binary grid (same folder as header)
    const base    = headerUrl.substring(0, headerUrl.lastIndexOf('/') + 1);
    const binUrl  = base + this._hdr.dataFile;
    const bRes    = await fetch(binUrl);
    if (!bRes.ok) throw new Error(`Cannot load flood binary: ${bRes.status}`);
    const buf     = await bRes.arrayBuffer();
    // Uint16, little-endian — matches Python array('H') output
    this._grid    = new Uint16Array(buf);

    this.ready = true;
    console.log(
      `[FloodData] ${this._hdr.cols}×${this._hdr.rows} grid | ` +
      `step=${this._hdr.step}m | ${(buf.byteLength/1024).toFixed(0)} KB binary`
    );
  }

  /**
   * Returns flood depth in metres at the given WGS-84 coordinate.
   * null  = outside data extent
   * 0     = inside extent, no flood modelled
   * >0    = flood depth in metres
   *
   * Uses bilinear interpolation across the four surrounding grid cells so
   * depth transitions smoothly as you move, rather than jumping by the full
   * cell width (~11 m) at each grid boundary.
   */
  getDepth(lat, lon) {
    if (!this.ready) return null;
    const { bounds, cols, rows, cellDeg, step } = this._hdr;

    if (lon < bounds.west  || lon > bounds.east ||
        lat < bounds.south || lat > bounds.north) return null;

    // Fractional cell position
    const fc = (lon - bounds.west)  / cellDeg;
    const fr = (bounds.north - lat) / cellDeg;

    const col0 = Math.min(Math.floor(fc), cols - 1);
    const row0 = Math.min(Math.floor(fr), rows - 1);

    // Fractional offset within the cell (0–1)
    const fx = fc - col0;
    const fy = fr - row0;

    // Safe neighbour read — clamps at grid edges
    const cell = (r, c) => {
      if (r < 0 || r >= rows || c < 0 || c >= cols) return 0;
      return this._grid[r * cols + c];
    };

    const q00 = cell(row0,     col0);

    // If the cell itself has no flood polygon, return 0 — don't bleed
    // values from neighbouring flooded cells into dry areas.
    if (q00 === 0) return 0;

    const q10 = cell(row0,     col0 + 1);
    const q01 = cell(row0 + 1, col0);
    const q11 = cell(row0 + 1, col0 + 1);

    // Bilinear blend
    const q = (1 - fy) * ((1 - fx) * q00 + fx * q10)
            +      fy  * ((1 - fx) * q01 + fx * q11);

    if (q <= 0) return 0;
    return +(q * step).toFixed(2);
  }

  hazardLevel(depth) {
    if (depth <= 0)  return 'none';
    if (depth < 0.5) return 'low';
    if (depth < 1.5) return 'med';
    return 'high';
  }

  hazardLabel(depth) {
    return { none: 'NO FLOOD IN THIS AREA', low: 'LOW HAZARD', med: 'MED HAZARD', high: 'HIGH HAZARD' }
      [this.hazardLevel(depth)];
  }
}
