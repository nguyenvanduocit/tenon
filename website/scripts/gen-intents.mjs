// Generate the intent reference from Tenon itself. Nothing here is hand-written.
//
// It reads TWO sources, because neither one alone can see the whole catalog:
//
//  1. `tenon-cli intent list/describe` — the running app's own discovery path.
//     Authoritative and complete, including JSON Schemas, for every contract the
//     CLI principal may call.
//  2. Sources/TenonCore/CoreIntentCatalog.swift — the enum that IS the inventory
//     boundary, read for names, titles, descriptions and audience.
//
// The second source exists because the first is fail-closed by design: contracts
// whose audience is `{plugin}` answer `intent_not_found` to a shell
// (docs/design-cli.md, "Hidden intents answer as not found"). That is correct
// behaviour, and it means a CLI-only generator would silently publish a partial
// inventory. So the catalog decides WHICH contracts exist and the CLI decides
// what their schemas are; where the CLI cannot see one, the page says so and
// sends the reader to `tenon.intents.list()` rather than inventing a schema.
//
//   bun run gen:intents
//
// Output is committed, so the site builds on a machine with no Tenon and no
// Swift. Re-run it whenever the catalog changes; the diff is the review.

import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const OUT_DIR = join(ROOT, 'reference', 'intents')
const SIDEBAR = join(ROOT, '.vitepress', 'generated', 'intent-sidebar.json')
const CATALOG = join(ROOT, '..', 'Sources', 'TenonCore', 'CoreIntentCatalog.swift')

const CLI = process.env.TENON_CLI ?? 'tenon-cli'
const CATALOG_URL =
  'https://github.com/nguyenvanduocit/tenon/blob/main/Sources/TenonCore/CoreIntentCatalog.swift'

/** Domain prefix → the section it is filed under, in reading order. */
const GROUPS = [
  ['workspace', 'Workspace'],
  ['terminal', 'Terminal'],
  ['agent', 'Agents'],
  ['filesystem', 'Filesystem'],
  ['file', 'Files'],
  ['process', 'Process'],
  ['browser', 'Browser'],
  ['ui', 'User prompts'],
  ['url', 'Opening'],
  ['clipboard', 'Clipboard'],
  ['secrets', 'Secrets'],
  ['network', 'Network'],
]

function cli(args) {
  try {
    return execFileSync(CLI, args, { encoding: 'utf8', timeout: 30_000 })
  } catch (error) {
    const detail = [error.stderr, error.stdout, error.message].filter(Boolean).join('\n').trim()
    throw new Error(`${CLI} ${args.join(' ')} failed:\n${detail}`)
  }
}

/** `terminal.open.v1` → `terminal-open-v1`, so the URL has no dots in it. */
const slug = (name) => name.replace(/\./g, '-')

/**
 * Read the inventory boundary out of CoreIntentCatalog.swift.
 *
 * Two shapes are parsed, and both are deliberately the most stable text in that
 * file — the enum that a fitness test forces to stay exhaustive, and the literal
 * title/description strings on their own lines:
 *
 *   case terminalOpen = "terminal.open.v1"
 *
 *   try CoreIntentRuleData.definition(
 *       .terminalOpen,
 *       title: "Open a terminal in a new tab",
 *       description: "Opens a new terminal tab …",
 *       …
 *       audiences: programmatic,
 *
 * A definition this parser cannot read is reported, never guessed past.
 */
function readSwiftCatalog(path) {
  const source = readFileSync(path, 'utf8')

  const namesByCase = new Map()
  const enumBlock = /public enum CoreIntentName[^{]*\{([\s\S]*?)\n\}/.exec(source)
  if (!enumBlock) throw new Error(`Could not find enum CoreIntentName in ${path}`)
  for (const match of enumBlock[1].matchAll(/case\s+(\w+)\s*=\s*"([^"]+)"/g)) {
    namesByCase.set(match[1], match[2])
  }

  const contracts = new Map()
  const unparsed = []
  const chunks = source.split('CoreIntentRuleData.definition(').slice(1)
  for (const chunk of chunks) {
    const caseName = /^\s*\.(\w+)\s*,/.exec(chunk)?.[1]
    if (!caseName || !namesByCase.has(caseName)) {
      unparsed.push(chunk.slice(0, 60).replace(/\s+/g, ' '))
      continue
    }
    const profile = /\n\s*audiences:\s*(\w+)/.exec(chunk)?.[1]
    if (profile !== 'programmatic' && profile !== 'pluginOnly') {
      throw new Error(
        `${namesByCase.get(caseName)} declares an audience profile this generator does not ` +
          `know: ${profile}. Add it to the parser rather than publishing a guess.`,
      )
    }
    contracts.set(namesByCase.get(caseName), {
      name: namesByCase.get(caseName),
      title: swiftString(chunk, 'title'),
      description: swiftString(chunk, 'description'),
      // The two profiles CoreIntentAudienceProfile allows. `programmatic` is
      // {plugin, cli, agent}; `pluginOnly` is {plugin}.
      audiences: profile === 'pluginOnly' ? ['plugin'] : ['agent', 'cli', 'plugin'],
      pluginOnly: profile === 'pluginOnly',
    })
  }

  return { contracts, namesByCase, unparsed }
}

/**
 * Read one `label: "…"` or `label: """…"""` argument out of a definition block.
 *
 * Swift writes long descriptions as multi-line literals and wraps them with a
 * trailing backslash, which is a line join and not part of the text.
 */
function swiftString(chunk, label) {
  const multiline = new RegExp(`\\n\\s*${label}:\\s*"""\\n([\\s\\S]*?)\\n\\s*""",`).exec(chunk)
  if (multiline) return joinSwiftLines(multiline[1])
  const single = new RegExp(`\\n\\s*${label}:\\s*"((?:[^"\\\\]|\\\\.)*)",`).exec(chunk)
  return single ? joinSwiftLines(single[1]) : undefined
}

const joinSwiftLines = (text) =>
  text
    .replace(/\\\n\s*/g, '')
    .replace(/\\"/g, '"')
    .replace(/\s+/g, ' ')
    .trim()

const groupOf = (name) => {
  const prefix = name.split('.')[0]
  const found = GROUPS.find(([key]) => key === prefix)
  return found ? found[1] : 'Other'
}

const escapeCell = (text) => String(text).replace(/\|/g, '\\|').replace(/\n+/g, ' ')

/** The first sentence of a description, for a table cell. */
function firstSentence(text) {
  if (!text) return ''
  const match = /^(.*?[.!?])(\s|$)/s.exec(text.trim())
  return (match ? match[1] : text.trim()).replace(/\s+/g, ' ')
}

const EFFECT_NOTES = {
  read: 'Reads state and changes nothing.',
  write: 'Changes state.',
}

const CONFIRMATION_NOTES = {
  never: 'Runs without asking.',
  policy: 'May require a live confirmation, decided by policy and the caller’s audience.',
  always: 'Always requires a live confirmation.',
}

/**
 * Follow a local `$ref` into the schema's own `$defs`.
 *
 * `process.exec.v1` returns `{"$ref": "#/$defs/textOutput"}` for its output
 * streams. Left unresolved that renders as `any`, which tells a plugin author
 * exactly nothing about the one contract they will call most.
 */
function deref(property, root, depth = 0) {
  if (!property || typeof property !== 'object' || depth > 8) return property
  const ref = property.$ref
  if (typeof ref !== 'string' || !ref.startsWith('#/')) return property
  const resolved = ref
    .slice(2)
    .split('/')
    .reduce((node, key) => (node == null ? node : node[key]), root)
  return resolved ? deref(resolved, root, depth + 1) : property
}

/** Render one JSON Schema object as a readable property table. */
function schemaTable(schema, root = schema) {
  if (!schema || typeof schema !== 'object') return '_No schema._\n'
  schema = deref(schema, root)
  const properties = schema.properties ?? {}
  const names = Object.keys(properties)
  if (names.length === 0) {
    return schema.additionalProperties === false
      ? 'Takes no properties — send `{}`.\n'
      : '_No declared properties._\n'
  }
  const required = new Set(schema.required ?? [])

  const rows = names.map((name) => {
    const property = deref(properties[name], root)
    return [
      `\`${name}\``,
      required.has(name) ? 'yes' : 'no',
      // A union type contains `|`, which would otherwise end the table cell.
      `\`${escapeCell(describeType(property, root))}\``,
      escapeCell(constraintsOf(property) || '—'),
    ]
  })

  const head = '| Property | Required | Type | Constraints |\n|---|---|---|---|\n'
  return head + rows.map((cells) => `| ${cells.join(' | ')} |`).join('\n') + '\n'
}

function describeType(property, root) {
  property = deref(property, root)
  if (!property || typeof property !== 'object') return 'any'
  if (property.const !== undefined) return JSON.stringify(property.const)
  if (Array.isArray(property.enum)) return property.enum.map((v) => JSON.stringify(v)).join(' | ')
  // A `oneOf`/`anyOf` is a real shape, not an unknown one — `recipient` is
  // either {kind:"human"} or an agent principal, and printing `any` there
  // loses the only thing a caller needs to know.
  const union = property.oneOf ?? property.anyOf
  if (Array.isArray(union)) return union.map((member) => describeType(member, root)).join(' | ')
  if (property.type === 'array') {
    const items = property.items ? describeType(property.items, root) : 'any'
    return `${items}[]`
  }
  if (property.type === 'object' && property.properties) {
    const keys = Object.keys(property.properties)
    const required = new Set(property.required ?? [])
    return `{${keys.map((k) => (required.has(k) ? k : `${k}?`)).join(', ')}}`
  }
  return property.type ?? 'any'
}

function constraintsOf(property) {
  if (!property || typeof property !== 'object') return ''
  const parts = []
  if (property.format) parts.push(`format \`${property.format}\``)
  if (property.minLength !== undefined || property.maxLength !== undefined) {
    parts.push(`length ${property.minLength ?? 0}–${property.maxLength ?? '∞'}`)
  }
  if (property.minimum !== undefined || property.maximum !== undefined) {
    parts.push(`range ${property.minimum ?? '−∞'}–${property.maximum ?? '∞'}`)
  }
  if (property.minItems !== undefined || property.maxItems !== undefined) {
    parts.push(`items ${property.minItems ?? 0}–${property.maxItems ?? '∞'}`)
  }
  if (property.default !== undefined) parts.push(`default \`${JSON.stringify(property.default)}\``)
  if (property.pattern) parts.push('pattern-checked')
  return parts.join(', ')
}

function intentPage(contract) {
  const {
    name,
    title,
    description,
    audiences = [],
    effects = {},
    domainErrors = [],
    providers = [],
    inputSchema,
    outputSchema,
    deprecated,
    class: contractClass,
  } = contract

  const lines = []
  lines.push('---')
  lines.push(`title: ${name}`)
  lines.push(`description: ${JSON.stringify(firstSentence(description) || title || name)}`)
  lines.push('---')
  lines.push('')
  lines.push(`# \`${name}\``)
  lines.push('')
  if (deprecated) {
    lines.push('::: danger DEPRECATED')
    lines.push('This contract is deprecated and will be removed. Do not build on it.')
    lines.push(':::')
    lines.push('')
  }
  lines.push(`**${title}**`)
  lines.push('')
  lines.push(description ?? '')
  lines.push('')

  lines.push('## At a glance')
  lines.push('')
  lines.push('| | |')
  lines.push('|---|---|')
  lines.push(
    `| Callable by | ${audiences.length ? audiences.map((a) => `\`${a}\``).join(', ') : '—'} |`,
  )
  if (effects.kind) {
    lines.push(`| Effect | \`${effects.kind}\` — ${EFFECT_NOTES[effects.kind] ?? ''} |`)
  }
  if (effects.confirmation) {
    lines.push(
      `| Confirmation | \`${effects.confirmation}\` — ${
        CONFIRMATION_NOTES[effects.confirmation] ?? ''
      } |`,
    )
  }
  if (effects.idempotency) lines.push(`| Idempotency | \`${effects.idempotency}\` |`)
  if (effects.external !== undefined) {
    lines.push(`| Leaves the machine | ${effects.external ? 'yes' : 'no'} |`)
  }
  lines.push(`| Provided by | ${providers.map((p) => `\`${p}\``).join(', ') || '—'} |`)
  if (contractClass) lines.push(`| Contract class | \`${contractClass}\` |`)
  lines.push('')

  if (!audiences.includes('cli')) {
    lines.push('::: tip Not reachable from `tenon-cli`')
    lines.push(
      `\`${name}\` is not in the \`cli\` audience, so a shell cannot send it. ` +
        'Naming an intent never grants authority — audience is checked before anything else.',
    )
    lines.push(':::')
    lines.push('')
  }

  if (contract.described) {
    lines.push('## Input')
    lines.push('')
    lines.push(schemaTable(inputSchema, inputSchema))
    lines.push('')

    lines.push('## Output')
    lines.push('')
    lines.push(schemaTable(outputSchema, outputSchema))
    lines.push('')
  } else {
    lines.push('## Input and output')
    lines.push('')
    lines.push('::: warning Schema not reproduced here')
    lines.push(
      contract.hiddenReason === 'plugin-only'
        ? `\`${name}\` is served only to plugins, so the CLI discovery path this page is ` +
            'generated from cannot read its schema — and a hand-copied schema on a website ' +
            'is a schema that goes stale. Ask the runtime instead, from inside a plugin ' +
            'that declares it in `intents.uses`:'
        : `\`${name}\` is callable from a shell, but the Tenon this page was generated ` +
            `against (${APP_LABEL}) did not serve it — the catalog beside this site is ` +
            'newer than that build. Update Tenon and re-run the generator, or ask your ' +
            'own build directly:',
    )
    lines.push('')
    if (contract.hiddenReason === 'plugin-only') {
      lines.push('```js')
      lines.push('const contracts = await tenon.intents.list()')
      lines.push(`const contract = contracts.find(c => c.name === ${JSON.stringify(name)})`)
      lines.push('tenon.log(JSON.stringify(contract.inputSchema, null, 2))')
      lines.push('```')
    } else {
      lines.push('```sh')
      lines.push(`tenon-cli intent describe ${name}`)
      lines.push('```')
    }
    lines.push('')
    lines.push(`The definition itself is in [\`CoreIntentCatalog.swift\`](${CATALOG_URL}).`)
    lines.push(':::')
    lines.push('')
  }

  if (domainErrors.length) {
    lines.push('## Errors it can return')
    lines.push('')
    lines.push('These are this contract’s own failures, on top of the lifecycle errors every')
    lines.push('intent can settle with. See [Errors](/reference/errors).')
    lines.push('')
    for (const code of domainErrors) lines.push(`- \`${code}\``)
    lines.push('')
  }

  lines.push('## Call it')
  lines.push('')
  lines.push('From a plugin — declare it in `intents.uses` first:')
  lines.push('')
  lines.push('```js')
  lines.push(`const result = await tenon.intents.send(${JSON.stringify(name)}, {})`)
  lines.push('if (!result.ok) throw new Error(result.error.code)')
  lines.push('```')
  lines.push('')
  if (audiences.includes('cli')) {
    lines.push('From a shell:')
    lines.push('')
    lines.push('```sh')
    lines.push(`tenon-cli intent send ${name} --input '{}'`)
    lines.push('```')
    lines.push('')
  }
  if (audiences.includes('cli')) {
    lines.push(
      `Ask your own build for this same contract with \`tenon-cli intent describe ${name}\`.`,
    )
    lines.push('')
  }

  return lines.join('\n')
}

function indexPage(contracts) {
  const byGroup = new Map()
  for (const contract of contracts) {
    const group = groupOf(contract.name)
    if (!byGroup.has(group)) byGroup.set(group, [])
    byGroup.get(group).push(contract)
  }

  const lines = []
  lines.push('---')
  lines.push('title: All intents')
  lines.push(
    'description: "Every canonical intent Tenon serves, generated from the running app."',
  )
  lines.push('---')
  lines.push('')
  lines.push('# All intents')
  lines.push('')
  lines.push(
    `Tenon serves **${contracts.length} canonical contracts**. Every finite request that ` +
      'crosses from a plugin, the CLI, or an agent into the host arrives as one of these, ' +
      'and each one is checked against the caller’s audience, declared uses, capabilities, ' +
      'and scope before it runs.',
  )
  lines.push('')
  lines.push(
    'This page is generated by [`scripts/gen-intents.mjs`]' +
      '(https://github.com/nguyenvanduocit/tenon/blob/main/website/scripts/gen-intents.mjs) ' +
      'from the Swift catalog and a running Tenon, so it cannot drift from what the app ' +
      'serves. Ask your own build the same question with `tenon-cli intent list`.',
  )
  lines.push('')
  lines.push('The **Callable by** column is the whole authorization story in one glance: a')
  lines.push('contract without `cli` cannot be sent from a shell, no matter how it is spelled.')
  lines.push('That is not cosmetic — a shell asking for one gets `intent_not_found`, because')
  lines.push('a caller that may not use a contract may not learn it exists either.')
  lines.push('')

  const pluginOnly = contracts.filter((c) => c.hiddenReason === 'plugin-only')
  const behind = contracts.filter((c) => c.hiddenReason === 'not-in-this-build')

  if (pluginOnly.length) {
    lines.push('::: info Why some pages have no schema table')
    lines.push(
      `${pluginOnly.length} of these are served only to plugins. This site is generated ` +
        'through the CLI discovery path, which fail-closes on exactly those, so their pages ' +
        'carry what the catalog declares and send you to `tenon.intents.list()` for the ' +
        'schema rather than printing a copy that can go stale.',
    )
    lines.push(':::')
    lines.push('')
  }

  if (behind.length) {
    lines.push('::: warning Generated against an older build')
    lines.push(
      `Schemas on this site came from **${APP_LABEL}**, and ${behind.length} contract` +
        `${behind.length === 1 ? '' : 's'} in the catalog beside it did not exist in that ` +
        `build yet: ${behind.map((c) => `\`${c.name}\``).join(', ')}. ` +
        'Those pages carry the declaration without a schema. Run `bun run gen:intents` ' +
        'against a current Tenon to fill them in.',
    )
    lines.push(':::')
    lines.push('')
  }

  lines.push(
    `<small>Schemas read from ${APP_LABEL}. Inventory read from the Swift catalog in ` +
      'the same commit as this page.</small>',
  )
  lines.push('')

  for (const [, group] of GROUPS.concat([['', 'Other']])) {
    const items = byGroup.get(group)
    if (!items || items.length === 0) continue
    lines.push(`## ${group}`)
    lines.push('')
    lines.push('| Intent | Does | Callable by | Effect |')
    lines.push('|---|---|---|---|')
    for (const contract of items.sort((a, b) => a.name.localeCompare(b.name))) {
      const audiences = (contract.audiences ?? []).map((a) => `\`${a}\``).join(' ')
      lines.push(
        `| [\`${contract.name}\`](/reference/intents/${slug(contract.name)}) | ` +
          `${escapeCell(firstSentence(contract.description))} | ${audiences || '—'} | ` +
          `\`${contract.effects?.kind ?? '—'}\` |`,
      )
    }
    lines.push('')
  }

  return lines.join('\n')
}

// ---------------------------------------------------------------------------

const ping = JSON.parse(cli(['ping']))
const APP_LABEL = `Tenon ${ping.version} (build ${ping.build}, wire v${ping.protocolVersion})`
console.log(`Talking to ${APP_LABEL}`)

console.log(`Reading the inventory boundary from ${CATALOG}…`)
const catalog = readSwiftCatalog(CATALOG)
console.log(`  ${catalog.contracts.size} contracts declared in Swift`)
if (catalog.unparsed.length) {
  console.warn(`  ${catalog.unparsed.length} definition block(s) unreadable:`)
  for (const chunk of catalog.unparsed) console.warn(`    …${chunk}`)
}
if (catalog.contracts.size !== catalog.namesByCase.size) {
  const missing = [...catalog.namesByCase.values()].filter((n) => !catalog.contracts.has(n))
  throw new Error(
    `${missing.length} enum case(s) have no readable definition block: ${missing.join(', ')}. ` +
      'Teach readSwiftCatalog the new shape rather than publishing a partial inventory.',
  )
}

console.log(`Asking ${CLI} for the schemas it can serve…`)
const listed = JSON.parse(cli(['intent', 'list']))
console.log(`  ${listed.length} contracts visible to the CLI principal`)

const contracts = []
for (const [name, declared] of catalog.contracts) {
  const visible = listed.some((entry) => entry.name === name)
  if (visible) {
    contracts.push({ ...JSON.parse(cli(['intent', 'describe', name])), described: true })
    continue
  }
  contracts.push({
    name,
    title: declared.title ?? name,
    description: declared.description ?? '',
    audiences: declared.audiences,
    effects: {},
    providers: ['dev.tenon.core'],
    domainErrors: [],
    described: false,
    // Two different reasons a schema is missing, and the reader deserves the
    // right one: the contract is closed to the CLI, or the Tenon this ran
    // against is older than the catalog it was generated beside.
    hiddenReason: declared.pluginOnly ? 'plugin-only' : 'not-in-this-build',
  })
}
contracts.sort((a, b) => a.name.localeCompare(b.name))

const hidden = contracts.filter((c) => !c.described).length
console.log(`  ${contracts.length - hidden} with full schemas, ${hidden} plugin-only`)

rmSync(OUT_DIR, { recursive: true, force: true })
mkdirSync(OUT_DIR, { recursive: true })
mkdirSync(dirname(SIDEBAR), { recursive: true })

for (const contract of contracts) {
  writeFileSync(join(OUT_DIR, `${slug(contract.name)}.md`), intentPage(contract))
}
writeFileSync(join(OUT_DIR, 'index.md'), indexPage(contracts))

const sidebar = []
for (const [, group] of GROUPS.concat([['', 'Other']])) {
  const items = contracts
    .filter((c) => groupOf(c.name) === group)
    .map((c) => ({ text: c.name, link: `/reference/intents/${slug(c.name)}` }))
  if (items.length) sidebar.push({ text: group, collapsed: true, items })
}
writeFileSync(SIDEBAR, JSON.stringify(sidebar, null, 2) + '\n')

console.log(`Wrote ${contracts.length} intent pages + index to reference/intents/`)
