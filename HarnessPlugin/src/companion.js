export function dayKey(now = new Date()) {
  const pad = value => String(value).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

const maxCount = 99999
const counts = ['pat', 'tea', 'turn', 'quiz', 'visits']
const limits = { pat: 10, tea: 3, turn: 10, quiz: 3, visits: 1 }
export const achievements = [
  { key: 'pat', target: 1, title: '初上花台', goal: '互动 1 次' },
  { key: 'tea', target: 5, title: '一盏清茶', goal: '奉茶 5 次' },
  { key: 'turn', target: 10, title: '台前同忙', goal: '陪伴完成 10 轮' },
  { key: 'quiz', target: 5, title: '识得花影', goal: '猜对造型 5 次' },
  { key: 'visits', target: 7, title: '七日相逢', goal: '累计签到 7 天' },
]

function number(value, max = maxCount) {
  return Number.isInteger(value) && value >= 0 ? Math.min(value, max) : 0
}

export function normalizeProgress(saved, now = new Date()) {
  const today = dayKey(now)
  const lastVisit = typeof saved?.lastVisit === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(saved.lastVisit)
    && saved.lastVisit <= today ? saved.lastVisit : ''
  const yesterday = dayKey(new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1))
  return {
    day: today,
    lastVisit,
    bond: number(saved?.bond),
    streak: lastVisit >= yesterday ? number(saved?.streak) : 0,
    total: Object.fromEntries(counts.map(key => [key, number(saved?.total?.[key])])),
    today: Object.fromEntries(counts.map(key => [
      key, saved?.day === today ? number(saved?.today?.[key], limits[key]) : 0,
    ])),
  }
}

export function recordProgress(saved, action, now = new Date()) {
  const progress = normalizeProgress(saved, now)
  if (!Object.hasOwn(limits, action) || progress.today[action] >= limits[action]) return progress
  if (action === 'visits') {
    if (progress.lastVisit === progress.day) return progress
    const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
    progress.streak = progress.lastVisit === dayKey(yesterday) ? number(progress.streak + 1) : 1
    progress.lastVisit = progress.day
  }
  progress.today[action]++
  progress.total[action] = number(progress.total[action] + 1)
  progress.bond = number(progress.bond + ({ tea: 2, turn: 2, quiz: 2, visits: 3 }[action] ?? 1))
  return progress
}

export function companionLevel(bond) {
  if (bond >= 80) return '长相伴'
  if (bond >= 30) return '常相见'
  if (bond >= 10) return '渐相熟'
  return '初相逢'
}
