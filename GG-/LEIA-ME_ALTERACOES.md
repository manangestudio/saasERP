# GEF – Alterações desta versão

## Passos obrigatórios (Supabase → SQL Editor)
1. Se ainda não correu: `migracao_embaixadores_v2.sql`.
2. Executar `migracao_embaixadores_v3.sql` (idempotente). Cria a função de liquidação que o
   front-end já chamava mas que não estava definida em nenhum .sql (só se ainda não existir),
   reforça o vínculo loja↔embaixador, enriquece o painel e liga o Realtime.
2b. Executar `migracao_embaixadores_v4.sql` (idempotente; já não depende da v3 ter corrido bem): cria
   `fn_ambassador_portal()` (uma só chamada com tudo o que o painel do embaixador mostra), repara o vínculo
   loja↔embaixador em registos antigos, reafirma as permissões de leitura e liga o Realtime.
2c. (Opcional, recomendado se vende metros decimais) `migracao_precisao_metros_v5.sql`: alarga a precisão do
   stock e dos custos/preços (não perde dados; cada alteração corre isolada).
3. Editar `js/config.js`: `ADMIN_CONTACT` (contacto da administração) e `SITE_URL`.
4. Publicar em HTTPS (PWA exige HTTPS). Ao publicar nova versão, alterar `CACHE_VERSION` em `sw.js`.

## O que mudou
- Embaixador: lojas regulares/atrasadas/bloqueadas/próximas do vencimento, comissão disponível/
  pendente/recebida/previsão, comissão por loja, localização, contacto, histórico de liquidações;
  actualiza sozinho (Realtime + verificação a cada 60 s + ao voltar ao separador).
- PDV: divisores entre produtos. Estoque: categoria + ordenação. Compras: pesquisa/filtros/ordenação
  nas listas e pesquisa/categoria de produto na janela de compra.
- Idioma/moeda: gravados só na loja activa (UPDATE protegido por RLS); "MT" fixo substituído pela
  moeda da loja nos módulos da loja.
- PWA: manifest.webmanifest, sw.js, offline.html, js/pwa.js. Supabase nunca passa pelo cache.

## Correcção: embaixador não via as suas lojas (v4)
- Causa 1 (painel): a tabela de lojas só era desenhada a partir de uma única chamada (`fn_ambassador_tracking`).
  Se essa chamada falhasse, o erro era engolido, a tabela ficava vazia e aparecia um aviso enganador.
  Agora, se falhar, as lojas vinculadas continuam a aparecer (estado registado) e o erro real é mostrado.
- Causa 2 (actualização): ao entrar em estado de erro/vazio, a actualização automática desligava-se para sempre.
  Agora só pára quando o utilizador sai do painel; verifica a cada 30 s, em tempo real e ao voltar ao separador.
- Causa 3 (dados): registos de loja indicada sem `store_id` apareciam como "SEM LOJA" e nunca geravam comissão.
  A v4 liga-os (mesmo id; ou nome+telefone só quando a correspondência é única).
- `sw.js`: `CACHE_VERSION` passou a `gef-v2`.

## Correcção definitiva: painel do Embaixador (v4 + front-end)
- O painel agora usa `fn_ambassador_portal()` (SECURITY DEFINER): não depende de RLS nem de `get_auth_user_role()`
  e cada secção falha isolada (devolve o resto + `warnings`). Se a v4 ainda não foi executada, o painel cai
  automaticamente para o caminho antigo e continua a mostrar as lojas vinculadas.
- A informação PERMANECE: o último estado bom fica em memória e em `localStorage`; se uma actualização falhar
  mostra a última informação guardada com aviso, e volta a tentar sozinho (30 s, Realtime, ao voltar ao separador).
- Um "perfil não encontrado" vindo de uma falha temporária já não apaga o que estava a ser mostrado.
- Diagnóstico (opcional): consulta no fim do `migracao_embaixadores_v4.sql` mostra, por embaixador, se o login
  está ligado (`user_id`), a função do login, as lojas vinculadas e as sem loja real.

## Dashboard do Administrador: vendido, custo e lucro
- Novo painel (só Administrador da loja): Vendido / Custo / Lucro de hoje e Lucro do mês, e tabela de lucro por
  item vendido (quantidade, vendido, custo, lucro, margem). Actualiza sozinho (15 s, ao voltar ao separador e a
  cada venda via Realtime). Só conta vendas CONCLUÍDAS (estornos ficam de fora). Custo = custo real do lote vendido.
- "Hoje" passou a ser o dia LOCAL (antes usava UTC: vendas depois das 22h contavam para o dia seguinte).

## Preços em metros (inteiros e decimais)
- Total da linha = quantidade × preço unitário, arredondado a 2 casas por linha (igual ao servidor), em vez de
  somar valores sem arredondar (podia diferir 0,01 do total gravado). Quantidades a 3 casas, sem deriva binária
  (0,1+0,2), aceita vírgula, e campo de quantidade mais largo para caber 12,345.
- Preço de embalagem sem preço próprio = preço por metro × metros da embalagem (proporcional).
- `sw.js`: `CACHE_VERSION` passou a `gef-v3`. `pwa.js`: já não recarrega a página na primeira instalação.

## Correcção: página `adesao.html` só mostrava o botão «Cadastrar» (v5-painel)
- Causa: `adesao.html` é a página PÚBLICA do link do embaixador. `adesao-publica.js` escondia sempre as secções
  de resumo e lojas (`display:none`), a função que desenhava as lojas nunca era chamada, e a página não tinha
  nenhuma ligação ao painel real (`index.html?tab=EMBAIXADORES`). Quem abria o link só via o botão.
- Agora, na mesma página: visitante anónimo continua a ver só o nome/código e o botão (sem dados privados);
  o Embaixador autenticado (perfil EMBAIXADOR, confirmado por `fn_ambassador_portal`, que liga ao `auth.uid()`)
  vê resumo, lojas com estado real, comissões, link pessoal + WhatsApp e notificações; estado vazio informativo.
- Sessão expirada, perfil errado, sem cadastro, link de outro embaixador e falha de rede têm mensagem própria;
  numa falha temporária mantém-se a última informação carregada.
- Se o dono do link regista uma loja nesta página, usa `fn_ambassador_create_store` (não troca a sessão dele).
- Painel do SPA (`modules/embaixadores`): acrescentados botão WhatsApp e cartão de Notificações.
- Novo ficheiro `js/core/ambassador-view.js` (lógica pura, partilhada). `sw.js`: `gef-v4` + novo ficheiro no cache.
- Não é preciso executar SQL novo. Requer a `migracao_embaixadores_v4.sql` já executada (cria `fn_ambassador_portal`).
