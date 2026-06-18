const TILESET_ID = 'upri-noah.mm_fh_100yr_tls';

export async function handler(event) {
  const { lat, lon } = event.queryStringParameters ?? {};

  if (!lat || !lon) {
    return { statusCode: 400, body: 'Missing lat/lon' };
  }

  const token = process.env.MAPBOX_TOKEN;
  if (!token) {
    return { statusCode: 500, body: 'MAPBOX_TOKEN not configured' };
  }

  // Tight radius + single result so we report the polygon directly under
  // the query point, not the worst of any neighbour within 25 m. The old
  // (radius=25, limit=5) would bleed nearby low-flood polygons into "safe"
  // locations like UP Resilience Institute and trigger a false gutter-level
  // reading. 5 m absorbs typical GPS jitter without crossing tile edges.
  const url =
    `https://api.mapbox.com/v4/${TILESET_ID}/tilequery/${lon},${lat}.json` +
    `?radius=5&limit=1&access_token=${token}`;

  try {
    const res  = await fetch(url);
    const data = await res.json();
    return {
      statusCode: 200,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    };
  } catch (e) {
    return { statusCode: 502, body: `Upstream error: ${e.message}` };
  }
}
