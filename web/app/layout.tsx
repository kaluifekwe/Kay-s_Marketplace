import "./globals.css";
import type { ReactNode } from "react";
import type { Metadata } from "next";
import { APP_NAME } from "@/lib/format";

export const metadata: Metadata = {
  title: APP_NAME,
  description: "Shop trusted vendors with escrow protection.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
