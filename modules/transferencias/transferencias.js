/**
 * GEF - GESTÃO FINANCEIRA | TRANSFERÊNCIAS INTERNAS DE ESTOQUE
 * Histórico real (tabela transfers) + nova transferência via RPC fn_transfer_stock.
 */

import { db } from '../../js/core/database.js';
import { showToast } from '../../js/components/toast.js';
import { openTransferModal } from '../../js/components/transfer-modal.js';
import { escapeHtml, formatDateTime } from '../../js/core/utils.js';

export async function initTransferenciasModule(container) {
  const storeId = db.getCurrentStoreId();

  if (!storeId || storeId === 'ALL') {
    container.innerHTML = `<div class="card" style="padding: 24px; text-align: center; color: #94a3b8;">
      Selecione uma loja específica na barra superior para ver e registrar transferências.</div>`;
    return;
  }

  const render = async () => {
    container.innerHTML = `<div class="card" style="padding: 24px; color: #94a3b8;">Carregando transferências...</div>`;
    let transfers = [];
    let products = [];
    try {
      [transfers, products] = await Promise.all([db.getTransfers(storeId), db.getProducts(storeId)]);
    } catch (err) {
      container.innerHTML = `<div class="card" style="padding: 24px; color: #fca5a5;">${escapeHtml(err.message || 'Falha ao carregar transferências.')}
        <div style="margin-top: 12px;"><button class="btn btn-secondary" id="btn-tr-retry">Tentar novamente</button></div></div>`;
      container.querySelector('#btn-tr-retry').onclick = () => render();
      return;
    }
    const nameOf = (id) => products.find(p => p.id === id)?.name || id;
    const unitOf = (id) => products.find(p => p.id === id)?.baseUnit || '';

    container.innerHTML = `
      <div style="display: flex; flex-direction: column; gap: 16px;">
        <div class="card" style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; padding: 14px 20px;">
          <div>
            <h2 style="font-size: 18px; font-weight: 800; color: #f8fafc; margin: 0;">Transferências Internas</h2>
            <div style="font-size: 11px; color: #94a3b8; margin-top: 2px;">Movimentação entre Armazém, Loja e Pátio com histórico e auditoria.</div>
          </div>
          <button class="btn btn-primary" id="btn-new-transfer">Nova Transferência</button>
        </div>
        <div class="card" style="padding: 0; overflow: hidden;">
          <div style="overflow-x: auto;">
            <table class="data-table">
              <thead><tr><th>Data</th><th>Produto</th><th>Quantidade</th><th>Origem</th><th>Destino</th><th>Observação</th></tr></thead>
              <tbody>
                ${transfers.length === 0 ? `<tr><td colspan="6" style="text-align: center; color: #64748b; padding: 32px;">Não existem transferências registradas.</td></tr>` :
                  transfers.map(t => `
                    <tr>
                      <td>${formatDateTime(t.createdAt)}</td>
                      <td style="font-weight: 700; color: #f8fafc;">${escapeHtml(nameOf(t.productId))}</td>
                      <td style="font-family: var(--font-mono);">${t.quantityBase} ${escapeHtml(unitOf(t.productId))}</td>
                      <td>${escapeHtml(t.fromLocation)}</td>
                      <td>${escapeHtml(t.toLocation)}</td>
                      <td style="font-size: 11px; color: #94a3b8;">${escapeHtml(t.notes || '')}</td>
                    </tr>`).join('')}
              </tbody>
            </table>
          </div>
        </div>
      </div>`;

    container.querySelector('#btn-new-transfer').onclick = () => {
      openTransferModal({ onSuccess: () => render() }).catch(err => showToast(err.message, 'error'));
    };
  };

  await render();
}
