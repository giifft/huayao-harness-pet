import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import portraits from './portraits.generated.json'
import { createActivitySource, labels, presentation, selectMainSession } from './session.js'
import styles from './pet.css'

const modes = { duo: '双人', hua: '花旦', sheng: '小生' }
const defaults = {
  mode: 'duo', selected: { duo: 'D09', hua: 'H08', sheng: 'S03' },
  collapsed: false, petals: true,
}
const storageKey = 'huayao-harness-pet.preferences.v1'
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

function readPreferences() {
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey))
    if (!saved) return defaults
    return {
      mode: Object.hasOwn(modes, saved.mode) ? saved.mode : defaults.mode,
      selected: { ...defaults.selected, ...saved.selected },
      collapsed: saved.collapsed === true,
      petals: saved.petals !== false,
    }
  } catch {
    return defaults
  }
}

function usePreferences() {
  const [preferences, setPreferences] = useState(readPreferences)
  useEffect(() => {
    try {
      localStorage.setItem(storageKey, JSON.stringify(preferences))
    } catch {
      // The pet stays usable when this profile disables browser storage.
    }
  }, [preferences])
  return [preferences, setPreferences]
}

function PortraitPicker({ mode, selected, petals, selectMode, selectPose, togglePetals }) {
  return (
    <section className="huayao-desktop__picker" aria-label="选择立绘">
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
      <label className="huayao-desktop__toggle">
        <input type="checkbox" checked={petals} onChange={togglePetals} /> 花瓣飘落
      </label>
    </section>
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

  const [prefs, setPrefs] = usePreferences()
  const [pickerOpen, setPickerOpen] = useState(false)
  const [speech, setSpeech] = useState('')
  const [hop, setHop] = useState(0)
  const speechTimer = useRef()
  useEffect(() => () => clearTimeout(speechTimer.current), [])

  const poseList = portraits[prefs.mode]
  const pose = poseList.find(item => item.id === prefs.selected[prefs.mode])
    ?? poseList.find(item => item.id === defaults.selected[prefs.mode]) ?? poseList[0]
  const detail = state === 'working' ? activity.tool : ''
  const status = detail ? `${labels[state]} · ${detail}` : labels[state]
  const notice = state === 'waiting' ? '那边等你点头呢。' : state === 'done' ? '这一轮忙完了，歇一歇罢。' : ''

  function selectMode(mode) {
    setPrefs(previous => ({ ...previous, mode }))
    setSpeech('')
  }

  function selectPose(id) {
    setPrefs(previous => ({
      ...previous, selected: { ...previous.selected, [previous.mode]: id },
    }))
    setSpeech('')
    setPickerOpen(false)
  }

  function speak() {
    const lines = greetings[prefs.mode]
    setSpeech(previous => {
      const options = lines.filter(line => line !== previous)
      return options[Math.floor(Math.random() * options.length)]
    })
    setHop(previous => previous + 1)
    clearTimeout(speechTimer.current)
    speechTimer.current = setTimeout(() => setSpeech(''), 3600)
  }

  function collapse() {
    setPrefs(previous => ({ ...previous, collapsed: !previous.collapsed }))
    setPickerOpen(false)
    setSpeech('')
  }

  return (
    <aside className="huayao-desktop" aria-label="花妖桌宠">
      <style>{styles}</style>
      {prefs.collapsed ? (
        <button type="button" className="huayao-desktop__badge" onClick={collapse} aria-label="展开花妖桌宠">
          <span className="huayao-desktop__dot" data-state={state} aria-hidden="true" />
          花妖 <span className="huayao-desktop__compact-status">{labels[state]}</span>
        </button>
      ) : (
        <>
          {pickerOpen && (
            <PortraitPicker
              mode={prefs.mode} selected={pose.id} petals={prefs.petals}
              selectMode={selectMode} selectPose={selectPose}
              togglePetals={() => setPrefs(previous => ({ ...previous, petals: !previous.petals }))}
            />
          )}
          <div className="huayao-desktop__stage" data-mode={prefs.mode}>
            {prefs.petals && (
              <div className="huayao-desktop__petals" aria-hidden="true">
                {petalOffsets.map(petal => (
                  <i key={petal.left} style={{
                    left: petal.left, animationDelay: petal.delay, animationDuration: petal.duration,
                  }} />
                ))}
              </div>
            )}
            <div className="huayao-desktop__actions">
              <button type="button" onClick={() => setPickerOpen(previous => !previous)} aria-expanded={pickerOpen}>
                立绘
              </button>
              <button type="button" onClick={collapse} aria-label="收起花妖桌宠">收起</button>
            </div>
            {(speech || notice) && (
              <div className="huayao-desktop__speech" role="status">{speech || notice}</div>
            )}
            <button className="huayao-desktop__actor" type="button" aria-label={`${pose.title}，点击互动`} onClick={speak}>
              <img key={`${pose.id}-${hop}`} src={pose.src} alt="" draggable="false" data-hop={hop > 0 ? '' : undefined} />
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
