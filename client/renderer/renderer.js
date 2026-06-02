// 渲染层逻辑：仅通过 window.api（preload 暴露）与主进程/服务端交互。
const $ = (id) => document.getElementById(id);
// 注意：preload 通过 contextBridge 暴露的 window.api 已是全局名 `api`，
// 不能再 `const api = ...`（会触发 "Identifier 'api' has already been declared"）。
// 下方代码直接引用全局 `api`。

let state = null;          // /api/state
let workspaceItems = [];
let remoteItems = [];      // 远端配置项清单
let localItems = [];       // 本地 SQLite 配置项
let diff = { onlyLocal: [], onlyRemote: [], changed: [], same: [] };
let workspaceDiff = { onlyLocal: [], onlyRemote: [], changed: [], same: [] };

function log(el, lines) {
  el.textContent = Array.isArray(lines) ? lines.join('\n') : String(lines);
}
function shortSha(s) { return s ? s.slice(0, 8) : '—'; }
function errorMessage(err) { return err instanceof Error ? err.message : String(err); }

// ---------- 启动 ----------
async function boot() {
  console.log('[boot] renderer start, api=' + (typeof api));
  $('serverUrl').value = (await api.getSetting('server_url')) || '';
  await loadTheme();
  bindEvents();
  await refreshState();
  await reloadSync();
  await reloadSnaps();
}

function bindEvents() {
  $('testConn').onclick = testConn;
  $('applyTier').onclick = applyTier;
  $('restartBtn').onclick = restart;
  $('reloadSync').onclick = reloadSync;
  $('downloadWorkspace').onclick = downloadWorkspaceToLocal;
  $('uploadWorkspace').onclick = uploadLocalToWorkspace;
  $('pullRedis').onclick = pullRedisToLocal;
  $('pushRedis').onclick = pushLocalToRedis;
  $('reloadSnaps').onclick = reloadSnaps;
  $('confirmCancel').onclick = () => $('confirmDlg').close();
  // tab 切换
  document.querySelectorAll('.tab-btn').forEach((btn) => {
    btn.onclick = () => switchTab(btn.dataset.tab);
  });
  // 设置弹窗
  $('settingsBtn').onclick = () => { $('themeSelect').value = document.documentElement.getAttribute('data-theme') || 'system'; $('settingsDlg').showModal(); };
  $('settingsClose').onclick = () => $('settingsDlg').close();
  $('themeSelect').onchange = () => setTheme($('themeSelect').value);
}

function switchTab(name) {
  document.querySelectorAll('.tab-btn').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('.tab-panel').forEach((p) => p.classList.toggle('active', p.id === 'tab-' + name));
}

async function setTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  await api.setSetting('theme', theme);
}

async function loadTheme() {
  const saved = (await api.getSetting('theme')) || 'system';
  setTheme(saved);
}

// ---------- 连接 / 状态 ----------
async function testConn() {
  const serverUrl = $('serverUrl').value.trim();
  try {
    const r = await api.testConnection(serverUrl);
    if (r.ok) {
      await api.setSetting('server_url', serverUrl);
      await refreshState(); await reloadSync(); await reloadSnaps();
      return;
    }
  } catch (err) {
    // 连接失败
  }
}

async function refreshState() {
  const r = await api.call('GET', '/api/state');
  if (r.ok === false) return;
  state = r;
  $('workspacePath').textContent = 'opencodeDir: ' + r.opencodeDir;
  // 档位下拉框
  const sel = $('tierSelect'); sel.innerHTML = '';
  for (const t of state.tiers.filter((t) => t.shared)) {
    const o = document.createElement('option');
    o.value = t.slug; o.textContent = `${t.index}. ${t.label}`;
    sel.appendChild(o);
  }
  // 当前档位 / 一致性
  const a = state.active;
  if (a.shared) { sel.value = a.shared; }
}

// ---------- 切换 ----------
async function applyTier() {
  const tier = $('tierSelect').value;
  if (!confirm(`将把 omo 与 omo-slim 同时切换到「${tier}」并覆盖各自生效文件，确认？`)) return;
  const r = await api.call('POST', '/api/switch', { tier });
  log($('switchLog'), r.ok ? r.log : ['切换失败: ' + (r.error?.message || JSON.stringify(r))]);
  await refreshState();
}

// ---------- 重启 ----------
async function restart() {
  log($('restartLog'), '执行中…');
  const r = await api.call('POST', '/api/restart', {});
  log($('restartLog'), r.log || ['重启失败: ' + (r.error?.message || JSON.stringify(r))]);
}

// ---------- 同步 ----------
async function reloadSync() {
  const workspace = await api.call('GET', '/api/config/items?fs=1');
  workspaceItems = workspace.items || [];
  const remote = await api.call('GET', '/api/config/items');
  remoteItems = remote.items || [];
  localItems = await api.listLocalItems();
  const dr = await api.call('POST', '/api/config/diff', { localItems });
  if (dr.ok) diff = dr.diff;
  workspaceDiff = diffItems(localItems, workspaceItems);
  const snaps = await api.call('GET', '/api/snapshots?limit=50');
  const ss = $('snapSelect'); ss.innerHTML = '<option value="">最新(head)</option>';
  (snaps.items || []).forEach((s) => {
    const o = document.createElement('option');
    o.value = s.id; o.textContent = `${new Date(s.ts).toLocaleString()} · ${s.note || s.id}`;
    ss.appendChild(o);
  });
  renderSyncTables();
}

function tagFor(key) {
  if (diff.onlyLocal.includes(key)) return '<span class="tag tag-onlyLocal">仅本地</span>';
  if (diff.onlyRemote.includes(key)) return '<span class="tag tag-onlyRemote">仅远端</span>';
  if (diff.changed.includes(key)) return '<span class="tag tag-changed">有差异</span>';
  return '';
}

function diffItems(leftItems, rightItems) {
  const left = new Map(leftItems.map((item) => [item.key, item.sha256]));
  const right = new Map(rightItems.map((item) => [item.key, item.sha256]));
  const result = { onlyLocal: [], onlyRemote: [], changed: [], same: [] };
  for (const [key, sha] of left) {
    if (!right.has(key)) result.onlyLocal.push(key);
    else if (right.get(key) !== sha) result.changed.push(key);
    else result.same.push(key);
  }
  for (const key of right.keys()) if (!left.has(key)) result.onlyRemote.push(key);
  return result;
}

function tagForDiff(key, targetDiff) {
  if (targetDiff.onlyLocal.includes(key)) return '<span class="tag tag-onlyLocal">仅 SQLite</span>';
  if (targetDiff.onlyRemote.includes(key)) return '<span class="tag tag-onlyRemote">仅目标</span>';
  if (targetDiff.changed.includes(key)) return '<span class="tag tag-changed">有差异</span>';
  return '';
}

// 档位元数据（label / 包含文件），用于把 slug 显示成可读名 + 悬浮看文件清单。
function tierMeta(slug) {
  const w = workspaceItems.find((i) => i.key === slug);
  const r = remoteItems.find((i) => i.key === slug);
  const l = localItems.find((i) => i.key === slug);
  const src = w || r || l || {};
  return {
    label: src.label || slug,        // 如 "3. 均衡 · Balanced"
    files: src.files || [],          // zip 内文件名列表
  };
}

// 只显示档位特征名（slug），并把完整 label 与所含文件放进 title 悬浮提示。
function tierCell(slug, targetDiff = diff) {
  const { label, files } = tierMeta(slug);
  const title = `${label}\n包含 ${files.length} 个文件:\n` + files.map((f) => '  · ' + f).join('\n');
  const filesBadge = files.length ? `<span class="mono" style="opacity:.6"> (${files.length}个文件)</span>` : '';
  return `<span title="${title.replace(/"/g, '&quot;')}"><b>${slug}</b>${filesBadge}</span> ${tagForDiff(slug, targetDiff)}`;
}

function renderSyncTables() {
  const wb = $('workspaceTable').querySelector('tbody'); wb.innerHTML = '';
  for (const it of workspaceItems) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input class="workspace-key" type="checkbox" data-key="${it.key}"></td>
      <td>${tierCell(it.key, workspaceDiff)}</td><td class="mono">${shortSha(it.sha256)}</td>`;
    wb.appendChild(tr);
  }
  const lb = $('localTable').querySelector('tbody'); lb.innerHTML = '';
  for (const it of localItems) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input class="local-key" type="checkbox" data-key="${it.key}"></td>
      <td>${tierCell(it.key, diff)}</td><td class="mono">${shortSha(it.sha256)}</td>`;
    lb.appendChild(tr);
  }
  const rb = $('remoteTable').querySelector('tbody'); rb.innerHTML = '';
  for (const it of remoteItems) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input class="remote-key" type="checkbox" data-key="${it.key}"></td>
      <td>${tierCell(it.key, diff)}</td><td class="mono">${shortSha(it.sha256)}</td>`;
    rb.appendChild(tr);
  }
  $('workspaceCount').textContent = workspaceItems.length + ' 项';
  $('localCount').textContent = localItems.length + ' 项';
  $('remoteCount').textContent = remoteItems.length + ' 项';
  $('diffLegend').innerHTML =
    `SQLite↔Redis：仅 SQLite ${diff.onlyLocal.length} · 仅 Redis ${diff.onlyRemote.length} · 有差异 ${diff.changed.length} · 相同 ${diff.same.length}`;
}

function selectedKeys(selector) {
  return [...new Set([...document.querySelectorAll(selector + ':checked')].map((c) => c.dataset.key))];
}

function defaultKeys(selector, items) {
  const keys = selectedKeys(selector);
  return keys.length ? keys : items.map((item) => item.key);
}

async function downloadWorkspaceToLocal() {
  const keys = defaultKeys('.workspace-key', workspaceItems);
  if (!keys.length) { alert('工作目录没有可下载的配置项'); return; }
  log($('localLog'), '从工作目录下载到 SQLite...');
  const r = await api.importLocal({ keys });
  log($('localLog'), r.ok !== false ? `已下载 ${r.imported?.length || 0} 项到 SQLite` : ('下载失败: ' + (r.error?.message || '')));
  await reloadSync();
}

async function uploadLocalToWorkspace() {
  const keys = defaultKeys('.local-key', localItems);
  if (!keys.length) { alert('SQLite 没有可上传的配置项'); return; }
  if (!confirm(`将把 SQLite 中 ${keys.length} 个档位包写回工作目录，确认？`)) return;
  log($('localLog'), '上传 SQLite 到工作目录...');
  const r = await api.exportLocal({ keys });
  const failed = r.failed?.length ? '\n失败: ' + r.failed.map((item) => `${item.key}: ${item.message}`).join('\n') : '';
  log($('localLog'), `已上传 ${r.exported?.length || 0} 项到工作目录${failed}`);
  await reloadSync(); await refreshState();
}

async function pullRedisToLocal() {
  const keys = defaultKeys('.remote-key', remoteItems);
  if (!keys.length) { alert('Redis 没有可下载的配置项'); return; }
  const snap = $('snapSelect').value;
  log($('localLog'), '从 Redis 下载到 SQLite...');
  const r = await api.pull({ keys, snapshot: snap || undefined });
  log($('localLog'), r.ok !== false ? `已从 Redis 下载 ${r.pulled?.length || 0} 项到 SQLite` : ('下载失败: ' + (r.error?.message || '')));
  await reloadSync();
}

async function pushLocalToRedis() {
  const keys = defaultKeys('.local-key', localItems);
  if (!keys.length) { alert('SQLite 没有可上传的配置项'); return; }
  if (!confirm(`将在 Redis 生成新快照，包含 SQLite 中 ${keys.length} 个档位包，确认？`)) return;
  log($('localLog'), '上传 SQLite 到 Redis...');
  const scope = keys.length === localItems.length ? 'all' : 'selected';
  const r = await api.push({ keys, note: `client ${scope} push` });
  log($('localLog'), r.ok !== false ? `已上传到 Redis: ${r.snapshotId}` : ('上传失败: ' + (r.error?.message || '')));
  await reloadSync(); await reloadSnaps();
}

// ---------- 历史版本 ----------
async function reloadSnaps() {
  const r = await api.call('GET', '/api/snapshots?limit=50');
  const tb = $('snapTable').querySelector('tbody'); tb.innerHTML = '';
  (r.items || []).forEach((s) => {
    const isHead = s.id === r.head;
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${new Date(s.ts).toLocaleString()}</td>
      <td class="mono">${s.id}${isHead ? ' ★' : ''}</td>
      <td>${s.note || ''}</td><td>${s.keys?.length ?? '?'}</td>
      <td><button class="secondary" data-act="view" data-id="${s.id}">查看</button>
          <button class="danger" data-act="rb" data-id="${s.id}">整体回滚</button></td>`;
    tb.appendChild(tr);
  });
  tb.querySelectorAll('button').forEach((b) => {
    b.onclick = () => (b.dataset.act === 'view' ? viewSnap(b.dataset.id) : rollbackAll(b.dataset.id));
  });
}

async function viewSnap(id) {
  const r = await api.call('GET', '/api/snapshots/' + encodeURIComponent(id));
  if (r.ok === false) return;
  const rows = (r.items || []).map(
    (it) => `<tr><td>${it.key}</td><td class="mono">${shortSha(it.sha256)}</td>
      <td><button class="secondary" data-id="${id}" data-key="${it.key}">单文件回滚</button></td></tr>`
  ).join('');
  $('snapDetail').innerHTML =
    `<h3>快照 ${id}</h3><table><thead><tr><th>文件</th><th>sha</th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
  $('snapDetail').querySelectorAll('button').forEach((b) => {
    b.onclick = () => rollbackFile(b.dataset.id, b.dataset.key);
  });
}

async function rollbackAll(id) {
  if (!confirm(`整体回滚到快照 ${id}？将生成一个新快照并设为最新。`)) return;
  const r = await api.call('POST', `/api/snapshots/${encodeURIComponent(id)}/rollback`, {});
  alert(r.ok !== false ? '回滚完成: ' + r.snapshotId : '回滚失败');
  await reloadSnaps(); await reloadSync();
}
async function rollbackFile(id, key) {
  if (!confirm(`从快照 ${id} 回滚单文件 ${key}？`)) return;
  const r = await api.call('POST', `/api/snapshots/${encodeURIComponent(id)}/rollback-file`, { key });
  alert(r.ok !== false ? '单文件回滚完成: ' + r.snapshotId : '回滚失败');
  await reloadSnaps(); await reloadSync();
}

if (!window.__OMO_SWITCHER_TEST__) boot();
