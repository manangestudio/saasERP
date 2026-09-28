/**
 * GEF - GESTÃO FINANCEIRA | LOGIN MODULE
 * JavaScript Puro (Vanilla JS)
 * Autenticação exclusivamente via Supabase Auth. Sem usuários de demonstração.
 */

import { auth } from '../../js/core/auth.js';
import { showToast } from '../../js/components/toast.js';
import { isSupabaseConfigured } from '../../js/core/supabase.js';

export async function initLoginModule(container, onSuccess) {
  const isConnected = isSupabaseConfigured();

  container.innerHTML = `
    <div style="min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 20px; background: #0b0f19;">
      <div style="width: 100%; max-width: 440px; background: #111827; border: 1px solid #1f2937; border-radius: 16px; padding: 32px; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);">
        <!-- Logo & Header -->
        <div style="text-align: center; margin-bottom: 20px;">
          <div style="display: inline-flex; align-items: center; justify-content: center; width: 64px; height: 64px; background: #1e293b; border-radius: 16px; border: 1px solid #334155; margin-bottom: 12px;">
            <img src="../../assets/icons/icon.svg" alt="GEF Logo" style="width: 44px; height: 44px;">
          </div>
          <h1 style="font-size: 20px; font-weight: 900; color: #f8fafc; margin: 0;">GEF - GESTÃO FINANCEIRA</h1>
          <p style="font-size: 12px; color: #94a3b8; margin-top: 4px;">ERP Especializado para Materiais de Construção & Ferragens</p>
        </div>

        ${!isConnected ? `
          <div style="margin-bottom: 16px; background: rgba(239, 68, 68, 0.1); border: 1px solid rgba(239, 68, 68, 0.3); border-radius: 8px; padding: 10px 12px; font-size: 12px; color: #fca5a5;">
            <strong>Supabase não configurado.</strong> Defina <code>SUPABASE_URL</code> e <code>SUPABASE_ANON_KEY</code> em <code>js/config.js</code> antes de publicar.
          </div>
        ` : ''}

        <!-- Form -->
        <form id="form-login" style="display: flex; flex-direction: column; gap: 14px;">
          <div>
            <label style="font-size: 11px; font-weight: 700; color: #cbd5e1; display: block; margin-bottom: 4px;">E-mail Corporativo</label>
            <input type="email" id="login-email" placeholder="seu.email@gef.co.mz" required style="width: 100%; font-size: 13px;">
          </div>
          <div>
            <label style="font-size: 11px; font-weight: 700; color: #cbd5e1; display: block; margin-bottom: 4px;">Senha de Acesso</label>
            <input type="password" id="login-password" placeholder="••••••••" required style="width: 100%; font-size: 13px;">
          </div>

          <button type="submit" class="btn btn-primary" id="btn-submit-login" style="width: 100%; padding: 12px; font-size: 13px; font-weight: 800; margin-top: 6px;" ${!isConnected ? 'disabled' : ''}>
            Acessar Sistema GEF
          </button>
        </form>
      </div>
    </div>
  `;

  const form = container.querySelector('#form-login');
  const submitBtn = container.querySelector('#btn-submit-login');
  form.onsubmit = async (e) => {
    e.preventDefault();
    const email = container.querySelector('#login-email').value;
    const password = container.querySelector('#login-password').value;

    submitBtn.disabled = true;
    submitBtn.textContent = 'Autenticando...';

    try {
      const res = await auth.signIn(email, password);
      if (res.success) {
        showToast(`Bem-vindo, ${res.user.fullName}!`, 'success');
        if (onSuccess) onSuccess(res.user);
      } else {
        showToast(res.error || 'Falha ao autenticar.', 'error');
      }
    } catch (err) {
      showToast(err.message || 'Erro inesperado ao realizar login.', 'error');
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Acessar Sistema GEF';
    }
  };
}
