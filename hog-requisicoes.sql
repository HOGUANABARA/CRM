-- =====================================================================
-- HOG Gestão — Requisição, autorização do convênio e pendências do paciente
--
-- Regras da operação:
--   • exame/procedimento só se agenda COM REQUISIÇÃO;
--   • a requisição tem NÚMERO e VALIDADE;
--   • se o convênio exigir, precisa de AUTORIZAÇÃO (senha) antes de agendar;
--   • o call center precisa ver a pendência SEM abrir cadastro ou prontuário.
--
-- Rode depois de hog-atendimentos.sql.
-- =====================================================================

-- 1) a requisição (guia) do médico ------------------------------------------
alter table solicitacoes
  add column if not exists numero_requisicao   text,
  add column if not exists requisicao_emitida  date default current_date,
  add column if not exists requisicao_validade date,
  add column if not exists exige_autorizacao   boolean default false,
  add column if not exists autorizacao_status  text default 'nao_requer',
     -- nao_requer | pendente | solicitada | autorizada | negada | vencida
  add column if not exists autorizacao_senha   text,        -- senha/nº da autorização
  add column if not exists autorizacao_validade date,
  add column if not exists autorizacao_solicitada_em timestamptz,
  add column if not exists autorizacao_em      timestamptz,
  add column if not exists autorizacao_por     text,
  add column if not exists autorizacao_obs     text;

create index if not exists ix_sol_paciente on solicitacoes(paciente_id, status);

-- 2) o convênio diz se exige autorização e por quanto tempo vale -------------
alter table convenios
  add column if not exists exige_autorizacao_exame     boolean default false,
  add column if not exists exige_autorizacao_cirurgia  boolean default true,
  add column if not exists validade_requisicao_dias    int default 30,
  add column if not exists validade_autorizacao_dias   int default 30,
  add column if not exists portal_autorizacao          text;   -- onde a equipe consulta

update convenios set exige_autorizacao_exame=true where tipo='convenio';
update convenios set exige_autorizacao_exame=false, exige_autorizacao_cirurgia=false where tipo='particular';

-- 3) preenche validade e exigência automaticamente na criação ---------------
create or replace function fn_prepara_requisicao() returns trigger as $$
declare c record;
begin
  select * into c from convenios where id = new.convenio_id;
  if found then
    if new.requisicao_validade is null then
      new.requisicao_validade := coalesce(new.requisicao_emitida, current_date)
                                 + coalesce(c.validade_requisicao_dias,30);
    end if;
    if new.exige_autorizacao is null or new.exige_autorizacao = false then
      new.exige_autorizacao := case
        when new.procedimento_id is not null then coalesce(c.exige_autorizacao_cirurgia,false)
        else coalesce(c.exige_autorizacao_exame,false) end;
    end if;
    if new.exige_autorizacao and new.autorizacao_status = 'nao_requer' then
      new.autorizacao_status := 'pendente';
    end if;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_prepara_requisicao on solicitacoes;
create trigger tg_prepara_requisicao before insert on solicitacoes
  for each row execute function fn_prepara_requisicao();

-- 4) o agendamento guarda a requisição que o autorizou -----------------------
alter table agendamentos
  add column if not exists numero_requisicao text,
  add column if not exists autorizacao_senha text;

-- 5) PENDÊNCIAS DO PACIENTE — é o que aparece embaixo do nome ---------------
create or replace view vw_pendencias_paciente as
select s.paciente_id,
       s.id                                   as solicitacao_id,
       coalesce(ex.nome, pr.nome, s.nome_item) as item,
       case when s.exame_id is not null then 'exame'
            when s.procedimento_id is not null then 'procedimento'
            else 'retorno' end                as natureza,
       s.lateralidade,
       m.nome                                 as medico_solicitante,
       cv.nome                                as convenio,
       s.numero_requisicao,
       s.requisicao_validade,
       (s.requisicao_validade < current_date) as requisicao_vencida,
       (s.requisicao_validade - current_date) as dias_para_vencer,
       s.exige_autorizacao,
       s.autorizacao_status,
       s.autorizacao_senha,
       s.autorizacao_validade,
       s.status,
       s.observacao_proximo_agendamento,
       s.retorno_data,
       /* pode agendar? */
       (s.status in ('pendente','entregue')
        and (s.numero_requisicao is not null or s.exame_id is null)
        and (s.requisicao_validade is null or s.requisicao_validade >= current_date)
        and (not s.exige_autorizacao or s.autorizacao_status = 'autorizada')) as pode_agendar,
       case
         when s.status not in ('pendente','entregue')               then 'já resolvida'
         when s.numero_requisicao is null and s.exame_id is not null then 'falta o número da requisição'
         when s.requisicao_validade < current_date                   then 'requisição vencida'
         when s.exige_autorizacao and s.autorizacao_status <> 'autorizada'
                                                                     then 'aguardando autorização do convênio'
         else 'liberada para agendar' end                            as impedimento
  from solicitacoes s
  left join exames ex        on ex.id = s.exame_id
  left join procedimentos pr on pr.id = s.procedimento_id
  left join medicos m        on m.id  = s.medico_solicitante_id
  left join convenios cv     on cv.id = s.convenio_id
 where s.status in ('pendente','entregue');

grant select on vw_pendencias_paciente to anon, authenticated;

-- 6) marca automaticamente o que venceu --------------------------------------
create or replace function fn_vence_autorizacoes() returns void as $$
  update solicitacoes set autorizacao_status='vencida'
   where autorizacao_status='autorizada' and autorizacao_validade < current_date;
$$ language sql;
