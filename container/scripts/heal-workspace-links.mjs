#!/usr/bin/env node
/**
 * Container heal script: restore pnpm workspace cross-links after a
 * `pnpm install --prod` in a pnpm workspace.
 *
 * With the default isolated linker, a `--prod` workspace install links only a
 * project's *external* production dependencies into `node_modules/.pnpm`; it
 * does not recreate the `node_modules/<workspace-dep>` symlinks that a full
 * install creates for workspace-to-workspace `dependencies`,
 * `peerDependencies`, and `optionalDependencies`. Production code still
 * imports those workspace packages by bare specifier, so without this heal
 * every cross-project `import '@deepseek-ai/...'` fails at boot.
 *
 * The heal re-creates exactly the links a full install would have made: for
 * each workspace project, one symlink per dependency whose package name
 * resolves to another workspace project. Targets and link paths are taken
 * from pnpm's own `node_modules/.pnpm-workspace-state-v1.json`, so the link
 * set cannot drift from what the workspace declares. pnpm records absolute
 * paths in that file; they are re-homed onto the actual deploy root, so the
 * script can also run after the tree moves (as in `COPY --from=builder`).
 *
 * Idempotent: correct links are kept, wrong/dangling links are replaced, and
 * anything that is not a symlink is left alone (fail loud).
 */

import { lstatSync, mkdirSync, readFileSync, readlinkSync, symlinkSync, unlinkSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'

/**
 * Recorded workspace root: the project directory that is a strict path prefix
 * of every other project directory.
 */
function recordedWorkspaceRoot(dirs) {
  if (dirs.length === 0) return undefined
  const sorted = [...dirs].sort()
  const first = sorted[0]
  const last = sorted[sorted.length - 1]
  const isPrefix = first === last.slice(0, first.length)
    && (first.length === last.length || last[first.length] === '/')
  let root = isPrefix ? first : dirname(first)
  while (root !== '/' && !dirs.includes(root)) {
    const parent = dirname(root)
    if (parent === root) break
    root = parent
  }
  return root === '/' ? undefined : root
}

function main(deployRoot) {
  const statePath = join(deployRoot, 'node_modules', '.pnpm-workspace-state-v1.json')
  const state = JSON.parse(readFileSync(statePath, 'utf8'))
  const projects = state.projects ?? {}
  const recordedDirs = Object.keys(projects)
  const recordedRoot = recordedWorkspaceRoot(recordedDirs)
  if (recordedRoot === undefined) {
    throw new Error(`heal-workspace-links: cannot derive the recorded workspace root from ${statePath}`)
  }
  const rehome = (recordedPath) => resolve(deployRoot, relative(recordedRoot, recordedPath))
  const nameToDir = new Map()
  for (const [dir, meta] of Object.entries(projects)) {
    if (meta.name !== undefined) nameToDir.set(meta.name, rehome(dir))
  }

  let linked = 0
  let kept = 0
  let replaced = 0
  const errors = []

  for (const recordedDir of recordedDirs) {
    const dir = rehome(recordedDir)
    const manifestPath = join(dir, 'package.json')
    let manifest
    try {
      manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    } catch {
      continue // a manifest-less project dir cannot request links
    }
    const depNames = new Set()
    for (const section of ['dependencies', 'peerDependencies', 'optionalDependencies']) {
      for (const name of Object.keys(manifest[section] ?? {})) depNames.add(name)
    }
    for (const specifier of depNames) {
      const targetDir = nameToDir.get(specifier)
      if (targetDir === undefined) continue // not a workspace project
      const parts = specifier.split('/')
      const bare = specifier.startsWith('@') ? parts[1] : parts[0]
      const scope = specifier.startsWith('@') ? parts[0] : undefined
      const link = scope === undefined
        ? join(dir, 'node_modules', bare)
        : join(dir, 'node_modules', scope, bare)
      const target = resolve(targetDir)
      try {
        const stat = lstatSync(link)
        if (stat.isSymbolicLink()) {
          if (readlinkSync(link) === target) {
            kept++
            continue
          }
          unlinkSync(link)
          replaced++
        } else {
          errors.push(`${link} exists and is not a symlink (${stat.isDirectory() ? 'directory' : 'file'})`)
          continue
        }
      } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
      try {
        mkdirSync(dirname(link), { recursive: true })
        symlinkSync(target, link, 'dir')
        linked++
      } catch (error) {
        errors.push(`${link}: ${String(error)}`)
      }
    }
  }

  console.log(
    `heal-workspace-links: root=${deployRoot} linked=${linked} kept=${kept} replaced=${replaced} errors=${errors.length}`,
  )
  for (const message of errors) console.error(`heal-workspace-links: ${message}`)
  if (errors.length > 0 && !process.env.DSH_CONTAINER_HEAL_FORCE) {
    process.exit(1)
  }
}

const arg = process.argv[2]
const deployRoot = arg === undefined || arg === '' ? process.cwd() : resolve(process.cwd(), arg)
main(deployRoot)
