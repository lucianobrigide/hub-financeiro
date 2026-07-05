"use client";

import { createContext, useContext, useState, useTransition, type ReactNode } from "react";
import type { DashboardData, Month } from "@/lib/data/types";
import { fetchDashboardAction } from "@/app/actions";

interface DashboardCtx {
  data: DashboardData;
  month: string;
  months: Month[];
  isPending: boolean;
  changeMonth: (m: string) => void;
}

const Ctx = createContext<DashboardCtx>(null!);

export function useDashboard() {
  return useContext(Ctx);
}

export function DashboardProvider({
  initialData,
  months,
  initialMonth,
  children,
}: {
  initialData: DashboardData;
  months: Month[];
  initialMonth?: string;
  children: ReactNode;
}) {
  const [data, setData] = useState(initialData);
  const [month, setMonth] = useState(initialMonth ?? months[0]?.value ?? "");
  const [isPending, startTransition] = useTransition();

  function changeMonth(m: string) {
    setMonth(m);
    startTransition(async () => {
      const d = await fetchDashboardAction(m);
      setData(d);
    });
  }

  return (
    <Ctx value={{ data, month, months, isPending, changeMonth }}>
      {children}
    </Ctx>
  );
}
