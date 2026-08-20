import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "MADS Backoffice",
  description: "Management Distribution System untuk Point of Sale, stok multi-warehouse, purchasing, dan finance.",
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
