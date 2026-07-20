import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "KGS Backoffice Dashboard",
  description: "Dashboard Manajemen ERP KGS - Point of Sales, Stok Multi-Warehouse, & Accounting Double-Entry.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="id" className="h-full antialiased">
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
