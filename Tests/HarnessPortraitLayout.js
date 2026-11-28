// Run with Playwright CLI against an isolated Harness web profile with the built plugin installed.
async (page) => {
  const pet = page.getByRole('complementary', { name: '花妖桌宠' })
  const stage = pet.locator('.huayao-desktop__stage')
  const actor = stage.locator('.huayao-desktop__actor img')
  const portraitToggle = stage.getByRole('button', { name: '立绘', exact: true })
  const picker = pet.getByLabel('选择立绘')
  const modes = [
    { key: 'duo', label: '双人', count: 21 },
    { key: 'hua', label: '花旦', count: 13 },
    { key: 'sheng', label: '小生', count: 4 },
  ]
  const result = []
  for (const viewport of [{ width: 1280, height: 820 }, { width: 480, height: 430 }]) {
    await page.setViewportSize(viewport)
    for (const size of ['small', 'normal', 'large']) {
      const settingsToggle = stage.getByRole('button', { name: '设置', exact: true })
      await settingsToggle.click()
      await pet.getByLabel('尺寸').selectOption(size)
      await settingsToggle.click()

      let reference
      for (const { key, label, count } of modes) {
        await portraitToggle.click()
        await picker.getByRole('button', { name: `${label} ${count}`, exact: true }).click()
        const outfits = picker.getByLabel(`${label}立绘`).getByRole('button')
        if (await outfits.count() !== count) throw new Error(`Unexpected ${label} pose count`)

        const indices = viewport.width === 1280 && size === 'normal'
          ? Array.from({ length: count }, (_, index) => index)
          : [0, count - 1]
        for (const [iteration, index] of indices.entries()) {
          if (iteration > 0) await portraitToggle.click()
          const outfit = outfits.nth(index)
          const title = (await outfit.innerText()).trim()
          await outfit.click()
          await stage.getByRole('button', { name: `${title}，点击互动`, exact: true }).waitFor()
          const geometry = await actor.evaluate(async (image) => {
            await image.decode()
            const { x, y, width, height, bottom, right } = image.getBoundingClientRect()
            const stageRect = image.closest('.huayao-desktop__stage').getBoundingClientRect()
            return {
              x, y, width, height, bottom, right,
              naturalWidth: image.naturalWidth, naturalHeight: image.naturalHeight,
              stageTop: stageRect.top, stageBottom: stageRect.bottom,
            }
          })
          const { x, y, width, height, bottom, right, naturalWidth, naturalHeight, stageTop, stageBottom } = geometry
          if (naturalWidth !== 560 || naturalHeight !== 560 || width <= 0 || Math.abs(width - height) > .1 ||
              x < 0 || right > viewport.width || y < stageTop || bottom > stageBottom) {
            throw new Error(`${key} ${title} is cropped or stretched at ${viewport.width} ${size}: ${JSON.stringify(geometry)}`)
          }
          const visibleBaseline = y + height * (1600 / 1728)
          reference ??= { x, width, visibleBaseline }
          if (Math.abs(x - reference.x) > .1 || Math.abs(width - reference.width) > .1 ||
              Math.abs(visibleBaseline - reference.visibleBaseline) > .1) {
            throw new Error(`${key} ${title} changes the visible baseline or scale at ${viewport.width} ${size}`)
          }
        }
      }
      result.push({ viewport, size, actualSide: reference.width })
    }
  }
  return result
}
