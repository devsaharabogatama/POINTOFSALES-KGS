import { db } from './db';
import type { LocalProduct, LocalCustomer, LocalWarehouse, LocalSalesHeader } from './db';
import { supabase } from './supabase';

/**
 * Downloads products, customers, and warehouses from Supabase 
 * and caches them into Dexie IndexedDB.
 */
export async function syncMasterData() {
  try {
    console.log('Starting Master Data Sync from Supabase...');

    // 1. Fetch Warehouses
    const { data: warehouses, error: whError } = await supabase
      .from('warehouses')
      .select('*')
      .eq('is_active', true);
    
    if (whError) throw whError;
    if (warehouses) {
      await db.warehouses.clear();
      await db.warehouses.bulkPut(warehouses as LocalWarehouse[]);
      console.log(`Synced ${warehouses.length} warehouses.`);
    }

    // 2. Fetch Products and their multi-warehouse stock levels
    const { data: products, error: prodError } = await supabase
      .from('products')
      .select(`
        *,
        product_stocks(warehouse_id, stock_qty)
      `)
      .eq('is_active', true);

    if (prodError) throw prodError;
    if (products) {
      // Map product stock into simple total stock for PWA
      const mappedProducts: LocalProduct[] = products.map((p: any) => {
        const totalStock = p.product_stocks?.reduce((sum: number, ps: any) => sum + (ps.stock_qty || 0), 0) || 0;
        return {
          id: p.id,
          sku: p.sku,
          name: p.name,
          category: p.category,
          vendor: p.vendor,
          merk: p.merk,
          price: Number(p.price) || 0,
          cogs: Number(p.cogs) || 0,
          uom: p.uom || 'pcs',
          is_bundle: p.is_bundle || false,
          is_active: p.is_active || true,
          stock: totalStock
        };
      });

      await db.products.clear();
      await db.products.bulkPut(mappedProducts);
      console.log(`Synced ${mappedProducts.length} products.`);
    }

    // 3. Fetch Customers
    const { data: customers, error: custError } = await supabase
      .from('customers')
      .select('*');

    if (custError) throw custError;
    if (customers) {
      await db.customers.clear();
      await db.customers.bulkPut(customers as LocalCustomer[]);
      console.log(`Synced ${customers.length} customers.`);
    }

    return { success: true };
  } catch (error) {
    console.error('Failed to sync master data:', error);
    return { success: false, error };
  }
}

/**
 * Saves a checkout transaction locally in IndexedDB as unsynced (is_synced = 0)
 */
export async function saveSaleOffline(
  header: LocalSalesHeader,
  details: any[],
  payments: any[]
) {
  try {
    await db.transaction('rw', [db.sales_headers, db.sales_details, db.sales_payments, db.products], async () => {
      // 1. Insert header (force is_synced to 0)
      await db.sales_headers.put({
        ...header,
        is_synced: 0,
      });

      // 2. Insert details
      await db.sales_details.bulkPut(details);

      // 3. Insert payments
      await db.sales_payments.bulkPut(payments.map(p => ({ ...p, is_synced: 0 })));

      // 4. Update local stock quantity inside IndexedDB
      for (const item of details) {
        const prod = await db.products.get(item.product_id);
        if (prod) {
          await db.products.update(item.product_id, {
            stock: Math.max(0, prod.stock - item.qty)
          });
        }
      }
    });

    console.log('Transaction saved offline successfully.');
    return { success: true };
  } catch (error) {
    console.error('Failed to save offline transaction:', error);
    return { success: false, error };
  }
}

/**
 * Syncs all pending transactions to the backend server endpoint
 */
export async function syncPendingSales(backendUrl: string) {
  try {
    const unsyncedHeaders = await db.sales_headers.where('is_synced').equals(0).toArray();
    if (unsyncedHeaders.length === 0) {
      return { success: true, count: 0 };
    }

    console.log(`Found ${unsyncedHeaders.length} unsynced transactions. Initiating sync...`);
    let syncCount = 0;

    for (const header of unsyncedHeaders) {
      const details = await db.sales_details.where('sales_id').equals(header.id).toArray();
      const payments = await db.sales_payments.where('sales_id').equals(header.id).toArray();

      const payload = {
        header,
        details,
        payments
      };

      // Send to Next.js backoffice sync api
      const response = await fetch(`${backendUrl}/api/pos/sync`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
      });

      if (response.ok) {
        // Success: Delete synced rows from IndexedDB as per blueprint
        await db.transaction('rw', [db.sales_headers, db.sales_details, db.sales_payments], async () => {
          await db.sales_headers.delete(header.id);
          await db.sales_details.where('sales_id').equals(header.id).delete();
          await db.sales_payments.where('sales_id').equals(header.id).delete();
        });
        syncCount++;
      } else {
        const errText = await response.text();
        console.error(`Failed to sync invoice ${header.invoice_no}:`, errText);
        break;
      }
    }

    return { success: true, count: syncCount };
  } catch (error) {
    console.error('Failed to sync pending sales:', error);
    return { success: false, error };
  }
}
