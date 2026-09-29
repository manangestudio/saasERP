/**
 * GEF - ADESÃO PÚBLICA POR EMBAIXADOR
 *
 * Fluxo:
 * 1. Lê o código do embaixador da URL.
 * 2. Valida o embaixador no Supabase.
 * 3. Cria o utilizador através do Supabase Auth.
 * 4. Completa o onboarding através da RPC segura.
 * 5. Cria a loja em public.stores.
 * 6. Liga o ADMIN à loja em public.profiles.
 * 7. Regista a relação em ambassador_referred_stores.
 */

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

import {
    getSupabaseConfig,
    isSupabaseConfigured
} from './core/supabase.js';


let supabase = null;
let ambassador = null;


/* =========================================================
   ELEMENTOS
========================================================= */

const form = document.getElementById('adesao-form');
const submitButton = document.getElementById('submit-btn');
const messageBox = document.getElementById('message');

const ambassadorBox = document.getElementById('ambassador-box');
const ambassadorName = document.getElementById('ambassador-name');


/* =========================================================
   MENSAGENS
========================================================= */

function showMessage(message, type = 'error') {

    messageBox.textContent = message;

    messageBox.className = `message ${type}`;

    messageBox.style.display = 'block';
}


function hideMessage() {

    messageBox.style.display = 'none';

    messageBox.textContent = '';
}


/* =========================================================
   CONFIGURAÇÃO SUPABASE
========================================================= */

function initializeSupabase() {

    if (!isSupabaseConfigured()) {

        throw new Error(
            'A ligação com o Supabase ainda não está configurada.'
        );
    }

    const config = getSupabaseConfig();

    if (!config?.url || !config?.anonKey) {

        throw new Error(
            'Configuração do Supabase inválida.'
        );
    }

    supabase = createClient(
        config.url,
        config.anonKey
    );
}


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
   VALIDAR EMBAIXADOR
========================================================= */

async function loadAmbassador() {

    const code = getAmbassadorCode();

    if (!code) {

        throw new Error(
            'Link de adesão inválido. O código do embaixador não foi informado.'
        );
    }

    const { data, error } = await supabase
        .rpc(
            'fn_validate_ambassador_code',
            {
                p_referral_code: code
            }
        );

    if (error) {

        console.error(
            'Erro ao validar embaixador:',
            error
        );

        throw new Error(
            'Não foi possível validar o link do embaixador.'
        );
    }

    if (!data) {

        throw new Error(
            'Este link de embaixador é inválido ou está inativo.'
        );
    }

    ambassador = data;

    ambassadorName.textContent =
        ambassador.name || ambassador.referral_code || code;

    ambassadorBox.style.display = 'block';
}


/* =========================================================
   OBTER DADOS DO FORMULÁRIO
========================================================= */

function getFormData() {

    const data = new FormData(form);

    return {

        storeName:
            String(data.get('storeName') || '').trim(),

        ownerName:
            String(data.get('ownerName') || '').trim(),

        phone:
            String(data.get('phone') || '').trim(),

        city:
            String(data.get('city') || '').trim(),

        address:
            String(data.get('address') || '').trim(),

        nuitNif:
            String(data.get('nuitNif') || '').trim(),

        monthlyFee:
            Number(data.get('monthlyFee') || 0),

        adminEmail:
            String(data.get('adminEmail') || '').trim().toLowerCase(),

        adminPassword:
            String(data.get('adminPassword') || '')
    };
}


/* =========================================================
   VALIDAÇÃO
========================================================= */

function validateForm(data) {

    if (!data.storeName) {

        throw new Error(
            'Informe o nome da empresa / loja.'
        );
    }

    if (!data.ownerName) {

        throw new Error(
            'Informe o nome do responsável.'
        );
    }

    if (!data.phone) {

        throw new Error(
            'Informe o telefone.'
        );
    }

    if (!data.city) {

        throw new Error(
            'Informe a cidade.'
        );
    }

    if (!data.adminEmail) {

        throw new Error(
            'Informe o e-mail do administrador.'
        );
    }

    if (!data.adminPassword || data.adminPassword.length < 6) {

        throw new Error(
            'A palavra-passe deve ter pelo menos 6 caracteres.'
        );
    }

    if (
        !Number.isFinite(data.monthlyFee) ||
        data.monthlyFee < 0
    ) {

        throw new Error(
            'A mensalidade informada é inválida.'
        );
    }
}


/* =========================================================
   CRIAR CONTA
========================================================= */

async function createAuthUser(data) {

    const { data: authData, error } =
        await supabase.auth.signUp({

            email: data.adminEmail,

            password: data.adminPassword,

            options: {

                data: {
                    full_name: data.ownerName
                }
            }
        });


    if (error) {

        console.error(
            'Erro Supabase Auth:',
            error
        );

        throw new Error(
            error.message ||
            'Não foi possível criar a conta.'
        );
    }


    if (!authData?.user) {

        throw new Error(
            'O Supabase não devolveu o utilizador criado.'
        );
    }


    return authData;
}


/* =========================================================
   COMPLETAR ONBOARDING
========================================================= */

async function completeOnboarding(data, authData) {

    /*
     * Normalmente, quando a confirmação de e-mail
     * está desativada, o Supabase devolve uma sessão.
     */

    if (!authData.session) {

        /*
         * Guardamos os dados localmente para permitir
         * continuar depois da confirmação do e-mail.
         */

        const pendingData = {

            ambassadorCode:
                ambassador.referral_code,

            storeName:
                data.storeName,

            ownerName:
                data.ownerName,

            phone:
                data.phone,

            city:
                data.city,

            address:
                data.address,

            nuitNif:
                data.nuitNif,

            monthlyFee:
                data.monthlyFee,

            adminEmail:
                data.adminEmail,

            createdAt:
                new Date().toISOString()
        };


        localStorage.setItem(
            'gef_pending_ambassador_onboarding',
            JSON.stringify(pendingData)
        );


        showMessage(
            'A conta foi criada. Verifique o seu e-mail para confirmar a conta. Depois de confirmar, entre novamente no sistema para concluir o registo da empresa.',
            'success'
        );

        return false;
    }


    const { data: result, error } =
        await supabase.rpc(
            'fn_complete_ambassador_onboarding',
            {
                p_ambassador_code:
                    ambassador.referral_code,

                p_store_name:
                    data.storeName,

                p_owner_name:
                    data.ownerName,

                p_phone:
                    data.phone,

                p_city:
                    data.city,

                p_address:
                    data.address,

                p_nuit_nif:
                    data.nuitNif,

                p_monthly_fee:
                    data.monthlyFee,

                p_admin_email:
                    data.adminEmail
            }
        );


    if (error) {

        console.error(
            'Erro ao completar onboarding:',
            error
        );

        throw new Error(
            error.message ||
            'A conta foi criada, mas não foi possível concluir o registo da empresa.'
        );
    }


    if (!result) {

        throw new Error(
            'O Supabase não confirmou a criação da empresa.'
        );
    }


    localStorage.removeItem(
        'gef_pending_ambassador_onboarding'
    );


    return true;
}


/* =========================================================
   SUBMIT
========================================================= */

form.addEventListener(
    'submit',
    async event => {

        event.preventDefault();

        hideMessage();

        submitButton.disabled = true;

        submitButton.textContent =
            'A processar...';


        try {

            if (!supabase) {

                initializeSupabase();
            }


            const data = getFormData();


            validateForm(data);


            /*
             * Se ainda não carregamos o embaixador,
             * carregamos agora.
             */

            if (!ambassador) {

                await loadAmbassador();
            }


            /*
             * Cria o utilizador no Auth.
             */

            const authData =
                await createAuthUser(data);


            /*
             * Cria a loja, perfil ADMIN e
             * relação com o embaixador.
             */

            const completed =
                await completeOnboarding(
                    data,
                    authData
                );


            if (!completed) {

                submitButton.disabled = true;

                submitButton.textContent =
                    'Aguardando confirmação de e-mail';

                return;
            }


            showMessage(
                'Registo concluído com sucesso! A empresa e o utilizador administrador foram criados.',
                'success'
            );


            form.reset();


            submitButton.textContent =
                'Registo concluído';


            /*
             * Não fazemos logout aqui porque a sessão
             * criada pelo Supabase pertence ao novo ADMIN.
             */

        } catch (error) {

            console.error(
                'Erro na adesão:',
                error
            );


            showMessage(
                error?.message ||
                'Ocorreu um erro ao processar a adesão.',
                'error'
            );


            submitButton.disabled = false;

            submitButton.textContent =
                'Criar conta e registar empresa';
        }

    }
);


/* =========================================================
   INICIALIZAÇÃO
========================================================= */

(async function init() {

    try {

        initializeSupabase();

        await loadAmbassador();

    } catch (error) {

        console.error(
            'Erro inicial:',
            error
        );

        showMessage(
            error?.message ||
            'Não foi possível carregar o link de adesão.',
            'error'
        );

        submitButton.disabled = true;
    }

})();
