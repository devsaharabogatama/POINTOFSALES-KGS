import { apiError, requireCaller } from '@/lib/server-auth'

type ImportRequest = { csvText?: string; companyId?: string }

const REQUIRED_HEADERS = [
  'sku',
  'nama_produk',
  'kategori',
  'harga_jual_umum',
  'harga_beli_awal_hpp',
  'satuan_uom',
  'berat_per_uom_kg',
  'stok_awal',
  'kode_gudang',
]

function detectDelimiter(header: string) {
  return (header.match(/;/g)?.length ?? 0) > (header.match(/,/g)?.length ?? 0) ? ';' : ','
}

function parseCsv(text: string, delimiter: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let quoted = false

  for (let index = 0; index < text.length; index += 1) {
    const character = text[index]
    const next = text[index + 1]
    if (character === '"' && quoted && next === '"') {
      field += '"'
      index += 1
    } else if (character === '"') {
      quoted = !quoted
    } else if (character === delimiter && !quoted) {
      row.push(field.trim())
      field = ''
    } else if ((character === '\n' || character === '\r') && !quoted) {
      if (character === '\r' && next === '\n') index += 1
      row.push(field.trim())
      if (row.some(Boolean)) rows.push(row)
      row = []
      field = ''
    } else {
      field += character
    }
  }
  row.push(field.trim())
  if (row.some(Boolean)) rows.push(row)
  return rows
}

function parseNumber(value: string): number {
  const normalized = value.trim().replace(/\s/g, '')
  if (!normalized) return 0
  const decimal = normalized.includes(',')
    ? normalized.replace(/\./g, '').replace(',', '.')
    : normalized
  const result = Number(decimal)
  if (!Number.isFinite(result)) throw new Error(`INVALID_NUMBER: ${value}`)
  return result
}

export async function POST(request: Request) {
  try {
    const caller = await requireCaller(request)
    const { csvText, companyId } = (await request.json()) as ImportRequest
    if (!csvText || !companyId) {
      return Response.json({ error: 'CSV_AND_COMPANY_REQUIRED' }, { status: 400 })
    }

    const firstLine = csvText.split(/\r?\n/, 1)[0] ?? ''
    const delimiter = detectDelimiter(firstLine)
    const parsed = parseCsv(csvText.replace(/^\uFEFF/, ''), delimiter)
    if (parsed.length < 2) {
      return Response.json({ error: 'CSV_HAS_NO_DATA_ROWS' }, { status: 400 })
    }

    const headers = parsed[0].map((header) => header.trim().toLowerCase())
    const missing = REQUIRED_HEADERS.filter((header) => !headers.includes(header))
    if (missing.length) {
      return Response.json({ error: `MISSING_HEADERS: ${missing.join(', ')}` }, { status: 400 })
    }

    const at = (row: string[], header: string) => row[headers.indexOf(header)] ?? ''
    const rows = parsed.slice(1).map((row, index) => {
      if (row.length !== headers.length) throw new Error(`COLUMN_MISMATCH_AT_ROW_${index + 2}`)
      return {
        sku: at(row, 'sku'),
        name: at(row, 'nama_produk'),
        category: at(row, 'kategori'),
        price: parseNumber(at(row, 'harga_jual_umum')),
        cogs: parseNumber(at(row, 'harga_beli_awal_hpp')),
        uom_code: at(row, 'satuan_uom'),
        weight_per_uom_kg: parseNumber(at(row, 'berat_per_uom_kg')),
        initial_stock: parseNumber(at(row, 'stok_awal')),
        warehouse_code: at(row, 'kode_gudang'),
      }
    })

    const duplicateSkus = rows
      .map((row) => row.sku.trim().toUpperCase())
      .filter((sku, index, list) => list.indexOf(sku) !== index)
    if (duplicateSkus.length) {
      return Response.json(
        { error: `DUPLICATE_SKU_IN_FILE: ${[...new Set(duplicateSkus)].join(', ')}` },
        { status: 400 },
      )
    }

    const { data, error } = await caller.client.rpc('import_products_for_company', {
      p_company_id: companyId,
      p_rows: rows,
    })
    if (error) return Response.json({ error: error.message }, { status: 400 })

    return Response.json({ success: true, result: data })
  } catch (error) {
    return apiError(error)
  }
}
