import { useState } from 'react'
import { achievements, companionLevel } from './companion.js'

function shuffle(items) {
  const shuffled = [...items]
  for (let index = shuffled.length - 1; index > 0; index--) {
    const other = Math.floor(Math.random() * (index + 1))
    const item = shuffled[index]
    shuffled[index] = shuffled[other]
    shuffled[other] = item
  }
  return shuffled
}

function makeRound(poses) {
  const matched = shuffle(poses)
  const featured = matched[0]
  const options = [featured, ...matched.filter(pose => pose.title !== featured.title).slice(0, 2)]
  return { featured, options: shuffle(options) }
}

export function CompanionPanel({ progress, interact, poses }) {
  const [round, setRound] = useState(null)
  const [answer, setAnswer] = useState(null)
  const checkedIn = progress.lastVisit === progress.day

  function nextRound() {
    setRound(makeRound(poses))
    setAnswer(null)
  }

  function pick(id) {
    if (answer !== null) return
    setAnswer(id)
    if (id === round.featured.id) interact('quiz')
  }

  return (
    <div className="huayao-desktop__companion">
      <div className="huayao-desktop__bond">
        <strong>{companionLevel(progress.bond)}</strong>
        <span>好感 {progress.bond} · 连续签到 {progress.streak} 天</span>
      </div>
      <div className="huayao-desktop__quick">
        <button type="button" onClick={() => interact('tea')} disabled={progress.today.tea >= 3}>奉茶 {progress.today.tea}/3</button>
        <button type="button" onClick={() => interact('visits')} disabled={checkedIn}>
          {checkedIn ? '今日已签到' : '今日签到'}
        </button>
      </div>
      <p className="huayao-desktop__tasks">今日相伴 {progress.today.turn} 轮 · 互动 {progress.today.pat} 次</p>
      <details>
        <summary>花台成就（{achievements.filter(item => progress.total[item.key] >= item.target).length}/{achievements.length}）</summary>
        <ul>
          {achievements.map(item => (
            <li key={item.key}>
              <span>{item.title}</span>
              <span>{progress.total[item.key] >= item.target ? '已解锁' : item.goal}</span>
            </li>
          ))}
        </ul>
      </details>
      {round ? (
        <div className="huayao-desktop__quiz">
          <img src={round.featured.src} alt="请辨认画中的造型" />
          <div className="huayao-desktop__quick">
            {round.options.map(pose => (
              <button type="button" key={pose.id} disabled={answer !== null} onClick={() => pick(pose.id)}>
                {pose.title}
              </button>
            ))}
          </div>
          {answer !== null && (
            <>
              <p role="status">{answer === round.featured.id ? '答对了。' : `此图是「${round.featured.title}」。`}</p>
              <button type="button" onClick={nextRound}>再看一幅</button>
            </>
          )}
        </div>
      ) : <button type="button" onClick={nextRound}>玩一局辨花影</button>}
    </div>
  )
}
