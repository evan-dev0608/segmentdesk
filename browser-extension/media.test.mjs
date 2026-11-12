import test from 'node:test';
import assert from 'node:assert/strict';
import { detectMedia } from './media.mjs';

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
