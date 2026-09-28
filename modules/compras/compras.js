/**
 * GEF - GESTÃO FINANCEIRA | COMPRAS & FORNECEDORES
 * JavaScript Puro (Vanilla JS)
 * Confirmar uma compra chama a RPC fn_confirm_purchase: entrada de estoque, custo médio,
 * lote, kardex e auditoria acontecem numa única transação no PostgreSQL.
 */

import { db } from '../../js/core/database.js';
import { i18n } from '../../js/core/i18n.js';
import { showToast } from '../../js/components/toast.js';
import { escapeHtml, formatDate, newId } from '../../js/core/utils.js';

const LOCATIONS = [
  { id: 'ARMAZEM', label: 'Armazém' },
  { id: 'LOJA', label: 'Loja (Balcão)' },
  { id: 'PATIO', label: 'Pátio' }
];

export async function initComprasModule(container) {
  const storeId = db.getCurrentStoreId();

  if (!storeId || storeId === 'ALL') {
    container.innerHTML = `
      <div class="card" style="padding: 24px; text-align: center; color: #94a3b8;">
        Selecione uma loja específica na barra superior para registrar compras e fornecedores.
      </div>`;
    return;
  }

  const render = async () => {
    container.innerHTML = `<div class="card" style="padding: 24px; color: #94a3b8;">Carregando compras...</div>`;

    let purchases = [];
    let suppliers = [];
    try {
      [purchases, suppliers] = await Promise.all([db.getPurchases(storeId), db.getSuppliers(storeId)]);
    } catch (err) {
      container.innerHTML = `<div class="card" style="padding: 24px; color: #fca5a5;">
        ${escapeHtml(err.message || 'Não foi possível carregar as compras.')}
        <div style="margin-top: 12px;"><button class="btn btn-secondary" id="btn-compras-retry">Tentar novamente</button></div>
      </div>`;
      container.querySelector('#btn-compras-retry').onclick = () => render();
      return;
    }

    container.innerHTML = `
      <div style="display: flex; flex-direction: column; gap: 16px;">
        <div class="card" style="display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; padding: 14px 20px;">
          <div>
            <h2 style="font-size: 18px; font-weight: 800; color: #f8fafc; margin: 0;">Compras & Fornecedores</h2>
            <div style="font-size: 11px; color: #94a3b8; margin-top: 2px;">Entrada de mercadorias com custo médio, lote/validade e rastreio no kardex.</div>
          </div>
          <div style="display: flex; gap: 8px;">
            <button class="btn btn-secondary" id="btn-new-supplier">Novo Fornecedor</button>
            <button class="btn btn-primary" id="btn-new-purchase">Registrar Compra</button>
          </div>
        </div>

        <div class="card" style="padding: 0; overflow: hidden;">
          <div style="padding: 12px 16px; font-weight: 800; color: #f8fafc;">Compras registradas</div>
          <div style="overflow-x: auto;">
            <table class="data-table">
              <thead><tr><th>Data</th><th>Fornecedor</th><th>Fatura / NF</th><th>Destino</th><th>Total</th><th>Observação</th></tr></thead>
              <tbody>
                ${purchases.length === 0 ? `<tr><td colspan="6" style="text-align: center; color: #64748b; padding: 32px;">Não existem compras registradas.</td></tr>` :
                  purchases.map(p => `
                    <tr>
                      <td>${formatDate(p.createdAt)}</td>
                      <td>${escapeHtml(p.supplierName || '—')}</td>
                      <td style="font-family: var(--font-mono);">${escapeHtml(p.invoiceNumber || '—')}</td>
                      <td>${escapeHtml(p.destinationLocation)}</td>
                      <td style="font-family: var(--font-mono); font-weight: 700;">${i18n.formatMoney(p.totalCost)}</td>
                      <td style="font-size: 11px; color: #94a3b8;">${escapeHtml(p.notes || '')}</td>
                    </tr>`).join('')}
              </tbody>
            </table>
          </div>
        </div>

        <div class="card" style="padding: 0; overflow: hidden;">
          <div style="padding: 12px 16px; font-weight: 800; color: #f8fafc;">Fornecedores</div>
          <div style="overflow-x: auto;">
            <table class="data-table">
              <thead><tr><th>Nome</th><th>Telefone</th><th>E-mail</th><th>NUIT</th><th>Estado</th><th>Ações</th></tr></thead>
              <tbody>
                ${suppliers.length === 0 ? `<tr><td colspan="6" style="text-align: center; color: #64748b; padding: 32px;">Não existem fornecedores cadastrados.</td></tr>` :
                  suppliers.map(s => `
                    <tr>
                      <td style="font-weight: 700; color: #f8fafc;">${escapeHtml(s.name)}</td>
                      <td>${escapeHtml(s.phone || '—')}</td>
                      <td>${escapeHtml(s.email || '—')}</td>
                      <td style="font-family: var(--font-mono);">${escapeHtml(s.nuitNif || '—')}</td>
                      <td><span class="badge ${s.active ? 'badge-emerald' : 'badge-red'}">${s.active ? 'ATIVO' : 'INATIVO'}</span></td>
                      <td><button class="btn btn-secondary btn-edit-supplier" data-id="${escapeHtml(s.id)}" style="padding: 4px 10px; font-size: 11px;">Editar</button></td>
                    </tr>`).join('')}
              </tbody>
            </table>
          </div>
        </div>
      </div>`;

    container.querySelector('#btn-new-supplier').onclick = () => openSupplierModal(null, render);
    container.querySelector('#btn-new-purchase').onclick = () => openPurchaseModal(suppliers, render);
    container.querySelectorAll('.btn-edit-supplier').forEach(btn => {
      btn.onclick = () => openSupplierModal(suppliers.find(s => s.id === btn.dataset.id), render);
    });
  };

  const openSupplierModal = (supplier, onSaved) => {
    const modal = document.createElement('div');
    modal.className = 'modal-backdrop';
    modal.innerHTML = `
      <div class="modal-dialog" style="max-width: 460px;">
        <div class="modal-header"><h3 class="modal-title">${supplier ? 'Editar Fornecedor' : 'Novo Fornecedor'}</h3>
          <button class="modal-close-btn" id="sp-close">✕</button></div>
        <div class="modal-body" style="padding: 16px; display: flex; flex-direction: column; gap: 10px;">
          <input id="sp-name" placeholder="Nome do fornecedor *" value="${escapeHtml(supplier?.name || '')}">
          <input id="sp-phone" placeholder="Telefone" value="${escapeHtml(supplier?.phone || '')}">
          <input id="sp-email" type="email" placeholder="E-mail" value="${escapeHtml(supplier?.email || '')}">
          <input id="sp-nuit" placeholder="NUIT / Documento" value="${escapeHtml(supplier?.nuitNif || '')}">
          <input id="sp-address" placeholder="Endereço" value="${escapeHtml(supplier?.address || '')}">
          <textarea id="sp-notes" rows="2" placeholder="Contatos / observações">${escapeHtml(supplier?.notes || '')}</textarea>
          <label style="font-size: 12px; color: #cbd5e1;"><input type="checkbox" id="sp-active" ${supplier?.active !== false ? 'checked' : ''}> Fornecedor ativo</label>
        </div>
        <div class="modal-footer">
          <button class="btn btn-secondary" id="sp-cancel">Cancelar</button>
          <button class="btn btn-primary" id="sp-save">Salvar</button>
        </div>
      </div>`;
    modal.querySelector('#sp-close').onclick = () => modal.remove();
    modal.querySelector('#sp-cancel').onclick = () => modal.remove();
    modal.querySelector('#sp-save').onclick = async (ev) => {
      const btn = ev.currentTarget;
      const name = modal.querySelector('#sp-name').value.trim();
      if (!name) { showToast('Informe o nome do fornecedor.', 'error'); return; }
      if (btn.disabled) return;
      btn.disabled = true;
      try {
        await db.saveSupplier({
          id: supplier?.id || newId('sup'),
          storeId,
          name,
          phone: modal.querySelector('#sp-phone').value.trim(),
          email: modal.querySelector('#sp-email').value.trim(),
          nuitNif: modal.querySelector('#sp-nuit').value.trim(),
          address: modal.querySelector('#sp-address').value.trim(),
          notes: modal.querySelector('#sp-notes').value.trim(),
          active: modal.querySelector('#sp-active').checked
        });
      } catch (err) {
        btn.disabled = false;
        showToast(err.message || 'Não foi possível salvar o fornecedor. Nenhuma alteração foi registrada.', 'error');
        return;
      }
      showToast('Fornecedor salvo com sucesso.', 'success');
      modal.remove();
      onSaved();
    };
    document.body.appendChild(modal);
  };

  const openPurchaseModal = async (suppliers, onSaved) => {
    let products = [];
    try {
      products = (await db.getProducts(storeId)).filter(p => p.active);
    } catch (err) {
      showToast(err.message || 'Não foi possível carregar os produtos.', 'error');
      return;
    }
    const activeSuppliers = suppliers.filter(s => s.active);
    if (activeSuppliers.length === 0) { showToast('Cadastre um fornecedor ativo antes de registrar uma compra.', 'warning'); return; }
    if (products.length === 0) { showToast('Cadastre produtos antes de registrar uma compra.', 'warning'); return; }

    const productOptions = products.map(p => `<option value="${escapeHtml(p.id)}">${escapeHtml(p.code || '')} — ${escapeHtml(p.name)} (${escapeHtml(p.baseUnit)})</option>`).join('');
    const rowHtml = () => `
      <div class="pu-row" style="display: grid; grid-template-columns: 2fr 1fr 1fr 1fr 1fr 1fr auto; gap: 6px; align-items: center;">
        <select class="pu-prod">${productOptions}</select>
        <input class="pu-qty" type="number" min="0" step="any" placeholder="Qtd (base)">
        <input class="pu-cost" type="number" min="0" step="any" placeholder="Custo unit.">
        <input class="pu-price" type="number" min="0" step="any" placeholder="Novo preço venda">
        <input class="pu-batch" placeholder="Lote">
        <input class="pu-exp" type="date">
        <button class="btn btn-secondary pu-del" style="padding: 4px 8px;">✕</button>
      </div>`;

    const modal = document.createElement('div');
    modal.className = 'modal-backdrop';
    modal.innerHTML = `
      <div class="modal-dialog" style="max-width: 980px;">
        <div class="modal-header"><h3 class="modal-title">Registrar Compra / Entrada de Mercadoria</h3>
          <button class="modal-close-btn" id="pu-close">✕</button></div>
        <div class="modal-body" style="padding: 16px; display: flex; flex-direction: column; gap: 10px;">
          <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px;">
            <select id="pu-supplier">${activeSuppliers.map(s => `<option value="${escapeHtml(s.id)}">${escapeHtml(s.name)}</option>`).join('')}</select>
            <input id="pu-invoice" placeholder="Nº da fatura / NF">
            <select id="pu-dest">${LOCATIONS.map(l => `<option value="${l.id}">${l.label}</option>`).join('')}</select>
          </div>
          <div id="pu-rows" style="display: flex; flex-direction: column; gap: 6px;">${rowHtml()}</div>
          <div><button class="btn btn-secondary" id="pu-add">+ Adicionar item</button></div>
          <textarea id="pu-notes" rows="2" placeholder="Observação"></textarea>
          <div style="text-align: right; font-weight: 800; color: #f8fafc;">Total: <span id="pu-total" style="font-family: var(--font-mono);">0.00</span></div>
        </div>
        <div class="modal-footer">
          <button class="btn btn-secondary" id="pu-cancel">Cancelar</button>
          <button class="btn btn-primary" id="pu-confirm">Confirmar Compra</button>
        </div>
      </div>`;

    const rowsEl = modal.querySelector('#pu-rows');
    const collect = () => [...rowsEl.querySelectorAll('.pu-row')].map(r => ({
      productId: r.querySelector('.pu-prod').value,
      quantityPurchased: parseFloat(r.querySelector('.pu-qty').value) || 0,
      unitCost: parseFloat(r.querySelector('.pu-cost').value) || 0,
      newSalePrice: parseFloat(r.querySelector('.pu-price').value) || null,
      batchNumber: r.querySelector('.pu-batch').value.trim() || null,
      expiryDate: r.querySelector('.pu-exp').value || null
    }));
    const refreshTotal = () => {
      const total = collect().reduce((sum, i) => sum + i.quantityPurchased * i.unitCost, 0);
      modal.querySelector('#pu-total').textContent = total.toFixed(2);
    };
    const bindRow = (row) => {
      row.querySelectorAll('input').forEach(inp => inp.oninput = refreshTotal);
      row.querySelector('.pu-del').onclick = () => {
        if (rowsEl.children.length > 1) { row.remove(); refreshTotal(); }
      };
    };
    bindRow(rowsEl.firstElementChild);
    modal.querySelector('#pu-add').onclick = () => {
      rowsEl.insertAdjacentHTML('beforeend', rowHtml());
      bindRow(rowsEl.lastElementChild);
    };
    modal.querySelector('#pu-close').onclick = () => modal.remove();
    modal.querySelector('#pu-cancel').onclick = () => modal.remove();
    modal.querySelector('#pu-confirm').onclick = async (ev) => {
      const btn = ev.currentTarget;
      if (btn.disabled) return;
      const items = collect();
      if (items.some(i => i.quantityPurchased <= 0)) { showToast('Todos os itens precisam de quantidade maior que zero.', 'error'); return; }
      if (items.some(i => i.batchNumber && !i.expiryDate)) { showToast('Informe a validade dos itens com lote.', 'error'); return; }
      const supplierSel = modal.querySelector('#pu-supplier');
      btn.disabled = true;
      try {
        await db.savePurchase({
          storeId,
          supplierId: supplierSel.value,
          supplierName: supplierSel.selectedOptions[0].textContent,
          invoiceNumber: modal.querySelector('#pu-invoice').value.trim(),
          destinationLocation: modal.querySelector('#pu-dest').value,
          notes: modal.querySelector('#pu-notes').value.trim(),
          items
        });
      } catch (err) {
        btn.disabled = false;
        showToast(err.message || 'Não foi possível confirmar a compra. Nenhuma alteração foi registrada.', 'error');
        return;
      }
      showToast('Compra confirmada e estoque atualizado.', 'success');
      modal.remove();
      onSaved();
    };
    document.body.appendChild(modal);
  };

  await render();
}
