export function detectMedia(rawUrl, contentType = '') {
  const url = URL.parse(rawUrl);
  const mime = contentType.split(';')[0].trim().toLowerCase();
  if (!url || !['http:', 'https:'].includes(url.protocol)) return null;
  if (mime === 'application/dash+xml' || /\.mpd$/i.test(url.pathname)) return 'DASH';
  if (mime === 'application/vnd.ms-sstr+xml' ||
      /\.ism(?:l)?(?:\/manifest(?:\([^/]*\))?)?\/?$/i.test(url.pathname)) return 'MSS';
  if (['application/vnd.apple.mpegurl', 'application/mpegurl', 'application/x-mpegurl',
    'audio/mpegurl', 'audio/x-mpegurl'].includes(mime) ||
      /\.m3u8$/i.test(url.pathname)) return 'HLS';
  if (/\.m3u$/i.test(url.pathname)) return 'M3U';
  if (!/\.(?:m4s|cmfv|cmfa|ts)$/i.test(url.pathname) &&
      (mime === 'video/mp4' || /\.mp4$/i.test(url.pathname))) return 'MP4';
  return null;
}

export function hlsVariants(text, base) {
  const lines = text.trimStart().split(/\r?\n/);
  if (lines[0]?.trim() !== '#EXTM3U') return [];
  const variants = [];
  for (let index = 0; index + 1 < lines.length; index++) {
    if (!lines[index].startsWith('#EXT-X-STREAM-INF:')) continue;
    const next = lines[index + 1].trim();
    if (!next || next.startsWith('#')) continue;
    const url = URL.parse(next, base);
    if (url && ['http:', 'https:'].includes(url.protocol)) variants.push(url.href);
  }
  return variants;
}

export async function inspectHls(url) {
  const response = await fetch(url, {
    credentials: 'omit',
    referrerPolicy: 'no-referrer',
    signal: AbortSignal.timeout(3500),
  });
  if (!response.body) return [];
  if (!response.ok) {
    await response.body.cancel();
    return [];
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let text = '';
  let remaining = 64 * 1024;
  try {
    while (remaining > 0) {
      const { done, value } = await reader.read();
      if (done) return hlsVariants(text + decoder.decode(), response.url || url);
      text += decoder.decode(value.subarray(0, remaining), { stream: true });
      remaining -= value.length;
    }
    return [];
  } finally {
    await reader.cancel().catch(() => {});
  }
}
