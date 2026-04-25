import {
  createClient,
  SupabaseClient as DefaultSupabaseClient,
  SupabaseClientOptions,
} from 'https://esm.sh/@supabase/supabase-js@2.49.9';
import { Database } from '@shared/database.ts';

export type SupabaseClient = DefaultSupabaseClient<Database>;

export function getServiceRoleSupabaseClient(
  options?: SupabaseClientOptions<'public'>,
): SupabaseClient {
  return createClient<Database, 'public', Database['public']>(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    {
      ...options,
      auth: { autoRefreshToken: false, persistSession: false },
    },
  );
}

export function getAnonSupabaseClient(
  options?: SupabaseClientOptions<'public'>,
): SupabaseClient {
  return createClient<Database, 'public', Database['public']>(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    options,
  );
}
