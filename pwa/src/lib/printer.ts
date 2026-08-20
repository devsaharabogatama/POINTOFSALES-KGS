interface ReceiptItem {
  product: {
    name: string;
    price: number;
  };
  quantity: number;
  lineTotal?: number;
}

interface ReceiptData {
  invoiceNo: string;
  items: ReceiptItem[];
  subtotal: number;
  grandTotal: number;
  paidAmount: number;
  change: number;
  customerBalanceCredit?: number;
  customerBalanceUsage?: number;
  paymentMethod: string;
  date: string;
  documentLabel?: string;
  warning?: string;
}

function escapeHtml(value: string) {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#039;',
      })[character] ?? character,
  );
}

function rupiah(value: number) {
  return `Rp ${Math.round(value).toLocaleString('id-ID')}`;
}

export class ESCPOSPrinter {
  private device: any = null;
  private characteristic: any = null;

  /**
   * Request Bluetooth device and connect to thermal printer
   */
  async connect(): Promise<boolean> {
    try {
      if (!(navigator as any).bluetooth) {
        throw new Error('Web Bluetooth is not supported in this browser/environment.');
      }

      console.log('Requesting Bluetooth Printer...');
      
      // Request device with generic printer/serial services
      this.device = await (navigator as any).bluetooth.requestDevice({
        filters: [
          { namePrefix: 'Printer' },
          { namePrefix: 'Thermal' },
          { namePrefix: 'POS' }
        ],
        optionalServices: ['000018f0-0000-1000-8000-00805f9b34fb'] // Common printer service UUID
      });

      console.log('Connecting to GATT Server...');
      const server = await this.device.gatt.connect();
      
      console.log('Getting Primary Service...');
      const service = await server.getPrimaryService('000018f0-0000-1000-8000-00805f9b34fb');
      
      console.log('Getting Characteristic...');
      // Get writing characteristic
      const characteristics = await service.getCharacteristics();
      this.characteristic = characteristics.find((c: any) => c.properties.write || c.properties.writeWithoutResponse);

      if (!this.characteristic) {
        throw new Error('Writing characteristic not found on Bluetooth device.');
      }

      console.log('Bluetooth Printer Connected!');
      return true;
    } catch (error: any) {
      console.error('Bluetooth Connection failed:', error);
      alert(`Gagal koneksi printer bluetooth: ${error.message}`);
      return false;
    }
  }

  /**
   * Disconnects the current printer
   */
  disconnect() {
    if (this.device && this.device.gatt.connected) {
      this.device.gatt.disconnect();
      console.log('Printer disconnected.');
    }
    this.device = null;
    this.characteristic = null;
  }

  /**
   * Format and send receipt to thermal printer.
   * If not connected, opens a printable receipt in a new browser tab.
   */
  async print(data: ReceiptData): Promise<void> {
    const encoder = new TextEncoder();
    
    // ESC/POS Commands
    const ESC = '\x1b';
    const GS = '\x1d';
    const INIT = ESC + '@';
    const CENTER = ESC + 'a' + '\x01';
    const LEFT = ESC + 'a' + '\x00';
    const BOLD_ON = ESC + 'E' + '\x01';
    const BOLD_OFF = ESC + 'E' + '\x00';
    const FEED_CUT = GS + 'V' + '\x41' + '\x03'; // Feed and cut paper

    // 1. Build Receipt Text
    let receipt = '';
    receipt += INIT;
    receipt += CENTER + BOLD_ON + 'KGS MINI-ERP\n' + BOLD_OFF;
    receipt += 'Pasar Raya Padang\n';
    if (data.documentLabel) {
      receipt += BOLD_ON + data.documentLabel.toUpperCase() + '\n' + BOLD_OFF;
    }
    receipt += '--------------------------------\n';
    receipt += LEFT;
    receipt += `Inv No: ${data.invoiceNo}\n`;
    receipt += `Tgl   : ${data.date}\n`;
    receipt += `Kasir : Kasir KGS\n`;
    receipt += '--------------------------------\n';
    
    data.items.forEach(item => {
      const lineTotal = item.lineTotal ?? item.product.price * item.quantity;
      // Item name and line total
      receipt += `${item.product.name.slice(0, 20)}\n`;
      receipt += `  ${item.quantity} x Rp ${item.product.price.toLocaleString('id-ID')} = Rp ${lineTotal.toLocaleString('id-ID')}\n`;
    });
    
    receipt += '--------------------------------\n';
    if (data.warning) {
      receipt += CENTER + BOLD_ON + data.warning + '\n' + BOLD_OFF + LEFT;
      receipt += '--------------------------------\n';
    }
    receipt += `Subtotal  : Rp ${data.subtotal.toLocaleString('id-ID')}\n`;
    receipt += BOLD_ON + `Grand Tot : Rp ${data.grandTotal.toLocaleString('id-ID')}\n` + BOLD_OFF;
    receipt += `Metode    : ${data.paymentMethod}\n`;
    receipt += `Bayar     : Rp ${data.paidAmount.toLocaleString('id-ID')}\n`;
    if (data.change > 0) {
      receipt += `Kembali   : Rp ${data.change.toLocaleString('id-ID')}\n`;
    }
    if ((data.customerBalanceCredit ?? 0) > 0) {
      receipt += `Saldo +   : Rp ${(data.customerBalanceCredit ?? 0).toLocaleString('id-ID')}\n`;
    }
    if ((data.customerBalanceUsage ?? 0) > 0) {
      receipt += `Pakai saldo: Rp ${(data.customerBalanceUsage ?? 0).toLocaleString('id-ID')}\n`;
    }
    receipt += '--------------------------------\n';
    receipt += CENTER + 'Terima Kasih atas Kunjungan Anda\n';
    receipt += 'Powered by KGS Mini-ERP\n\n\n\n';
    receipt += FEED_CUT;

    // 2. Transmit via Bluetooth if connected, otherwise open browser print view
    if (this.characteristic) {
      try {
        console.log('Transmitting print job in chunks...');
        const buffer = encoder.encode(receipt);
        const chunkSize = 20; // Send in 20-byte chunks to avoid buffer overflow on generic print chips
        for (let i = 0; i < buffer.length; i += chunkSize) {
          const chunk = buffer.slice(i, i + chunkSize);
          await this.characteristic.writeValue(chunk);
        }
        console.log('Print completed!');
      } catch (err: any) {
        console.error('Failed to print via Bluetooth:', err);
        this.openPrintableReceipt(data);
      }
    } else {
      console.log('No Bluetooth Printer connected. Opening browser print view...');
      this.openPrintableReceipt(data);
    }
  }

  /**
   * Browser fallback: open a clean thermal receipt and launch print dialog.
   */
  private openPrintableReceipt(data: ReceiptData) {
    const rows = data.items
      .map((item) => {
        const lineTotal =
          item.lineTotal ?? item.product.price * item.quantity;
        return `
          <div class="item">
            <strong>${escapeHtml(item.product.name)}</strong>
            <div class="row muted">
              <span>${item.quantity} x ${rupiah(item.product.price)}</span>
              <span>${rupiah(lineTotal)}</span>
            </div>
          </div>`;
      })
      .join('');
    const change =
      data.change > 0
        ? `<div class="row"><span>Kembali</span><strong>${rupiah(data.change)}</strong></div>`
        : '';
    const customerBalanceCredit =
      (data.customerBalanceCredit ?? 0) > 0
        ? `<div class="row"><span>Masuk Saldo Customer</span><strong>+${rupiah(data.customerBalanceCredit ?? 0)}</strong></div>`
        : '';
    const customerBalanceUsage =
      (data.customerBalanceUsage ?? 0) > 0
        ? `<div class="row"><span>Potongan Saldo Customer</span><strong>-${rupiah(data.customerBalanceUsage ?? 0)}</strong></div>`
        : '';
    const html = `<!doctype html>
<html lang="id">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width,initial-scale=1" />
    <title>Struk ${escapeHtml(data.invoiceNo)}</title>
    <style>
      * { box-sizing: border-box; }
      body { margin: 0; background: #eef2f3; color: #17211f; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      main { width: min(80mm, 100%); min-height: 100vh; margin: 0 auto; background: #fff; padding: 8mm 5mm; }
      h1 { margin: 0; text-align: center; font: 800 20px/1.2 ui-sans-serif, system-ui, sans-serif; letter-spacing: .08em; }
      .subtitle { margin: 4px 0 18px; text-align: center; font-size: 11px; color: #61706d; }
      .rule { border-top: 1px dashed #87938f; margin: 12px 0; }
      .row { display: flex; justify-content: space-between; gap: 12px; margin: 5px 0; }
      .item { margin: 10px 0; font-size: 12px; }
      .muted { color: #53605d; font-size: 11px; }
      .total { font-size: 15px; margin-top: 9px; }
      .thanks { margin-top: 20px; text-align: center; font-size: 11px; line-height: 1.6; }
      .warning { margin: 10px 0 14px; border: 2px solid #b91c1c; padding: 8px; color: #991b1b; text-align: center; font: 800 11px/1.4 ui-sans-serif, system-ui, sans-serif; }
      .actions { position: fixed; right: 18px; bottom: 18px; display: flex; gap: 8px; font-family: ui-sans-serif, system-ui, sans-serif; }
      button { border: 0; border-radius: 12px; padding: 12px 18px; background: #0f766e; color: white; font-weight: 700; cursor: pointer; }
      @media print {
        @page { size: 80mm auto; margin: 0; }
        body, main { width: 80mm; min-height: auto; background: #fff; }
        .actions { display: none; }
      }
    </style>
  </head>
  <body>
    <main>
      <h1>MADS POS</h1>
      <p class="subtitle">${escapeHtml(data.documentLabel ?? 'Struk transaksi')}</p>
      ${
        data.warning
          ? `<div class="warning">${escapeHtml(data.warning)}</div>`
        : ''
      }
      <div class="row"><span>Invoice</span><strong>${escapeHtml(data.invoiceNo)}</strong></div>
      <div class="row"><span>Tanggal</span><span>${escapeHtml(data.date)}</span></div>
      <div class="rule"></div>
      ${rows}
      <div class="rule"></div>
      <div class="row"><span>Subtotal</span><span>${rupiah(data.subtotal)}</span></div>
      <div class="row total"><strong>Total</strong><strong>${rupiah(data.grandTotal)}</strong></div>
      <div class="row"><span>${escapeHtml(data.paymentMethod)}</span><span>${rupiah(data.paidAmount)}</span></div>
      ${change}
      ${customerBalanceCredit}
      ${customerBalanceUsage}
      <div class="rule"></div>
      <p class="thanks">Terima kasih atas kunjungan Anda.<br />Simpan struk ini sebagai bukti transaksi.</p>
    </main>
    <div class="actions"><button type="button" onclick="window.print()">Cetak struk</button></div>
    <script>window.addEventListener('load', () => setTimeout(() => window.print(), 250));</script>
  </body>
</html>`;
    const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const printWindow = window.open(url, '_blank');
    if (!printWindow) {
      URL.revokeObjectURL(url);
      throw new Error('POPUP_BLOCKED');
    }
    window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }
}

export const printer = new ESCPOSPrinter();
