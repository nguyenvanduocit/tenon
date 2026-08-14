// Screenshot built pages over the DevTools protocol, with colour scheme and
// viewport emulated.
//
// A passing build proves links resolve and Markdown parsed. It proves nothing
// about whether a reference table overflows at 390 pixels wide, or whether the
// light-mode brand colour is readable. Those need a picture.
//
//   bun run build && bun run preview --port 4173 &
//   "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
//     --remote-debugging-port=9222 --user-data-dir=/tmp/shot-profile about:blank &
//   bun scripts/shoot.mjs /tmp/shots dark 1440x1100 / /guide/install
//
// Uses its own throwaway Chrome profile deliberately: pointing a screenshot
// tool at someone's real browser profile is not a thing a build script does.

import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const [outDir, scheme = 'dark', size = '1440x1100', ...paths] = process.argv.slice(2)
if (!outDir || paths.length === 0) {
  console.error('usage: shoot.mjs <outdir> <dark|light> <WxH> <path...>')
  process.exit(1)
}

const BASE = process.env.BASE ?? 'http://localhost:4173'
const DEVTOOLS = process.env.DEVTOOLS ?? 'http://localhost:9222'
const [width, height] = size.split('x').map(Number)

mkdirSync(outDir, { recursive: true })

const target = await fetch(`${DEVTOOLS}/json/new?about:blank`, { method: 'PUT' }).then((r) =>
  r.json(),
)

const socket = new WebSocket(target.webSocketDebuggerUrl)
await new Promise((resolve, reject) => {
  socket.onopen = resolve
  socket.onerror = reject
})

let nextID = 0
const pending = new Map()
const events = []

socket.onmessage = (message) => {
  const frame = JSON.parse(message.data)
  if (frame.id !== undefined) {
    const settle = pending.get(frame.id)
    pending.delete(frame.id)
    settle?.(frame)
  } else {
    events.push(frame)
  }
}

const send = (method, params = {}) =>
  new Promise((resolve) => {
    const id = ++nextID
    pending.set(id, resolve)
    socket.send(JSON.stringify({ id, method, params }))
  })

await send('Page.enable')
await send('Runtime.enable')
await send('Emulation.setDeviceMetricsOverride', {
  width,
  height,
  deviceScaleFactor: 1,
  mobile: width < 500,
})
await send('Emulation.setEmulatedMedia', {
  features: [{ name: 'prefers-color-scheme', value: scheme }],
})

let failed = 0

for (const path of paths) {
  const name = path.replace(/^\/|\/$/g, '').replace(/\//g, '-') || 'home'
  const file = join(outDir, `${name}-${scheme}-${width}.png`)

  await send('Page.navigate', { url: `${BASE}${path}` })
  // VitePress hydrates after load; wait for the theme class to settle rather
  // than for a fixed delay, so a slow machine does not photograph a flash of
  // the wrong colour scheme.
  for (let attempt = 0; attempt < 60; attempt++) {
    const probe = await send('Runtime.evaluate', {
      expression: `document.readyState === 'complete' &&
        !!document.querySelector('.VPContent, .VPHome')`,
      returnByValue: true,
    })
    if (probe.result?.result?.value === true) break
    await new Promise((r) => setTimeout(r, 250))
  }

  const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  if (!shot.result?.data) {
    console.error(`FAIL ${path}`)
    failed++
    continue
  }
  writeFileSync(file, Buffer.from(shot.result.data, 'base64'))

  // A page wider than its viewport is the failure a screenshot hides: the shot
  // is cropped to the viewport, so the overflowing table is simply not in the
  // picture. Measure it instead of looking for it.
  const overflow = await send('Runtime.evaluate', {
    expression: `(() => {
      const doc = document.documentElement
      const wide = [...document.querySelectorAll('.vp-doc *')]
        .filter(el => el.scrollWidth > doc.clientWidth + 1)
        .map(el => el.tagName.toLowerCase() + (el.className ? '.' + String(el.className).split(' ')[0] : ''))
      return { page: doc.scrollWidth - doc.clientWidth, wide: [...new Set(wide)].slice(0, 5) }
    })()`,
    returnByValue: true,
  })
  const measured = overflow.result?.result?.value ?? {}

  const errors = events.filter(
    (e) => e.method === 'Runtime.exceptionThrown' || e.params?.type === 'error',
  )
  const notes = []
  if (measured.page > 0) notes.push(`OVERFLOW ${measured.page}px: ${measured.wide.join(', ')}`)
  if (errors.length) notes.push(`${errors.length} console errors`)
  if (notes.length) failed++

  console.log(`${notes.length ? 'WARN' : 'ok  '} ${path} → ${file}`)
  for (const note of notes) console.log(`       ${note}`)
  events.length = 0
}

socket.close()
await fetch(`${DEVTOOLS}/json/close/${target.id}`)
process.exit(failed === 0 ? 0 : 1)
