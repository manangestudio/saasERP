/**
 * GEF - GESTÃO FINANCEIRA | AUTH SERVICE
 * JavaScript Puro (Vanilla JS)
 *
 * Autenticação exclusivamente via Supabase Auth.
 * Não existe login local, usuário de demonstração ou senha hardcoded.
 * Se o Supabase rejeitar as credenciais, o acesso é negado.
 */

import { normalizeRole, canSwitchStores } from './permissions.js';
import { db } from './database.js';
import {
  loginWithSupabase,
  registerWithSupabase,
  logoutWithSupabase,
  restoreSupabaseSession,
  isSupabaseConfigured
} from './supabase.js';

class AuthService {
  constructor() {
    this.currentUser = null;
    this.listeners = new Set();
    // Promise resolvida quando a sessão (se existir) já foi restaurada do Supabase.
    // app.js deve aguardar `await auth.ready` antes de decidir se mostra login ou app.
    this.ready = this.init();
  }

  async init() {
    try {
      if (!isSupabaseConfigured()) {
        this.currentUser = null;
        return;
      }
      const restored = await restoreSupabaseSession();
      if (restored && restored.user) {
        this.currentUser = restored.user;
      } else {
        this.currentUser = null;
      }
    } catch (err) {
      console.warn('Falha ao restaurar sessão do Supabase:', err);
      this.currentUser = null;
    } finally {
      this.notify();
    }
  }

  subscribe(listener) {
    this.listeners.add(listener);
    listener(this.currentUser);
    return () => this.listeners.delete(listener);
  }

  notify() {
    this.listeners.forEach(fn => fn(this.currentUser));
  }

  getCurrentUser() {
    return this.currentUser;
  }

  isAuthenticated() {
    return !!this.currentUser && this.currentUser.active !== false;
  }

  _applyCurrentStore(user) {
    if (!user) return;
    if (user.role === 'SUPERADMIN') {
      db.setCurrentStoreId('ALL');
    } else if (user.storeId && user.storeId !== 'ALL') {
      db.setCurrentStoreId(user.storeId);
    }
  }

  async signIn(email, password) {
    const cleanEmail = (email || '').trim().toLowerCase();
    const cleanPassword = (password || '').trim();

    if (!cleanEmail || !cleanPassword) {
      return { success: false, error: 'Por favor, informe o e-mail e a senha de acesso.' };
    }

    if (!isSupabaseConfigured()) {
      return {
        success: false,
        error: 'Supabase ainda não configurado. Defina SUPABASE_URL e SUPABASE_ANON_KEY em js/config.js.'
      };
    }

    try {
      const supaRes = await loginWithSupabase(cleanEmail, cleanPassword);
      if (supaRes.success && supaRes.user) {
        this.currentUser = supaRes.user;
        this._applyCurrentStore(this.currentUser);
        this.notify();
        return { success: true, user: this.currentUser };
      }
      // Credenciais rejeitadas pelo Supabase: NUNCA improvisar acesso.
      return { success: false, error: supaRes.error || 'Credenciais inválidas.' };
    } catch (err) {
      console.warn('Falha no Supabase signIn:', err);
      return { success: false, error: 'Falha ao autenticar no Supabase: ' + (err.message || 'Erro de conexão.') };
    }
  }

  async signUp(email, password, fullName, role = 'CASHIER', storeId = 'store-001') {
    if (!isSupabaseConfigured()) {
      return { success: false, error: 'Supabase ainda não configurado. Defina SUPABASE_URL e SUPABASE_ANON_KEY em js/config.js.' };
    }

    const normalizedRole = normalizeRole(role, null, email);
    const targetStoreId = normalizedRole === 'SUPERADMIN' ? 'ALL' : storeId;

    const supaRes = await registerWithSupabase(email, password, fullName, normalizedRole, targetStoreId);
    if (!supaRes.success) {
      return { success: false, error: supaRes.error };
    }

    // O Supabase pode exigir confirmação de e-mail antes de liberar sessão.
    if (supaRes.session && supaRes.user) {
      const loginRes = await loginWithSupabase(email, password);
      if (loginRes.success) {
        this.currentUser = loginRes.user;
        this._applyCurrentStore(this.currentUser);
        this.notify();
        return { success: true, user: this.currentUser };
      }
    }

    return { success: true, user: null, pendingConfirmation: true };
  }

  async switchActiveStore(storeId) {
    if (!this.currentUser) return;
    if (!canSwitchStores(this.currentUser)) {
      console.warn('Troca de loja não autorizada para esta função.');
      return;
    }
    const stores = await db.getStores();
    const assignedStore = stores.find(s => s.id === storeId);
    const storeName = storeId === 'ALL'
      ? 'Todas as Filiais (Consolidado)'
      : (assignedStore?.tradeName || assignedStore?.name || 'Loja Ativa');

    this.currentUser = {
      ...this.currentUser,
      storeId,
      storeName
    };
    db.setCurrentStoreId(storeId);
    this.notify();
  }

  async signOut() {
    this.currentUser = null;
    await logoutWithSupabase();
    this.notify();
  }
}

export const auth = new AuthService();
