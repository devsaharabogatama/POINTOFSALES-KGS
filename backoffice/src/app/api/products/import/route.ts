import { NextResponse } from 'next/server'
import { supabase } from '@/lib/supabase'

export async function POST(request: Request) {
  try {
    const { csvText } = await request.json()
    if (!csvText) {
      return NextResponse.json({ error: 'CSV data is required.' }, { status: 400 })
    }

    const lines = csvText.split('\n').map((line: string) => line.trim()).filter(Boolean)
    if (lines.length <= 1) {
      return NextResponse.json({ error: 'CSV file contains no data rows.' }, { status: 400 })
    }

    // Robust CSV parser supporting commas and semicolons (Indonesian Excel standard)
    const firstLine = lines[0]
    const commaCount = (firstLine.match(/,/g) || []).length
    const semicolonCount = (firstLine.match(/;/g) || []).length
    const delimiter = commaCount >= semicolonCount ? ',' : ';'

    const parseCSVRow = (text: string, delim: string): string[] => {
      const result = []
      let insideQuote = false
      let currentField = ''
      for (let idx = 0; idx < text.length; idx++) {
        const char = text[idx]
        if (char === '"') {
          insideQuote = !insideQuote
        } else if (char === delim && !insideQuote) {
          result.push(currentField.trim())
          currentField = ''
        } else {
          currentField += char
        }
      }
      result.push(currentField.trim())
      return result.map(f => f.replace(/^"|"$/g, ''))
    }

    const headers = parseCSVRow(firstLine, delimiter).map((h: string) => h.toLowerCase())
    
    // Check if essential headers are present
    const requiredHeaders = ['sku', 'nama_produk', 'kategori', 'harga_jual_umum', 'harga_beli_awal_hpp', 'satuan_uom', 'stok_awal', 'kode_gudang']
    const missingHeaders = requiredHeaders.filter(rh => !headers.includes(rh))
    if (missingHeaders.length > 0) {
      return NextResponse.json({ error: `Missing required headers: ${missingHeaders.join(', ')}. Detected delimiter: "${delimiter}"` }, { status: 400 })
    }

    const skuIdx = headers.indexOf('sku')
    const nameIdx = headers.indexOf('nama_produk')
    const catIdx = headers.indexOf('kategori')
    const priceIdx = headers.indexOf('harga_jual_umum')
    const cogsIdx = headers.indexOf('harga_beli_awal_hpp')
    const uomIdx = headers.indexOf('satuan_uom')
    const stockIdx = headers.indexOf('stok_awal')
    const whIdx = headers.indexOf('kode_gudang')

    const importResults = []
    let successCount = 0
    let failureCount = 0

    // Process rows sequentially
    for (let i = 1; i < lines.length; i++) {
      const row = parseCSVRow(lines[i], delimiter)
      if (row.length < headers.length) {
        failureCount++
        importResults.push({ row: i, sku: row[skuIdx] || 'UNKNOWN', status: 'FAILED', reason: 'Column length mismatch' })
        continue
      }

      const sku = row[skuIdx]
      const name = row[nameIdx]
      const category = row[catIdx]
      const price = Number(row[priceIdx]) || 0
      const cogs = Number(row[cogsIdx]) || 0
      const uomCode = row[uomIdx].toUpperCase()
      const initialStock = Number(row[stockIdx]) || 0
      const warehouseCode = row[whIdx].toUpperCase()

      try {
        // 1. Get or create UOM
        let uomId = null
        const { data: existingUom } = await supabase.from('uoms').select('id').eq('code', uomCode).single()
        if (existingUom) {
          uomId = existingUom.id
        } else {
          const { data: newUom, error: uomErr } = await supabase
            .from('uoms')
            .insert({ code: uomCode, name: uomCode })
            .select('id')
            .single()
          if (uomErr) throw uomErr
          uomId = newUom.id
        }

        // 2. Upsert Product
        let productId = null
        const { data: existingProduct } = await supabase.from('products').select('id').eq('sku', sku).single()
        if (existingProduct) {
          productId = existingProduct.id
          await supabase.from('products').update({
            name, category, price, cogs, uom: uomCode, uom_id: uomId
          }).eq('id', productId)
        } else {
          const { data: newProduct, error: prodErr } = await supabase
            .from('products')
            .insert({ sku, name, category, price, cogs, uom: uomCode, uom_id: uomId })
            .select('id')
            .single()
          if (prodErr) throw prodErr
          productId = newProduct.id
        }

        // 3. Find or Create Warehouse
        let warehouseId = null
        const { data: existingWh } = await supabase.from('warehouses').select('id').eq('code', warehouseCode).single()
        if (existingWh) {
          warehouseId = existingWh.id
        } else {
          const { data: newWh, error: whErr } = await supabase
            .from('warehouses')
            .insert({ code: warehouseCode, name: `Gudang ${warehouseCode}` })
            .select('id')
            .single()
          if (whErr) throw whErr
          warehouseId = newWh.id
        }

        // 4. Upsert Product Stock
        const { data: existingStock } = await supabase
          .from('product_stocks')
          .select('id, stock_qty')
          .eq('product_id', productId)
          .eq('warehouse_id', warehouseId)
          .single()
        
        if (existingStock) {
          await supabase.from('product_stocks').update({
            stock_qty: existingStock.stock_qty + initialStock,
            updated_at: new Date().toISOString()
          }).eq('id', existingStock.id)
        } else {
          await supabase.from('product_stocks').insert({
            product_id: productId,
            warehouse_id: warehouseId,
            stock_qty: initialStock
          })
        }

        // 5. Create Initial FIFO batch if stock > 0
        if (initialStock > 0) {
          const { data: batch, error: batchErr } = await supabase.from('product_batches').insert({
            product_id: productId,
            warehouse_id: warehouseId,
            qty_purchased: initialStock,
            qty_remaining: initialStock,
            cogs_unit: cogs
          }).select('id').single()

          if (batchErr) throw batchErr

          // 6. Log Stock Movement
          await supabase.from('stock_movements').insert({
            product_id: productId,
            warehouse_id: warehouseId,
            qty_change: initialStock,
            movement_type: 'PURCHASE',
            reference_table: 'product_batches',
            reference_id: batch.id
          })
        }

        successCount++
        importResults.push({ row: i, sku, status: 'SUCCESS' })
      } catch (err: any) {
        console.error(`Error importing row ${i}:`, err)
        failureCount++
        importResults.push({ row: i, sku, status: 'FAILED', reason: err.message })
      }
    }

    return NextResponse.json({
      success: true,
      processed: lines.length - 1,
      successCount,
      failureCount,
      details: importResults
    })
  } catch (error: any) {
    console.error('Import API error:', error)
    return NextResponse.json({ error: error.message }, { status: 500 })
  }
}
