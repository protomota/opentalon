const { contextBridge, ipcRenderer } = require('electron')
const commandCallbacks = new Set()
const pendingCommands = []
ipcRenderer.on('opentalon:command', (_event, command) => {
  if (!commandCallbacks.size) pendingCommands.push(command)
  else for (const callback of commandCallbacks) callback(command)
})
function subscribe(channel, callback) {
  const listener = (_event, value) => callback(value)
  ipcRenderer.on(channel, listener)
  return () => ipcRenderer.removeListener(channel, listener)
}
contextBridge.exposeInMainWorld('opentalon', {
  platform: process.platform,
  action: (name, input = {}) => ipcRenderer.invoke('opentalon:action', name, input),
  onCommand: (callback) => {
    commandCallbacks.add(callback)
    for (const command of pendingCommands.splice(0)) callback(command)
    return () => commandCallbacks.delete(callback)
  },
  onChanged: (callback) => subscribe('opentalon:changed', callback),
})
