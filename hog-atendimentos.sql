-- =====================================================================
-- HOG Gestão — Catálogo de ATENDIMENTOS + regra de encaixe
--
-- Espelha a tela "Agendar" do VoxComm (dados?get=agendar&id=…):
--   Médico · Data · lista de Atendimentos (é o cao2 atendimento).
--
-- Regra observada:
--   • o agendamento só acontece se HOUVER HORÁRIO DISPONÍVEL na agenda;
--   • ENCAIXE é permissão de perfil — quem não tem, não força vaga.
--
-- Rode depois de hog-visitas.sql.
-- =====================================================================

-- 1) catálogo de atendimentos ------------------------------------------------
create table if not exists atendimentos (
  id text primary key,
  nome text not null,
  codigo text,                       -- código do VoxComm (cao2 atendimento.codigo)
  tipo text,                         -- consulta|exame|cirurgia|procedimento|consultora|pa
  exame_id text references exames(id),
  procedimento_id text references procedimentos(id),
  duracao_min int,
  exige_autorizacao boolean default false,
  ativo boolean default true,
  id_voxcomm int);                   -- id de origem, para casar com atendimentos_permitidos

grant all on atendimentos to anon, authenticated;
alter table atendimentos enable row level security;
drop policy if exists p_atend on atendimentos;
create policy p_atend on atendimentos for all using (true) with check (true);

-- lista lida da tela do VoxComm (conferir e completar o que ficou fora do print)
insert into atendimentos (id,nome,tipo) values
 ('angiofluor','Angiofluoresce','exame'),
 ('aplicacao','Aplicação','procedimento'),
 ('aval_rossi','AVALIAÇÃO ROSSI','consulta'),
 ('biometria','Biometria','exame'),
 ('campo','Campo','exame'),
 ('ceratoscopia','Ceratoscopia','exame'),
 ('ciclofoto','Ciclofoto','procedimento'),
 ('cirurgia','Cirurgia','cirurgia'),
 ('cir_crosslinking','Cirurgia Crosslinking','cirurgia'),
 ('cir_estrabismo','Cirurgia Estrabismo','cirurgia'),
 ('cir_faco_convenio','Cirurgia FACO CONVÊNIO','cirurgia'),
 ('cir_faco_imp','Cirurgia FACO IMP','cirurgia'),
 ('cir_faco_parceiro','Cirurgia FACO Parceiro','cirurgia'),
 ('cir_plastica','Cirurgia Plástica','cirurgia'),
 ('cir_refrativa','Cirurgia Refrativa','cirurgia'),
 ('cir_trec','Cirurgia TREC','cirurgia'),
 ('cir_vitre','Cirurgia Vitre','cirurgia'),
 ('coa','Coa','exame'),
 ('consulta','Consulta','consulta'),
 ('consulta_55','Consulta 55+','consulta'),
 ('consulta_catarata','Consulta Catarata','consulta'),
 ('consulta_cornea','Consulta Córnea','consulta'),
 ('consulta_encaixe','Consulta Encaixe','consulta'),
 ('consulta_oculos','Consulta Óculos','consulta'),
 ('consulta_plastica','Consulta Plástica','consulta'),
 ('consulta_pre_anest','Consulta Pré Anestésica','consulta'),
 ('consultora_cir','Consultora Cirúrgica','consultora'),
 ('curva','Curva','exame'),
 ('eco','Eco','exame'),
 ('pa','PA','pa')
on conflict (id) do nothing;

-- amarra com o catálogo de exames que já existe
update atendimentos set exame_id='BIO'   where id='biometria';
update atendimentos set exame_id='CAMPO' where id='campo';
update atendimentos set exame_id='TOPO'  where id='ceratoscopia';

-- 2) quais atendimentos cada agenda aceita (o atendimentos_permitidos do VoxComm)
alter table agendas_logicas
  add column if not exists atendimentos_permitidos text[];

-- 3) ENCAIXE é permissão de perfil -------------------------------------------
--    O agendamento normal só usa vaga livre. Encaixe força além da capacidade
--    e só quem tem a permissão consegue.
alter table perfis add column if not exists pode_encaixar boolean default false;

update perfis set pode_encaixar=true  where id in ('coordenacao','admin','consultora','centro_cirurgico');
update perfis set pode_encaixar=false where id in ('callcenter','recepcao','tecnico','financeiro','medico');

alter table agendamentos
  add column if not exists atendimento_id text references atendimentos(id),
  add column if not exists encaixe_autorizado_por text;

-- 4) função de vaga: quem pode marcar, e se ainda cabe -----------------------
create or replace function fn_tem_vaga(p_agenda text, p_data date)
returns table (vagas int, agendados int, extras int, livre int) as $$
  select
    coalesce(al.qtd_periodo,0)                                                    as vagas,
    (select count(*)::int from agendamentos a
      where a.agenda_logica_id=p_agenda and a.data=p_data and a.status<>'cancelado') as agendados,
    coalesce((select sum(ve.quantidade)::int from vagas_extras ve
       where ve.status='ativa' and ve.agenda_logica_id=p_agenda and ve.data=p_data),0) as extras,
    coalesce(al.qtd_periodo,0)
      + coalesce((select sum(ve.quantidade)::int from vagas_extras ve
           where ve.status='ativa' and ve.agenda_logica_id=p_agenda and ve.data=p_data),0)
      - (select count(*)::int from agendamentos a
          where a.agenda_logica_id=p_agenda and a.data=p_data and a.status<>'cancelado') as livre
  from agendas_logicas al where al.id=p_agenda;
$$ language sql stable;

grant execute on function fn_tem_vaga(text,date) to anon, authenticated;

-- =====================================================================
-- Regra de agendamento no HOG Gestão:
--   1. o atendimento escolhido precisa estar em agendas_logicas.atendimentos_permitidos
--   2. precisa haver vaga (fn_tem_vaga.livre > 0)
--   3. se não houver vaga, só um perfil com pode_encaixar=true segue adiante,
--      e o sistema grava encaixe=true + encaixe_autorizado_por
-- =====================================================================
