import { detectMedia, responseFilename } from './media.mjs';

const storage = chrome.storage.session;
let pending = Promise.resolve();

function serialize(work) {
  const result = pending.then(work);
  pending = result.catch(console.error);
  return result;
}

async function recordCandidates(tabId, candidates, documentId) {
  const key = String(tabId);
  const state = (await storage.get(key))[key];
  if (!state?.active ||
      (documentId && state.documentId && documentId !== state.documentId)) return;
  const known = new Map(state.items.map(item => [item.url, item]));
  const fresh = [];
  let updated = false;
  for (const candidate of candidates) {
    const previous = known.get(candidate.url);
    if (previous) {
      for (const field of ['size', 'filename', 'duration']) {
        if (candidate[field] && !previous[field]) {
          previous[field] = candidate[field];
          updated = true;
        }
      }
      continue;
    }
    known.set(candidate.url, candidate);
    fresh.push(candidate);
  }
  if (updated || fresh.length) {
    await storage.set({ [key]: {
      ...state, items: [...fresh.reverse(), ...state.items].slice(0, 30),
    } });
  }
}

async function scanPage(tabId) {
  const frames = await chrome.scripting.executeScript({
    target: { tabId, allFrames: true },
    func: () => [
      { pageTitle: document.querySelector('meta[property="og:title"]')?.content ||
          document.title },
      ...performance.getEntriesByType('resource').map(
        entry => ({ url: entry.name, mime: entry.contentType }),
      ),
      ...Array.from(document.querySelectorAll('video, audio, source'))
        .flatMap(element => [element.currentSrc, element.src].filter(Boolean)
          .map(url => ({
            url, mime: element.type,
            duration: url === element.currentSrc ? element.duration : null,
          }))),
    ],
  });
  const title = frames.find(frame => frame.frameId === 0)?.result?.[0]?.pageTitle;
  if (title?.trim()) {
    const key = String(tabId);
    const state = (await storage.get(key))[key];
    if (state?.active) {
      await storage.set({ [key]: { ...state, pageTitle: title.trim().slice(0, 240) } });
    }
  }
  const candidates = frames.flatMap(({ result }) => (result ?? []).flatMap(({ url, mime, duration }) => {
    const type = detectMedia(url, mime);
    return type ? [{ type, url, ...(type === 'MP4' && Number.isFinite(duration) && duration > 0
      ? { duration } : {}) }] : [];
  }));
  await recordCandidates(tabId, candidates);
}

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (!['start', 'stop'].includes(message.action) ||
      !Number.isInteger(message.tabId)) return;
  const key = String(message.tabId);
  serialize(async () => {
    const state = (await storage.get(key))[key];
    await storage.set({
      [key]: message.action === 'start'
        ? { active: true, items: [], ...(message.pageUrl ? { pageUrl: message.pageUrl } : {}) }
        : { ...state, active: false, items: state?.items ?? [] },
    });
    if (message.action === 'start') {
      try {
        await scanPage(message.tabId);
      } catch {
        // Live request detection still works when Chrome restricts script injection.
      }
    }
  }).then(() => reply({ ok: true }), () => reply({ ok: false }));
  return true;
});

chrome.tabs.onRemoved.addListener(tabId => {
  serialize(() => storage.remove(String(tabId)));
});

function resetForNavigation({ tabId, frameId, url, documentId }) {
  if (frameId !== 0) return;
  const key = String(tabId);
  serialize(async () => {
    const state = (await storage.get(key))[key];
    if (state) await storage.set({
      [key]: { active: state.active, items: [], pageUrl: url,
        ...(documentId ? { documentId } : {}) },
    });
  });
}

chrome.webNavigation.onCommitted.addListener(resetForNavigation);
chrome.webNavigation.onHistoryStateUpdated.addListener(resetForNavigation);

chrome.webRequest.onHeadersReceived.addListener(details => {
  if (details.tabId < 0 ||
      (details.statusCode !== 304 &&
       (details.statusCode < 200 || details.statusCode >= 300))) return;
  const headers = new Map(details.responseHeaders?.map(
    header => [header.name.toLowerCase(), header.value],
  ));
  const mime = headers.get('content-type');
  const type = detectMedia(details.url, mime);
  if (!type) return;
  const candidate = { type, url: details.url };
  const filename = responseFilename(headers.get('content-disposition'));
  if (filename) candidate.filename = filename;
  if (type === 'MP4') {
    const total = details.statusCode === 206
      ? headers.get('content-range')?.match(/\/(\d+)$/)?.[1]
      : headers.get('content-length');
    const size = Number(total);
    if (Number.isSafeInteger(size) && size > 0) candidate.size = size;
  }
  serialize(() => recordCandidates(
    details.tabId, [candidate], details.frameId === 0 ? details.documentId : undefined,
  ));
}, { urls: ['http://*/*', 'https://*/*'] }, ['responseHeaders']);
