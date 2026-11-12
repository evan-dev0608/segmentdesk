export function detectMedia(rawUrl, contentType = '') {
  const url = new URL(rawUrl);
  const mime = contentType.split(';')[0].trim().toLowerCase();
  if (!['http:', 'https:'].includes(url.protocol)) return null;
  if (mime === 'application/dash+xml' || /\.mpd$/i.test(url.pathname)) return 'DASH';
  if (['application/vnd.apple.mpegurl', 'application/x-mpegurl',
    'audio/mpegurl', 'audio/x-mpegurl'].includes(mime) ||
      /\.m3u8$/i.test(url.pathname)) return 'HLS';
  return null;
}
