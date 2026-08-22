-- =====================================================================
-- HOG Gestão — Vagas extras por negociação especial
--
-- A coordenação pode abrir vagas ADICIONAIS em qualquer agenda para o
-- call center — ex.: "Dr. Monir aceitou mais 20 pacientes", podendo
-- inclusive colocar 2 pacientes no mesmo horário (encaixe duplo).
-- Isso NÃO é a capacidade normal da agenda: é uma negociação, com
-- quem autorizou, motivo, validade e — se for o caso — pagamento
-- diferente do contrato padrão.
--
-- Rode depois de hog-multipadrao-pa.sql.
-- =====================================================================

create table if not exists vagas_extras (
  id uuid primary key default gen_random_uuid(),
  reserva_id uuid references reservas(id) on delete cascade,   -- bloco específico...
  agenda_logica_id text references agendas_logicas(id),        -- ...ou a agenda como um todo
  medico_id text references medicos(id),
  data date,                                                   -- dia em que valem
  quantidade int not null,                                     -- quantas vagas a mais
  max_por_horario int default 1,                               -- 2 = dois pacientes no mesmo horário
  motivo text,                                                 -- "mutirão de catarata", "fila de espera"
  negociacao text,                                             -- o que foi combinado com o médico
  autorizado_por text,                                         -- quem da coordenação liberou
  autorizado_em timestamptz default now(),
  valido_ate date,                                             -- até quando o call center pode usar
  contrato_id text references contratos(id),                   -- repasse diferente nessa negociação
  valor_acordado numeric(12,2),
  status text default 'ativa',                                 -- ativa | encerrada | esgotada
  usadas int default 0,
  observacao text);

create index if not exists ix_ve_reserva on vagas_extras(reserva_id);
create index if not exists ix_ve_agenda  on vagas_extras(agenda_logica_id, data);

grant all on vagas_extras to anon, authenticated;
alter table vagas_extras enable row level security;
drop policy if exists p_ve on vagas_extras;
create policy p_ve on vagas_extras for all using (true) with check (true);

-- quantos pacientes podem ocupar o mesmo horário no bloco (padrão: 1)
alter table reservas add column if not exists max_por_horario int default 1;

-- o agendamento registra se nasceu de uma vaga extra (para o faturamento e os indicadores)
alter table agendamentos
  add column if not exists vaga_extra_id uuid references vagas_extras(id),
  add column if not exists sobreposto boolean default false;   -- 2º paciente no mesmo horário

-- o aviso ao call center também serve para "abriram vagas extras"
-- (a coluna tipo já existe; aqui só documentamos os valores usados)
--   agenda_liberada | vagas_extras | agenda_cancelada

-- visão de capacidade: base do padrão + extras ativos
create or replace view vw_capacidade_agenda as
select r.id                          as reserva_id,
       r.data, r.medico_id, r.sala_id, r.estado,
       rp.agenda_logica_id,
       al.nome                       as padrao,
       coalesce(rp.cota, al.qtd_periodo)                          as vagas_base,
       coalesce((select sum(ve.quantidade) from vagas_extras ve
                  where ve.status='ativa'
                    and (ve.reserva_id = r.id
                     or (ve.agenda_logica_id = rp.agenda_logica_id and ve.data = r.data))),0) as vagas_extras,
       (select count(*) from agendamentos a
         where a.agenda_logica_id = rp.agenda_logica_id and a.data = r.data
           and a.status <> 'cancelado')                            as agendados
  from reservas r
  join reserva_padroes rp on rp.reserva_id = r.id
  left join agendas_logicas al on al.id = rp.agenda_logica_id;

grant select on vw_capacidade_agenda to anon, authenticated;

-- exemplo: Dr. Monir aceitou 20 pacientes a mais, com 2 por horário
insert into vagas_extras (agenda_logica_id, medico_id, data, quantidade, max_por_horario,
                          motivo, negociacao, autorizado_por, valido_ate, observacao)
select null,'monir', current_date + 7, 20, 2,
       'Fila de espera de rotina','Dr. Monir aceitou atender 20 pacientes a mais no período, 2 por horário',
       'coordenação', current_date + 14, 'Negociação especial — não é a capacidade normal da agenda'
where not exists (select 1 from vagas_extras where medico_id='monir');
