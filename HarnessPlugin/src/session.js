const toolLabels = {
  read: '在翻文件',
  read_file: '在翻文件',
  write: '在写字',
  write_file: '在写字',
  edit: '在改稿子',
  edit_file: '在改稿子',
  bash: '在跑命令',
  exec_command: '在跑命令',
  glob: '在找文件',
  grep: '在查字句',
  web_search: '在查资料',
  web_fetch: '在看网页',
  subagent: '在请人帮忙',
}

export const labels = {
  none: '暂无会话',
  idle: '空闲',
  thinking: '思考中',
  working: '干活中',
  waiting: '待确认',
  done: '完成',
  error: '出错',
  cancelled: '已中止',
}

const emptyActivity = Object.freeze({ tool: '', intent: '', terminal: null })
const toolIntent = {
  read: 'reading', read_file: 'reading', glob: 'reading', grep: 'reading',
  write: 'writing', write_file: 'writing', edit: 'writing', edit_file: 'writing',
  web_search: 'searching', web_fetch: 'searching',
}
const settleTime = 14000

export const emptySource = {
  subscribe: () => () => {},
  getSnapshot: () => emptyActivity,
}

export function selectMainSession({ byId }) {
  return Object.values(byId).find(session => (session.retainedBy?.mainView ?? 0) > 0)?.id
}

export function createActivitySource(eventSource) {
  if (!eventSource) return emptySource
  const tools = new Map()
  let terminal = null
  let snapshot = emptyActivity
  let revision
  let timer

  function reduce({ event, type }) {
    if (type !== 'event') return
    const data = event.data ?? {}
    switch (event.type) {
      case 'turn/start':
        tools.clear()
        terminal = null
        break
      case 'tool/call':
        if (data.callId) {
          const key = typeof data.name === 'string' ? data.name.toLowerCase() : ''
          tools.set(data.callId, {
            label: Object.hasOwn(toolLabels, key) ? toolLabels[key] : '在调用工具',
            intent: Object.hasOwn(toolIntent, key) ? toolIntent[key] : '',
          })
        }
        break
      case 'tool/result':
        tools.delete(data.message?.toolCallId)
        break
      case 'turn/end': {
        tools.clear()
        const kind = data.reason?.kind
        const state = kind === 'error' ? 'error' : ['aborted', 'cancelled'].includes(kind) ? 'cancelled' : 'done'
        terminal = { state, time: event.time, sequence: event.seq }
        break
      }
    }
  }

  function update() {
    const window = eventSource.getSnapshot()
    if (window.revision !== revision) {
      if (revision + 1 === window.revision && window.change.kind === 'append') {
        window.change.entries.forEach(reduce)
      } else if (revision + 1 !== window.revision || ['replace', 'prepend'].includes(window.change.kind)) {
        tools.clear()
        terminal = null
        window.entries.forEach(reduce)
      }
      revision = window.revision
    }
    const call = Array.from(tools.values()).at(-1)
    const tool = call?.label ?? ''
    const intent = call?.intent ?? ''
    const recent = terminal && Date.now() - terminal.time < settleTime ? terminal : null
    if (tool !== snapshot.tool || intent !== snapshot.intent || recent !== snapshot.terminal) snapshot = { tool, intent, terminal: recent }
    return snapshot
  }

  return {
    getSnapshot: update,
    subscribe(listener) {
      function publish() {
        clearTimeout(timer)
        const previous = snapshot
        const current = update()
        if (current.terminal) {
          timer = setTimeout(publish, Math.max(1, current.terminal.time + settleTime - Date.now()))
        }
        if (previous !== current) listener()
      }
      const dispose = eventSource.subscribe(publish)
      publish()
      return () => {
        clearTimeout(timer)
        dispose()
      }
    },
  }
}

export function presentation(sessionId, running, waiting, activity) {
  if (!sessionId) return 'none'
  if (waiting) return 'waiting'
  if (running) return activity.tool ? 'working' : 'thinking'
  return activity.terminal?.state ?? 'idle'
}
