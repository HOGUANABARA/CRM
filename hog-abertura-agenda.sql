-- =====================================================================
-- HOG Gestão — Painel de Abertura de Agendas (grade semanal)
-- Camada 1 (reserva de sala/médico) ganha horário, pagamento e cor,
-- no mesmo modelo da grade do Google Agenda usada hoje.
-- Rode inteiro no SQL Editor do Supabase.
-- =====================================================================

-- 1) colunas novas na reserva ------------------------------------------------
alter table reservas
  add column if not exists hora_ini        time,
  add column if not exists hora_fim        time,
  add column if not exists titulo          text,          -- o que aparece no bloco
  add column if not exists cor             text,          -- manha|tarde|cirurgico|vaga
  add column if not exists pagamento_tipo  text,          -- repasse|aluguel_sala|producao|preceptor|sem_pagamento
  add column if not exists pagamento_valor numeric(12,2),
  add column if not exists pagamento_obs   text,
  add column if not exists serie_id        uuid,          -- agrupa ocorrências de uma recorrência
  add column if not exists repete_ate      date,
  add column if not exists liberado_por    text,
  add column if not exists liberado_em     timestamptz,
  -- o número do consultório só é definido na véspera (D-1)
  add column if not exists sala_definida_por text,
  add column if not exists sala_definida_em  timestamptz;

create index if not exists ix_reservas_data  on reservas(data);
create index if not exists ix_reservas_serie on reservas(serie_id);

-- 2) catálogo de formas de pagamento da abertura de agenda -------------------
create table if not exists formas_pagamento_agenda (
  id text primary key, nome text not null, descricao text, ativo boolean default true);

insert into formas_pagamento_agenda (id,nome,descricao) values
 ('repasse','Repasse ao médico','O HOG fatura e repassa o percentual/valor combinado'),
 ('aluguel_sala','Aluguel de sala','O médico paga taxa para usar a sala/CC (ex.: Dra. Roberta)'),
 ('producao','Produção','Pagamento por produção/plantão do período'),
 ('preceptor','Residente — repasse ao preceptor','Agenda de residente; o repasse vai para o preceptor'),
 ('sem_pagamento','Sem pagamento','Agenda interna, sem repasse (ex.: exame por técnico)')
on conflict (id) do nothing;

grant all on formas_pagamento_agenda to anon, authenticated;
alter table formas_pagamento_agenda enable row level security;
drop policy if exists p_fpa on formas_pagamento_agenda;
create policy p_fpa on formas_pagamento_agenda for all using (true) with check (true);

-- 3) médicos que aparecem na grade e ainda não estavam cadastrados -----------
insert into medicos (id,nome,tipo) values
 ('eliane','Dra. Eliane Soares','medico'),
 ('beatriz','Dra. Beatriz Ferreira','residente'),
 ('gadioli','Dr. Daniel Gadioli','medico')
on conflict (id) do nothing;

-- 4) GRADE REAL da semana 17–22/08/2026 (importada do Google Agenda) ---------
--    Blocos com padrão de atendimento associado já entram LIBERADOS.
--    Os demais entram como "aguardando liberação" (tarja amarela) —
--    é justamente o trabalho de associar padrão + pagamento no painel.
--    As SALAS são uma sugestão: ajuste clicando no bloco.
delete from reservas where data between '2026-08-16' and '2026-08-22';

insert into reservas
 (data,hora_ini,hora_fim,medico_id,sala_id,agenda_logica_id,titulo,cor,turno,recorrencia,estado,hora_extra,pagamento_tipo,motivo_bloqueio) values
-- ---------- SEGUNDA 17/08 ----------
 ('2026-08-17','07:30','11:30','monir','cons1',null,'Dr. Monir','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-17','07:30','11:00','eliane','cons2',null,'Dra. Eliane Soares','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-17','07:30','10:30','lucas','cc',null,'Dr. Lucas — Fellow (CC)','cirurgico','cirurgico','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-17','08:00','11:30','ishida','cons3',null,'Dr. Alexandre Ichida','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-17','08:00','11:30','beatriz','cons4',null,'Dra. Beatriz Ferreira','manha','manha','recorrente','pre_programado',false,'preceptor',null),
 ('2026-08-17','12:00','16:00','nilson','cc',null,'Dr. Nilson (CC)','cirurgico','cirurgico','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-17','13:00','17:00','ishida','cons1',null,'Dr. Alexandre Ichida','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-17','13:00','17:00','beatriz','cons2',null,'Dra. Beatriz Ferreira — residente','tarde','tarde','recorrente','pre_programado',false,'preceptor',null),
 ('2026-08-17','13:30','17:00','takano','cons3','edu_retina','Dr. Eduardo — agenda de retina','tarde','tarde','recorrente','liberado',false,'repasse',null),
 ('2026-08-17','14:00','17:00',null,'cons4',null,'Sala vaga','vaga',null,'eventual','pre_programado',false,null,null),
-- ---------- TERÇA 18/08 ----------
 ('2026-08-18','07:30','11:30','monir','cons1',null,'Dr. Monir','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-18','07:30','08:30','roberta','cc',null,'Dra. Roberta — 1 cirurgia (Evvoia)','cirurgico','cirurgico','eventual','pre_programado',false,'aluguel_sala',null),
 ('2026-08-18','08:00','11:30','ishida','cons2',null,'Dr. Alexandre Ichida','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-18','08:00','11:00','guilherme','cons3','glaucoma','Dr. Guilherme — Glaucoma','manha','manha','recorrente','liberado',false,'repasse',null),
 ('2026-08-18','08:00','11:00','lucas','cons4',null,'Dr. Lucas — agenda de córnea','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-18','12:30','15:00','nilson','exames','mr_ni','Dr. Nilson — 2 agendas de Mapeamento de retina','tarde','tarde','recorrente','liberado',false,'repasse',null),
 ('2026-08-18','13:00','17:00','ishida','cons1',null,'Dr. Alexandre Ichida','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-18','13:00','16:00','anacarol','cons2',null,'Dra. Ana Carolina — Rotina / óculos','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-18','15:30','17:00','beatriz','cons3',null,'Dra. Beatriz Ferreira — a partir das 15:30','tarde','tarde','eventual','pre_programado',false,'preceptor',null),
-- ---------- QUARTA 19/08 ----------
 ('2026-08-19','08:00','11:30','ishida','cons1',null,'Dr. Alexandre Ichida','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-19','08:00','11:30','beatriz','cons2',null,'Dra. Beatriz Ferreira','manha','manha','recorrente','pre_programado',false,'preceptor',null),
 ('2026-08-19','08:00','11:00','nilson','cons3','ni_cat','Dr. Nilson — Catarata','manha','manha','recorrente','liberado',false,'repasse',null),
 ('2026-08-19','08:00','11:00','georgiana',null,'monte_mor','Dra. Georgiana — Monte Mor (externo)','vaga',null,'recorrente','pre_programado',false,'repasse',null),
 ('2026-08-19','08:30','11:30','mcarolina','cons4','rotina_mcarolina','Dra. Mª Carolina Andolpho','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-19','12:30','16:00','nilson','cc',null,'Dr. Nilson — Cirurgia c/ sedação','cirurgico','cirurgico','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-19','12:30','14:30','mclaudia','cons1',null,'Dra. Maria Claudia','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-19','13:00','17:00','georgiana','cons2',null,'Dra. Georgiana — córnea','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-19','13:00','17:00','beatriz','cons3',null,'Dra. Beatriz Ferreira — P.A','tarde','tarde','recorrente','pre_programado',false,'preceptor',null),
-- ---------- QUINTA 20/08 ----------
 ('2026-08-20','07:00','11:00','lucas','cc',null,'Dr. Lucas (CC)','cirurgico','cirurgico','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-20','07:30','11:30','monir','cons1',null,'Dr. Monir','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-20','08:00','11:30','takano','cons2',null,'Dr. Eduardo Takano — retina','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-20','08:00','11:30','beatriz','cons3',null,'Dra. Beatriz Ferreira — antecipada para 18/08 (P.A)','manha','manha','eventual','bloqueado',false,'preceptor','Não vem — antecipei para 18/08 no P.A'),
 ('2026-08-20','08:00','09:30','joaolian','gerais',null,'Dr. João Lian — consulta pré-anestésica (3 pacientes)','manha','manha','eventual','pre_programado',false,'producao',null),
 ('2026-08-20','12:30','16:00','nilson','cc',null,'Dr. Nilson — aplicação','cirurgico','cirurgico','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-20','13:15','16:15','lucas','cons1','lu_cat','Dr. Lucas — catarata','tarde','tarde','recorrente','liberado',false,'repasse',null),
 ('2026-08-20','13:30','17:00','takano','cons2',null,'Dr. Eduardo Takano — P.A','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-20','13:30','17:00','mclaudia','cons3',null,'Dra. Maria Claudia','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-20','13:30','16:30','mclaudia','cons4',null,'Dra. Maria Claudia — 2ª agenda','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
-- ---------- SEXTA 21/08 ----------
 ('2026-08-21','07:00','10:30','anacarol','cons1','plastica_carol','Dra. Ana Carolina — plástica','manha','manha','recorrente','liberado',false,'repasse',null),
 ('2026-08-21','07:30','11:30','monir','cons2',null,'Dr. Monir','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-21','08:00','11:30',null,'cons3',null,'Dr. Alexandre (confirmar: Ichida ou Rueda)','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-21','08:30','11:00','nilson','cons4',null,'Dr. Nilson — retina','manha','manha','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-21','12:00','16:00','anacarol','cc',null,'Dra. Carol (CC)','cirurgico','cirurgico','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-21','13:00','17:00','takano','cons1',null,'Dr. Eduardo Takano — Mapa','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-21','13:00','16:00',null,'cons1',null,'Retinografia (técnico)','tarde','tarde','recorrente','pre_programado',false,'sem_pagamento',null),
 ('2026-08-21','13:30','17:00','gadioli','cons2',null,'Dr. Daniel Gadioli — P.A','tarde','tarde','recorrente','pre_programado',false,'repasse',null),
 ('2026-08-21','13:30','17:00',null,'cons3',null,'Sala vaga','vaga',null,'eventual','pre_programado',false,null,null),
-- ---------- SÁBADO 22/08 (hora extra) ----------
 ('2026-08-22','07:00','11:00',null,'cons1',null,'Retinografia (técnico)','manha','manha','extra','pre_programado',true,'sem_pagamento',null),
 ('2026-08-22','07:30','10:30','monir','cons1',null,'Dr. Monir','manha','manha','extra','pre_programado',true,'repasse',null);
