# De-para VoxComm → HOG Gestão

Origem: banco do VoxComm (prefixo `cao2`), lido pelo Power BI da Evelise.
Modelo do .pbix "beneficiencia - atendimentos": `cao2 agenda`, `cao2 atendimento`,
`cao2 medicos`, `cao2 pacientes`, `cao2 pacientes_categoria`, `cao2 procedimentos`.

---

## `cao2 agenda` — é a nossa RESERVA + LIBERAÇÃO, tudo numa tabela

| VoxComm | HOG Gestão | Observação |
|---|---|---|
| `id` | `reservas.id_voxcomm` | chave de origem, guardar para reconciliar |
| `nome` | `reservas.titulo` / `agendas_logicas.nome` | é o nome que aparece no quadro ("Ni Cat", "EDU Retina") |
| `id_medico` | `reservas.medico_id` | de-para pela `cao2 medicos` |
| `id_paciente` | `agendamentos.paciente_id` | quando a linha é o agendamento do paciente |
| `id_convenio` | `agendamentos.convenio_id` | |
| `dt_agenda` | `reservas.data` + `hora_ini` | data/hora do atendimento |
| `dt_cadastro` | `agendamentos.criado_em` | quando foi marcado — dá o tempo de antecedência |
| `dt_entrada` | `agendamentos.chegada_em` | chegada do paciente na recepção (rastreio) |
| **`dt_liberacao`** | **`reservas.liberado_em`** | **a camada 2 já existe no VoxComm** |
| **`atendimentos_permitidos`** | **vagas do período** (`agendas_logicas.qtd_periodo` / cota) | é a capacidade; mudanças nesse número são as **vagas extras** negociadas |
| `atendimento` | `agendamentos.tipo` / procedimento | ex.: "Biometria" |
| **`escada`** | **`pacientes.sobe_escada`** | a regra de escada já é registrada hoje |
| `id_regra` | `agendas_logicas.regras` | ver o catálogo de regras do VoxComm |
| `id_grupo` | agrupamento de agendas | provável origem das "agendas Z" e dos agrupamentos do mapa |
| `id_consulta` | `agendamentos.solicitacao_id` / vínculo com a consulta de origem | confirmar |
| `obs` | `reservas.observacao` / `agendamentos.observacao` | lembrete da coordenação |
| `id_user_cadastro` | `agendamentos.criado_por` | |
| `id_user_alteracao` | quem alterou | auditoria |
| `id_user_entrada` | quem deu entrada na recepção | |
| `id_user_adicionado` | quem encaixou | **provável marcador de ENCAIXE** |

### O que isso confirma
- **Liberação e capacidade já são conceitos do VoxComm** (`dt_liberacao`, `atendimentos_permitidos`) —
  a migração não precisa inventar isso, só separar o que lá está numa tabela só.
- **`escada` já é registrada** — dá para migrar a regra de "não sobe escada" sem recadastrar.
- **`atendimentos_permitidos` variando no mesmo dia/agenda = negociação de vagas extras.**
  Comparar o valor com a contagem real de agendamentos mostra quantas vezes por mês isso acontece.

### Colunas restantes (confirmadas)
| VoxComm | HOG Gestão | Observação |
|---|---|---|
| `status` (numérico) | `agendamentos.status` | é **código**, não texto — falta decodificar (agendado/compareceu/faltou/cancelado) |
| `tipo` | separa **bloco de agenda** de **agendamento de paciente** | provavelmente é o que distingue a linha da grade da linha do paciente — confirmar |

### `cao2 atendimento` — catálogo, não é o desfecho
`id`, `codigo`, `atendimento`, `descricao` → é a lista de tipos de atendimento
(o campo `agenda.atendimento` aponta para cá). Mapeia para `procedimentos` / `exames`.

### `cao2 medicos`
| VoxComm | HOG Gestão |
|---|---|
| `id` | `medicos.id_voxcomm` |
| `nome` | `medicos.nome` |
| `crm`, `rqe` | `medicos.crm`, `medicos.rqe` (criar) |
| `especialidade` | `medicos.especialidade_id` (de-para por texto) |
| `id_grupo` | agrupamento de agendas — mesma chave de `agenda.id_grupo`; é a origem do agrupamento do mapa |
| `telefone`, `telefone2` | `medicos.telefone` |

### Ainda falta
- **decodificar `status` e `tipo`** (são números) — ver instrução abaixo
- sala/consultório: não existe coluna na `cao2 agenda` → confirma que **o consultório é decidido fora do sistema**, na véspera (bate com a regra que a Evelise descreveu)
- flag de encaixe: não há coluna explícita; o candidato é `id_user_adicionado` preenchido

### Como decodificar sem mexer no relatório
Página nova no Power BI (`+` na barra inferior) → visual **Tabela** → arrastar
`cao2 agenda[tipo]`, `cao2 agenda[status]` e `cao2 agenda[id]` (mudar para **Contagem**),
mais `atendimentos_permitidos` (**Máximo**). Uma página nova não altera consultas nem modelo.

---

## Consultas agregadas (sem dado pessoal)

Rodar no banco de origem — trocar `?` pelos nomes reais quando confirmados.

```sql
-- 1) PADRÃO SEMANAL: quem atende em que dia e período, e quantos cabem
select m.nome as medico, a.nome as agenda,
       dayofweek(a.dt_agenda) as dia_semana,
       case when hour(a.dt_agenda) < 12 then 'manha' else 'tarde' end as periodo,
       count(*) as blocos,
       min(time(a.dt_agenda)) as primeiro_horario,
       max(time(a.dt_agenda)) as ultimo_horario,
       avg(a.atendimentos_permitidos) as vagas_medias
  from cao2_agenda a
  join cao2_medicos m on m.id = a.id_medico
 where a.dt_agenda >= date_sub(curdate(), interval 12 month)
 group by 1,2,3,4
 order by 1,3,4;

-- 2) OCUPAÇÃO E VAGAS EXTRAS: capacidade x agendados por dia
select date(a.dt_agenda) as dia, m.nome as medico, a.nome as agenda,
       max(a.atendimentos_permitidos) as vagas,
       count(a.id_paciente)           as agendados
  from cao2_agenda a
  join cao2_medicos m on m.id = a.id_medico
 where a.dt_agenda >= date_sub(curdate(), interval 12 month)
 group by 1,2,3
 order by 1;

-- 3) ANTECEDÊNCIA E ENCAIXE: quanto tempo antes o paciente marca
select m.nome as medico, a.nome as agenda,
       avg(datediff(a.dt_agenda, a.dt_cadastro)) as dias_antecedencia,
       sum(case when datediff(a.dt_agenda, a.dt_cadastro) = 0 then 1 else 0 end) as marcados_no_dia
  from cao2_agenda a
  join cao2_medicos m on m.id = a.id_medico
 where a.dt_agenda >= date_sub(curdate(), interval 12 month)
   and a.id_paciente is not null
 group by 1,2;

-- 4) ESCADA: quanto da demanda não sobe escada, por agenda
select a.nome as agenda, a.escada, count(*) as pacientes
  from cao2_agenda a
 where a.dt_agenda >= date_sub(curdate(), interval 6 month)
 group by 1,2;
```

---

## Regra da FALTA no VoxComm (confirmada pela Evelise)

> "É calculado entre data da agenda e data de entrada: se não entrou, dá falta."

```
faltante  =  tem id_paciente  E  dt_agenda já passou  E  dt_entrada vazia
atendido  =  tem id_paciente  E  dt_entrada preenchida
```

### Consequência: falta e cancelamento estão misturados
Quem **cancelou com antecedência** e quem **não apareceu** caem os dois no mesmo balde,
porque nenhum dos dois tem `dt_entrada`. O relatório de Faltantes está inflado — e a
taxa de falta nunca bate com a percepção da equipe.

**No HOG Gestão isso é separado na origem:** o cancelamento é uma ação registrada
(`status='cancelado'`, com quem cancelou, quando e por quê), e a falta é o que sobra —
paciente que tinha hora, não cancelou e não deu entrada.

### Regra de migração (status derivado)
| Situação na origem | status no HOG Gestão |
|---|---|
| `dt_entrada` preenchida | `compareceu` |
| `dt_agenda` no futuro, sem entrada | `agendado` |
| `dt_agenda` passada, com paciente, sem entrada | `faltou` *(marcado como `origem_incerta=true`: pode ter sido cancelamento)* |
| sem `id_paciente` | não é agendamento — é a linha do bloco da agenda |

A flag `origem_incerta` evita que o histórico importado contamine o indicador de falta
do sistema novo: os primeiros meses de operação já nascem com a medição correta,
e o histórico fica marcado como aproximado.
