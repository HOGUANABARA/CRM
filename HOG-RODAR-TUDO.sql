-- =====================================================================
-- HOG Gestão — TUDO QUE FALTA RODAR, na ordem certa
-- Gerado em 22/08/2026. Cole inteiro no SQL Editor do Supabase.
-- Já rodados (não estão aqui): hog-abertura-agenda, hog-grade,
-- hog-contratos, hog-chamada-exames, hog-equipamentos, hog-indicadores.
-- =====================================================================


-- #####################################################################
-- ##  hog-multipadrao-pa.sql
-- #####################################################################
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


-- #####################################################################
-- ##  hog-vagas-extras.sql
-- #####################################################################
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


-- #####################################################################
-- ##  hog-cancelamento.sql
-- #####################################################################
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


-- #####################################################################
-- ##  hog-visitas.sql
-- #####################################################################
-- =====================================================================
-- HOG Gestão — Visitas do paciente e categoria (beneficência)
--
-- Espelha a janela "Visitas" do VoxComm (dados?get=visitas&id=…):
--   Data · há quanto tempo · Atendimento · Médico · Categoria · Atendente
--
-- A visita é o registro de que o paciente REALMENTE foi atendido —
-- é o elo entre a agenda e o faturamento, e é a ausência dela que
-- o VoxComm interpreta como falta.
--
-- Rode depois de hog-cancelamento.sql.
-- =====================================================================

-- 1) categoria do paciente (beneficência, particular, convênio…) --------------
create table if not exists pacientes_categoria (
  id text primary key, nome text not null, descricao text,
  filantropia boolean default false,      -- entra na cota de beneficência
  ativo boolean default true);

insert into pacientes_categoria (id,nome,descricao,filantropia) values
 ('beneficiencia','BENEFICIÊNCIA','Atendimento filantrópico — entra na cota social',true),
 ('convenio','CONVÊNIO','Atendimento por plano de saúde',false),
 ('particular','PARTICULAR','Atendimento particular',false),
 ('parceiro','PARCEIRO','Encaminhado por parceiro / modalidade comercial',false)
on conflict (id) do nothing;

grant all on pacientes_categoria to anon, authenticated;
alter table pacientes_categoria enable row level security;
drop policy if exists p_pcat on pacientes_categoria;
create policy p_pcat on pacientes_categoria for all using (true) with check (true);

alter table pacientes add column if not exists categoria_id text references pacientes_categoria(id);

-- 2) quem atendeu (coluna "Atendente" da janela de visitas) ------------------
alter table agendamentos
  add column if not exists atendente        text,
  add column if not exists categoria_id     text references pacientes_categoria(id),  -- categoria no dia
  add column if not exists visita_registrada boolean default false,
  add column if not exists visita_em        timestamptz;

-- registrar a visita é o que fecha o atendimento (e libera o faturamento)
create or replace function fn_registra_visita() returns trigger as $$
begin
  if new.status in ('compareceu','realizado') and not coalesce(new.visita_registrada,false) then
    new.visita_registrada := true;
    new.visita_em := coalesce(new.chegada_em, now());
    if new.categoria_id is null then
      select categoria_id into new.categoria_id from pacientes where id = new.paciente_id;
    end if;
  end if;
  return new;
end $$ language plpgsql;

drop trigger if exists tg_registra_visita on agendamentos;
create trigger tg_registra_visita before insert or update on agendamentos
  for each row execute function fn_registra_visita();

-- 3) a janela de visitas do paciente -----------------------------------------
create or replace view vw_visitas_paciente as
select a.paciente_id,
       p.nome                                   as paciente,
       (a.data + coalesce(a.hora,'00:00'::time)) as quando,
       a.data,
       a.hora,
       date_part('year', age(current_date, a.data))::int as anos_atras,
       date_part('month', age(current_date, a.data))::int as meses_atras,
       coalesce(ex.nome, pr.nome, al.nome, a.tipo) as atendimento,
       m.nome                                    as medico,
       coalesce(pc.nome, pc2.nome)               as categoria,
       a.atendente,
       a.status
  from agendamentos a
  left join pacientes p            on p.id = a.paciente_id
  left join medicos   m            on m.id = a.medico_id
  left join exames    ex           on ex.id = a.exame_id
  left join procedimentos pr       on pr.id = a.procedimento_id
  left join agendas_logicas al     on al.id = a.agenda_logica_id
  left join pacientes_categoria pc on pc.id = a.categoria_id
  left join pacientes_categoria pc2 on pc2.id = p.categoria_id
 where a.status in ('compareceu','realizado')
 order by a.data desc;

grant select on vw_visitas_paciente to anon, authenticated;

-- 4) CRM: paciente sem retornar há muito tempo (a coluna "+12 ano" do VoxComm)
create or replace view vw_pacientes_sem_retorno as
select p.id, p.nome, p.telefone, p.categoria_id,
       max(a.data)                                            as ultima_visita,
       (current_date - max(a.data))                           as dias_sem_voltar,
       count(*) filter (where a.status in ('compareceu','realizado')) as visitas
  from pacientes p
  join agendamentos a on a.paciente_id = p.id
 where a.status in ('compareceu','realizado')
 group by p.id, p.nome, p.telefone, p.categoria_id
having (current_date - max(a.data)) > 365;

grant select on vw_pacientes_sem_retorno to anon, authenticated;


-- #####################################################################
-- ##  hog-atendimentos.sql
-- #####################################################################
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

-- 5) agenda médica x agenda interna (o "Médicos" e o "Interno" do VoxComm) ----
alter table agendas_logicas add column if not exists categoria_agenda text default 'medica';
update agendas_logicas set categoria_agenda = case when medico_id is null then 'interna' else 'medica' end;


-- #####################################################################
-- ##  hog-requisicoes.sql
-- #####################################################################
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


-- #####################################################################
-- ##  hog-avulsos.sql
-- #####################################################################
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


-- #####################################################################
-- ##  hog-autorizacoes.sql
-- #####################################################################
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


-- #####################################################################
-- ##  hog-digisac.sql
-- #####################################################################
-- =====================================================================
-- HOG Gestão × DIGISAC — conversa do WhatsApp ligada ao paciente
--
-- O problema real: o telefone que fala com a clínica NEM SEMPRE é o do
-- paciente (filho, cônjuge, cuidador, vizinho). Hoje a conversa não
-- cruza com o cadastro, então a requisição some no WhatsApp e ninguém
-- sabe qual paciente aquele número está tratando.
--
-- A solução não é "achar o paciente pelo telefone": é ter CONTATOS
-- (quem fala) ligados a PACIENTES (por quem fala), com o vínculo
-- aprendido uma vez e reaproveitado sempre.
--
-- Rode depois de hog-autorizacoes.sql.
-- =====================================================================

-- 1) quem fala com a clínica --------------------------------------------------
create table if not exists contatos (
  id uuid primary key default gen_random_uuid(),
  telefone text unique not null,             -- E.164: 5519999999999
  nome text,                                 -- como se identificou / nome no WhatsApp
  digisac_contact_id text,                   -- id do contato no DIGISAC
  ultimo_contato timestamptz,
  observacao text,
  criado_em timestamptz default now());

create index if not exists ix_contato_tel on contatos(telefone);

-- 2) por quem esse contato fala (N:N — um filho cuida de pai e mãe) -----------
create table if not exists contato_paciente (
  contato_id uuid not null references contatos(id) on delete cascade,
  paciente_id uuid not null references pacientes(id) on delete cascade,
  relacao text default 'responsavel',        -- proprio|filho|conjuge|cuidador|responsavel|outro
  autorizado_a_agendar boolean default true,
  confirmado_por text,                       -- quem da equipe confirmou o vínculo
  confirmado_em timestamptz default now(),
  primary key (contato_id, paciente_id));

-- 3) a conversa (ticket do DIGISAC) ------------------------------------------
create table if not exists conversas (
  id uuid primary key default gen_random_uuid(),
  digisac_ticket_id text unique,
  contato_id uuid references contatos(id),
  paciente_id uuid references pacientes(id),  -- paciente TRATADO nesta conversa
  assunto text,                               -- agendamento|requisicao|confirmacao|duvida|resultado
  status text default 'aberta',               -- aberta | identificada | resolvida
  atendente text,
  iniciada_em timestamptz default now(),
  fechada_em timestamptz,
  agendamento_id uuid,                        -- o que saiu da conversa
  solicitacao_id uuid references solicitacoes(id),
  autorizacao_id uuid references autorizacoes(id));

create index if not exists ix_conversa_status on conversas(status, iniciada_em desc);

-- 4) as mensagens que interessam (principalmente as FOTOS) -------------------
create table if not exists mensagens (
  id uuid primary key default gen_random_uuid(),
  conversa_id uuid references conversas(id) on delete cascade,
  digisac_message_id text unique,
  direcao text default 'entrada',             -- entrada | saida
  tipo text default 'texto',                  -- texto | imagem | documento | audio
  texto text,
  arquivo_url text,
  anexo_id uuid references anexos(id),         -- quando vira requisição anexada
  recebida_em timestamptz default now(),
  processada boolean default false);

create index if not exists ix_msg_conversa on mensagens(conversa_id, recebida_em);

grant all on contatos, contato_paciente, conversas, mensagens to anon, authenticated;
alter table contatos         enable row level security;
alter table contato_paciente enable row level security;
alter table conversas        enable row level security;
alter table mensagens        enable row level security;
drop policy if exists p_cont on contatos;         create policy p_cont on contatos         for all using (true) with check (true);
drop policy if exists p_cp   on contato_paciente; create policy p_cp   on contato_paciente for all using (true) with check (true);
drop policy if exists p_conv on conversas;        create policy p_conv on conversas        for all using (true) with check (true);
drop policy if exists p_msg  on mensagens;        create policy p_msg  on mensagens        for all using (true) with check (true);

-- 5) o paciente ganha telefones alternativos ---------------------------------
alter table pacientes
  add column if not exists whatsapp text,
  add column if not exists telefone_responsavel text,
  add column if not exists nome_responsavel text;

-- 6) A FILA QUE IMPORTA: conversas ainda não ligadas a um paciente -----------
create or replace view vw_conversas_nao_identificadas as
select c.id as conversa_id, c.digisac_ticket_id, c.iniciada_em, c.assunto, c.atendente,
       ct.telefone, ct.nome as nome_contato,
       (select count(*) from mensagens m where m.conversa_id=c.id and m.tipo='imagem') as fotos,
       (select m.texto from mensagens m where m.conversa_id=c.id and m.direcao='entrada'
         order by m.recebida_em limit 1) as primeira_mensagem,
       (select count(*) from contato_paciente cp where cp.contato_id=ct.id) as pacientes_ja_ligados
  from conversas c
  join contatos ct on ct.id = c.contato_id
 where c.paciente_id is null and c.status <> 'resolvida'
 order by c.iniciada_em desc;

grant select on vw_conversas_nao_identificadas to anon, authenticated;

-- 7) sugestão de paciente para uma conversa (o sistema propõe, humano confirma)
create or replace function fn_sugere_pacientes(p_telefone text)
returns table (paciente_id uuid, nome text, motivo text, peso int) as $$
  -- 1. vínculo já confirmado antes: é o caminho normal depois do primeiro uso
  select p.id, p.nome, 'vínculo já confirmado ('||cp.relacao||')', 100
    from contato_paciente cp
    join contatos ct on ct.id = cp.contato_id and ct.telefone = p_telefone
    join pacientes p on p.id = cp.paciente_id
  union all
  -- 2. o telefone está no cadastro do próprio paciente
  select p.id, p.nome, 'telefone do cadastro', 90
    from pacientes p
   where regexp_replace(coalesce(p.telefone,''),'\D','','g') like '%'||right(regexp_replace(p_telefone,'\D','','g'),8)||'%'
      or regexp_replace(coalesce(p.whatsapp,''),'\D','','g') like '%'||right(regexp_replace(p_telefone,'\D','','g'),8)||'%'
  union all
  -- 3. telefone cadastrado como do responsável
  select p.id, p.nome, 'telefone do responsável ('||coalesce(p.nome_responsavel,'—')||')', 80
    from pacientes p
   where regexp_replace(coalesce(p.telefone_responsavel,''),'\D','','g') like '%'||right(regexp_replace(p_telefone,'\D','','g'),8)||'%'
  order by 4 desc;
$$ language sql stable;

grant execute on function fn_sugere_pacientes(text) to anon, authenticated;

-- 8) ao confirmar o vínculo, ele fica aprendido para sempre ------------------
create or replace function fn_liga_conversa(p_conversa uuid, p_paciente uuid, p_relacao text, p_quem text)
returns void as $$
declare v_contato uuid;
begin
  select contato_id into v_contato from conversas where id = p_conversa;
  update conversas set paciente_id = p_paciente, status='identificada' where id = p_conversa;
  if v_contato is not null then
    insert into contato_paciente (contato_id, paciente_id, relacao, confirmado_por)
    values (v_contato, p_paciente, coalesce(p_relacao,'responsavel'), p_quem)
    on conflict (contato_id, paciente_id) do update set relacao = excluded.relacao;
  end if;
end $$ language plpgsql;

grant execute on function fn_liga_conversa(uuid,uuid,text,text) to anon, authenticated;

