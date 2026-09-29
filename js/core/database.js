/**
 * GEF - GESTÃO FINANCEIRA | CORE DATABASE & BUSINESS ENGINE
 * JavaScript Puro (Vanilla JS)
 *
 * Supabase é a ÚNICA fonte de verdade. Nenhum dado é gravado em localStorage,
 * nenhum dado fictício é gerado quando uma tabela está vazia.
 * Operações críticas (venda, estorno, compra, transferência, perda,
 * fechamento de caixa, inventário, pagamento de fiado) chamam RPCs atômicas
 * no Postgres (ver supabase_schema_rls.sql) em vez de fazer múltiplos passos
 * não-transacionais a partir do cliente.
 */

import { i18n } from './i18n.js';
import { supabase, isSupabaseConfigured } from './supabase.js';

function requireClient() {
  if (!supabase || !isSupabaseConfigured()) {
    throw new Error('Supabase não configurado. Defina SUPABASE_URL/SUPABASE_ANON_KEY em js/config.js.');
  }
  return supabase;
}

function unwrap({ data, error }, fallback) {
  if (error) throw new Error(error.message || 'Erro ao consultar o Supabase.');
  return data ?? fallback;
}

function normalizeRole(role) {
  return String(role || '').trim().toUpperCase();
}

// --- Mapeamento snake_case (banco) <-> camelCase (usado pelos módulos) ---

function productFromRow(row, batches = [], packages = []) {
  const stockByLocation = {
    LOJA: Number(row.stock_loja || 0),
    ARMAZEM: Number(row.stock_armazem || 0),
    PATIO: Number(row.stock_patio || 0)
  };
  return {
    id: row.id,
    storeId: row.store_id,
    code: row.code,
    barcode: row.barcode,
    name: row.name,
    category: row.category,
    baseUnit: row.unit,
    costPriceBase: Number(row.cost_price || 0),
    salePriceBase: Number(row.sale_price || 0),
    wholesalePrice: row.wholesale_price != null ? Number(row.wholesale_price) : null,
    minStockBase: Number(row.min_stock ?? 10),
    minStockAlert: Number(row.min_stock ?? 10),
    currentStockBase: Number(row.current_stock || 0),
    stockByLocation,
    isFractional: !!row.is_fractional,
    active: row.active !== false,
    batches: batches.filter(b => b.productId === row.id),
    conversions: packages.filter(p => p.productId === row.id)
  };
}

function batchFromRow(row) {
  return {
    id: row.id,
    storeId: row.store_id,
    productId: row.product_id,
    batchNumber: row.batch_number,
    supplierId: row.supplier_id,
    initialQuantityBase: Number(row.initial_quantity_base),
    currentQuantityBase: Number(row.current_quantity_base),
    costPerBase: Number(row.cost_per_base),
    expiryDate: row.expiry_date,
    status: row.status
  };
}

function packageFromRow(row) {
  return {
    id: row.id,
    productId: row.product_id,
    packagingName: row.packaging_name,
    multiplier: Number(row.multiplier_to_base),
    multiplierToBase: Number(row.multiplier_to_base),
    salePrice: row.sale_price != null ? Number(row.sale_price) : null,
    unitId: row.unit_id
  };
}

function customerFromRow(row) {
  const debt = Number(row.current_debt || 0);
  return {
    id: row.id,
    storeId: row.store_id,
    name: row.name,
    document: row.document,
    taxId: row.document,
    phone: row.phone,
    email: row.email,
    address: row.address,
    creditLimit: Number(row.credit_limit || 0),
    currentDebt: debt,
    creditBalance: debt
  };
}

function supplierFromRow(row) {
  return {
    id: row.id,
    storeId: row.store_id,
    name: row.name,
    phone: row.phone,
    email: row.email,
    address: row.address,
    nuitNif: row.nuit_nif,
    notes: row.notes,
    active: row.active !== false
  };
}

function saleFromRow(row, items = []) {
  return {
    id: row.id,
    storeId: row.store_id,
    sessionId: row.session_id,
    saleNumber: row.code,
    receiptNumber: row.receipt_number || row.code,
    customerId: row.customer_id,
    customerName: row.customer_name || 'Consumidor Final',
    cashierName: row.cashier_name || '',
    operatorId: row.operator_id,
    subtotal: Number(row.total_gross),
    totalGross: Number(row.total_gross),
    discountAmount: Number(row.discount || 0),
    discount: Number(row.discount || 0),
    totalNet: Number(row.total_net),
    total: Number(row.total_net),
    totalCogs: Number(row.total_cogs || 0),
    grossProfit: Number(row.gross_profit || 0),
    paymentMethod: row.payment_method,
    paymentDetails: row.payment_details || {},
    needsDelivery: !!row.needs_delivery,
    status: row.status,
    reversalReason: row.reversal_reason,
    reversedAt: row.reversed_at,
    notes: row.notes,
    createdAt: row.created_at,
    timestamp: row.created_at,
    items: items.filter(i => i.saleId === row.id)
  };
}

function saleItemFromRow(row) {
  return {
    saleId: row.sale_id,
    productId: row.product_id,
    productName: row.product_name,
    productCode: row.product_code,
    batchId: row.batch_id,
    batchNumber: row.batch_number,
    packagingName: row.packaging_name,
    selectedUnit: row.packaging_name,
    quantity: Number(row.quantity),
    quantitySold: Number(row.quantity),
    quantityBase: Number(row.quantity_base ?? row.quantity),
    multiplierToBase: Number(row.multiplier_to_base || 1),
    unitPrice: Number(row.unit_price),
    total: Number(row.total_price),
    totalPrice: Number(row.total_price),
    unitCogs: Number(row.unit_cogs || 0),
    totalCogs: Number(row.total_cogs || 0),
    location: row.location
  };
}

const CASH_METHODS = new Set(['DINHEIRO', 'CASH']);

function cashSessionFromRow(row, movements = []) {
  const mine = movements.filter(m => m.session_id === row.id);
  const sum = (fn) => mine.filter(fn).reduce((acc, m) => acc + Number(m.amount || 0), 0);
  const cashSales = sum(m => m.movement_type === 'SALE' && CASH_METHODS.has(m.payment_method));
  const mpesaSales = sum(m => m.movement_type === 'SALE' && m.payment_method === 'M-PESA');
  const emolaSales = sum(m => m.movement_type === 'SALE' && m.payment_method === 'E-MOLA');
  const posSales = sum(m => m.movement_type === 'SALE' && m.payment_method === 'POS_CARTAO');
  const creditSales = sum(m => m.movement_type === 'SALE' && (m.payment_method === 'CREDITO_FIADO' || m.payment_method === 'FIADO'));
  const totalSupplies = sum(m => m.movement_type === 'REFORCO');
  const totalBleeds = sum(m => m.movement_type === 'SANGRIA_BANK' || m.movement_type === 'SANGRIA_SAFE');
  const totalExpenses = sum(m => m.movement_type === 'DESPESA');
  const cashReversals = sum(m => m.movement_type === 'ESTORNO' && CASH_METHODS.has(m.payment_method));
  const opening = Number(row.opening_balance || 0);
  const cashInDrawer = Number((opening + cashSales + totalSupplies - totalBleeds - totalExpenses - cashReversals).toFixed(2));
  const closed = !!row.is_closed;
  return {
    id: row.id,
    storeId: row.store_id,
    operatorId: row.operator_id,
    cashierId: row.operator_id,
    cashierName: row.cashier_name || '',
    operatorName: row.cashier_name || '',
    openedAt: row.opened_at,
    closedAt: row.closed_at,
    openingBalance: opening,
    initialCash: opening,
    initialFloat: opening,
    cashSales,
    mpesaSales,
    emolaSales,
    posSales,
    creditSales,
    totalSupplies,
    totalBleeds,
    totalExpenses,
    cashInDrawer,
    expectedCash: closed && row.expected_cash != null ? Number(row.expected_cash) : cashInDrawer,
    closingCountedBalance: row.declared_cash != null ? Number(row.declared_cash) : null,
    closingExpectedBalance: row.expected_cash != null ? Number(row.expected_cash) : null,
    countedCash: row.declared_cash != null ? Number(row.declared_cash) : null,
    declaredCash: row.declared_cash != null ? Number(row.declared_cash) : null,
    difference: row.difference != null ? Number(row.difference) : null,
    status: closed ? 'CLOSED' : 'OPEN',
    isClosed: closed,
    notes: row.notes
  };
}

function quoteFromRow(r) {
  return {
    id: r.id, storeId: r.store_id, quoteNumber: r.quote_number || r.id, customerId: r.customer_id,
    customerName: r.customer_name, phone: r.phone, projectLocation: r.project_location,
    items: r.items || [], discount: Number(r.discount || 0), total: Number(r.total || 0),
    validUntil: r.valid_until, status: r.status, convertedSaleId: r.converted_sale_id, createdAt: r.created_at
  };
}

function deliveryFromRow(r) {
  return {
    id: r.id, storeId: r.store_id, saleId: r.sale_id, saleNumber: r.sale_number, customerName: r.customer_name,
    address: r.address, contactPhone: r.contact_phone, driverName: r.driver_name, vehiclePlate: r.vehicle_plate,
    status: r.status, scheduledDate: r.scheduled_date, dispatchedAt: r.dispatched_at, deliveredAt: r.delivered_at,
    items: r.items || [], notes: r.notes, createdAt: r.created_at
  };
}

function lossFromRow(r) {
  const qty = Number(r.quantity_base || 0);
  return {
    id: r.id, storeId: r.store_id, productId: r.product_id, productName: r.product_name, quantity: qty,
    quantityBase: qty, unit: r.unit, costUnit: Number(r.cost_unit || 0), totalCost: Number(r.total_loss_cost || 0),
    totalLossCost: Number(r.total_loss_cost || 0), location: r.location, reason: r.reason, notes: r.notes,
    userName: r.user_name, date: r.created_at, createdAt: r.created_at, timestamp: r.created_at
  };
}

function inventoryFromRow(r) {
  return {
    id: r.id, storeId: r.store_id, code: r.code, operatorName: r.operator_name || '', reconciled: !!r.reconciled,
    notes: r.notes, totalItemsAudited: r.total_items_audited, totalDivergentItems: r.total_divergent_items,
    totalDivergenceValue: Number(r.total_divergence_value || 0), items: r.items || [],
    timestamp: r.created_at, createdAt: r.created_at
  };
}

function auditFromRow(r) {
  return {
    id: r.id, storeId: r.store_id, action: r.action, entity: r.entity, entityId: r.entity_id,
    details: r.details, description: r.details, createdAt: r.created_at, timestamp: r.created_at
  };
}

function transferFromRow(r) {
  return {
    id: r.id, storeId: r.store_id, productId: r.product_id, quantityBase: Number(r.quantity_base),
    fromLocation: r.from_location, toLocation: r.to_location, notes: r.notes, timestamp: r.created_at, createdAt: r.created_at
  };
}

function purchaseFromRow(r) {
  return {
    id: r.id, storeId: r.store_id, supplierId: r.supplier_id, supplierName: r.supplier_name,
    invoiceNumber: r.invoice_number, destinationLocation: r.destination_location,
    totalCost: Number(r.total_cost || 0), notes: r.notes, createdAt: r.created_at
  };
}

class GefDatabase {
  constructor() {
    this.initialized = false;
    this.currentStoreId = null;
  }

  requireClient() {
    return requireClient();
  }

  unwrap(res, fallback) {
    if (res && (res.error !== undefined || res.data !== undefined)) {
      return unwrap(res, fallback);
    }
    return res ?? fallback;
  }

  async init() {
    if (this.initialized) return;
    this.initialized = true;
  }

  // --- STORES & MULTI-TENANCY ---
  async getStores() {
    const client = requireClient();
    const rows = unwrap(await client.from('stores').select('*').order('name'), []);
    return rows.map(s => ({
      id: s.id,
      code: s.code,
      name: s.name,
      tradeName: s.trade_name,
      cnpjNif: s.nuit_nif,
      city: s.city,
      province: s.province,
      address: s.address,
      phone: s.phone,
      email: s.email,
      currency: s.currency,
      language: s.language,
      isHeadquarters: s.is_headquarters,
      valorMensalidade: s.valor_mensalidade,
      valor_mensalidade: s.valor_mensalidade,
      receiptWidth: s.receipt_width || '80mm',
      scaleProtocol: s.scale_protocol || '',
      receiptFooter: s.receipt_footer || '',
      data_fim_teste: s.data_fim_teste,
      acesso_ativo: s.acesso_ativo,
      motivo_bloqueio: s.motivo_bloqueio
    }));
  }

  getCurrentStoreId() {
    return this.currentStoreId || 'store-001';
  }

  setCurrentStoreId(storeId) {
    this.currentStoreId = storeId;
  }

  async getCurrentStore() {
    const id = this.getCurrentStoreId();
    const stores = await this.getStores();
    const found = stores.find(s => s.id === id) || stores[0];
    if (found && found.currency) i18n.setCurrency(found.currency);
    if (found && found.language) i18n.setLanguage(found.language);
    return found || null;
  }

  async saveStore(store) {
    const client = requireClient();
    const row = {
      id: store.id,
      code: store.code,
      name: store.name,
      trade_name: store.tradeName,
      nuit_nif: store.cnpjNif,
      city: store.city,
      province: store.province,
      address: store.address,
      phone: store.phone,
      email: store.email,
      currency: store.currency,
      language: store.language,
      receipt_width: store.receiptWidth,
      scale_protocol: store.scaleProtocol,
      receipt_footer: store.receiptFooter
    };

    if (store.valor_mensalidade !== undefined) row.valor_mensalidade = store.valor_mensalidade;
    if (store.data_fim_teste !== undefined) row.data_fim_teste = store.data_fim_teste;
    if (store.acesso_ativo !== undefined) row.acesso_ativo = store.acesso_ativo;
    if (store.motivo_bloqueio !== undefined) row.motivo_bloqueio = store.motivo_bloqueio;

    unwrap(await client.from('stores').upsert(row), null);
    return store;
  }

  async deleteStore(storeId) {
    const client = requireClient();
    unwrap(await client.from('stores').delete().eq('id', storeId), null);
    return true;
  }

  async getConfig() {
    const store = await this.getCurrentStore();
    if (!store) return {};
    return {
      ...store,
      companyName: store.name,
      brandName: store.tradeName || store.name,
      nuit: store.cnpjNif,
      receiptFooterMessage: store.receiptFooter
    };
  }

  async saveConfig(config) {
    const store = await this.getCurrentStore();
    if (!store) return;
    await this.saveStore({
      ...store,
      name: config.companyName || config.name || store.name,
      tradeName: config.brandName || config.tradeName || store.tradeName,
      cnpjNif: config.nuit || config.cnpjNif || store.cnpjNif,
      phone: config.phone || store.phone,
      email: config.email || store.email,
      address: config.address || store.address,
      currency: config.currency || store.currency,
      language: config.language || store.language,
      receiptWidth: config.receiptWidth || store.receiptWidth,
      scaleProtocol: config.scaleProtocol ?? store.scaleProtocol,
      receiptFooter: config.receiptFooter ?? store.receiptFooter
    });
    if (config.currency) i18n.setCurrency(config.currency);
    if (config.language) i18n.setLanguage(config.language);
  }

  // --- UNITS ---
  async getUnits() {
    const client = requireClient();
    const rows = unwrap(await client.from('units').select('*').order('name'), []);
    return rows.map(u => ({ id: u.id, code: u.code, name: u.name, isFractional: !!u.is_fractional }));
  }

  // --- PRODUCTS, BATCHES & PACKAGES ---
  async getProducts(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();
    let query = client.from('products').select('*').order('name');
    if (targetStore !== 'ALL') query = query.eq('store_id', targetStore);
    const rows = unwrap(await query, []);
    if (rows.length === 0) return [];

    const ids = rows.map(r => r.id);

    const batchRows = unwrap(
      await client
        .from('batches')
        .select('*')
        .in('product_id', ids)
        .eq('status', 'ACTIVE')
        .order('expiry_date'),
      []
    );

    const packageRows = unwrap(
      await client
        .from('product_packages')
        .select('*')
        .in('product_id', ids),
      []
    );

    const batches = batchRows.map(b => ({ ...batchFromRow(b), productId: b.product_id }));
    const packages = packageRows.map(p => ({ ...packageFromRow(p), productId: p.product_id }));

    return rows.map(r => productFromRow(r, batches, packages));
  }

  async getProductById(id) {
    const client = requireClient();

    const row = unwrap(
      await client
        .from('products')
        .select('*')
        .eq('id', id)
        .maybeSingle(),
      null
    );

    if (!row) return null;

    const batchRows = unwrap(
      await client
        .from('batches')
        .select('*')
        .eq('product_id', id)
        .eq('status', 'ACTIVE'),
      []
    );

    const packageRows = unwrap(
      await client
        .from('product_packages')
        .select('*')
        .eq('product_id', id),
      []
    );

    const batches = batchRows.map(b => ({ ...batchFromRow(b), productId: b.product_id }));
    const packages = packageRows.map(p => ({ ...packageFromRow(p), productId: p.product_id }));

    return productFromRow(row, batches, packages);
  }

  async saveProduct(product) {
    const client = requireClient();
    const isNew = !(await this.getProductById(product.id));

    const row = {
      id: product.id,
      store_id: product.storeId || this.getCurrentStoreId(),
      code: product.code,
      barcode: product.barcode,
      name: product.name,
      category: product.category,
      unit: product.baseUnit || 'UN',
      cost_price: product.costPriceBase ?? 0,
      sale_price: product.salePriceBase ?? 0,
      wholesale_price: product.wholesalePrice ?? null,
      min_stock: product.minStockBase ?? 10,
      is_fractional: !!product.isFractional,
      active: product.active !== false
    };

    if (isNew) {
      row.current_stock = product.currentStockBase ?? 0;
      row.stock_loja = product.stockByLocation?.LOJA ?? 0;
      row.stock_armazem = product.stockByLocation?.ARMAZEM ?? 0;
      row.stock_patio = product.stockByLocation?.PATIO ?? 0;
    }

    unwrap(await client.from('products').upsert(row), null);

    if (Array.isArray(product.conversions)) {
      unwrap(
        await client
          .from('product_packages')
          .delete()
          .eq('product_id', product.id),
        null
      );

      const pkgRows = product.conversions
        .filter(c => c.packagingName && c.multiplierToBase)
        .map(c => ({
          id: c.id || ('pkg-' + Date.now() + '-' + Math.floor(Math.random() * 9000)),
          product_id: product.id,
          packaging_name: c.packagingName,
          multiplier_to_base: c.multiplierToBase || c.multiplier || 1,
          sale_price: c.salePrice ?? null
        }));

      if (pkgRows.length > 0) {
        unwrap(
          await client
            .from('product_packages')
            .insert(pkgRows),
          null
        );
      }
    }

    return product;
  }

  async deleteProduct(id) {
    const client = requireClient();
    unwrap(await client.from('products').delete().eq('id', id), null);
    return true;
  }

  async getAllBatches(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('batches')
      .select('*, products(name)')
      .order('expiry_date');

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    const rows = unwrap(await query, []);

    return rows.map(r => ({
      ...batchFromRow(r),
      productName: r.products?.name
    }));
  }

  // --- CUSTOMERS ---
  async getCustomers(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('customers')
      .select('*')
      .order('name');

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    const rows = unwrap(await query, []);

    return rows.map(customerFromRow);
  }

  async saveCustomer(customer) {
    const client = requireClient();

    const row = {
      id: customer.id,
      store_id: customer.storeId || this.getCurrentStoreId(),
      name: customer.name,
      document: customer.document || customer.taxId,
      phone: customer.phone,
      email: customer.email,
      address: customer.address,
      credit_limit: customer.creditLimit ?? 0,
      current_debt: customer.currentDebt ?? customer.creditBalance ?? 0
    };

    unwrap(await client.from('customers').upsert(row), null);

    return customer;
  }

  async deleteCustomer(id) {
    const client = requireClient();
    unwrap(await client.from('customers').delete().eq('id', id), null);
    return true;
  }

  // --- SUPPLIERS ---
  async getSuppliers(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('suppliers')
      .select('*')
      .order('name');

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    const rows = unwrap(await query, []);

    return rows.map(supplierFromRow);
  }

  async saveSupplier(supplier) {
    const client = requireClient();

    const row = {
      id: supplier.id,
      store_id: supplier.storeId || this.getCurrentStoreId(),
      name: supplier.name,
      phone: supplier.phone,
      email: supplier.email,
      address: supplier.address,
      nuit_nif: supplier.nuitNif,
      notes: supplier.notes,
      active: supplier.active !== false
    };

    unwrap(await client.from('suppliers').upsert(row), null);

    return supplier;
  }

  async deleteSupplier(id) {
    const client = requireClient();
    unwrap(await client.from('suppliers').delete().eq('id', id), null);
    return true;
  }

  // --- CASH SESSIONS, SANGRIAS, SUPRIMENTOS, DESPESAS (todas via RPC) ---
  async getCashSessions(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('cash_sessions')
      .select('*')
      .order('opened_at', { ascending: false })
      .limit(200);

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    const rows = unwrap(await query, []);

    if (rows.length === 0) return [];

    const movements = unwrap(
      await client
        .from('cash_movements')
        .select('*')
        .in('session_id', rows.map(r => r.id)),
      []
    );

    return rows.map(r => cashSessionFromRow(r, movements));
  }

  async getActiveCashSession(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    if (targetStore === 'ALL') return null;

    const row = unwrap(
      await client
        .from('cash_sessions')
        .select('*')
        .eq('store_id', targetStore)
        .eq('is_closed', false)
        .order('opened_at', { ascending: false })
        .limit(1)
        .maybeSingle(),
      null
    );

    if (!row) return null;

    const movements = unwrap(
      await client
        .from('cash_movements')
        .select('*')
        .eq('session_id', row.id),
      []
    );

    return cashSessionFromRow(row, movements);
  }

  async openCashSession(storeId, initialCash, cashierName) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    const row = unwrap(
      await client.rpc('fn_open_cash_session', {
        p_store_id: targetStore,
        p_initial_cash: Number(initialCash) || 0,
        p_cashier_name: cashierName || null
      }),
      null
    );

    return cashSessionFromRow(row, []);
  }

  async closeCashSession(sessionId, countedCash, notes) {
    const client = requireClient();

    const row = unwrap(
      await client.rpc('fn_close_cash_session', {
        p_session_id: sessionId,
        p_counted_cash: countedCash,
        p_notes: notes || null,
        p_operator_id: null
      }),
      null
    );

    return cashSessionFromRow(row, []);
  }

  async registerCashMovement(sessionId, type, amount, reason, notes) {
    const client = requireClient();

    return unwrap(
      await client.rpc('fn_register_cash_movement', {
        p_session_id: sessionId,
        p_type: type,
        p_amount: amount,
        p_reason: reason,
        p_notes: notes || null
      }),
      null
    );
  }

  async registerSangria(sessionId, amount, reason, destination = 'SANGRIA_SAFE') {
    return this.registerCashMovement(sessionId, destination, amount, reason);
  }

  async registerSuprimento(sessionId, amount, reason) {
    return this.registerCashMovement(sessionId, 'REFORCO', amount, reason);
  }

  async registerExpense(sessionId, amount, reason) {
    return this.registerCashMovement(sessionId, 'DESPESA', amount, reason);
  }

  async getCashMovements(sessionId) {
    const client = requireClient();

    let query = client
      .from('cash_movements')
      .select('*')
      .order('created_at', { ascending: false });

    if (sessionId) {
      query = query.eq('session_id', sessionId);
    }

    return unwrap(await query, []);
  }

  // --- SALES & ATOMIC POS (FEFO via RPC) ---
  async getSales(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('sales')
      .select('*')
      .order('created_at', { ascending: false });

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    const rows = unwrap(await query, []);

    if (rows.length === 0) return [];

    const ids = rows.map(r => r.id);

    const itemRows = unwrap(
      await client
        .from('sale_items')
        .select('*')
        .in('sale_id', ids),
      []
    );

    const items = itemRows.map(i => ({
      ...saleItemFromRow(i),
      saleId: i.sale_id
    }));

    return rows.map(r => saleFromRow(r, items));
  }

  async getSaleById(saleId) {
    const client = requireClient();

    const row = unwrap(
      await client
        .from('sales')
        .select('*')
        .eq('id', saleId)
        .maybeSingle(),
      null
    );

    if (!row) return null;

    const itemRows = unwrap(
      await client
        .from('sale_items')
        .select('*')
        .eq('sale_id', saleId),
      []
    );

    return saleFromRow(
      row,
      itemRows.map(saleItemFromRow)
    );
  }

  async processAtomicSale(
    storeId,
    sessionId,
    customerName,
    customerTaxId,
    paymentMethod,
    discountAmount,
    items,
    extraInfo = {}
  ) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    const row = unwrap(
      await client.rpc('fn_process_atomic_sale', {
        p_store_id: targetStore,
        p_session_id: sessionId || null,
        p_customer_id: extraInfo.customerId || null,
        p_customer_name: customerName,
        p_payment_method: paymentMethod,
        p_discount: discountAmount || 0,
        p_items: items.map(it => ({
          productId: it.productId,
          quantity: it.quantity,
          unitPrice: it.unitPrice,
          multiplierToBase: it.multiplierToBase || it.multiplier || 1,
          packagingName: it.packagingName || it.packageName || it.selectedUnit || null
        })),
        p_operator_id: null,
        p_notes: extraInfo.notes || null,
        p_cashier_name: extraInfo.cashierName || null,
        p_payment_details: extraInfo.paymentDetails || {},
        p_needs_delivery: !!extraInfo.needsDelivery
      }),
      null
    );

    const sale = await this.getSaleById(row.id);

    return {
      success: true,
      sale_id: sale.id,
      receipt_number: sale.receiptNumber,
      total_gross: sale.totalGross,
      discount_amount: sale.discount,
      total_net: sale.totalNet,
      payment_method: sale.paymentMethod,
      sale
    };
  }

  async reverseSale(saleId, reason) {
    const client = requireClient();

    unwrap(
      await client.rpc('fn_reverse_sale', {
        p_sale_id: saleId,
        p_reason: reason,
        p_operator_id: null
      }),
      null
    );

    return true;
  }

  // --- PURCHASES (via RPC) ---
  async getPurchases(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('purchases')
      .select('*')
      .order('created_at', { ascending: false });

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    return unwrap(await query, []).map(purchaseFromRow);
  }

  async savePurchase(purchase, operatorId) {
    const client = requireClient();
    const targetStore = purchase.storeId || this.getCurrentStoreId();

    const row = unwrap(
      await client.rpc('fn_confirm_purchase', {
        p_store_id: targetStore,
        p_supplier_id: purchase.supplierId || null,
        p_supplier_name: purchase.supplierName || null,
        p_invoice_number: purchase.invoiceNumber || null,
        p_destination_location: purchase.destinationLocation || 'ARMAZEM',
        p_items: purchase.items || [],
        p_operator_id: null,
        p_notes: purchase.notes || null
      }),
      null
    );

    return row;
  }

  // --- LOSSES / AVARIAS (via RPC) ---
  async getLosses(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('losses')
      .select('*')
      .order('created_at', { ascending: false });

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    return unwrap(await query, []).map(lossFromRow);
  }

  async registerLoss(loss) {
    const client = requireClient();
    const targetStore = loss.storeId || this.getCurrentStoreId();

    const row = unwrap(
      await client.rpc('fn_register_loss', {
        p_store_id: targetStore,
        p_product_id: loss.productId,
        p_quantity_base: loss.quantityBase || loss.quantity,
        p_location: loss.location || 'LOJA',
        p_reason: loss.reason,
        p_operator_id: null,
        p_notes: loss.notes || null
      }),
      null
    );

    return lossFromRow(row);
  }

  // --- QUOTES / ORÇAMENTOS DE OBRA ---
  async getQuotes(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('quotes')
      .select('*')
      .order('created_at', { ascending: false });

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    return unwrap(await query, []).map(quoteFromRow);
  }

  async saveQuote(quote) {
    const client = requireClient();

    const row = {
      id: quote.id,
      store_id: quote.storeId || this.getCurrentStoreId(),
      quote_number: quote.quoteNumber || null,
      customer_id: quote.customerId || null,
      customer_name: quote.customerName,
      phone: quote.phone || null,
      project_location: quote.projectLocation || null,
      items: quote.items || [],
      discount: quote.discount || 0,
      total: quote.total || 0,
      valid_until: quote.validUntil || null,
      status: quote.status || 'RASCUNHO',
      updated_at: new Date().toISOString()
    };

    unwrap(await client.from('quotes').upsert(row), null);

    return quote;
  }

  async deleteQuote(id) {
    const client = requireClient();

    unwrap(
      await client
        .from('quotes')
        .delete()
        .eq('id', id),
      null
    );

    return true;
  }

  // --- DELIVERIES EM CANTEIRO ---
  async getDeliveries(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('deliveries')
      .select('*')
      .order('created_at', { ascending: false });

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    return unwrap(await query, []).map(deliveryFromRow);
  }

  async saveDelivery(delivery) {
    const client = requireClient();

    const row = {
      id: delivery.id,
      store_id: delivery.storeId || this.getCurrentStoreId(),
      sale_id: delivery.saleId || null,
      sale_number: delivery.saleNumber || null,
      customer_name: delivery.customerName,
      address: delivery.address,
      contact_phone: delivery.contactPhone || null,
      driver_name: delivery.driverName || null,
      vehicle_plate: delivery.vehiclePlate || null,
      status: delivery.status || 'PENDENTE',
      scheduled_date: delivery.scheduledDate || null,
      dispatched_at: delivery.dispatchedAt || null,
      delivered_at: delivery.status === 'ENTREGUE'
        ? (delivery.deliveredAt || new Date().toISOString())
        : null,
      items: delivery.items || [],
      notes: delivery.notes || null
    };

    unwrap(
      await client
        .from('deliveries')
        .upsert(row),
      null
    );

    return delivery;
  }

  async deleteDelivery(id) {
    const client = requireClient();

    unwrap(
      await client
        .from('deliveries')
        .delete()
        .eq('id', id),
      null
    );

    return true;
  }

  // --- TRANSFERS (via RPC) ---
  async getTransfers(storeId) {
    const client = requireClient();
    const targetStore = storeId || this.getCurrentStoreId();

    let query = client
      .from('transfers')
      .select('*')
      .order('created_at', { ascending: false });

    if (targetStore !== 'ALL') {
      query = query.eq('store_id', targetStore);
    }

    return unwrap(await query, []).map(transferFromRow);
  }

  async saveTransfer(transfer, operatorId) {
    const client = requireClient();
    const targetStore = transfer.storeId || this.getCurrentStoreId();

    return unwrap(
      await client.rpc('fn_transfer_stock', {
        p_store_id: targetStore,
        p_product_id: transfer.productId,
        p_quantity_base: transfer.quantityBase,
        p_from_location: transfer.fromLocation,
        p_to_location: transfer.toLocation,
        p_operator_id: null,
        p_notes: transfer.notes || null
      }),
      null
    );
  }

  async transferStock(transferObj, operatorId) {
    return this.saveTransfer(transferObj, operatorId);
  }

  // --- CUSTOMER CREDIT & PAYMENTS (via RPC) ---
  async getCustomerCreditHistory(customerId) {
    const client = requireClient();

    return unwrap(
      await client
        .from('credit_transactions')
        .select('*')
        .eq('customer_id', customerId)
        .order('created_at', { ascending: false }),
      []
    );
  }

  async registerCustomerPayment(
    customerId,
    amount,
    paymentMethod,
    sessionId,
    notes
  ) {
    const client = requireClient();

    const row = unwrap(
      await client.rpc('fn_register_customer_payment', {
        p_customer_id: customerId,
        p_amount: amount,
        p_notes: notes || 'Pagamento de conta',
        p_operator_id: null,
        p_payment_method: paymentMethod || 'DINHEIRO',
        p_session_id: sessionId || null
      }),
      null
    );

    return customerFromRow(row);
  }

  // ============================================================
  // --- AMBASSADORS & PARTNERS ---
  // ============================================================

  _normalizeAmbassadorStatus(status, active = true) {
    const value = String(status || '').toUpperCase().trim();

    if (value === 'ATIVO') return 'ATIVO';
    if (value === 'BLOQUEADO') return 'BLOQUEADO';
    if (value === 'DESATIVADO') return 'DESATIVADO';

    // Compatibilidade com dados antigos
    if (value === 'INATIVO') return 'DESATIVADO';

    return active === false ? 'DESATIVADO' : 'ATIVO';
  }

  async getAmbassadors() {
    const client = this.requireClient();

    const { data: { user } = {} } = await client.auth.getUser();

    if (!user) {
      throw new Error('Utilizador não autenticado.');
    }

    // Descobrir o perfil atual
    const { data: profile, error: profileError } = await client
      .from('profiles')
      .select('role')
      .eq('id', user.id)
      .maybeSingle();

    if (profileError) {
      throw profileError;
    }

    const role = normalizeRole(profile?.role);

    let query = client
      .from('ambassadors')
      .select(`
        *,
        ambassador_referred_stores(*),
        ambassador_payouts(*)
      `)
      .order('created_at', { ascending: false });

    // Superadmin vê todos. Embaixador vê somente o próprio registo.
    if (role !== 'SUPERADMIN') {
      query = query.eq('user_id', user.id);
    }

    const { data, error } = await query;

    if (error) {
      throw error;
    }

    const rows = Array.isArray(data) ? data : [];

    return rows.map((a) => {
      const status = this._normalizeAmbassadorStatus(
        a.status,
        a.active
      );

      const referredStores = Array.isArray(a.ambassador_referred_stores)
        ? a.ambassador_referred_stores
        : [];

      const payouts = Array.isArray(a.ambassador_payouts)
        ? a.ambassador_payouts
        : [];

      const paidCommissions = payouts.reduce(
        (sum, payout) => sum + Number(payout.amount || 0),
        0
      );

      return {
        id: a.id,
        userId: a.user_id,

        name: a.name || '',
        phone: a.phone || '',
        pixMpesa: a.pix_mpesa || '',
        paymentDetails: a.pix_mpesa || '',

        code: a.referral_code || '',

        commissionRate: Number(a.commission_rate || 0),

        totalEarned: Number(a.total_earned || 0),
        pendingCommissions: Number(a.pending_commissions || 0),
        paidCommissions,

        status,

        // Compatibilidade com código antigo
        active: status !== 'DESATIVADO',

        createdAt: a.created_at,

        referredStores: referredStores.map((store) => ({
          id: store.id,
          ambassadorId: store.ambassador_id,

          name: store.name || '',
          ownerName: store.owner_name || '',
          phone: store.phone || '',
          city: store.city || '',

          monthlyFee: Number(store.monthly_fee || 0),

          paymentStatus: store.payment_status || 'PENDENTE',
          lastPaymentDate: store.last_payment_date || null,
          nextDueDate: store.next_due_date || null,

          commissionRate: Number(
            store.commission_rate ?? a.commission_rate ?? 0
          ),

          contractDurationMonths: Number(
            store.contract_duration_months || 0
          ),

          monthsActive: Number(
            store.months_active || 0
          ),

          totalCommissionEarned: Number(
            store.total_commission_earned || 0
          ),

          createdAt: store.created_at
        })),

        payoutHistory: payouts.map((payout) => ({
          id: payout.id,
          ambassadorId: payout.ambassador_id,
          amount: Number(payout.amount || 0),
          method: payout.method || '',
          receipt: payout.receipt || '',
          status: payout.status || '',
          createdAt: payout.created_at
        })),

        totalStores: referredStores.length,

        activeStores: referredStores.filter(
          store =>
            String(store.payment_status || '').toUpperCase() === 'PAGO'
        ).length
      };
    });
  }

  // ------------------------------------------------------------
  // Criar / atualizar dados básicos do embaixador
  // ------------------------------------------------------------
  async saveAmbassador(ambassador) {
    const client = this.requireClient();

    if (!ambassador?.id) {
      throw new Error('ID do embaixador é obrigatório.');
    }

    const name = String(ambassador.name || '').trim();
    const phone = String(ambassador.phone || '').trim();
    const pixMpesa = String(
      ambassador.pixMpesa ??
      ambassador.paymentDetails ??
      ''
    ).trim();

    const commissionRate = Number(
      ambassador.commissionRate ?? 0
    );

    if (!name) {
      throw new Error('Nome do embaixador é obrigatório.');
    }

    if (!phone) {
      throw new Error('Telefone do embaixador é obrigatório.');
    }

    if (!Number.isFinite(commissionRate) || commissionRate < 0) {
      throw new Error('Taxa de comissão inválida.');
    }

    const res = await client.rpc(
      'fn_admin_update_ambassador',
      {
        p_ambassador_id: ambassador.id,
        p_name: name,
        p_phone: phone,
        p_pix_mpesa: pixMpesa,
        p_commission_rate: commissionRate
      }
    );

    return this.unwrap(res);
  }

  // ------------------------------------------------------------
  // Alterar estado do embaixador
  // ATIVO | BLOQUEADO | DESATIVADO
  // ------------------------------------------------------------
  async setAmbassadorStatus(ambassadorId, status) {
    const client = this.requireClient();

    if (!ambassadorId) {
      throw new Error('ID do embaixador é obrigatório.');
    }

    const normalizedStatus = this._normalizeAmbassadorStatus(status);

    const res = await client.rpc(
      'fn_admin_set_ambassador_status',
      {
        p_ambassador_id: ambassadorId,
        p_status: normalizedStatus
      }
    );

    return this.unwrap(res);
  }

  // Ativar
  async activateAmbassador(ambassadorId) {
    return this.setAmbassadorStatus(
      ambassadorId,
      'ATIVO'
    );
  }

  // Bloquear
  async blockAmbassador(ambassadorId) {
    return this.setAmbassadorStatus(
      ambassadorId,
      'BLOQUEADO'
    );
  }

  // Desativar
  async deactivateAmbassador(ambassadorId) {
    return this.setAmbassadorStatus(
      ambassadorId,
      'DESATIVADO'
    );
  }

  // ------------------------------------------------------------
  // Aprovar loja indicada
  // ------------------------------------------------------------
  async approveAmbassadorStore(referredStoreId) {
    const client = this.requireClient();

    if (!referredStoreId) {
      throw new Error('ID da loja indicada é obrigatório.');
    }

    const res = await client.rpc(
      'fn_approve_ambassador_store',
      {
        p_referred_store_id: referredStoreId
      }
    );

    return this.unwrap(res);
  }

  // ------------------------------------------------------------
  // Rejeitar loja indicada
  // ------------------------------------------------------------
  async rejectAmbassadorStore(referredStoreId, reason = null) {
    const client = this.requireClient();

    if (!referredStoreId) {
      throw new Error('ID da loja indicada é obrigatório.');
    }

    const res = await client.rpc(
      'fn_reject_ambassador_store',
      {
        p_referred_store_id: referredStoreId,
        p_reason: reason || null
      }
    );

    return this.unwrap(res);
  }

  // ------------------------------------------------------------
  // Pagar / liquidar comissão
  // ------------------------------------------------------------
  async payAmbassadorCommission(
    ambassadorId,
    amount,
    method,
    ref = ''
  ) {
    const client = this.requireClient();

    if (!ambassadorId) {
      throw new Error('ID do embaixador é obrigatório.');
    }

    const paidAmount = Number(amount);

    if (!Number.isFinite(paidAmount) || paidAmount <= 0) {
      throw new Error('Valor da comissão inválido.');
    }

    const paymentMethod = String(method || '').trim();

    if (!paymentMethod) {
      throw new Error('Método de pagamento é obrigatório.');
    }

    const receipt = String(ref || '').trim();

    const res = await client.rpc(
      'fn_admin_pay_ambassador_commission',
      {
        p_ambassador_id: ambassadorId,
        p_amount: paidAmount,
        p_method: paymentMethod,
        p_receipt: receipt
      }
    );

    return this.unwrap(res);
  }

  // ------------------------------------------------------------
  // Adicionar loja indicada
  // ------------------------------------------------------------
  async addAmbassadorReferredStore(
    ambassadorId,
    storeData
  ) {
    const client = this.requireClient();

    if (!ambassadorId) {
      throw new Error('ID do embaixador é obrigatório.');
    }

    if (!storeData?.name) {
      throw new Error('Nome da loja é obrigatório.');
    }

    const monthlyFee = Number(
      storeData.monthlyFee ?? 0
    );

    const commissionRate = Number(
      storeData.commissionRate ?? 15
    );

    const paymentStatus =
      storeData.paymentStatus || 'PENDENTE';

    const commission =
      paymentStatus === 'PAGO'
        ? (monthlyFee * commissionRate) / 100
        : 0;

    const generatedId = (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function')
      ? crypto.randomUUID()
      : ('ref-' + Date.now() + '-' + Math.random().toString(36).substring(2, 9));

    const row = {
      id: storeData.id || generatedId,

      ambassador_id: ambassadorId,

      name: String(storeData.name).trim(),

      owner_name:
        String(storeData.ownerName || '').trim() || null,

      phone:
        String(storeData.phone || '').trim() || null,

      city:
        String(storeData.city || '').trim() || null,

      monthly_fee: monthlyFee,

      payment_status: paymentStatus,

      last_payment_date:
        storeData.lastPaymentDate || null,

      next_due_date:
        storeData.nextDueDate || null,

      commission_rate: commissionRate,

      contract_duration_months:
        Number(storeData.contractDurationMonths || 12),

      months_active:
        Number(storeData.monthsActive || 0),

      total_commission_earned:
        Number(storeData.totalCommissionEarned || commission)
    };

    const { data, error } = await client
      .from('ambassador_referred_stores')
      .insert(row)
      .select()
      .single();

    if (error) {
      throw error;
    }

    return data;
  }

  // ------------------------------------------------------------
  // Compatibilidade: método antigo para pagamento
  // ------------------------------------------------------------
  async settleAmbassadorCommission(
    ambassadorId,
    amount,
    method,
    ref = ''
  ) {
    return this.payAmbassadorCommission(
      ambassadorId,
      amount,
      method,
      ref
    );
  }

  // --- SAAS & LOCK ENGINE ---
  checkStoreLock(store) {
    if (!store) {
      return {
        isLocked: false,
        daysRemaining: 999,
        reason: '',
        store: null
      };
    }

    if (store.acesso_ativo === false) {
      return {
        isLocked: true,
        daysRemaining: 0,
        reason:
          store.motivo_bloqueio ||
          'Acesso suspenso pelo administrador do sistema GEF.',
        store
      };
    }

    if (store.data_fim_teste) {
      const diffDays =
        Math.ceil(
          (
            new Date(
              store.data_fim_teste
            ).getTime() -
            Date.now()
          ) /
          86400000
        );

      if (diffDays <= 0) {
        return {
          isLocked: true,
          daysRemaining: diffDays,
          reason:
            `A assinatura da loja expirou em ${new Date(store.data_fim_teste).toLocaleDateString('pt-PT')}. Regularize para continuar faturando.`,
          store
        };
      }

      return {
        isLocked: false,
        daysRemaining: diffDays,
        reason: '',
        store
      };
    }

    return {
      isLocked: false,
      daysRemaining: 999,
      reason: '',
      store
    };
  }

  async toggleStoreAccess(
    storeId,
    acessoAtivo,
    motivo
  ) {
    const client = requireClient();

    return unwrap(
      await client
        .from('stores')
        .update({
          acesso_ativo: acessoAtivo,
          motivo_bloqueio:
            motivo ||
            (
              acessoAtivo
                ? null
                : 'Assinatura vencida / Bloqueio administrativo'
            )
        })
        .eq('id', storeId)
        .select()
        .maybeSingle(),
      null
    );
  }

  async renewStoreSubscription(
    storeId,
    daysToAdd = 30
  ) {
    const client = requireClient();

    return unwrap(
      await client.rpc(
        'fn_renew_store_subscription',
        {
          p_store_id: storeId,
          p_days: daysToAdd
        }
      ),
      null
    );
  }

  // --- DASHBOARD METRICS ---
  async getDashboardStats(storeId) {
    const targetStore =
      storeId ||
      this.getCurrentStoreId();

    const [
      products,
      customers,
      sales,
      quotes,
      deliveries,
      losses
    ] = await Promise.all([
      this.getProducts(targetStore),
      this.getCustomers(targetStore),
      this.getSales(targetStore),
      this.getQuotes(targetStore),
      this.getDeliveries(targetStore),
      this.getLosses(targetStore)
    ]);

    const todayStr =
      new Date()
        .toISOString()
        .split('T')[0];

    const firstDayOfMonth =
      todayStr.slice(0, 7) +
      '-01';

    const validSales =
      sales.filter(
        s => s.status === 'CONCLUIDA'
      );

    const todaySales =
      validSales.filter(
        s =>
          (s.createdAt || '')
            .startsWith(todayStr)
      );

    const monthSales =
      validSales.filter(
        s =>
          (s.createdAt || '') >=
          firstDayOfMonth
      );

    const totalTodaySales =
      todaySales.reduce(
        (acc, s) =>
          acc +
          (s.total || 0),
        0
      );

    const monthSalesRevenue =
      monthSales.reduce(
        (acc, s) =>
          acc +
          (s.total || 0),
        0
      );

    const batches =
      await this.getAllBatches(
        targetStore
      );

    const batchCost =
      batches.reduce(
        (sum, b) =>
          sum +
          (
            b.currentQuantityBase *
            b.costPerBase
          ),
        0
      );

    const productCost =
      products.reduce(
        (sum, p) =>
          sum +
          (
            p.currentStockBase *
            p.costPriceBase
          ),
        0
      );

    const stockCostTotal =
      Number(
        (
          batches.length > 0
            ? batchCost
            : productCost
        ).toFixed(2)
      );

    const stockSaleValuation =
      Number(
        products
          .reduce(
            (sum, p) =>
              sum +
              (
                p.currentStockBase *
                p.salePriceBase
              ),
            0
          )
          .toFixed(2)
      );

    const activeShift =
      await this.getActiveCashSession(
        targetStore
      );

    const currentCashInDrawer =
      activeShift
        ? activeShift.expectedCash || 0
        : 0;

    const totalReceivable =
      customers.reduce(
        (sum, c) =>
          sum +
          (c.currentDebt || 0),
        0
      );

    const lowStockList =
      products.filter(
        p =>
          p.currentStockBase > 0 &&
          p.currentStockBase <=
            p.minStockAlert
      );

    const outOfStockList =
      products.filter(
        p =>
          p.currentStockBase <= 0
      );

    const totalLossCost =
      losses.reduce(
        (sum, l) =>
          sum +
          (l.totalLossCost || 0),
        0
      );

    return {
      totalTodaySales,
      todaySalesCount:
        todaySales.length,

      totalRealEquity:
        Number(
          (
            stockCostTotal +
            currentCashInDrawer
          ).toFixed(2)
        ),

      stockCostTotal,
      stockSaleValuation,
      currentCashInDrawer,
      totalReceivable,

      lowStockCount:
        lowStockList.length,

      outOfStockCount:
        outOfStockList.length,

      pendingQuotesCount:
        quotes.filter(
          q =>
            [
              'RASCUNHO',
              'PENDENTE',
              'ENVIADO'
            ].includes(q.status)
        ).length,

      pendingDeliveriesCount:
        deliveries.filter(
          d =>
            d.status !== 'ENTREGUE' &&
            d.status !== 'CANCELADA'
        ).length,

      recentSales:
        sales.slice(0, 8),

      totalLossCost
    };
  }

  // --- AUDIT LOGS (somente leitura; escrita acontece dentro das RPCs) ---
  async getAuditLogs(storeId) {
    const client = requireClient();
    const targetStore =
      storeId ||
      this.getCurrentStoreId();

    let query = client
      .from('audit_logs')
      .select('*')
      .order('created_at', {
        ascending: false
      })
      .limit(500);

    if (targetStore !== 'ALL') {
      query = query.eq(
        'store_id',
        targetStore
      );
    }

    return unwrap(
      await query,
      []
    ).map(auditFromRow);
  }

  // --- INVENTORIES (via RPC) ---
  async getInventories(storeId) {
    const client = requireClient();
    const targetStore =
      storeId ||
      this.getCurrentStoreId();

    let query = client
      .from('inventories')
      .select('*')
      .order('created_at', {
        ascending: false
      });

    if (targetStore !== 'ALL') {
      query = query.eq(
        'store_id',
        targetStore
      );
    }

    return unwrap(
      await query,
      []
    ).map(inventoryFromRow);
  }

  async saveInventoryAudit({
    storeId,
    operatorId,
    items,
    notes,
    reconcile
  }) {
    const client = requireClient();

    const targetStore =
      storeId ||
      this.getCurrentStoreId();

    const inv = unwrap(
      await client.rpc(
        'fn_reconcile_inventory',
        {
          p_store_id: targetStore,
          p_items: items,
          p_notes: notes || '',
          p_reconcile: !!reconcile,
          p_operator_id: null
        }
      ),
      null
    );

    return inventoryFromRow(inv);
  }
}

export const db = new GefDatabase();
