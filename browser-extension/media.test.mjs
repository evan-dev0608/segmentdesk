import test from 'node:test';
import assert from 'node:assert/strict';
import { detectMedia, hlsVariants } from './media.mjs';

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
