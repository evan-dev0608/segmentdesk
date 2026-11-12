import { inspectHls } from './media.mjs';

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
  const variants = document.querySelector('#variants');
  const variantResults = document.querySelector('#variant-results');

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
    count.textContent = `${items.length} 项`;
    empty.hidden = items.length > 0;
    emptyTitle.textContent = active ? '正在等待媒体' : '还没有媒体';
    emptyDescription.textContent = active
      ? '请播放视频。已经在播放时，可以刷新页面。'
      : '开始检测后，在网页上播放视频。';
    results.replaceChildren();
    variantResults.replaceChildren();
    for (const { url, type } of items.slice(0, 12)) {
      if (type !== 'HLS' || inspections.has(url)) continue;
      inspections.set(url, []);
      inspectHls(url).then(children => {
        if (!children.length) return;
        inspections.set(url, children);
        render(currentState);
      }).catch(() => {});
    }
    const isMaster = item => Boolean(inspections.get(item.url)?.length);
    const children = new Set(items.flatMap(item => inspections.get(item.url) ?? []));
    const ordered = [...items].sort((a, b) => Number(isMaster(b)) - Number(isMaster(a)));
    let variantCount = 0;
    for (const item of ordered) {
      const row = document.createElement('li');
      const url = new URL(item.url);
      const label = document.createElement('div');
      label.className = 'media';
      label.title = url.host + url.pathname;
      const name = document.createElement('span');
      name.className = 'name';
      const filename = url.pathname.split('/').filter(Boolean).at(-1);
      name.textContent = (item.type === 'MP4' ? tab.title : filename) || filename || '媒体资源';
      const host = document.createElement('span');
      host.className = 'meta';
      const size = item.size ? new Intl.NumberFormat('zh-CN', {
        style: 'unit', unit: item.size >= 1e9 ? 'gigabyte' : 'megabyte',
        maximumFractionDigits: 2,
      }).format(item.size / (item.size >= 1e9 ? 1e9 : 1e6)) : null;
      host.textContent = [isMaster(item) ? 'HLS · 可选画质' : item.type, size, url.host]
        .filter(Boolean).join(' · ');
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
              !currentState?.items.some(candidate => candidate.url === item.url)) {
            status.textContent = '页面已切换，请选择当前页面的媒体。';
            return;
          }
          const result = await chrome.runtime.sendNativeMessage('com.segmentdesk.import', {
            version: 1, url: item.url, type: item.type,
            title: currentTab.title ?? '', source: currentTab.url,
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
      if (['HLS', 'DASH', 'MSS', 'M3U'].includes(item.type)) {
        actions.append(send);
      } else {
        const support = document.createElement('div');
        support.className = 'meta';
        support.textContent = '直链下载待支持';
        label.append(support);
      }
      actions.append(copy);
      if (focusedUrl === item.url) {
        nextFocus = focusedAction === 'send' ? send : copy;
      }
      row.append(label, actions);
      if (item.type === 'HLS' && !isMaster(item) && children.has(item.url)) {
        variantResults.append(row);
        variantCount++;
      } else {
        results.append(row);
      }
    }
    variants.hidden = variantCount === 0;
    document.querySelector('#variant-label').textContent = `单画质清单（${variantCount}）`;
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
