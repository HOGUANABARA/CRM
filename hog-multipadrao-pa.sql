-- =====================================================================
-- HOG Gestão — Dois padrões no mesmo período + disponibilidade de P.A.
--
-- PROBLEMA 1: o médico atende córnea E catarata no mesmo período, sem
-- horário pré-definido. O repasse não pode sair do BLOCO (o bloco tem
-- os dois) — ele sai do PADRÃO de cada atendimento.
--   bloco (reserva) ──< reserva_padroes >── padrão ── contrato ── repasse
--   O agendamento já nasce com o padrão; o faturamento lê o contrato
--   daquele padrão e congela a regra no momento da realização.
--
-- PROBLEMA 2: no planejamento é preciso saber quem cobre o P.A.
--
-- Rode depois de hog-grade.sql e hog-contratos.sql.
-- =====================================================================

-- 1) um bloco pode servir a vários padrões ------------------------------------
create table if not exists reserva_padroes (
  reserva_id uuid not null references reservas(id) on delete cascade,
  agenda_logica_id text not null references agendas_logicas(id),
  cota int,                       -- vagas reservadas para este padrão; null = divide o total
  ordem int default 1,
  primary key (reserva_id, agenda_logica_id));

create index if not exists ix_rp_reserva on reserva_padroes(reserva_id);

grant all on reserva_padroes to anon, authenticated;
alter table reserva_padroes enable row level security;
drop policy if exists p_rp on reserva_padroes;
create policy p_rp on reserva_padroes for all using (true) with check (true);

-- migra o que já existe (bloco com um padrão só)
insert into reserva_padroes (reserva_id, agenda_logica_id, ordem)
select id, agenda_logica_id, 1 from reservas
where agenda_logica_id is not null
on conflict do nothing;

-- 2) P.A. no planejamento -----------------------------------------------------
alter table reservas
  add column if not exists atende_pa  boolean default false,   -- este médico cobre P.A. no período
  add column if not exists pa_limite  int;                     -- quantos P.A. aceita (null = sem limite)

-- 3) repasse congelado no atendimento (o faturamento não pode mudar depois) ---
alter table agendamentos
  add column if not exists contrato_id        text references contratos(id),
  add column if not exists repasse_tipo       text,
  add column if not exists repasse_percentual numeric(5,2),
  add column if not exists repasse_valor      numeric(12,2),
  add column if not exists repasse_base       text,
  add column if not exists repasse_congelado_em timestamptz;

-- congela a regra quando o atendimento é realizado
create or replace function fn_congela_repasse() returns trigger as $$
declare c record;
begin
  if new.status in ('compareceu','realizado') and new.repasse_congelado_em is null then
    select ct.* into c
      from agendas_logicas al
      join contratos ct on ct.id = al.contrato_id
     where al.id = new.agenda_logica_id;
    if found then
      new.contrato_id        := c.id;
      new.repasse_tipo       := c.tipo_remuneracao;
      new.repasse_percentual := c.percentual;
      new.repasse_valor      := c.valor;
      new.repasse_base       := c.base_calculo;
      new.repasse_congelado_em := now();
    end if;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_congela_repasse on agendamentos;
create trigger tg_congela_repasse before insert or update on agendamentos
  for each row execute function fn_congela_repasse();

-- 4) visão para o faturamento: repasse atendimento a atendimento -------------
create or replace view vw_repasse_atendimento as
select a.id                         as agendamento_id,
       a.data, a.hora, a.status,
       a.paciente_id, p.nome        as paciente,
       a.medico_id,   m.nome        as medico,
       a.agenda_logica_id, al.nome  as padrao,
       al.tipo                      as tipo_padrao,
       coalesce(a.contrato_id, al.contrato_id)          as contrato_id,
       coalesce(a.repasse_tipo, ct.tipo_remuneracao)    as repasse_tipo,
       coalesce(a.repasse_percentual, ct.percentual)    as repasse_percentual,
       coalesce(a.repasse_valor, ct.valor)              as repasse_valor,
       coalesce(a.repasse_base, ct.base_calculo)        as repasse_base,
       a.repasse_congelado_em
  from agendamentos a
  left join pacientes p      on p.id = a.paciente_id
  left join medicos   m      on m.id = a.medico_id
  left join agendas_logicas al on al.id = a.agenda_logica_id
  left join contratos ct     on ct.id = al.contrato_id
 where a.status <> 'cancelado';

grant select on vw_repasse_atendimento to anon, authenticated;

-- 5) exemplo real: Dr. Lucas atende córnea e catarata no mesmo período --------
insert into agendas_logicas (id,nome,medico_id,especialidade_id,tipo,modo_contagem,tempo_atendimento_min,qtd_periodo)
values ('cornea_lucas','Córnea — Dr. Lucas','lucas','cornea','consulta','encaixe',20,6)
on conflict (id) do nothing;

insert into contratos (id,nome,medico_id,tipo_remuneracao,percentual,base_calculo,periodicidade,vigencia_ini,observacao)
values ('ct_lucas_cornea','Córnea 40% — Dr. Lucas','lucas','repasse_percentual',40,'faturamento recebido','por_atendimento','2026-01-01','Córnea tem repasse diferente da catarata'),
       ('ct_lucas_cat','Catarata 25% — Dr. Lucas','lucas','repasse_percentual',25,'faturamento recebido','por_atendimento','2026-01-01',null)
on conflict (id) do nothing;

update agendas_logicas set contrato_id='ct_lucas_cornea' where id='cornea_lucas';
update agendas_logicas set contrato_id='ct_lucas_cat'    where id='lu_cat';

-- P.A. nos blocos que já existem com esse nome
update reservas set atende_pa=true where titulo ilike '%P.A%';
