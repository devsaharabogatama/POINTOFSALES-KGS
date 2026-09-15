// Explicit test-only received quantities, no database or Production writes.
// Matches the observed12 saved/null-destination/positive-remaining source shape.
import assert from 'node:assert/strict'
import { buildForm } from '../src/lib/goods-receipt-form.ts'
const quantities = [60,30,20,60,20,240,100,140,20,140,40,40]
const order = { id:'PO-test',order_no:'PO-test',supplier_name:'Supplier',status:'CONFIRMED',expected_date:null }
const draft = { id:'GR-test',receipt_no:'GR-test',supplier_order_id:order.id,
  supplier_delivery_no:'11092026',notes:'OK',master_version:7,received_by:'actor',
  warehouse_id:'warehouse-A',warehouse_name:'Gudang A',line_count:12 }
const orderLines = quantities.map((qty,index) => ({ id:`line-${index}`,document_id:order.id,
  product_id:'product',ordered_uom_id:'base',ordered_qty:qty,
  product_name_snapshot:`Product ${index}`,ordered_uom_name_snapshot:'Unit',
  destination_warehouse_id:null,remaining_base_qty:qty }))
const saved = orderLines.map((line,index) => ({ document_id:draft.id,client_line_key:`key-${index}`,
  supplier_order_line_id:line.id,received_uom_id:'base',received_qty:index+3,
  accepted_good_qty:index+1,damaged_qty:1,rejected_qty:1 }))
const productUoms = [{ product_id:'product',uom_id:'base',factor_to_base:1,
  uom_name:'Unit',allow_decimal:false,decimal_precision:0 },
  { product_id:'product',uom_id:'box',factor_to_base:10,uom_name:'Box',allow_decimal:false,decimal_precision:0 }]
const workspace = { orders:[order],drafts:[draft],orderLines,draftLines:saved,productUoms }
const before = JSON.stringify(workspace)
const form = buildForm(workspace,order,draft)
assert.equal(form.lines.length,12)
for (const [index,row] of form.lines.entries()) {
  assert.equal(row.key,saved[index].client_line_key)
  assert.equal(row.sourceId,saved[index].supplier_order_line_id)
  assert.equal(row.uomId,saved[index].received_uom_id)
  assert.equal(row.received,String(saved[index].received_qty))
  assert.equal(row.good,String(saved[index].accepted_good_qty))
  assert.equal(row.damaged,'1'); assert.equal(row.rejected,'1'); assert.equal(row.detailed,true)
}
assert.equal(form.deliveryNo,'11092026'); assert.equal(form.notes,'OK')
assert.equal(form.draft.master_version,7); assert.equal(JSON.stringify(workspace),before)
const other = { ...draft,id:'GR-other',warehouse_id:'warehouse-B' }
assert.equal(buildForm(workspace,order,other).lines.length,0)
assert.deepEqual([draft,other].map(item => buildForm(workspace,order,item).lines.length),[12,0])
const changed = { ...workspace,orderLines:orderLines.map(line => ({ ...line,
  remaining_base_qty:0,destination_warehouse_id:'warehouse-B' })) }
assert.equal(buildForm(changed,order,draft).lines.length,12)
assert.equal(buildForm({ ...workspace,orderLines:orderLines.map(line => ({ ...line,document_id:'other-PO' })) },order,draft).lines.length,0)
const pending = { ...workspace,draftLines:[],orderLines:[
  { ...orderLines[0],destination_warehouse_id:'warehouse-A',ordered_uom_id:'box',remaining_base_qty:20 },
  { ...orderLines[1],destination_warehouse_id:'warehouse-A',ordered_uom_id:'box',remaining_base_qty:3 },
  { ...orderLines[2],destination_warehouse_id:'warehouse-B' },
  { ...orderLines[3],destination_warehouse_id:'warehouse-A',remaining_base_qty:0 },orderLines[4]] }
const fresh = buildForm(pending,order,{ ...draft,line_count:0 })
assert.equal(fresh.lines.length,2)
assert.equal(fresh.lines[0].uomId,'box'); assert.equal(fresh.lines[0].received,'2')
assert.equal(fresh.lines[1].uomId,'base'); assert.equal(fresh.lines[1].received,'3')
fresh.lines[0].received='1'; assert.equal(fresh.lines[0].received,'1')
console.log('PASS:12 saved legacy lines; qty/UOM/dispositions/notes preserved; single/bulk isolation; zero remaining; unsaved Warehouse/PO boundaries; autofill/edit; source unmodified')
