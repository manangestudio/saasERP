/**
 * GEF - GESTÃO FINANCEIRA | CONEXÃO SUPABASE & REAL AUTH
 *
 * Suporte a conexão nativa com Supabase:
 * - Login verdadeiro via supabase.auth.signInWithPassword()
 * - Registro via supabase.auth.signUp()
 * - Recuperação do perfil em public.profiles
 * - Persistência automática de sessão (gerida pelo próprio supabase-js)
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from '../config.js';
import { normalizeRole } from './permissions.js';

export function isSupabaseConfigured() {
  return Boolean(
    SUPABASE_URL &&
    !SUPABASE_URL.includes('seu-projeto') &&
    SUPABASE_ANON_KEY &&
    !SUPABASE_ANON_KEY.includes('sua-chave')
  );
}

export let supabase = null;

if (isSupabaseConfigured()) {
  try {
    supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true
      }
    });
  } catch (err) {
    console.warn('Falha ao inicializar cliente Supabase:', err);
    supabase = null;
  }
}

/**
 * Monta o objeto de usuário da aplicação a partir de um `authUser` do Supabase,
 * buscando (e sincronizando) o perfil correspondente em public.profiles.
 */
async function buildAppUser(authUser) {
  const cleanEmail = (authUser.email || '').trim().toLowerCase();

  let profile = null;
  try {
    const { data: profData } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', authUser.id)
      .maybeSingle();

    if (profData) {
      profile = profData;
    } else {
      const { data: profByEmail } = await supabase
        .from('profiles')
        .select('*')
        .ilike('email', cleanEmail)
        .maybeSingle();
      if (profByEmail) profile = profByEmail;
    }
  } catch (e) {
    console.warn('Não foi possível buscar profile no Supabase:', e);
  }

  const userMeta = authUser.user_metadata || {};
  const appMeta = authUser.app_metadata || {};

  // O papel (role) só é confiável quando vem da tabela profiles (protegida por RLS).
  // Metadados do próprio usuário (user_metadata) NÃO são fonte segura de role,
  // pois podem ser alterados pelo próprio usuário via API.
  const rawRole = profile?.role || appMeta.role;
  const role = normalizeRole(rawRole, authUser.id, authUser.email);

  let storeId;
  let storeName;
  if (role === 'SUPERADMIN') {
    storeId = 'ALL';
    storeName = 'Plataforma Global (Monitor & SaaS)';
  } else {
    storeId = profile?.store_id || appMeta.store_id || null;
    try {
      if (storeId) {
        const { data: st } = await supabase.from('stores').select('name, trade_name').eq('id', storeId).maybeSingle();
        storeName = st?.trade_name || st?.name || 'Loja não atribuída';
      } else {
        storeName = 'Loja não atribuída';
      }
    } catch {
      storeName = 'Loja não atribuída';
    }
  }

  const fullName = profile?.full_name || userMeta.full_name || userMeta.name || cleanEmail.split('@')[0];

  return {
    id: authUser.id,
    email: authUser.email,
    fullName,
    role,
    storeId,
    storeName,
    active: profile ? profile.active !== false : true
  };
}

/**
 * Autenticação real com Supabase
 */
export async function loginWithSupabase(email, password) {
  if (!supabase || !isSupabaseConfigured()) {
    return {
      success: false,
      isConfigError: true,
      error: 'Supabase ainda não configurado com URL e Anon Key válidas.'
    };
  }

  const cleanEmail = (email || '').trim().toLowerCase();
  const cleanPassword = (password || '').trim();

  try {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: cleanEmail,
      password: cleanPassword
    });

    if (error) {
      let msg = error.message;
      if (msg.includes('Invalid login credentials')) {
        msg = 'Credenciais inválidas: e-mail ou senha incorretos.';
      } else if (msg.includes('Email not confirmed')) {
        msg = 'E-mail ainda não confirmado. Verifique sua caixa de entrada.';
      }
      return { success: false, error: msg };
    }

    if (!data?.user) {
      return { success: false, error: 'Credenciais inválidas: usuário não retornado pelo Supabase.' };
    }

    const appUser = await buildAppUser(data.user);
    return { success: true, user: appUser, session: data.session };
  } catch (err) {
    return { success: false, error: err.message || 'Falha na conexão com Supabase.' };
  }
}

/**
 * Restaura a sessão já persistida pelo supabase-js (se houver), sem exigir novo login.
 * Chamado uma única vez no arranque da aplicação.
 */
export async function restoreSupabaseSession() {
  if (!supabase || !isSupabaseConfigured()) return null;

  try {
    const { data, error } = await supabase.auth.getSession();
    if (error || !data?.session?.user) return null;

    const appUser = await buildAppUser(data.session.user);
    return { user: appUser, session: data.session };
  } catch (err) {
    console.warn('Falha ao restaurar sessão do Supabase:', err);
    return null;
  }
}

/**
 * Registro de novo usuário com Supabase Auth.
 * O perfil (role, store_id) é criado com valores padrão seguros;
 * a promoção de papéis (ex: ADMIN, GERENTE) deve ser feita por um
 * administrador via painel/RPC, nunca pelo próprio usuário no signup.
 */
export async function registerWithSupabase(email, password, fullName, role = 'CASHIER', storeId = 'store-001') {
  if (!supabase || !isSupabaseConfigured()) {
    return { success: false, error: 'Supabase não configurado.' };
  }

  try {
    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        data: {
          full_name: fullName
        }
      }
    });

    if (error) return { success: false, error: error.message };

    return { success: true, user: data.user, session: data.session };
  } catch (err) {
    return { success: false, error: err.message };
  }
}

/**
 * Logout real no Supabase
 */
export async function logoutWithSupabase() {
  if (supabase && isSupabaseConfigured()) {
    try {
      await supabase.auth.signOut();
    } catch (e) {
      console.warn('Erro ao fazer signOut no Supabase:', e);
    }
  }
}

export default supabase;
