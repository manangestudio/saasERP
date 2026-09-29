import {
    supabase as supabaseClient,
    isSupabaseConfigured
} from './core/supabase.js';

let supabase = null;
let ambassadorCode = null;
let ambassadorData = null;
let stores = [];

function getAmbassadorCode() {
    const params = new URLSearchParams(window.location.search);

    return (
        params.get('embaixador') ||
        params.get('ambassador') ||
        params.get('codigo') ||
        ''
    ).trim();
}

function escapeHtml(value) {
    return String(value ?? '')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');
}

function getName(data) {
    return (
        data?.full_name ||
        data?.fullName ||
        data?.name ||
        data?.ambassador_name ||
        'Embaixador GEF'
    );
}

function getStatus(data) {
    return String(
        data?.status ||
        data?.ambassador_status ||
        data?.state ||
        'ACTIVE'
    ).toUpperCase();
}

function showPublicError(message) {
    const box = document.getElementById('public-message');

    if (!box) return;

    box.textContent = message;
    box.className = 'message error public-message';
    box.style.display = 'block';
}

function renderAmbassador() {
    const box = document.getElementById('ambassador-box');
    const name = document.getElementById('ambassador-name');
    const code = document.getElementById('ambassador-code');
    const avatar = document.getElementById('ambassador-avatar');

    const ambassadorName = getName(ambassadorData);

    if (name) {
        name.textContent = ambassadorName;
    }

    if (code) {
        code.textContent = `Código: ${ambassadorCode}`;
    }

    if (avatar) {
        avatar.textContent =
            ambassadorName
                .trim()
                .charAt(0)
                .toUpperCase() || 'G';
    }

    if (box) {
        box.style.display = 'block';
    }
}

function renderStores() {
    const list = document.getElementById('stores-list');
    const count = document.getElementById('stores-count');

    if (!list) return;

    if (count) {
        count.textContent =
            `${stores.length} ${stores.length === 1 ? 'loja' : 'lojas'}`;
    }

    if (!stores.length) {
        list.innerHTML = `
            <div class="empty-stores">
                Ainda não existem lojas registadas através deste embaixador.
            </div>
        `;

        return;
    }

    list.innerHTML = stores.map(store => {

        const name =
            store.name ||
            store.store_name ||
            'Loja GEF';

        const city =
            store.city ||
            store.store_city ||
            '';

        return `
            <article class="store-card">

                <div class="store-name">
                    ${escapeHtml(name)}
                </div>

                <div class="store-city">
                    ${city
                        ? `📍 ${escapeHtml(city)}`
                        : 'Empresa associada ao GEF'
                    }
                </div>

                <span class="badge badge-emerald">
                    Registada
                </span>

            </article>
        `;
    }).join('');
}

async function loadStoresFromRPC() {
    /*
     * Primeiro tenta obter as lojas diretamente do resultado
     * do RPC principal.
     */
    if (Array.isArray(ambassadorData?.referred_stores)) {
        return ambassadorData.referred_stores;
    }

    if (Array.isArray(ambassadorData?.stores)) {
        return ambassadorData.stores;
    }

    if (Array.isArray(ambassadorData?.ambassador_referred_stores)) {
        return ambassadorData.ambassador_referred_stores;
    }

    /*
     * Se o RPC principal não devolver as lojas,
     * tenta a função pública específica.
     */
    const { data, error } = await supabase.rpc(
        'fn_get_public_ambassador_stores',
        {
            p_code: ambassadorCode
        }
    );

    if (error) {
        console.warn(
            'Lista pública de lojas indisponível:',
            error
        );

        return [];
    }

    if (Array.isArray(data)) {
        return data;
    }

    return [];
}

function configureCTA() {
    const button =
        document.getElementById('register-store-btn');

    const formSection =
        document.getElementById('form-section');

    if (!button || !formSection) return;

    const status = getStatus(ambassadorData);

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

        button.classList.remove('btn-primary');
        button.classList.add('btn-danger');

        const blockedCard =
            document.getElementById('blocked-card');

        if (blockedCard) {
            blockedCard.style.display = 'block';
        }

        return;
    }

    button.addEventListener('click', () => {

        formSection.style.display = 'block';

        formSection.scrollIntoView({
            behavior: 'smooth',
            block: 'start'
        });
    });
}

async function loadAmbassador() {

    ambassadorCode = getAmbassadorCode();

    if (!ambassadorCode) {
        showPublicError(
            'Link de embaixador inválido ou incompleto.'
        );
        return;
    }

    if (!isSupabaseConfigured() || !supabaseClient) {
        showPublicError(
            'A ligação ao Supabase não está configurada.'
        );
        return;
    }

    supabase = supabaseClient;

    try {

        const { data, error } = await supabase.rpc(
            'fn_validate_ambassador_code',
            {
                p_code: ambassadorCode
            }
        );

        if (error) {
            console.error(
                'Erro ao validar embaixador:',
                error
            );

            showPublicError(
                'Não foi possível validar o link do embaixador.'
            );

            return;
        }

        if (!data) {
            showPublicError(
                'Este link de embaixador não é válido.'
            );

            return;
        }

        ambassadorData =
            Array.isArray(data)
                ? data[0]
                : data;

        if (!ambassadorData) {
            showPublicError(
                'Embaixador não encontrado.'
            );

            return;
        }

        renderAmbassador();

        stores = await loadStoresFromRPC();

        renderStores();

        configureCTA();

    } catch (error) {

        console.error(
            'Erro na página pública de adesão:',
            error
        );

        showPublicError(
            'Ocorreu um erro ao carregar a página de adesão.'
        );
    }
}

document.addEventListener(
    'DOMContentLoaded',
    loadAmbassador
);
