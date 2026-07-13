interface ReceiptItem {
  product: {
    name: string;
    price: number;
  };
  quantity: number;
}

interface ReceiptData {
  invoiceNo: string;
  items: ReceiptItem[];
  subtotal: number;
  grandTotal: number;
  paidAmount: number;
  change: number;
  paymentMethod: string;
  date: string;
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
   * If not connected, downloads receipt as plain text file for preview.
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
    receipt += '--------------------------------\n';
    receipt += LEFT;
    receipt += `Inv No: ${data.invoiceNo}\n`;
    receipt += `Tgl   : ${data.date}\n`;
    receipt += `Kasir : Kasir KGS\n`;
    receipt += '--------------------------------\n';
    
    data.items.forEach(item => {
      const lineTotal = item.product.price * item.quantity;
      // Item name and line total
      receipt += `${item.product.name.slice(0, 20)}\n`;
      receipt += `  ${item.quantity} x Rp ${item.product.price.toLocaleString('id-ID')} = Rp ${lineTotal.toLocaleString('id-ID')}\n`;
    });
    
    receipt += '--------------------------------\n';
    receipt += `Subtotal  : Rp ${data.subtotal.toLocaleString('id-ID')}\n`;
    receipt += BOLD_ON + `Grand Tot : Rp ${data.grandTotal.toLocaleString('id-ID')}\n` + BOLD_OFF;
    receipt += `Metode    : ${data.paymentMethod}\n`;
    receipt += `Bayar     : Rp ${data.paidAmount.toLocaleString('id-ID')}\n`;
    if (data.paymentMethod === 'Cash') {
      receipt += `Kembali   : Rp ${data.change.toLocaleString('id-ID')}\n`;
    }
    receipt += '--------------------------------\n';
    receipt += CENTER + 'Terima Kasih atas Kunjungan Anda\n';
    receipt += 'Powered by KGS Mini-ERP\n\n\n\n';
    receipt += FEED_CUT;

    // 2. Transmit via Bluetooth if connected, otherwise download text mockup
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
        this.downloadMockupText(data);
      }
    } else {
      console.log('No Bluetooth Printer connected. Triggering fallback download mockup...');
      this.downloadMockupText(data);
    }
  }

  /**
   * Fallback for development: Download the receipt as a text file
   */
  private downloadMockupText(data: ReceiptData) {
    let text = '=== STRUK PEMBELIAN KGS ===\n';
    text += 'Pasar Raya Padang\n';
    text += '==========================\n';
    text += `No Invoice : ${data.invoiceNo}\n`;
    text += `Tanggal    : ${data.date}\n`;
    text += `Kasir      : Kasir KGS\n`;
    text += '--------------------------\n';
    
    data.items.forEach(item => {
      text += `${item.product.name}\n`;
      text += `  ${item.quantity} x Rp ${item.product.price} = Rp ${item.product.price * item.quantity}\n`;
    });
    
    text += '--------------------------\n';
    text += `Subtotal   : Rp ${data.subtotal}\n`;
    text += `Grand Total: Rp ${data.grandTotal}\n`;
    text += `Metode     : ${data.paymentMethod}\n`;
    text += `Bayar      : Rp ${data.paidAmount}\n`;
    if (data.paymentMethod === 'Cash') {
      text += `Kembali    : Rp ${data.change}\n`;
    }
    text += '==========================\n';
    text += 'Terima Kasih atas Kunjungan Anda!\n';

    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `Struk-${data.invoiceNo}.txt`;
    link.click();
    URL.revokeObjectURL(url);
  }
}

export const printer = new ESCPOSPrinter();
