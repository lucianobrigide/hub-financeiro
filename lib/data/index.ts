import type { DataProvider } from "./types";
import { mockProvider } from "./mock";
import { supabaseProvider } from "./supabase";

// Mock é o DEFAULT. O provider real (Supabase/ML) só entra quando
// DATA_SOURCE=supabase — permite testar lado a lado sem trocar o padrão.
export const dataProvider: DataProvider =
  process.env.DATA_SOURCE === "supabase" ? supabaseProvider : mockProvider;
