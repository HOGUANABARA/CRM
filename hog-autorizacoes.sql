-- =====================================================================
-- HOG Gestão — Autorização do convênio por PROCEDIMENTO e QUANTIDADE
--               + a foto da requisição que chega pelo DIGISAC
--
-- Como é na prática:
--   • a requisição é gerada pelo CONVÊNIO e chega em FOTO pelo DIGISAC,
--     na hora do agendamento;
--   • a autorização é POR PROCEDIMENTO e POR QUANTIDADE
--     (ex.: 2 OCT + 1 TOPO na mesma guia);
--   • cada agendamento CONSOME uma unidade do item autorizado.
--
-- Rode depois de hog-requisicoes.sql.
-- =====================================================================

-- 1) a guia/autorização em si -------------------------------------------------
create table if not exists autorizacoes (
  id uuid primary key default gen_random_uuid(),
  paciente_id uuid references pacientes(id),
  convenio_id text references convenios(id),
  numero_requisicao text,                    -- número da guia gerada pelo convênio
  senha_autorizacao text,                    -- senha/autorização quando o convênio exige
  emitida_em date default current_date,
  validade date,
  medico_solicitante_id text references medicos(id),
  status text default 'ativa',               -- ativa | vencida | esgotada | cancelada
  origem text default 'digisac',             -- digisac | recepcao | portal | email
  recebida_em timestamptz default now(),
  telefone_origem text,                      -- de quem chegou no DIGISAC
  observacao text);

create index if not exists ix_aut_paciente on autorizacoes(paciente_id, status);

-- 2) os itens: procedimento + quantidade autorizada ---------------------------
create table if not exists autorizacao_itens (
  id uuid primary key default gen_random_uuid(),
  autorizacao_id uuid not null references autorizacoes(id) on delete cascade,
  exame_id text references exames(id),
  procedimento_id text references procedimentos(id),
  descricao text,                            -- o que está escrito na guia
  codigo_tuss text,
  lateralidade text,                         -- OD | OE | AO
  quantidade_autorizada int not null default 1,
  quantidade_utilizada  int not null default 0,
  valor_autorizado numeric(12,2));

create index if not exists ix_aut_item on autorizacao_itens(autorizacao_id);

-- 3) a FOTO da requisição (chega pelo DIGISAC) --------------------------------
create table if not exists anexos (
  id uuid primary key default gen_random_uuid(),
  tipo text default 'requisicao',            -- requisicao | autorizacao | documento | exame
  autorizacao_id uuid references autorizacoes(id) on delete cascade,
  paciente_id uuid references pacientes(id),
  solicitacao_id uuid references solicitacoes(id),
  url text,                                  -- link da imagem (Storage do Supabase ou DIGISAC)
  nome_arquivo text,
  origem text default 'digisac',
  recebido_em timestamptz default now(),
  recebido_por text,
  observacao text);

create index if not exists ix_anexo_pac on anexos(paciente_id, tipo);

grant all on autorizacoes, autorizacao_itens, anexos to anon, authenticated;
alter table autorizacoes      enable row level security;
alter table autorizacao_itens enable row level security;
alter table anexos            enable row level security;
drop policy if exists p_aut  on autorizacoes;
drop policy if exists p_auti on autorizacao_itens;
drop policy if exists p_anx  on anexos;
create policy p_aut  on autorizacoes      for all using (true) with check (true);
create policy p_auti on autorizacao_itens for all using (true) with check (true);
create policy p_anx  on anexos            for all using (true) with check (true);

-- 4) o agendamento consome uma unidade do item -------------------------------
alter table agendamentos      add column if not exists autorizacao_item_id uuid references autorizacao_itens(id);
alter table exame_agendamentos add column if not exists autorizacao_item_id uuid references autorizacao_itens(id);

create or replace function fn_consome_autorizacao() returns trigger as $$
declare it record;
begin
  if new.autorizacao_item_id is not null
     and (TG_OP='INSERT' or old.autorizacao_item_id is distinct from new.autorizacao_item_id) then
    select * into it from autorizacao_itens where id = new.autorizacao_item_id;
    if found then
      if it.quantidade_utilizada >= it.quantidade_autorizada then
        raise exception 'Autorização esgotada para % (autorizado %, usado %)',
          coalesce(it.descricao,it.exame_id,it.procedimento_id), it.quantidade_autorizada, it.quantidade_utilizada;
      end if;
      update autorizacao_itens set quantidade_utilizada = quantidade_utilizada + 1
       where id = new.autorizacao_item_id;
    end if;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_consome_autorizacao on agendamentos;
create trigger tg_consome_autorizacao before insert or update on agendamentos
  for each row execute function fn_consome_autorizacao();

-- devolve a unidade quando o agendamento é cancelado
create or replace function fn_devolve_autorizacao() returns trigger as $$
begin
  if new.status='cancelado' and old.status<>'cancelado' and new.autorizacao_item_id is not null then
    update autorizacao_itens set quantidade_utilizada = greatest(quantidade_utilizada-1,0)
     where id = new.autorizacao_item_id;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_devolve_autorizacao on agendamentos;
create trigger tg_devolve_autorizacao before update on agendamentos
  for each row execute function fn_devolve_autorizacao();

-- 5) saldo por item — é o que o call center precisa ver ----------------------
create or replace view vw_saldo_autorizacao as
select a.id                as autorizacao_id,
       a.paciente_id, p.nome as paciente,
       cv.nome             as convenio,
       a.numero_requisicao, a.senha_autorizacao,
       a.validade,
       (a.validade < current_date) as vencida,
       (a.validade - current_date) as dias_para_vencer,
       i.id                as item_id,
       coalesce(i.descricao, ex.nome, pr.nome) as item,
       i.lateralidade,
       i.quantidade_autorizada,
       i.quantidade_utilizada,
       (i.quantidade_autorizada - i.quantidade_utilizada) as saldo,
       (select count(*) from anexos an where an.autorizacao_id = a.id) as fotos,
       a.status
  from autorizacoes a
  join autorizacao_itens i on i.autorizacao_id = a.id
  left join pacientes p    on p.id = a.paciente_id
  left join convenios cv   on cv.id = a.convenio_id
  left join exames ex      on ex.id = i.exame_id
  left join procedimentos pr on pr.id = i.procedimento_id
 where a.status='ativa';

grant select on vw_saldo_autorizacao to anon, authenticated;

-- 6) marca as vencidas e as esgotadas ---------------------------------------
create or replace function fn_atualiza_autorizacoes() returns void as $$
  update autorizacoes set status='vencida' where status='ativa' and validade < current_date;
  update autorizacoes a set status='esgotada'
   where a.status='ativa'
     and not exists (select 1 from autorizacao_itens i
                      where i.autorizacao_id=a.id
                        and i.quantidade_utilizada < i.quantidade_autorizada);
$$ language sql;

-- =====================================================================
-- 7) SOLICITADO ≠ AUTORIZADO
--    O médico pede 2 olhos e o convênio autoriza 1. O sistema precisa
--    mostrar a diferença, agendar o que foi autorizado e manter o resto
--    pendente — em vez de perder o olho que ficou de fora.
-- =====================================================================
alter table solicitacoes
  add column if not exists quantidade_solicitada int default 1,
  add column if not exists quantidade_autorizada int,
  add column if not exists autorizacao_item_id uuid references autorizacao_itens(id),
  add column if not exists olhos_pendentes text;      -- OD | OE | AO — o que ficou sem autorização

-- lateralidade AO conta como 2 unidades
update solicitacoes set quantidade_solicitada = case when lateralidade='AO' then 2 else 1 end
 where quantidade_solicitada is null or quantidade_solicitada = 1;

create or replace view vw_divergencia_autorizacao as
select s.id                     as solicitacao_id,
       s.paciente_id, p.nome    as paciente,
       coalesce(ex.nome, pr.nome, s.nome_item) as item,
       s.lateralidade           as solicitado_para,
       s.quantidade_solicitada,
       coalesce(i.quantidade_autorizada,0)                        as quantidade_autorizada,
       coalesce(i.quantidade_utilizada,0)                         as ja_agendado,
       (coalesce(i.quantidade_autorizada,0) - coalesce(i.quantidade_utilizada,0)) as saldo_autorizado,
       (s.quantidade_solicitada - coalesce(i.quantidade_autorizada,0))            as nao_autorizado,
       a.numero_requisicao, a.senha_autorizacao, a.validade,
       cv.nome                  as convenio,
       case
         when i.id is null                                                then 'sem autorização ainda'
         when i.quantidade_autorizada >= s.quantidade_solicitada          then 'autorizado integral'
         when i.quantidade_autorizada = 0                                 then 'negado'
         else 'autorizado parcial — falta '||(s.quantidade_solicitada - i.quantidade_autorizada)||' olho(s)'
       end as situacao
  from solicitacoes s
  left join autorizacao_itens i on i.id = s.autorizacao_item_id
  left join autorizacoes a      on a.id = i.autorizacao_id
  left join pacientes p         on p.id = s.paciente_id
  left join convenios cv        on cv.id = s.convenio_id
  left join exames ex           on ex.id = s.exame_id
  left join procedimentos pr    on pr.id = s.procedimento_id
 where s.status in ('pendente','entregue','agendado');

grant select on vw_divergencia_autorizacao to anon, authenticated;

-- ao agendar consumindo a autorização, registra qual olho foi e o que sobrou
create or replace function fn_atualiza_pendencia_olho() returns trigger as $$
declare s record; i record;
begin
  if new.solicitacao_id is not null and new.autorizacao_item_id is not null then
    select * into s from solicitacoes where id = new.solicitacao_id;
    select * into i from autorizacao_itens where id = new.autorizacao_item_id;
    if found and s.lateralidade='AO' and i.quantidade_autorizada < 2 then
      update solicitacoes
         set olhos_pendentes = case when new.lateralidade='OD' then 'OE'
                                    when new.lateralidade='OE' then 'OD' else 'AO' end,
             status = 'entregue',      -- continua pendente: falta o outro olho
             quantidade_autorizada = i.quantidade_autorizada
       where id = new.solicitacao_id;
    end if;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_pendencia_olho on agendamentos;
create trigger tg_pendencia_olho after insert on agendamentos
  for each row execute function fn_atualiza_pendencia_olho();
