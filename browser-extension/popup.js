import { groupMedia, inspectHls } from './media.mjs';

function formatDuration(duration) {
  if (!duration) return null;
  const seconds = Math.round(duration);
  const minutes = Math.floor(seconds / 60);
  return [Math.floor(minutes / 60), minutes % 60, seconds % 60]
    .map(value => String(value).padStart(2, '0')).join(':');
}

const button = document.querySelector('#capture');
const status = document.querySelector('#status');
const results = document.querySelector('#results');
const empty = document.querySelector('#empty');
const emptyTitle = document.querySelector('#empty-title');
const emptyDescription = document.querySelector('#empty-description');
const count = document.querySelector('#count');
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

if (!tab?.url || !/^https?:\/\//i.test(tab.url)) {
  emptyTitle.textContent = '此页面无法检测';
  emptyDescription.textContent = '请在视频网页中打开扩展。';
} else {
  document.querySelector('#site').textContent = new URL(tab.url).hostname;
  const key = String(tab.id);
  let active = false;
  let currentState;
  const inspections = new Map();
  const sending = new Set();

  function render(state) {
    currentState = state;
    const focused = document.activeElement;
    const focusedUrl = focused?.dataset.url;
    const focusedAction = focused?.className;
    let nextFocus;
    const page = URL.parse(state?.pageUrl ?? tab.url);
    document.querySelector('#site').textContent = page?.hostname ?? '媒体检测';
    active = state?.active ?? false;
    button.textContent = active ? '停止检测' : '开始检测';
    button.setAttribute('aria-pressed', String(active));
    const items = state?.items ?? [];
    empty.hidden = items.length > 0;
    emptyTitle.textContent = active ? '正在等待媒体' : '还没有媒体';
    emptyDescription.textContent = active
      ? '请播放视频。已经在播放时，可以刷新页面。'
      : '开始检测后，在网页上播放视频。';
    results.replaceChildren();
    const groups = groupMedia(items, inspections);
    const ordered = groups.flatMap(({ item, options }) => [item, ...options]);
    count.hidden = ordered.length === 0;
    count.textContent = `${groups.length} 组 · ${ordered.length} 项`;
    for (const { url, type } of ordered.slice(0, 12)) {
      if (type !== 'HLS' || inspections.has(url) || inspections.size >= 24) continue;
      inspections.set(url, null);
      void (async () => {
        for (let attempt = 0; attempt < 2; attempt++) {
          if (attempt) {
            await new Promise(resolve => setTimeout(resolve, 1200));
            if (!currentState?.items?.some(item => item.url === url)) return;
          }
          const metadata = await inspectHls(url).catch(() => null);
          if (!metadata) continue;
          inspections.set(url, metadata);
          render(currentState);
          return;
        }
      })();
    }
    const containers = new Map();
    const pageTitle = state?.pageTitle || (state?.pageUrl === tab.url ? tab.title : '') || page?.hostname;
    for (const { item, options } of groups) {
      const card = document.createElement('li');
      card.className = 'media-group';
      const title = document.createElement('h3');
      title.textContent = pageTitle || item.filename || new URL(item.url).hostname;
      title.title = title.textContent;
      const list = document.createElement('ul');
      list.className = 'media-options';
      list.setAttribute('aria-label', '下载选项');
      for (const option of [item, ...options]) {
        containers.set(option, list);
      }
      card.append(title, list);
      results.append(card);
    }
    for (const item of ordered) {
      const row = document.createElement('li');
      const url = new URL(item.url);
      const label = document.createElement('div');
      label.className = 'media';
      label.title = url.host + url.pathname;
      const name = document.createElement('span');
      name.className = 'name';
      const filename = url.pathname.split('/').filter(Boolean).at(-1);
      const host = document.createElement('dl');
      host.className = 'media-facts';
      const metadata = inspections.get(item.url);
      const variant = item.variant;
      const master = Boolean(metadata?.variants.length);
      name.textContent = master ? '自动选轨 · 主清单' :
        (item.filename || filename || '媒体资源');
      const duration = item.duration ?? metadata?.duration ??
        metadata?.variants.map(entry => inspections.get(entry.url)?.duration).find(Boolean);
      const height = variant?.height || item.height;
      const bitrate = variant?.average || variant?.bandwidth;
      const estimated = duration && variant?.average ? duration * variant.average / 8 : null;
      const bytes = item.size ?? estimated;
      const size = bytes ? new Intl.NumberFormat('zh-CN', {
        style: 'unit', unit: bytes >= 1e9 ? 'gigabyte' : 'megabyte',
        maximumFractionDigits: 2,
      }).format(bytes / (bytes >= 1e9 ? 1e9 : 1e6)) : null;
      const details = [
        ['类型', item.type],
        ['画质', height ? `${height}p` : null],
        ['码率', bitrate ? `${Math.round(bitrate / 1000)} kbps` : null],
        ['时长', formatDuration(duration)],
        ['大小', size && (item.size ? size : `约 ${size}`)],
      ];
      for (const [key, value] of details) {
        if (!value) continue;
        const fact = document.createElement('div');
        const term = document.createElement('dt');
        const definition = document.createElement('dd');
        term.textContent = key;
        definition.textContent = value;
        fact.append(term, definition);
        host.append(fact);
      }
      label.append(name, host);
      const copy = document.createElement('button');
      copy.className = 'copy';
      copy.dataset.url = item.url;
      copy.textContent = '复制';
      copy.setAttribute('aria-label', '复制链接');
      copy.onclick = async () => {
        try {
          await navigator.clipboard.writeText(item.url);
          status.textContent = '已复制完整链接，请粘贴到 SegmentDesk。';
        } catch {
          status.textContent = '复制失败，请重试。';
        }
      };
      const send = document.createElement('button');
      send.className = 'send';
      send.dataset.url = item.url;
      send.disabled = sending.has(item.url);
      send.textContent = send.disabled ? '正在发送…' : '发送到客户端';
      send.onclick = async () => {
        if (sending.has(item.url)) return;
        sending.add(item.url);
        send.disabled = true;
        send.textContent = '正在发送…';
        try {
          const currentTab = await chrome.tabs.get(tab.id);
          if (currentTab.url !== (state?.pageUrl ?? tab.url) ||
              !groupMedia(currentState?.items ?? [], inspections).some(group =>
                group.item.url === item.url || group.options.some(option => option.url === item.url))) {
            status.textContent = '页面已切换，请选择当前页面的媒体。';
            return;
          }
          const result = await chrome.runtime.sendNativeMessage('com.segmentdesk.import', {
            version: 1, url: item.url, type: item.type,
            title: pageTitle || currentTab.title || '', source: currentTab.url,
          });
          if (!result?.ok) throw new Error('Import failed');
          status.textContent = '已加入 SegmentDesk 导入队列。请在客户端查看。';
        } catch {
          status.textContent = '无法连接 SegmentDesk。请使用新版 Windows 安装包，或复制链接。';
        } finally {
          sending.delete(item.url);
          for (const button of document.querySelectorAll('.send')) {
            if (button.dataset.url !== item.url) continue;
            button.disabled = false;
            button.textContent = '发送到客户端';
          }
        }
      };
      const actions = document.createElement('div');
      actions.className = 'actions';
      if (['HLS', 'DASH', 'MSS', 'M3U', 'MP4'].includes(item.type)) {
        actions.append(send);
      } else {
        const support = document.createElement('div');
        support.className = 'meta';
        support.textContent = '仅可复制链接';
        label.append(support);
      }
      actions.append(copy);
      if (focusedUrl === item.url) {
        nextFocus = focusedAction === 'send' ? send : copy;
      }
      row.append(label, actions);
      containers.get(item).append(row);
    }
    nextFocus?.focus({ preventScroll: true });
  }

  chrome.storage.session.onChanged.addListener(changes => {
    if (key in changes) render(changes[key].newValue);
  });
  render((await chrome.storage.session.get(key))[key]);
  button.disabled = false;
  button.onclick = async () => {
    status.textContent = '';
    button.disabled = true;
    try {
      const response = await chrome.runtime.sendMessage({
        action: active ? 'stop' : 'start', tabId: tab.id,
        pageUrl: (await chrome.tabs.get(tab.id)).url,
      });
      if (!response?.ok) throw new Error('Capture state update failed');
    } catch {
      status.textContent = '无法更新检测状态，请重试。';
    } finally {
      button.disabled = false;
    }
  };
}
