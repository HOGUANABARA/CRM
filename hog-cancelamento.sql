-- =====================================================================
-- HOG Gestão — Separar FALTA de CANCELAMENTO
--
-- No VoxComm os dois se confundem: falta é calculada por ausência de
-- dt_entrada, então quem cancelou com antecedência conta como faltante.
-- Aqui o cancelamento é uma AÇÃO registrada, e a falta é o que sobra.
--
-- Rode depois de hog-indicadores.sql.
-- =====================================================================

alter table agendamentos
  add column if not exists cancelado_por      text,
  add column if not exists cancelado_em       timestamptz,
  add column if not exists motivo_cancelamento text,      -- paciente|clinica|convenio|medico|outro
  add column if not exists cancelado_com_antecedencia_h int,  -- horas de antecedência do cancelamento
  add column if not exists chegada_em         timestamptz,     -- equivale ao dt_entrada do VoxComm
  add column if not exists origem_incerta     boolean default false; -- histórico migrado: falta OU cancelamento

-- carimba a antecedência do cancelamento automaticamente
create or replace function fn_marca_cancelamento() returns trigger as $$
begin
  if new.status='cancelado' and (old.status is distinct from 'cancelado') then
    new.cancelado_em := coalesce(new.cancelado_em, now());
    new.cancelado_com_antecedencia_h :=
      greatest(0, extract(epoch from ((new.data + coalesce(new.hora,'00:00'::time)) - new.cancelado_em))/3600)::int;
  end if;
  if new.status in ('compareceu','em_atendimento') and new.chegada_em is null then
    new.chegada_em := now();
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_marca_cancelamento on agendamentos;
create trigger tg_marca_cancelamento before update on agendamentos
  for each row execute function fn_marca_cancelamento();

-- visão da qualidade da agenda: falta real x cancelamento x remarcação
create or replace view vw_falta_cancelamento as
select a.data,
       al.nome                                as padrao,
       m.nome                                 as medico,
       count(*) filter (where a.status in ('compareceu','realizado'))               as atendidos,
       count(*) filter (where a.status='faltou' and not a.origem_incerta)           as faltas_reais,
       count(*) filter (where a.status='faltou' and a.origem_incerta)               as faltas_historico,
       count(*) filter (where a.status='cancelado')                                 as cancelados,
       count(*) filter (where a.status='cancelado'
                          and a.cancelado_com_antecedencia_h >= 24)                 as cancelados_com_24h,
       count(*) filter (where a.status='cancelado'
                          and a.cancelado_com_antecedencia_h < 24)                  as cancelados_em_cima,
       count(*) filter (where a.reagendamento_de is not null)                       as remarcados
  from agendamentos a
  left join agendas_logicas al on al.id = a.agenda_logica_id
  left join medicos m          on m.id  = a.medico_id
 group by 1,2,3;

grant select on vw_falta_cancelamento to anon, authenticated;

-- =====================================================================
-- Como o VoxComm calcularia (para conferir o histórico importado):
--   faltante_voxcomm = faltas_reais + faltas_historico + cancelados
-- A diferença entre esse número e faltas_reais é o quanto a taxa de
-- falta está inflada hoje.
-- =====================================================================
