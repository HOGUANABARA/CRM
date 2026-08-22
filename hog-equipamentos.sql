-- =====================================================================
-- HOG Gestão — Correção dos aparelhos (o que é fixo, o que se move)
--
-- Regras da Evelise:
--   • Retinógrafo e angiógrafo: fixos no Consultório 1 (térreo).
--   • Laser de fotocoagulação: fixo no Consultório 4.
--   • YAG: Consultório 2 ou 3.
--   • Da sala de exames, SÓ O CAMPÍMETRO se move.
--   • O Consultório 1 recebe apenas a BIO DE CONTATO (que não é o
--     biômetro Lenstar), para o paciente que não sobe escada.
--
-- Rode depois de hog-grade.sql.
-- =====================================================================

alter table equipamentos add column if not exists observacao text;

-- 1) o que é FIXO na sala de exames (não vai para consultório) ---------------
update equipamentos set movel=false, sala_id='exames', salas_possiveis='{exames}'
 where id in ('biometro','oct','topografo','paquimetro','microscopio');

update equipamentos set nome='Biômetro Lenstar (óptico)',
       observacao='Fixo na sala de exames. Para quem não sobe escada, usa-se a bio de contato no Consultório 1.'
 where id='biometro';

-- 2) o único móvel da sala de exames ----------------------------------------
update equipamentos set movel=true, salas_possiveis='{exames,cons1,cons2,cons3,cons4}',
       observacao='Único aparelho da sala de exames que se move — pode ir para um consultório livre (dois técnicos ao mesmo tempo).'
 where id='campimetro';

-- 3) fixos nos consultórios --------------------------------------------------
update equipamentos set movel=false, sala_id='cons1', salas_possiveis='{cons1}'  where id in ('retinografo','angiografo');
update equipamentos set movel=false, sala_id='cons4', salas_possiveis='{cons4}'  where id='laser_foto';
update equipamentos set movel=true,  sala_id='cons2', salas_possiveis='{cons2,cons3}' where id='yag';

-- 4) BIO DE CONTATO — aparelho próprio, não é o Lenstar ----------------------
insert into equipamentos (id,nome,sala_id,movel)
values ('bio_contato','Bio de contato (ultrassom)','cons1',true)
on conflict (id) do nothing;

update equipamentos
   set sala_id='cons1', movel=true, salas_possiveis='{cons1,exames}',
       observacao='Biometria de contato — usada no Consultório 1 (térreo) para paciente que NÃO sobe escada. Não substitui o Lenstar nos demais casos.'
 where id='bio_contato';

-- 5) o exame de biometria passa a ter aparelho alternativo -------------------
alter table exames
  add column if not exists equipamento_alt_id text references equipamentos(id),
  add column if not exists alt_motivo text,
  add column if not exists alt_sala_id text references salas(id);

update exames
   set equipamento_alt_id='bio_contato',
       alt_sala_id='cons1',
       alt_motivo='Paciente que não sobe escada: biometria de contato no Consultório 1 (térreo)'
 where id='BIO';

-- 6) conferência -------------------------------------------------------------
-- select e.id, e.nome, s.nome as sala, e.movel, e.salas_possiveis, e.observacao
--   from equipamentos e left join salas s on s.id=e.sala_id order by s.ordem, e.nome;
