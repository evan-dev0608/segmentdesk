import test from 'node:test';
import assert from 'node:assert/strict';

test('stores only opted-in tab manifests and preserves signed URLs', async () => {
  const data = {};
  let message, request, remove;
  globalThis.chrome = {
    storage: { session: {
      get: async key => ({ [key]: data[key] }),
      set: async values => Object.assign(data, values),
      remove: async key => delete data[key],
    } },
    runtime: { onMessage: { addListener: fn => { message = fn; } } },
    tabs: { onRemoved: { addListener: fn => { remove = fn; } } },
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
  request({ ...response, tabId: 2 });
  request({ ...response, tabId: 1 });
  request({ ...response, tabId: 1 });
  await command('stop', 1);
  request({ ...response, url: 'https://cdn.test/other', tabId: 1 });
  await command('stop', 1);
  assert.deepEqual(data, { 1: { active: false, items: [{ type: 'DASH', url }] } });
  remove(1);
  await command('stop', 2);
  assert.equal(data[1], undefined);
});
