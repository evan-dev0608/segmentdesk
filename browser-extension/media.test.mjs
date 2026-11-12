import test from 'node:test';
import assert from 'node:assert/strict';
import { detectMedia, groupMedia, hlsMetadata, hlsVariants, responseFilename } from './media.mjs';

test('groups declared HLS options by their own master and sorts by quality', () => {
  const master = { type: 'HLS', url: 'https://cdn.test/master.m3u8' };
  const low = { type: 'HLS', url: 'https://cdn.test/low.m3u8?sig=A%2Bb' };
  const high = 'https://cdn.test/high.m3u8';
  const unrelated = { type: 'MP4', url: 'https://cdn.test/other.mp4' };
  const metadata = new Map([[master.url, { variants: [
    { url: low.url, height: 360 }, { url: high, height: 1080 },
  ] }]]);
  const groups = groupMedia([low, master, unrelated], metadata);
  assert.deepEqual(groups.map(group => group.item), [master, unrelated]);
  assert.deepEqual(groups[0].options.map(option => option.url), [high, low.url]);
});

test('reads HLS quality and finite duration and leaves live duration unknown', () => {
  const base = 'https://cdn.test/master.m3u8';
  const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2400000,AVERAGE-BANDWIDTH=2000000,RESOLUTION=1280x720\nvideo.m3u8';
  assert.deepEqual(hlsMetadata(master, base).variants[0], {
    url: 'https://cdn.test/video.m3u8', height: 720, average: 2000000, bandwidth: 2400000,
  });
  const media = '#EXTM3U\n#EXTINF:8.5,\na.ts\n#EXTINF:7.5,\nb.ts';
  assert.equal(hlsMetadata(media, base).duration, null);
  assert.equal(hlsMetadata(media + '\n#EXT-X-ENDLIST', base).duration, 16);
});

test('prefers UTF-8 server filename and strips path components', () => {
  assert.equal(responseFilename("attachment; filename=old.mp4; filename*=UTF-8''%E8%A7%86%E9%A2%91.mp4"), '视频.mp4');
  assert.equal(responseFilename('attachment; filename="../movie.mp4"'), 'movie.mp4');
});

test('only groups exact variant URLs declared by an HLS master', () => {
  const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200\nhi.m3u8?sig=A%2Bb\n' +
    '#EXT-X-STREAM-INF:BANDWIDTH=600\n../low.m3u8\n';
  assert.deepEqual(hlsVariants(master, 'https://cdn.test/video/master.m3u8'), [
    'https://cdn.test/video/hi.m3u8?sig=A%2Bb',
    'https://cdn.test/low.m3u8',
  ]);
  assert.deepEqual(hlsVariants('#EXTM3U\n#EXTINF:6,\nsegment.ts', 'https://cdn.test/'), []);
});

test('detects Smooth Streaming, M3U playlists and MP4 direct media', () => {
  assert.equal(detectMedia('https://cdn.test/live.isml/Manifest(format=mss)?sig=A%2Bb'), 'MSS');
  assert.equal(detectMedia('https://cdn.test/play', 'application/vnd.ms-sstr+xml'), 'MSS');
  assert.equal(detectMedia('https://cdn.test/channels.m3u'), 'M3U');
  assert.equal(detectMedia('https://cdn.test/play?sig=A%2Bb', 'video/mp4'), 'MP4');
  assert.equal(detectMedia('https://cdn.test/segment.m4s', 'video/mp4'), null);
});

test('recognizes signed HLS and DASH URLs', () => {
  assert.equal(detectMedia('https://cdn.test/a.M3U8?token=abc'), 'HLS');
  assert.equal(detectMedia('https://cdn.test/a.mpd?token=abc'), 'DASH');
});
test('recognizes manifests without file extensions', () => {
  assert.equal(detectMedia('https://cdn.test/play', 'Application/Vnd.Apple.Mpegurl; charset=utf-8'), 'HLS');
  assert.equal(detectMedia('https://cdn.test/play', 'application/dash+xml'), 'DASH');
});
test('ignores media segments and query parameters containing a filename', () => {
  assert.equal(detectMedia('https://cdn.test/chunk.ts', 'video/mp2t'), null);
  assert.equal(detectMedia('https://cdn.test/play?name=file.m3u8'), null);
});
