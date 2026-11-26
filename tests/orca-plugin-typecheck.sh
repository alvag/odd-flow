#!/usr/bin/env bash
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for tool in orca npm node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'SKIP Orca plugin typecheck: %s is not on PATH\n' "$tool"
        exit 0
    fi
done

cd -- "$root"
orca plugin types orca-plugin

prefix=$(mktemp -d)
trap 'rm -rf -- "$prefix"' EXIT
npm install --prefix "$prefix" --ignore-scripts --no-save --no-package-lock typescript@7.0.2 @types/node@26.6.10

node - "$root/orca-plugin" "$prefix" <<'NODE'
const { readFileSync, writeFileSync } = require('node:fs')
const { join, resolve } = require('node:path')
const [plugin, prefix] = process.argv.slice(2)
const generated = join(plugin, '.orca/types')
const { compilerOptions: { types, typeRoots } } = JSON.parse(readFileSync(join(generated, 'tsconfig.json'), 'utf8'))
writeFileSync(join(prefix, 'tsconfig.json'), JSON.stringify({
  extends: join(plugin, 'tsconfig.json'),
  include: [join(plugin, 'src')],
  compilerOptions: {
    typeRoots: [...typeRoots.map(root => resolve(generated, root)), join(prefix, 'node_modules/@types')],
    types: [...types, 'node']
  }
}))
NODE

"$prefix/node_modules/.bin/tsc" --noEmit -p "$prefix/tsconfig.json"
