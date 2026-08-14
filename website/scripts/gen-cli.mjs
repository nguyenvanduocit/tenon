// Lift the CLI's own usage text out of Sources/TenonCLI/main.swift.
//
// `tenon-cli` prints one `usage` string, and that string is the only complete
// statement of its verbs. Retyping it here would produce a second one, and the
// two would disagree the first time a verb is added — which is exactly what
// happened before this site existed: `rename` shipped in the tree while the
// prose describing the CLI still listed six verbs.
//
//   bun run gen:cli

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SOURCE = join(ROOT, '..', 'Sources', 'TenonCLI', 'main.swift')
const OUT = join(ROOT, '.vitepress', 'generated', 'cli-usage.txt')

const source = readFileSync(SOURCE, 'utf8')
const usage = /private let usage = """\n([\s\S]*?)\n"""/.exec(source)
if (!usage) {
  throw new Error(
    `Could not find the usage literal in ${SOURCE}. ` +
      'Teach this generator the new shape rather than letting the page go stale.',
  )
}

mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, usage[1] + '\n')

const verbs = usage[1].split('\n').filter((line) => /^ {2}\S/.test(line)).length
console.log(`Wrote the CLI usage block (${verbs} verb lines) to .vitepress/generated/`)
