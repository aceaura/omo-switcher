// 通过 contextBridge 暴露白名单 API 给渲染层。渲染层不接触 node/electron 内部。
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('api', {
  // 设置
  settingsAll: () => ipcRenderer.invoke('settings:all'),
  getSetting: (k) => ipcRenderer.invoke('settings:get', k),
  setSetting: (k, v) => ipcRenderer.invoke('settings:set', k, v),

  // 服务端 REST 透传
  call: (method, path, body) => ipcRenderer.invoke('api:call', method, path, body),
  testConnection: (serverUrl) => ipcRenderer.invoke('api:testConnection', serverUrl),

  // 本地 SQLite
  listLocalItems: () => ipcRenderer.invoke('db:listItems'),
  getLocalItem: (k) => ipcRenderer.invoke('db:getItem', k),
  recentSync: (n) => ipcRenderer.invoke('db:recentSync', n),

  // 高层同步
  pull: (opts) => ipcRenderer.invoke('sync:pull', opts),
  push: (opts) => ipcRenderer.invoke('sync:push', opts),
  importLocal: (opts) => ipcRenderer.invoke('local:importFromServer', opts),
  exportLocal: (opts) => ipcRenderer.invoke('local:exportToServer', opts),
});
