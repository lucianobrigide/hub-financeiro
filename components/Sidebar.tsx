"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { COLORS } from "./ui";

interface NavItem {
  label: string;
  href?: string;
  children?: { label: string; href: string }[];
}

const NAV_ITEMS: NavItem[] = [
  { label: "F.C. Projetado", href: "/fc-projetado" },
  { label: "Previsão de Impostos", href: "/previsao-impostos" },
  { label: "D.R.E", href: "/dre" },
  {
    label: "Marketplaces",
    children: [
      { label: "Mercado Livre", href: "/marketplaces/mercado-livre" },
      { label: "Shopee", href: "/marketplaces/shopee" },
      { label: "TikTok", href: "/marketplaces/tiktok" },
      { label: "Amazon", href: "/marketplaces/amazon" },
      { label: "B2B", href: "/marketplaces/vendas-internas" },
    ],
  },
];

function NavLink({ href, label, active }: { href: string; label: string; active: boolean }) {
  return (
    <Link
      href={href}
      className="block rounded-lg px-3 py-2 text-sm transition-colors"
      style={{
        color: active ? COLORS.cyan : COLORS.muted,
        background: active ? `${COLORS.cyan}10` : "transparent",
        fontWeight: active ? 600 : 400,
      }}
    >
      {label}
    </Link>
  );
}

export function Sidebar() {
  const pathname = usePathname();
  const [marketplacesOpen, setMarketplacesOpen] = useState(
    pathname.startsWith("/marketplaces"),
  );

  return (
    <aside
      className="flex w-[220px] shrink-0 flex-col border-r"
      style={{ borderColor: COLORS.panelBorder, background: COLORS.panel }}
    >
      <div className="border-b p-4" style={{ borderColor: COLORS.panelBorder }}>
        <Link href="/">
          <h1 className="text-sm font-bold" style={{ color: COLORS.cyan }}>
            Hub Financeiro
          </h1>
        </Link>
      </div>

      <nav className="flex-1 overflow-y-auto p-3">
        <ul className="space-y-1">
          {NAV_ITEMS.map((item) => {
            if (item.children) {
              const childActive = item.children.some((c) => pathname === c.href);
              return (
                <li key={item.label}>
                  <button
                    type="button"
                    onClick={() => setMarketplacesOpen((o) => !o)}
                    className="flex w-full items-center justify-between rounded-lg px-3 py-2 text-sm transition-colors"
                    style={{
                      color: childActive || marketplacesOpen ? COLORS.white : COLORS.muted,
                      fontWeight: childActive ? 600 : 400,
                    }}
                  >
                    <span>{item.label}</span>
                    <span
                      className="text-xs transition-transform"
                      style={{
                        transform: marketplacesOpen ? "rotate(90deg)" : "rotate(0deg)",
                        color: COLORS.muted,
                      }}
                    >
                      ▸
                    </span>
                  </button>
                  {marketplacesOpen && (
                    <ul className="mt-1 ml-2 space-y-0.5 border-l pl-2" style={{ borderColor: COLORS.panelBorder }}>
                      {item.children.map((child) => (
                        <li key={child.href}>
                          <NavLink
                            href={child.href}
                            label={child.label}
                            active={pathname === child.href}
                          />
                        </li>
                      ))}
                    </ul>
                  )}
                </li>
              );
            }
            return (
              <li key={item.href}>
                <NavLink
                  href={item.href!}
                  label={item.label}
                  active={pathname === item.href}
                />
              </li>
            );
          })}
        </ul>
      </nav>
    </aside>
  );
}
