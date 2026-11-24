import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import portraits from './portraits.generated.json'
import themeLyricsText from '../../Resources/ThemeLyrics.txt'
import { createActivitySource, labels, presentation, selectMainSession } from './session.js'
import { CompanionPanel } from './companion-panel.jsx'
import { dayKey, normalizeProgress, recordProgress } from './companion.js'
import styles from './pet.css'

const modes = { duo: '双人', hua: '花旦', sheng: '小生' }
const defaults = {
  mode: 'duo', selected: { duo: 'D09', hua: 'H08', sheng: 'S03' },
  collapsed: false, hidden: false, petals: true, statusPoses: true,
  idleTalk: false, roam: false, size: 'normal', position: null,
}
const storageKey = 'huayao-harness-pet.preferences.v1'
const progressKey = 'huayao-harness-pet.companion.v1'
const sizes = { small: '小', normal: '中', large: '大' }
const stagePoses = {
  duo: { thinking: 'D02', reading: 'D03', writing: 'D13', searching: 'D10', working: 'D10', waiting: 'D11', done: 'D01', error: 'D16' },
  hua: { thinking: 'H02', reading: 'H04', writing: 'H03', searching: 'H07', working: 'H04', waiting: 'H09', done: 'H12', error: 'H06' },
  sheng: { thinking: 'S02', reading: 'S04', writing: 'S03', searching: 'S02', working: 'S03', waiting: 'S04', done: 'S01', error: 'S02' },
}
const reactions = {
  waiting: '那边等你点头呢。',
  done: '这一轮忙完了，歇一歇罢。',
  error: '这折先停一停，回会话看看。',
  cancelled: '且收了这一折。',
  tea: '承你这一盏茶。',
  visits: '今日又在花台见面了。',
}
const allPoses = Object.values(portraits).flat()
const clamp = value => Math.max(0, Math.min(1, value))
const homePosition = { x: 1, y: 1 }
const themeLyrics = themeLyricsText.trim().split(/\r?\n/).filter(Boolean)
const greetings = {
  duo: ['今日台子搭好了，你且坐。', '你看，水袖一拂，花就落了。', '这回的身段，可合你的眼？'],
  hua: ['且坐片刻，容我理一理水袖。', '这一袖风，替你把花吹过来。', '看官，你瞧见刚才落的花了吗？'],
  sheng: ['台前灯亮了，我把折扇备好。', '折扇一展，且听这一声锣。', '这位看官，且慢走。'],
}
const petalOffsets = [
  { left: '9%', delay: '-2s', duration: '6.6s' },
  { left: '25%', delay: '-5s', duration: '7.5s' },
  { left: '50%', delay: '-3s', duration: '8.4s' },
  { left: '67%', delay: '-6s', duration: '6.9s' },
  { left: '84%', delay: '-2s', duration: '8.1s' },
]

function normalizePreferences(saved) {
  const position = saved?.position
  return {
    mode: Object.hasOwn(modes, saved?.mode) ? saved.mode : defaults.mode,
    selected: Object.fromEntries(Object.keys(modes).map(mode => [
      mode, portraits[mode].find(pose => pose.id === saved?.selected?.[mode])?.id ?? defaults.selected[mode],
    ])),
    collapsed: saved?.collapsed === true,
    hidden: saved?.hidden === true,
    petals: saved?.petals !== false,
    statusPoses: saved?.statusPoses !== false,
    idleTalk: saved?.idleTalk === true,
    roam: saved?.roam === true,
    size: Object.hasOwn(sizes, saved?.size) ? saved.size : defaults.size,
    position: Number.isFinite(position?.x) && Number.isFinite(position?.y)
      ? { x: clamp(position.x), y: clamp(position.y) } : null,
  }
}

function useLocalState(key, normalize) {
  const [value, setValue] = useState(() => {
    try {
      return normalize(JSON.parse(localStorage.getItem(key)))
    } catch {
      return normalize(null)
    }
  })
  useEffect(() => {
    try {
      localStorage.setItem(key, JSON.stringify(value))
    } catch {
      // The current session remains usable when storage is unavailable.
    }
  }, [key, value])
  return [value, setValue]
}

function positionStyle(position) {
  return {
    insetInlineEnd: 'auto', bottom: 'auto',
    left: `calc(${position.x * 100}% + ${8 - 16 * position.x}px)`,
    top: `calc(${position.y * 100}% + ${8 - 16 * position.y}px)`,
    transform: `translate(${-position.x * 100}%, ${-position.y * 100}%)`,
  }
}

function PortraitPicker({ mode, selected, selectMode, selectPose }) {
  return (
    <div aria-label="选择立绘">
      <div className="huayao-desktop__tabs" aria-label="角色模式">
        {Object.entries(modes).map(([id, name]) => (
          <button type="button" key={id} aria-pressed={id === mode} onClick={() => selectMode(id)}>
            {name} <span>{portraits[id].length}</span>
          </button>
        ))}
      </div>
      <div className="huayao-desktop__poses" aria-label={`${modes[mode]}立绘`}>
        {portraits[mode].map(pose => (
          <button
            className="huayao-desktop__pose"
            type="button" key={pose.id} aria-pressed={pose.id === selected}
            onClick={() => selectPose(pose.id)}
          >
            <img src={pose.src} alt="" loading="lazy" />
            <span>{pose.title}</span>
          </button>
        ))}
      </div>
    </div>
  )
}

function Pet({ useSessions, useSessionStatus, sessionBinding }) {
  const sessionId = useSessions(selectMainSession)
  const running = useSessionStatus(snapshot => snapshot.get(sessionId)?.running === true)
  const waiting = useSessionStatus(snapshot => Boolean(snapshot.get(sessionId)?.pendingInteraction))
  const eventSource = sessionBinding(sessionId)?.eventSource
  const activitySource = useMemo(() => createActivitySource(eventSource), [eventSource])
  const activity = useSyncExternalStore(activitySource.subscribe, activitySource.getSnapshot)
  const state = presentation(sessionId, running, waiting, activity)
  const busy = running || waiting

  const [prefs, setPrefs] = useLocalState(storageKey, normalizePreferences)
  const [savedProgress, setProgress] = useLocalState(progressKey, normalizeProgress)
  const [clock, setClock] = useState(dayKey)
  const [panel, setPanel] = useState(null)
  const [speech, setSpeech] = useState('')
  const [hop, setHop] = useState(0)
  const [temporaryPosition, setTemporaryPosition] = useState(null)
  const [moving, setMoving] = useState(false)
  const [feedback, setFeedback] = useState('')
  const petRef = useRef(null)
  const drag = useRef(null)
  const suppressClick = useRef(false)
  const speechTimer = useRef()
  const importInput = useRef(null)
  const [openedAt] = useState(Date.now)
  const heardTurns = useRef(new Set())

  const progress = useMemo(() => normalizeProgress(savedProgress, new Date(`${clock}T12:00:00`)), [savedProgress, clock])
  const poseList = portraits[prefs.mode]
  const selectedPose = poseList.find(item => item.id === prefs.selected[prefs.mode]) ?? poseList[0]
  const intent = state === 'working' && activity.intent ? activity.intent : state
  const linkedPose = prefs.statusPoses && stagePoses[prefs.mode][intent]
  const pose = (linkedPose && poseList.find(item => item.id === linkedPose)) || selectedPose
  const detail = state === 'working' ? activity.tool : ''
  const status = detail ? `${labels[state]} · ${detail}` : labels[state]
  const notice = !busy || waiting ? reactions[state] : ''
  const position = temporaryPosition ?? prefs.position ?? homePosition

  function record(action) {
    const now = new Date()
    setClock(dayKey(now))
    setProgress(previous => recordProgress(previous, action, now))
  }

  useEffect(() => {
    const terminal = activity.terminal
    if (terminal?.state !== 'done' || terminal.time < openedAt || !sessionId) return
    const key = `${sessionId}:${terminal.time}:${terminal.sequence ?? ''}`
    if (heardTurns.current.has(key)) return
    heardTurns.current.add(key)
    if (heardTurns.current.size > 128) heardTurns.current.delete(heardTurns.current.values().next().value)
    const now = new Date()
    setClock(dayKey(now))
    setProgress(previous => recordProgress(previous, 'turn', now))
  }, [sessionId, activity.terminal, openedAt, setProgress])

  useEffect(() => {
    const timer = setInterval(() => setClock(dayKey()), 30_000)
    return () => {
      clearInterval(timer)
      clearTimeout(speechTimer.current)
    }
  }, [])

  useEffect(() => {
    if (busy || prefs.collapsed || prefs.hidden || panel || moving || (!prefs.idleTalk && !prefs.roam)) return
    const roamTimer = prefs.roam ? setInterval(() => {
      if (!document.hidden && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
        setTemporaryPosition({ x: Math.random(), y: 0.75 + Math.random() * 0.25 })
      }
    }, 45_000) : undefined
    const talkTimer = prefs.idleTalk ? setInterval(() => {
      const hour = new Date().getHours()
      if (document.hidden || hour < 6 || hour >= 23) return
      const lines = greetings[prefs.mode]
      setSpeech(lines[Math.floor(Math.random() * lines.length)])
      clearTimeout(speechTimer.current)
      speechTimer.current = setTimeout(() => setSpeech(''), 3600)
    }, 5 * 60_000) : undefined
    return () => {
      clearInterval(roamTimer)
      clearInterval(talkTimer)
    }
  }, [busy, moving, panel, prefs.collapsed, prefs.hidden, prefs.idleTalk, prefs.mode, prefs.roam])

  function setPreference(key, value) {
    setPrefs(previous => ({ ...previous, [key]: value }))
  }

  function tell(line) {
    setSpeech(line)
    setHop(value => value + 1)
    clearTimeout(speechTimer.current)
    speechTimer.current = setTimeout(() => setSpeech(''), 3600)
  }

  function speak(event) {
    if (event.detail > 0 && suppressClick.current) return
    record('pat')
    if (busy) return
    const lines = themeLyrics.length && Math.random() < 0.25 ? themeLyrics : greetings[prefs.mode]
    const choices = lines.filter(line => line !== speech)
    tell(choices[Math.floor(Math.random() * choices.length)] ?? lines[0])
  }

  function interact(action) {
    record(action)
    if (!busy && reactions[action]) tell(reactions[action])
  }

  function moveHome() {
    setTemporaryPosition(null)
    setPreference('position', null)
  }

  function pointerDown(event) {
    if (event.button !== 0 || !event.isPrimary) return
    suppressClick.current = false
    const pet = petRef.current
    const frame = pet.offsetParent?.getBoundingClientRect()
    if (!frame) return
    const rect = pet.getBoundingClientRect()
    drag.current = { id: event.pointerId, x: event.clientX, y: event.clientY, frame, rect, position: null }
    event.currentTarget.setPointerCapture(event.pointerId)
  }

  function pointerMove(event) {
    const start = drag.current
    if (start?.id !== event.pointerId) return
    const dx = event.clientX - start.x
    const dy = event.clientY - start.y
    if (!start.position && Math.hypot(dx, dy) < 6) return
    if (!start.position) {
      setMoving(true)
      setPanel(null)
    }
    const availableX = Math.max(1, start.frame.width - start.rect.width - 16)
    const availableY = Math.max(1, start.frame.height - start.rect.height - 16)
    start.position = {
      x: clamp((start.rect.left + dx - start.frame.left - 8) / availableX),
      y: clamp((start.rect.top + dy - start.frame.top - 8) / availableY),
    }
    setTemporaryPosition(start.position)
  }

  function finishDrag(event, cancelled = false) {
    const start = drag.current
    if (start?.id !== event.pointerId) return
    drag.current = null
    if (!start.position) return
    suppressClick.current = true
    if (!cancelled) setPreference('position', start.position)
    setTemporaryPosition(null)
    setMoving(false)
  }

  function moveByKey(event) {
    const steps = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }
    const step = steps[event.key]
    if (!step) return
    event.preventDefault()
    const distance = event.shiftKey ? 0.2 : 0.05
    setTemporaryPosition(null)
    setPanel(null)
    setPreference('position', { x: clamp(position.x + step[0] * distance), y: clamp(position.y + step[1] * distance) })
  }

  function toggleCollapse() {
    setPreference('collapsed', !prefs.collapsed)
    setPanel(null)
    setSpeech('')
    setTemporaryPosition(null)
  }

  function setHidden(hidden) {
    setPreference('hidden', hidden)
    setTemporaryPosition(null)
    setPanel(null)
    setSpeech('')
  }

  function backup() {
    const data = JSON.stringify({ format: 'huayao-pet', version: 1, preferences: prefs, companion: progress })
    const url = URL.createObjectURL(new Blob([data], { type: 'application/json' }))
    const link = document.createElement('a')
    link.href = url
    link.download = `花妖桌宠存档-${dayKey()}.json`
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  }

  async function restore(event) {
    const file = event.currentTarget.files?.[0]
    event.currentTarget.value = ''
    if (!file) return
    try {
      if (file.size > 64 * 1024) throw new Error()
      const data = JSON.parse(await file.text())
      const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value)
      if (data?.format !== 'huayao-pet' || data.version !== 1
        || !isObject(data.preferences) || !isObject(data.companion)) throw new Error()
      setPrefs({ ...normalizePreferences(data.preferences), hidden: false, collapsed: false })
      setProgress(normalizeProgress(data.companion))
      setClock(dayKey())
      setTemporaryPosition(null)
      setFeedback('已导入花妖桌宠存档。')
    } catch {
      setFeedback('无法导入，请选择花妖桌宠导出的 JSON 存档。')
    }
  }

  const dragHandlers = {
    onPointerDown: pointerDown, onPointerMove: pointerMove,
    onPointerUp: event => finishDrag(event), onPointerCancel: event => finishDrag(event, true),
    onLostPointerCapture: event => finishDrag(event, true), onKeyDown: moveByKey,
  }

  return (
    <aside
      ref={petRef}
      className="huayao-desktop"
      aria-label="花妖桌宠"
      data-size={prefs.size}
      data-moving={moving || undefined}
      data-roaming={Boolean(temporaryPosition && !moving) || undefined}
      data-anchor-x={position.x < 0.5 ? 'left' : 'right'}
      data-anchor-y={position.y < 0.5 ? 'top' : 'bottom'}
      style={{
        '--hy-panel-share': Math.max(position.y, 1 - position.y),
        ...(!prefs.hidden && (temporaryPosition || prefs.position) ? positionStyle(position) : {}),
      }}
    >
      <style>{styles}</style>
      {prefs.hidden ? (
        <button type="button" className="huayao-desktop__badge" onClick={() => setHidden(false)}>唤回花妖</button>
      ) : prefs.collapsed ? (
        <button type="button" className="huayao-desktop__badge huayao-desktop__draggable" {...dragHandlers}
          onClick={event => { if (event.detail === 0 || !suppressClick.current) toggleCollapse() }} aria-label="展开花妖桌宠">
          <span className="huayao-desktop__dot" data-state={state} aria-hidden="true" />
          花妖 <span className="huayao-desktop__compact-status">{labels[state]}</span>
        </button>
      ) : (
        <>
          {panel && (
            <section className="huayao-desktop__picker" aria-label="花妖设置"
              onKeyDown={event => { if (event.key === 'Escape') { event.stopPropagation(); setPanel(null) } }}>
              <div className="huayao-desktop__tabs" aria-label="桌宠面板">
                {Object.entries({ portrait: '立绘', companion: '陪伴', settings: '设置' }).map(([id, label]) => (
                  <button type="button" key={id} aria-pressed={panel === id} onClick={() => setPanel(id)}>{label}</button>
                ))}
              </div>
              {panel === 'portrait' && <PortraitPicker mode={prefs.mode} selected={selectedPose.id}
                selectMode={mode => { setPreference('mode', mode); setSpeech('') }}
                selectPose={id => {
                  setPrefs(previous => ({ ...previous, selected: { ...previous.selected, [previous.mode]: id } }))
                  setSpeech('')
                  setPanel(null)
                }} />}
              {panel === 'companion' && <CompanionPanel progress={progress} interact={interact} poses={allPoses} />}
              {panel === 'settings' && (
                <div className="huayao-desktop__settings">
                  <label>尺寸 <select value={prefs.size} onChange={event => setPreference('size', event.target.value)}>
                    {Object.entries(sizes).map(([id, name]) => <option key={id} value={id}>{name}</option>)}
                  </select></label>
                  {Object.entries({ petals: '花瓣飘落', statusPoses: '跟随工作状态换姿', idleTalk: '待机闲聊', roam: '待机巡场' }).map(([id, name]) => (
                    <label className="huayao-desktop__toggle" key={id}>
                      <input type="checkbox" checked={prefs[id]} onChange={event => {
                        setPreference(id, event.target.checked)
                        if (id === 'roam' && !event.target.checked) setTemporaryPosition(null)
                      }} /> {name}
                    </label>
                  ))}
                  <div className="huayao-desktop__quick">
                    <button type="button" onClick={moveHome}>回到右下角</button>
                    <button type="button" onClick={() => setHidden(true)}>隐藏桌宠</button>
                    <button type="button" onClick={backup}>导出存档</button>
                    <button type="button" onClick={() => importInput.current?.click()}>导入存档</button>
                  </div>
                  <input type="file" accept=".json,application/json" ref={importInput} hidden onChange={restore} />
                  {feedback && <p role="status">{feedback}</p>}
                </div>
              )}
            </section>
          )}
          <div className="huayao-desktop__stage" data-mode={prefs.mode} data-state={state}>
            {prefs.petals && !busy && (
              <div className="huayao-desktop__petals" aria-hidden="true">
                {petalOffsets.map(petal => (
                  <i key={petal.left} style={{
                    left: petal.left, animationDelay: petal.delay, animationDuration: petal.duration,
                  }} />
                ))}
              </div>
            )}
            <div className="huayao-desktop__actions">
              <button type="button" onClick={() => setPanel(previous => previous === 'portrait' ? null : 'portrait')}
                aria-expanded={panel === 'portrait'}>立绘</button>
              <button type="button" onClick={() => setPanel(previous => previous === 'companion' ? null : 'companion')}
                aria-expanded={panel === 'companion'}>陪伴</button>
              <button type="button" onClick={() => setPanel(previous => previous === 'settings' ? null : 'settings')}
                aria-expanded={panel === 'settings'}>设置</button>
              <button type="button" onClick={toggleCollapse} aria-label="收起花妖桌宠">收起</button>
            </div>
            {((speech && !busy) || notice) && (
              <div className="huayao-desktop__speech">{(!busy && speech) || notice}</div>
            )}
            <button className="huayao-desktop__actor huayao-desktop__draggable" type="button"
              {...dragHandlers} aria-label={`${pose.title}，点击互动`} title="点击互动，拖动或用方向键移动" onClick={speak}>
              <img key={`${pose.id}-${hop}`} src={pose.src} alt="" draggable="false" data-hop={hop > 0 && !busy ? '' : undefined} />
            </button>
          </div>
          <div className="huayao-desktop__status" role="status" aria-live="polite">
            <span className="huayao-desktop__dot" data-state={state} aria-hidden="true" />
            {status}
          </div>
        </>
      )}
    </aside>
  )
}

export const inject = ['slots', 'sessions']

export function apply(ctx) {
  const sessionBinding = id => id ? ctx.sessions.binding(id) : undefined
  ctx.slots.inject('shell.overlay', () => ctx.slots.register({
    name: 'shell.overlay',
    id: 'huayao-harness-pet',
    order: 25,
    inject: () => ({ sessionBinding }),
  }, Pet))
}
