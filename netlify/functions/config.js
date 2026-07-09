// Exposes the public (pk) Mapbox token to the browser so mini-map.js can
// initialise Mapbox GL JS. The token is URL-restricted at Mapbox to the
// bahar-mm.netlify.app origin, so shipping it to the client is safe.
export async function handler() {
  const token = process.env.MAPBOX_PUBLIC_TOKEN;
  if (!token) {
    return { statusCode: 500, body: 'MAPBOX_PUBLIC_TOKEN not configured' };
  }
  return {
    statusCode: 200,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'public, max-age=300',
    },
    body: JSON.stringify({ mapboxToken: token }),
  };
}
