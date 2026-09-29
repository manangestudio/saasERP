import {
    supabase as supabaseClient,
    isSupabaseConfigured
} from './core/supabase.js';

let supabase = null;
let ambassadorCode = null;
let ambassadorData = null;
let stores = [];


/* =========================================================
   CÓDIGO DO EMBAIXADOR
========================================================= */

function getAmbassadorCode() {

    const params = new URLSearchParams(
        window.location.search
    );

    return (
        params.get('embaixador') ||
        params.get('ambassador') ||
        params.get('codigo') ||
        ''
    ).trim();
}


/* =========================================================
   SEGURANÇA HTML
========================================================= */

function escapeHtml(value) {

    return String(value ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');
}


/* =========================================================
   FORMATAÇÃO MONETÁRIA
========================================================= */

function formatMoney(value) {

    const number = Number(value || 0);

    return number.toLocaleString(
        'pt-MZ',
        {
            minimumFractionDigits: 2,
            maximumFractionDigits: 2
        }
    ) + ' MT';
}


/* =========================================================
   NOME
========================================================= */

function getName(data) {

    return (
        data?.name ||
        data?.full_name ||
        data?.fullName ||
        data?.ambassador_name ||
        'Embaixador GEF'
    );
}


/* =========================================================
   STATUS
========================================================= */

function getStatus(data) {

    return String(
        data?.status ||
        data?.ambassador_status ||
        data?.state ||
        'ATIVO'
    ).toUpperCase();
}


/* =========================================================
   ERRO PÚBLICO
========================================================= */

function showPublicError(message) {

    const box =
        document.getElementById('public-message');

    if (!box) return;

    box.textContent = message;

    box.className =
        'message error public-message';

    box.style.display = 'block';
}


/* =========================================================
   MOSTRAR PAINEL FINANCEIRO
========================================================= */

function renderFinancialPanel() {

    const ambassador =
        ambassadorData?.ambassador || {};


    const total =
        document.getElementById(
            'ambassador-total-earned'
        );

    const pending =
        document.getElementById(
            'ambassador-pending'
        );

    const rate =
        document.getElementById(
            'ambassador-commission-rate'
        );


    if (total) {

        total.textContent =
            formatMoney(
                ambassador.total_earned
            );
    }


    if (pending) {

        pending.textContent =
            formatMoney(
                ambassador.pending_commissions
            );
    }


    if (rate) {

        rate.textContent =
            `${Number(
                ambassador.commission_rate || 0
            )}%`;
    }
}


/* =========================================================
   MOSTRAR EMBAIXADOR
========================================================= */

function renderAmbassador() {

    const box =
        document.getElementById(
            'ambassador-box'
        );

    const name =
        document.getElementById(
            'ambassador-name'
        );

    const code =
        document.getElementById(
            'ambassador-code'
        );

    const avatar =
        document.getElementById(
            'ambassador-avatar'
        );


    const ambassador =
        ambassadorData?.ambassador || {};


    const ambassadorName =
        getName(ambassador);


    if (name) {

        name.textContent =
            ambassadorName;
    }


    if (code) {

        code.textContent =
            `Código: ${
                ambassador.referral_code ||
                ambassadorCode
            }`;
    }


    if (avatar) {

        avatar.textContent =
            ambassadorName
                .trim()
                .charAt(0)
                .toUpperCase() || 'G';
    }


    if (box) {

        box.style.display =
            'block';
    }


    renderFinancialPanel();
}


/* =========================================================
   MOSTRAR LOJAS
========================================================= */

function renderStores() {

    const list =
        document.getElementById(
            'stores-list'
        );

    const count =
        document.getElementById(
            'stores-count'
        );


    if (!list) return;


    if (count) {

        count.textContent =
            `${stores.length} ${
                stores.length === 1
                    ? 'loja'
                    : 'lojas'
            }`;
    }


    if (!stores.length) {

        list.innerHTML = `
            <div class="empty-stores">
                Ainda não existem lojas registadas através deste embaixador.
            </div>
        `;

        return;
    }


    list.innerHTML =
        stores.map(store => {

            const name =
                store.name ||
                'Loja GEF';


            const owner =
                store.owner_name ||
                'Não informado';


            const phone =
                store.phone ||
                'Não informado';


            const city =
                store.city ||
                'Não informada';


            const monthlyFee =
                formatMoney(
                    store.monthly_fee
                );


            const paymentStatus =
                store.payment_status ||
                'PENDENTE';


            const commissionRate =
                Number(
                    store.commission_rate || 0
                );


            const commission =
                formatMoney(
                    store.total_commission_earned
                );


            return `
                <article class="store-card">

                    <div class="store-name">
                        ${escapeHtml(name)}
                    </div>

                    <div class="store-city">
                        📍 ${escapeHtml(city)}
                    </div>

                    <div class="store-info">

                        <div>
                            <strong>
                                Responsável:
                            </strong>
                            ${escapeHtml(owner)}
                        </div>

                        <div>
                            <strong>
                                Contacto:
                            </strong>
                            ${escapeHtml(phone)}
                        </div>

                        <div>
                            <strong>
                                Mensalidade:
                            </strong>
                            ${monthlyFee}
                        </div>

                        <div>
                            <strong>
                                Pagamento:
                            </strong>
                            ${escapeHtml(
                                paymentStatus
                            )}
                        </div>

                        <div>
                            <strong>
                                Comissão:
                            </strong>
                            ${commissionRate}%
                        </div>

                        <div>
                            <strong>
                                Comissão gerada:
                            </strong>
                            ${commission}
                        </div>

                    </div>

                    <span class="badge badge-emerald">
                        Registada
                    </span>

                </article>
            `;

        }).join('');
}


/* =========================================================
   CONFIGURAR BOTÃO DE ADESÃO
========================================================= */

function configureCTA() {

    const button =
        document.getElementById(
            'register-store-btn'
        );

    const formSection =
        document.getElementById(
            'form-section'
        );


    if (!button || !formSection) {

        return;
    }


    const ambassador =
        ambassadorData?.ambassador || {};


    const status =
        getStatus(ambassador);


    const blocked =
        status === 'BLOCKED' ||
        status === 'BLOQUEADO' ||
        status === 'DISABLED' ||
        status === 'DESATIVADO' ||
        status === 'INACTIVE';


    if (blocked) {

        button.disabled = true;

        button.textContent =
            'Adesão temporariamente bloqueada';


        button.classList.remove(
            'btn-primary'
        );


        button.classList.add(
            'btn-danger'
        );


        const blockedCard =
            document.getElementById(
                'blocked-card'
            );


        if (blockedCard) {

            blockedCard.style.display =
                'block';
        }


        return;
    }


    button.addEventListener(
        'click',
        () => {

            formSection.style.display =
                'block';


            formSection.scrollIntoView({
                behavior: 'smooth',
                block: 'start'
            });

        }
    );
}


/* =========================================================
   CARREGAR PAINEL
========================================================= */

async function loadAmbassador() {

    ambassadorCode =
        getAmbassadorCode();


    if (!ambassadorCode) {

        showPublicError(
            'Link de embaixador inválido ou incompleto.'
        );

        return;
    }


    if (
        !isSupabaseConfigured() ||
        !supabaseClient
    ) {

        showPublicError(
            'A ligação ao Supabase não está configurada.'
        );

        return;
    }


    supabase =
        supabaseClient;


    try {

        const {
            data,
            error
        } = await supabase.rpc(
            'fn_get_public_ambassador_dashboard',
            {
                p_referral_code:
                    ambassadorCode
            }
        );


        if (error) {

            console.error(
                'Erro ao carregar painel do embaixador:',
                error
            );


            showPublicError(
                'Não foi possível carregar o painel do embaixador.'
            );

            return;
        }


        if (!data) {

            showPublicError(
                'Este link de embaixador não é válido.'
            );

            return;
        }


        if (data.valid === false) {

            showPublicError(
                data.message ||
                'Este link de embaixador não é válido.'
            );

            return;
        }


        ambassadorData =
            data;


        stores =
            Array.isArray(data.stores)
                ? data.stores
                : [];


        renderAmbassador();

        renderStores();

        configureCTA();


    } catch (error) {

        console.error(
            'Erro na página pública do embaixador:',
            error
        );


        showPublicError(
            'Ocorreu um erro ao carregar o painel do embaixador.'
        );
    }
}


/* =========================================================
   INICIALIZAÇÃO
========================================================= */

document.addEventListener(
    'DOMContentLoaded',
    loadAmbassador
);
