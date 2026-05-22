"""
Terrain Elevation Preprocessing — QC
Samples SRTM30m terrain elevation over Quezon City via OpenTopoData batch API.
Output: qc_terrain.bin (uint8, value = metres above sea level) + qc_terrain_header.json
Resolution: 0.002 deg (~220 m) — sufficient for elevation correction.
"""

import json, array, time, urllib.request, urllib.error

BOUNDS = {"west": 120.945, "south": 14.580, "east": 121.175, "north": 14.785}
CELL_DEG   = 0.002
OUTPUT_DIR = r"c:\Users\eka\Desktop\NOAH AR"

cols = round((BOUNDS["east"]  - BOUNDS["west"])  / CELL_DEG)  # 115
rows = round((BOUNDS["north"] - BOUNDS["south"]) / CELL_DEG)  # 103
print(f"Grid: {cols} cols x {rows} rows = {cols*rows} cells (~{cols*rows} bytes)")

# Build ordered list of (lat, lon, row, col)
points = []
for r in range(rows):
    lat = BOUNDS["north"] - (r + 0.5) * CELL_DEG
    for c in range(cols):
        lon = BOUNDS["west"] + (c + 0.5) * CELL_DEG
        points.append((lat, lon, r, c))

terrain = array.array('B', bytes(rows * cols))  # uint8

BATCH = 100
total_batches = (len(points) + BATCH - 1) // BATCH
print(f"Fetching {len(points)} points in {total_batches} batches (1/s rate limit)...\n")

for i in range(0, len(points), BATCH):
    batch  = points[i:i+BATCH]
    locs   = "|".join(f"{lat:.4f},{lon:.4f}" for lat, lon, _, _ in batch)
    url    = f"https://api.opentopodata.org/v1/srtm30m?locations={locs}"
    b_num  = i // BATCH + 1

    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                data = json.loads(r.read())
            for j, result in enumerate(data["results"]):
                elev = result.get("elevation") or 0
                _, _, row, col = batch[j]
                terrain[row * cols + col] = max(0, min(255, round(elev)))
            break
        except Exception as e:
            print(f"  Batch {b_num} attempt {attempt+1} failed: {e}")
            time.sleep(2)

    if b_num % 10 == 0 or b_num == total_batches:
        print(f"  {b_num}/{total_batches} batches done", flush=True)

    time.sleep(1.05)  # stay under 1 req/s free-tier limit

# Save binary
bin_path = f"{OUTPUT_DIR}\\qc_terrain.bin"
with open(bin_path, "wb") as f:
    terrain.tofile(f)
print(f"\nBinary: {bin_path}  ({len(terrain)} bytes)")

# Save header
header = {
    "bounds":   BOUNDS,
    "cols":     cols,
    "rows":     rows,
    "cellDeg":  CELL_DEG,
    "dtype":    "uint8",
    "dataFile": "qc_terrain.bin",
    "encoding": "uint8 — value = terrain elevation in metres above sea level"
}
with open(f"{OUTPUT_DIR}\\qc_terrain_header.json", "w") as f:
    json.dump(header, f, indent=2)

nz = sum(1 for v in terrain if v > 0)
print(f"Elevation stats: min {min(terrain)} m  max {max(terrain)} m  ({nz} non-zero cells)")
print("Done.")