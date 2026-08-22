-- =====================================================================
-- HOG Gestão — Agenda de exames no lugar da planilha de AVULSOS
--
-- Hoje a equipe agenda primeiro num Excel ("AVULSOS — SALA 2") e depois
-- redigita no VoxComm, porque o sistema não guarda requisição, telefone,
-- nascimento e observação. Estas colunas eliminam a etapa do Excel.
--
-- Rode depois de hog-requisicoes.sql.
-- =====================================================================
alter table exame_agendamentos
  add column if not exists nascimento        date,
  add column if not exists telefone          text,
  add column if not exists numero_requisicao text,
  add column if not exists requisicao_validade date,
  add column if not exists solicitado_em     date,      -- "Do dia 18/08" da planilha
  add column if not exists observacao        text,
  add column if not exists autorizacao_senha text,
  add column if not exists convenio_id       text references convenios(id),
  add column if not exists vaga              int;        -- AVULSO 01, 02, 03…

create index if not exists ix_exame_ag_data on exame_agendamentos(data);

-- numera as vagas do dia na ordem do horário (o "AVULSO NN")
create or replace function fn_numera_vagas(p_data date) returns void as $$
  update exame_agendamentos e set vaga = v.n
    from (select id, row_number() over (order by ini, criado_em) as n
            from exame_agendamentos where data = p_data) v
   where e.id = v.id;
$$ language sql;
