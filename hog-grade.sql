-- =====================================================================
-- HOG Gestão — Grade do HOG
-- Cada local de atendimento nasce DISPONÍVEL dentro do horário de
-- funcionamento; a reserva ocupa; a liberação abre para agendamento.
-- Rode depois de hog-abertura-agenda.sql.
-- =====================================================================

-- 0) "Consultório Térreo" e "Consultório 1" são a MESMA sala -----------------
--    O cadastro tinha os dois; tudo passa a apontar para cons1 (que já está
--    marcado como térreo e sem escada) e o duplicado é removido.
update salas set nome='Consultório 1 (térreo)', andar='terreo', sobe_escada=false where id='cons1';

update agendas_logicas set sala_padrao_id='cons1' where sala_padrao_id='terreo';
update reservas          set sala_id='cons1'      where sala_id='terreo';
update agendamentos      set sala_id='cons1'      where sala_id='terreo';
update exame_agendamentos set sala='cons1'        where sala='terreo';
update equipamentos      set sala_id='cons1'      where sala_id='terreo';
delete from salas where id = 'terreo';

-- 0.1) onde cada aparelho pode ficar ----------------------------------------
--      Retinógrafo e angiógrafo são fixos no Consultório 1 (térreo);
--      laser de fotocoagulação no 4; YAG no 2 ou no 3;
--      os aparelhos móveis da sala de exames podem ir para um consultório livre
--      (é o caso de rodar dois técnicos ao mesmo tempo).
alter table equipamentos add column if not exists salas_possiveis text[];

update equipamentos set sala_id='cons1', movel=false, salas_possiveis='{cons1}'                 where id in ('retinografo','angiografo');
update equipamentos set sala_id='cons4', movel=false, salas_possiveis='{cons4}'                 where id='laser_foto';
update equipamentos set sala_id='cons2', movel=true,  salas_possiveis='{cons2,cons3}'           where id='yag';
update equipamentos set salas_possiveis='{exames,cons1,cons2,cons3,cons4}'                      where movel=true and id<>'yag';
update equipamentos set salas_possiveis=array[sala_id]                                          where salas_possiveis is null and sala_id is not null;

-- 1) horário de funcionamento e ordem de exibição de cada local ---------------
alter table salas
  add column if not exists hora_abre  time default '07:00',
  add column if not exists hora_fecha time default '19:00',
  add column if not exists ordem int default 50,
  add column if not exists agendavel_por text[];    -- perfis que podem agendar neste local

update salas set ordem=1,  hora_abre='07:00', hora_fecha='19:00' where id='cons1';
update salas set ordem=2,  hora_abre='07:00', hora_fecha='19:00' where id='cons2';
update salas set ordem=3,  hora_abre='07:00', hora_fecha='19:00' where id='cons3';
update salas set ordem=4,  hora_abre='07:00', hora_fecha='19:00' where id='cons4';
update salas set ordem=5,  hora_abre='07:00', hora_fecha='19:00' where id='exames';
update salas set ordem=6,  hora_abre='08:00', hora_fecha='18:00' where id='consultora';
update salas set ordem=7,  hora_abre='07:00', hora_fecha='19:00' where id='cc';
update salas set ordem=9,  hora_abre='07:00', hora_fecha='19:00' where id='gerais';

-- quem pode agendar em cada local (o CC é restrito)
update salas set agendavel_por='{callcenter,recepcao,coordenacao,admin}'          where tipo in ('consultorio','exames','gerais');
update salas set agendavel_por='{consultora,coordenacao,admin}'                    where tipo='consultora';
update salas set agendavel_por='{centro_cirurgico,consultora,coordenacao,admin}'    where tipo='cc';

-- 2) quem pode agendar naquele bloco (pode diferir do padrão da sala) ---------
alter table reservas add column if not exists perfis_agendamento text[];

-- 3) alerta para o call center quando uma agenda é liberada ------------------
create table if not exists alertas_call_center (
  id uuid primary key default gen_random_uuid(),
  tipo text default 'agenda_liberada',          -- agenda_liberada | agenda_cancelada
  reserva_id uuid,
  agenda_logica_id text references agendas_logicas(id),
  medico_id text references medicos(id),
  data_agenda date,
  paciente_id uuid references pacientes(id),    -- quem estava na lista de espera
  mensagem text,
  status text default 'pendente',               -- pendente | tratado | dispensado
  criado_em timestamptz default now(),
  tratado_por text, tratado_em timestamptz);

create index if not exists ix_alertas_status on alertas_call_center(status, criado_em desc);

grant all on alertas_call_center to anon, authenticated;
alter table alertas_call_center enable row level security;
drop policy if exists p_alertas on alertas_call_center;
create policy p_alertas on alertas_call_center for all using (true) with check (true);

-- 4) lista de espera ganha o médico (nem sempre se sabe o padrão) ------------
alter table lista_espera
  add column if not exists medico_id text references medicos(id),
  add column if not exists status text default 'aguardando',   -- aguardando | avisado | agendado | desistiu
  add column if not exists telefone text,
  add column if not exists avisado_em timestamptz;

-- exemplos de espera, para ver o alerta funcionando na liberação
insert into lista_espera (paciente_id, agenda_logica_id, medico_id, tipo, prioridade, observacao)
select p.id,'ni_cat','nilson','consulta',
       case when row_number() over () = 1 then 'urgente' else 'normal' end,
       'quer a primeira data que abrir'
from (select id from pacientes order by nome limit 3) p
where not exists (select 1 from lista_espera where agenda_logica_id='ni_cat');
