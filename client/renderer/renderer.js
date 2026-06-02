// 渲染层逻辑：仅通过 window.api（preload 暴露）与主进程/服务端交互。
const $ = (id) => document.getElementById(id);
// 注意：preload 通过 contextBridge 暴露的 window.api 已是全局名 `api`，
// 不能再 `const api = ...`（会触发 "Identifier 'api' has already been declared"）。
// 下方代码直接引用全局 `api`。

let state = null;          // /api/state
let remoteItems = [];      // 远端配置项清单
let localItems = [];       // 本地 SQLite 配置项
let diff = { onlyLocal: [], onlyRemote: [], changed: [], same: [] };

function log(el, lines) {
  el.textContent = Array.isArray(lines) ? lines.join('\n') : String(lines);
}
function shortSha(s) { return s ? s.slice(0, 8) : '—'; }

// ---------- 启动 ----------
async function boot() {
  console.log('[boot] renderer start, api=' + (typeof api));
  $('serverUrl').value = (await api.getSetting('server_url')) || '';
  bindEvents();
  console.log('[boot] events bound');
  await refreshState();
  await reloadSync();
  await reloadSnaps();
  console.log('[boot] done, connected');
}

function bindEvents() {
  $('saveUrl').onclick = async () => {
    await api.setSetting('server_url', $('serverUrl').value.trim());
    await refreshState(); await reloadSync(); await reloadSnaps();
  };
  $('testConn').onclick = testConn;
  $('applyTier').onclick = applyTier;
  $('restartBtn').onclick = restart;
  $('reloadSync').onclick = reloadSync;
  $('importLocal').onclick = importLocal;
  $('selectAll').onchange = (e) => {
    document.querySelectorAll('#localTable input[type=checkbox]').forEach((c) => (c.checked = e.target.checked));
  };
  $('syncBtn').onclick = openSyncConfirm;
  $('reloadSnaps').onclick = reloadSnaps;
  $('confirmCancel').onclick = () => $('confirmDlg').close();
}

// ---------- 连接 / 状态 ----------
async function testConn() {
  const r = await api.call('GET', '/api/health');
  if (r.ok) {
    $('conn').className = 'pill pill-ok'; $('conn').textContent = '已连接';
    $('store').textContent = 'store: ' + r.storeMode;
  } else {
    $('conn').className = 'pill pill-bad'; $('conn').textContent = '连接失败';
  }
}

async function refreshState() {
  const r = await api.call('GET', '/api/state');
  if (r.ok === false) { $('conn').className = 'pill pill-bad'; $('conn').textContent = '连接失败'; return; }
  state = r;
  $('conn').className = 'pill pill-ok'; $('conn').textContent = '已连接';
  // 档位下拉框
  const sel = $('tierSelect'); sel.innerHTML = '';
  for (const t of state.tiers.filter((t) => t.shared)) {
    const o = document.createElement('option');
    o.value = t.slug; o.textContent = `${t.index}. ${t.label}`;
    sel.appendChild(o);
  }
  // 当前档位 / 一致性
  const a = state.active;
  if (a.shared) { sel.value = a.shared; $('activeTier').textContent = '当前档位: ' + a.shared; $('activeWarn').classList.add('hidden'); }
  else {
    $('activeTier').textContent = '当前档位: 不一致';
    $('activeWarn').classList.remove('hidden');
    $('activeWarn').textContent = `omo=${a.omo || '?'} / slim=${a['omo-slim'] || '?'}`;
  }
  await api.getSetting('store'); // noop keep
  const h = await api.call('GET', '/api/health'); if (h.ok) $('store').textContent = 'store: ' + h.storeMode;
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
  const cwd = $('restartCwd').value.trim() || undefined;
  log($('restartLog'), '执行中…');
  const r = await api.call('POST', '/api/restart', { cwd });
  log($('restartLog'), r.log || ['重启失败: ' + (r.error?.message || JSON.stringify(r))]);
}

// ---------- 同步 ----------
async function reloadSync() {
  // 远端清单
  const remote = await api.call('GET', '/api/config/items');
  remoteItems = remote.items || [];
  // 本地清单
  localItems = await api.listLocalItems();
  // diff（按 sha）
  const dr = await api.call('POST', '/api/config/diff', { localItems });
  if (dr.ok) diff = dr.diff;
  // 快照下拉
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

function renderSyncTables() {
  const lb = $('localTable').querySelector('tbody'); lb.innerHTML = '';
  for (const it of localItems) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input type="checkbox" data-key="${it.key}"></td>
      <td>${it.key} ${tagFor(it.key)}</td><td class="mono">${shortSha(it.sha256)}</td>`;
    lb.appendChild(tr);
  }
  const rb = $('remoteTable').querySelector('tbody'); rb.innerHTML = '';
  for (const it of remoteItems) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${it.key} ${tagFor(it.key)}</td><td class="mono">${shortSha(it.sha256)}</td>`;
    rb.appendChild(tr);
  }
  $('diffLegend').innerHTML =
    `差异：仅本地 ${diff.onlyLocal.length} · 仅远端 ${diff.onlyRemote.length} · 有差异 ${diff.changed.length} · 相同 ${diff.same.length}`;
}

function selectedKeys() {
  return [...document.querySelectorAll('#localTable input[type=checkbox]:checked')].map((c) => c.dataset.key);
}
function direction() {
  return document.querySelector('input[name=dir]:checked').value;
}

async function importLocal() {
  const r = await api.importLocal();
  alert('已从本机导入 ' + (r.imported?.length || 0) + ' 项到本地 SQLite');
  await reloadSync();
}

function openSyncConfirm() {
  const keys = selectedKeys();
  if (!keys.length) { alert('请先勾选要同步的配置项'); return; }
  const dir = direction();
  const snap = $('snapSelect').value;
  const scope = keys.length === localItems.length ? '全部' : '单项';
  const body = [
    `方向：${dir === 'pull' ? '拉取 远端→本地' : '推送 本地→远端'}`,
    `范围：${scope}（${keys.length} 项）`,
    dir === 'pull' && snap ? `远端版本：${snap}` : '',
    '',
    '将处理以下文件：',
    ...keys.map((k) => '  · ' + k + ' ' + (diff.changed.includes(k) ? '(覆盖)' : '')),
    '',
    dir === 'pull' ? '注意：本地“当前档位/服务器地址”不会被改动。' : '将在远端生成一个新的时间戳快照。',
  ].filter((x) => x !== null);
  log($('confirmBody'), body);
  $('confirmOk').onclick = async () => {
    $('confirmDlg').close();
    let r;
    if (dir === 'pull') r = await api.pull({ keys, snapshot: snap || undefined });
    else r = await api.push({ keys, note: `client ${scope} push` });
    alert(r.ok !== false ? '同步完成' : ('同步失败: ' + (r.error?.message || '')));
    await reloadSync(); await reloadSnaps();
  };
  $('confirmDlg').showModal();
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

boot();
