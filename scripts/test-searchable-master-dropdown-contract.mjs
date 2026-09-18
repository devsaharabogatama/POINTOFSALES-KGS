import { readFile } from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'

const root = process.cwd()
const files = {
  backofficeComponent: path.join(root, 'backoffice/src/components/SearchableSelectEnhancer.tsx'),
  backofficeRoot: path.join(root, 'backoffice/src/app/layout.tsx'),
  pwaComponent: path.join(root, 'pwa/src/components/SearchableSelectEnhancer.tsx'),
  pwaRoot: path.join(root, 'pwa/src/main.tsx'),
}

const entries = Object.fromEntries(
  await Promise.all(Object.entries(files).map(async ([key, file]) => [key, await readFile(file, 'utf8')])),
)

const failures = []
const expect = (condition, message) => {
  if (!condition) failures.push(message)
}

for (const key of ['backofficeComponent', 'pwaComponent']) {
  const source = entries[key]
  expect(source.includes('const SEARCH_THRESHOLD = 10'), `${key}: threshold must remain 10`)
  expect(source.includes('option.value !=='), `${key}: empty placeholder must not count toward threshold`)
  expect(source.includes("toLocaleLowerCase"), `${key}: filtering must remain case-insensitive`)
  expect(source.includes('.normalize('), `${key}: visible labels must use normalized text matching`)
  expect(source.includes('HTMLSelectElement.prototype'), `${key}: native select value setter is required`)
  expect(source.includes("new Event("), `${key}: native change event dispatch is required`)
  expect(source.includes('Pilihan tidak ditemukan.'), `${key}: empty filter state is required`)
  expect(source.includes('ArrowDown') && source.includes('ArrowUp') && source.includes('Enter') && source.includes('Escape'), `${key}: keyboard contract is incomplete`)
}

expect(entries.backofficeRoot.includes('<SearchableSelectEnhancer />'), 'Backoffice root does not mount enhancer')
expect(entries.pwaRoot.includes('<SearchableSelectEnhancer />'), 'PWA root does not mount enhancer')

if (failures.length) {
  console.error(`SEARCHABLE_MASTER_DROPDOWN_CONTRACT=FAIL\n- ${failures.join('\n- ')}`)
  process.exit(1)
}

console.log('SEARCHABLE_MASTER_DROPDOWN_CONTRACT=PASS')
console.log('clients=backoffice,pwa threshold=10 nativeSelectSourcePreserved=true')

