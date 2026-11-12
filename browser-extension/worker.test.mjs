import test from 'node:test';
import assert from 'node:assert/strict';

test('stores only opted-in tab manifests and preserves signed URLs', async () => {
  const data = {};
  let message, request, remove, commit, history;
  globalThis.chrome = {
    scripting: {
      executeScript: async ({ target }) => {
        assert.deepEqual(target, { tabId: 1, allFrames: true });
        return [
          { result: [{ url: 'blob:https://player.test/123' }] },
          { result: [{ url: 'https://cdn.test/master?token=A%2Bb',
            mime: 'application/vnd.apple.mpegurl' }] },
        ];
      },
    },
    storage: { session: {
      get: async key => ({ [key]: data[key] }),
      set: async values => Object.assign(data, values),
      remove: async key => delete data[key],
    } },
    runtime: { onMessage: { addListener: fn => { message = fn; } } },
    tabs: { onRemoved: { addListener: fn => { remove = fn; } } },
    webNavigation: {
      onCommitted: { addListener: fn => { commit = fn; } },
      onHistoryStateUpdated: { addListener: fn => { history = fn; } },
    },
    webRequest: { onHeadersReceived: { addListener: fn => { request = fn; } } },
  };
  await import('./worker.js');
  const command = (action, tabId) => new Promise(resolve => {
    assert.equal(message({ action, tabId }, {}, resolve), true);
  });
  const url = 'https://cdn.test/manifest?signature=A%2Bb';
  const response = {
    url, statusCode: 200,
    initiator: 'https://player.test',
    responseHeaders: [{ name: 'Content-Type', value: 'application/dash+xml' }],
  };
  assert.deepEqual(await command('start', 1), { ok: true });
  const earlier = { type: 'HLS', url: 'https://cdn.test/master?token=A%2Bb' };
  assert.deepEqual(data[1].items, [earlier]);
  request({ ...response, tabId: 2 });
  request({ ...response, tabId: 1 });
  request({ ...response, tabId: 1 });
  await command('stop', 1);
  request({ ...response, url: 'https://cdn.test/other', tabId: 1 });
  await command('stop', 1);
  assert.deepEqual(data, {
    1: { active: false, items: [{ type: 'DASH', url }, earlier] },
  });
  await command('start', 1);
  const mp4 = 'https://cdn.test/video?token=A%2Bb';
  request({ tabId: 1, url: mp4, statusCode: 206, responseHeaders: [
    { name: 'Content-Type', value: 'video/mp4' },
    { name: 'Content-Length', value: '100' },
    { name: 'Content-Range', value: 'bytes 0-99/1000000000' },
  ] });
  await command('stop', 1);
  assert.deepEqual(data[1].items[0], { type: 'MP4', url: mp4, size: 1000000000 });
  await command('start', 1);
  commit({ tabId: 1, frameId: 0, url: 'https://player.test/next', documentId: 'new' });
  request({ ...response, tabId: 1, frameId: 0, documentId: 'old' });
  request({ ...response, tabId: 1, frameId: 0, documentId: 'new' });
  await command('stop', 1);
  assert.deepEqual(data[1].items, [{ type: 'DASH', url }]);
  history({ tabId: 1, frameId: 0, url: 'https://player.test/third', documentId: 'new' });
  await command('stop', 1);
  assert.deepEqual(data[1].items, []);
  assert.equal(data[1].pageUrl, 'https://player.test/third');
  remove(1);
  await command('stop', 2);
  assert.equal(data[1], undefined);
});
