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
