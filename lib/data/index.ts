import { mockProvider } from './mock';
export const dataProvider = mockProvider;
// TODO: trocar por supabaseProvider quando Supabase estiver pronto.
// O frontend nunca verá token — dados virão via Edge Function do Supabase.
