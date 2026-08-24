import { strFromU8, unzipSync } from 'fflate'

export type DistributorPricelistRow = {
  rowNumber: number
  sku: string
  productName: string | null
  cogs: number
  retail: number
  agentPrice: number | null
  specialPrice: number | null
  customPrice: number | null
  min60Price: number | null
  min100Price: number | null
  min150Price: number | null
}

type Grid = Array<Array<string | number | null>>

const requiredHeaders = {
  sku: ['kodeproduk', 'sku'],
  productName: ['namaproduk', 'productname'],
  cogs: ['cogs', 'hpp'],
  retail: ['retail', 'hargaretail'],
  agentPrice: ['agensm', 'hargaagensm', 'agen'],
  specialPrice: ['spesial', 'special', 'hargaspesial'],
  customPrice: ['khusus', 'hargakhusus'],
  min60Price: ['min60pack', 'minimal60pack'],
  min100Price: ['min100pack', 'minimal100pack'],
  min150Price: ['min150pack', 'minimal150pack'],
} as const

function normalizeHeader(value: unknown) {
  return String(value ?? '').trim().toLowerCase().replace(/[^a-z0-9]/g, '')
}

function columnIndex(reference: string) {
  const letters = reference.match(/^[A-Z]+/i)?.[0]?.toUpperCase() ?? ''
  let result = 0
  for (const letter of letters) result = result * 26 + letter.charCodeAt(0) - 64
  return result - 1
}

function xml(bytes: Uint8Array | undefined, name: string) {
  if (!bytes) throw new Error(`File Excel tidak memiliki ${name}.`)
  const document = new DOMParser().parseFromString(strFromU8(bytes), 'application/xml')
  if (document.querySelector('parsererror')) throw new Error(`Struktur ${name} tidak valid.`)
  return document
}

function xlsxGrid(buffer: ArrayBuffer): Grid {
  const archive = unzipSync(new Uint8Array(buffer))
  const sharedDocument = archive['xl/sharedStrings.xml']
    ? xml(archive['xl/sharedStrings.xml'], 'shared strings')
    : null
  const shared = sharedDocument
    ? Array.from(sharedDocument.getElementsByTagName('si')).map((node) =>
        Array.from(node.getElementsByTagName('t')).map((text) => text.textContent ?? '').join(''))
    : []
  const sheet = xml(archive['xl/worksheets/sheet1.xml'], 'worksheet pertama')
  return Array.from(sheet.getElementsByTagName('row')).map((row) => {
    const values: Array<string | number | null> = []
    for (const cell of Array.from(row.getElementsByTagName('c'))) {
      const index = columnIndex(cell.getAttribute('r') ?? '')
      const type = cell.getAttribute('t')
      const raw = cell.getElementsByTagName('v')[0]?.textContent ?? ''
      let value: string | number | null = raw
      if (type === 's') value = shared[Number(raw)] ?? ''
      else if (type === 'inlineStr') value = cell.getElementsByTagName('t')[0]?.textContent ?? ''
      else if (type === 'b') value = raw === '1' ? 1 : 0
      else if (raw !== '' && Number.isFinite(Number(raw))) value = Number(raw)
      values[index] = value
    }
    return values
  })
}

function csvGrid(text: string): Grid {
  const source = text.replace(/^\uFEFF/, '')
  const firstLine = source.split(/\r?\n/, 1)[0] ?? ''
  const delimiter = [',', ';', '\t', '|'].reduce((best, candidate) =>
    firstLine.split(candidate).length > firstLine.split(best).length ? candidate : best, ',')
  const rows: string[][] = []
  let row: string[] = []
  let cell = ''
  let quoted = false
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index]
    if (character === '"') {
      if (quoted && source[index + 1] === '"') { cell += '"'; index += 1 }
      else quoted = !quoted
    } else if (character === delimiter && !quoted) {
      row.push(cell); cell = ''
    } else if ((character === '\r' || character === '\n') && !quoted) {
      if (character === '\r' && source[index + 1] === '\n') index += 1
      row.push(cell)
      if (row.some((value) => value.trim())) rows.push(row)
      row = []; cell = ''
    } else cell += character
  }
  if (quoted) throw new Error('Tanda kutip CSV tidak tertutup.')
  row.push(cell)
  if (row.some((value) => value.trim())) rows.push(row)
  return rows
}

function numberValue(value: unknown, label: string, required: boolean) {
  if (value === null || value === undefined || String(value).trim() === '') {
    if (required) throw new Error(`${label} wajib diisi.`)
    return null
  }
  const parsed = typeof value === 'number'
    ? value
    : Number(String(value).trim().replace(/\s|Rp/gi, '').replace(',', '.'))
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error(`${label} harus berupa angka positif.`)
  return parsed
}

function rowsFromGrid(grid: Grid): DistributorPricelistRow[] {
  const headerRowIndex = grid.findIndex((row) => row.some((cell) => normalizeHeader(cell) === 'kodeproduk'))
  if (headerRowIndex < 0) throw new Error('Kolom Kode Produk tidak ditemukan.')
  const headers = grid[headerRowIndex].map(normalizeHeader)
  const positions = Object.fromEntries(Object.entries(requiredHeaders).map(([key, aliases]) => {
    const index = headers.findIndex((header) => (aliases as readonly string[]).includes(header))
    if (index < 0) throw new Error(`Kolom ${aliases[0]} tidak ditemukan.`)
    return [key, index]
  })) as Record<keyof typeof requiredHeaders, number>

  const result: DistributorPricelistRow[] = []
  const seen = new Set<string>()
  for (let index = headerRowIndex + 1; index < grid.length; index += 1) {
    const source = grid[index]
    const sku = String(source[positions.sku] ?? '').trim()
    if (!sku) continue
    const normalizedSku = sku.toUpperCase().replace(/\s+/g, ' ')
    if (seen.has(normalizedSku)) throw new Error(`SKU ${sku} muncul lebih dari satu kali.`)
    seen.add(normalizedSku)
    try {
      result.push({
        rowNumber: index + 1,
        sku,
        productName: String(source[positions.productName] ?? '').trim() || null,
        cogs: numberValue(source[positions.cogs], `COGS baris ${index + 1}`, true) as number,
        retail: numberValue(source[positions.retail], `Retail baris ${index + 1}`, true) as number,
        agentPrice: numberValue(source[positions.agentPrice], `Agen/SM baris ${index + 1}`, false),
        specialPrice: numberValue(source[positions.specialPrice], `Spesial baris ${index + 1}`, false),
        customPrice: numberValue(source[positions.customPrice], `Khusus baris ${index + 1}`, false),
        min60Price: numberValue(source[positions.min60Price], `Min 60 Pack baris ${index + 1}`, false),
        min100Price: numberValue(source[positions.min100Price], `Min 100 Pack baris ${index + 1}`, false),
        min150Price: numberValue(source[positions.min150Price], `Min 150 Pack baris ${index + 1}`, false),
      })
    } catch (error) {
      throw new Error(`SKU ${sku}: ${error instanceof Error ? error.message : 'nilai tidak valid'}`)
    }
  }
  if (!result.length) throw new Error('File tidak memiliki baris Product yang dapat dibaca.')
  if (result.length > 500) throw new Error('Satu file maksimal 500 Product.')
  return result
}

async function checksum(buffer: ArrayBuffer) {
  const digest = await crypto.subtle.digest('SHA-256', buffer)
  return Array.from(new Uint8Array(digest), (value) => value.toString(16).padStart(2, '0')).join('')
}

export async function parseDistributorPricelistFile(file: File) {
  if (file.size > 5 * 1024 * 1024) throw new Error('File maksimal 5 MB.')
  const buffer = await file.arrayBuffer()
  const lowerName = file.name.toLowerCase()
  const grid = lowerName.endsWith('.xlsx')
    ? xlsxGrid(buffer)
    : lowerName.endsWith('.csv')
      ? csvGrid(new TextDecoder().decode(buffer))
      : (() => { throw new Error('Gunakan file .xlsx atau .csv.') })()
  return { fileName: file.name, checksum: await checksum(buffer), rows: rowsFromGrid(grid) }
}
