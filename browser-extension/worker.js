import { detectMedia } from './media.mjs';

const storage = chrome.storage.session;
let pending = Promise.resolve();

function serialize(work) {
  const result = pending.then(work);
  pending = result.catch(console.error);
  return result;
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!['start', 'stop'].includes(message.action) ||
      !Number.isInteger(message.tabId)) return;
  const key = String(message.tabId);
  serialize(async () => {
    const state = (await storage.get(key))[key];
    await storage.set({
      [key]: message.action === 'start'
        ? { active: true, items: [] }
        : { active: false, items: state?.items ?? [] },
    });
  }).then(() => reply({ ok: true }), () => reply({ ok: false }));
  return true;
});

chrome.tabs.onRemoved.addListener(tabId => {
  serialize(() => storage.remove(String(tabId)));
});

chrome.webRequest.onHeadersReceived.addListener(details => {
  if (details.tabId < 0 ||
      (details.statusCode !== 304 &&
       (details.statusCode < 200 || details.statusCode >= 300))) return;
  const mime = details.responseHeaders?.find(
    header => header.name.toLowerCase() === 'content-type'
  )?.value;
  const type = detectMedia(details.url, mime);
  if (!type) return;
  const key = String(details.tabId);
  serialize(async () => {
    const state = (await storage.get(key))[key];
    if (!state?.active || state.items.some(item => item.url === details.url)) return;
    state.items.unshift({ type, url: details.url });
    await storage.set({ [key]: { active: true, items: state.items.slice(0, 30) } });
  });
}, { urls: ['http://*/*', 'https://*/*'] }, ['responseHeaders']);
