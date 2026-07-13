import Dexie, { type Table } from 'dexie';

export interface LocalProduct {
  id: string;
  sku: string;
  name: string;
  category: string;
  vendor?: string;
  merk?: string;
  price: number;
  cogs: number;
  uom: string;
  is_bundle: boolean;
  is_active: boolean;
  stock: number;
}

export interface LocalCustomer {
  id: string;
  code: string;
  name: string;
  phone?: string;
  address?: string;
  current_balance: number;
  credit_limit: number;
}

export interface LocalWarehouse {
  id: string;
  code: string;
  name: string;
  is_active: boolean;
}

export interface LocalCashierSession {
  id: string;
  session_code: string;
  cashier_id: string;
  opened_at: string;
  closed_at?: string;
  opening_balance: number;
  expected_cash: number;
  actual_cash: number;
  difference: number;
  status: 'OPEN' | 'CLOSED';
}

export interface LocalSalesHeader {
  id: string;
  invoice_no: string;
  session_id: string;
  customer_id?: string;
  transaction_date: string;
  is_tempo: boolean;
  due_date?: string;
  subtotal: number;
  item_discount: number;
  global_discount: number;
  grand_total: number;
  paid_amount: number;
  sisa_piutang: number;
  payment_status: 'DRAFT' | 'UNPAID' | 'PARTIAL' | 'PAID';
  created_by: string;
  is_synced: number; // 0 = false, 1 = true
  payload_snapshot: string; // JSON string of complete POS payload
}

export interface LocalSalesDetail {
  id: string;
  sales_id: string;
  product_id: string;
  warehouse_id: string;
  qty: number;
  price: number;
  discount_amount: number;
  subtotal: number;
  cogs_unit: number;
  cogs_total: number;
}

export interface LocalSalesPayment {
  id: string;
  payment_no: string;
  sales_id: string;
  payment_date: string;
  session_id: string;
  payment_method: 'Cash' | 'Transfer' | 'QRIS' | 'Customer_Balance';
  amount: number;
  balance_before: number;
  balance_after: number;
  is_reversal: boolean;
  is_synced: number; // 0 = false, 1 = true
}

export class KGSPOSDatabase extends Dexie {
  products!: Table<LocalProduct>;
  customers!: Table<LocalCustomer>;
  warehouses!: Table<LocalWarehouse>;
  cashier_sessions!: Table<LocalCashierSession>;
  sales_headers!: Table<LocalSalesHeader>;
  sales_details!: Table<LocalSalesDetail>;
  sales_payments!: Table<LocalSalesPayment>;

  constructor() {
    super('KGSPOSDatabase');
    this.version(1).stores({
      products: 'id, sku, name, category, is_active',
      customers: 'id, code, name',
      warehouses: 'id, code, is_active',
      cashier_sessions: 'id, session_code, status',
      sales_headers: 'id, invoice_no, session_id, customer_id, is_synced, transaction_date',
      sales_details: 'id, sales_id, product_id, warehouse_id',
      sales_payments: 'id, payment_no, sales_id, session_id, is_synced',
    });
  }
}

export const db = new KGSPOSDatabase();
