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
