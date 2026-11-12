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

export function hlsMetadata(text, base) {
  const lines = text.trimStart().split(/\r?\n/);
  if (lines[0]?.trim() !== '#EXTM3U') return null;
  const variants = [];
  for (let index = 0; index + 1 < lines.length; index++) {
    if (!lines[index].startsWith('#EXT-X-STREAM-INF:')) continue;
    const next = lines[index + 1].trim();
    if (!next || next.startsWith('#')) continue;
    const url = URL.parse(next, base);
    if (!url || !['http:', 'https:'].includes(url.protocol)) continue;
    const attributes = lines[index].slice('#EXT-X-STREAM-INF:'.length);
    const height = Number(attributes.match(/(?:^|,)RESOLUTION=\d+x(\d+)/i)?.[1]);
    const average = Number(attributes.match(/(?:^|,)AVERAGE-BANDWIDTH=(\d+)/i)?.[1]);
    const bandwidth = Number(attributes.match(/(?:^|,)BANDWIDTH=(\d+)/i)?.[1]);
    variants.push({ url: url.href, height, average, bandwidth });
  }
  const duration = lines.reduce((sum, line) => {
    const seconds = Number(line.match(/^#EXTINF:([\d.]+)(?:,|$)/)?.[1]);
    return sum + (Number.isFinite(seconds) ? seconds : 0);
  }, 0);
  return { variants, duration: lines.some(line => line.trim() === '#EXT-X-ENDLIST')
    && duration > 0 ? duration : null };
}

export function hlsVariants(text, base) {
  return hlsMetadata(text, base)?.variants.map(variant => variant.url) ?? [];
}

export function groupMedia(items, inspections) {
  const byUrl = new Map(items.map(item => [item.url, item]));
  const variantUrls = new Set(items.flatMap(item =>
    (inspections.get(item.url)?.variants ?? []).map(variant => variant.url),
  ));
  return items
    .filter(item => !variantUrls.has(item.url) || inspections.get(item.url)?.variants.length)
    .map(item => {
      const variants = inspections.get(item.url)?.variants ?? [];
      const options = new Map();
      for (const variant of variants) {
        if (variant.url === item.url || inspections.get(variant.url)?.variants.length) continue;
        options.set(variant.url, {
          type: 'HLS', url: variant.url, ...byUrl.get(variant.url), variant,
        });
      }
      return {
        item,
        options: [...options.values()].sort((a, b) =>
          (b.variant.height || 0) - (a.variant.height || 0) ||
          (b.variant.bandwidth || 0) - (a.variant.bandwidth || 0)),
      };
    });
}

export function responseFilename(value = '') {
  const encoded = value.match(/(?:^|;)\s*filename\*=UTF-8'[^']*'([^;]+)/i)?.[1];
  const plain = value.match(/(?:^|;)\s*filename\s*=\s*(?:"([^"]*)"|([^;]+))/i);
  let name = plain?.[1] ?? plain?.[2] ?? '';
  if (encoded) {
    try { name = decodeURIComponent(encoded.trim()); } catch { /* use plain filename */ }
  }
  return name.split(/[\\/]/).at(-1)?.replace(/[\x00-\x1f\x7f]/g, '').trim() || null;
}

export async function inspectHls(url) {
  const response = await fetch(url, {
    credentials: 'omit',
    referrerPolicy: 'no-referrer',
    signal: AbortSignal.timeout(3500),
  });
  if (!response.body) return null;
  if (!response.ok) {
    await response.body.cancel();
    return null;
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let text = '';
  let remaining = 64 * 1024;
  try {
    while (remaining > 0) {
      const { done, value } = await reader.read();
      if (done) return hlsMetadata(text + decoder.decode(), response.url || url);
      text += decoder.decode(value.subarray(0, remaining), { stream: true });
      remaining -= value.length;
    }
    return null;
  } finally {
    await reader.cancel().catch(() => {});
  }
}
