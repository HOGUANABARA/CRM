# Como VoxComm e HOG Gestão vão coexistir

## A regra de ouro

**Cada informação tem um dono só, por vez.** Nunca os dois sistemas gravando a mesma
coisa. Onde houver dúvida sobre quem manda, há retrabalho e divergência — e a equipe
perde a confiança nos dois.

A transição é **por módulo, não por setor**. Ninguém fica "metade no sistema novo":
o que muda é *qual assunto* mora onde.

---

## Fase 1 — O que o VoxComm não faz (agora)

O HOG Gestão entra pelos buracos, sem disputar nada:

| Assunto | Dono | Por quê |
|---|---|---|
| **Grade do HOG** (reserva de sala, liberação) | **HOG Gestão** | hoje vive no Google Agenda |
| **Agenda de exames / avulsos** | **HOG Gestão** | hoje vive numa planilha Excel |
| **Requisição, autorização e saldo** | **HOG Gestão** | hoje vive no WhatsApp |
| **Vínculo conversa ↔ paciente** | **HOG Gestão** | hoje não existe |
| **Lista de espera e aviso de agenda liberada** | **HOG Gestão** | hoje é caderno/memória |
| Cadastro de paciente, agendamento de consulta, prontuário | **VoxComm** | segue igual |

**Risco desta fase:** dupla digitação do agendamento de exame (nasce no HOG Gestão e
precisa aparecer no VoxComm para a recepção). Mitigação: a agenda do dia sai impressa
ou em Excel do HOG Gestão — exatamente como a planilha de hoje, só que gerada.

**Ganho imediato:** acaba a planilha de avulsos, acaba a foto perdida no WhatsApp,
e a coordenação passa a enxergar ocupação e vagas extras.

---

## Fase 2 — Espelho de leitura (o HOG enxerga o VoxComm)

Carga diária do banco do VoxComm (`cao2`) para o HOG Gestão, **só leitura**:

- pacientes, médicos, convênios, procedimentos;
- agendamentos do dia e do histórico (com o de-para de status já definido).

Com isso o HOG Gestão mostra indicadores, ocupação real e o painel do DIGISAC com o
histórico completo — **sem ninguém digitar duas vezes**. O VoxComm continua dono do
agendamento de consulta.

> Detalhe importante: nesta fase o HOG Gestão **não escreve** nada no VoxComm.
> Se a equipe alterar algo lá, a carga do dia seguinte corrige aqui.

---

## Fase 3 — Vira a chave do agendamento (um módulo por vez)

Ordem sugerida, do menor risco para o maior:

1. **Exames** — já nasce no HOG Gestão desde a Fase 1; só para de ser redigitado.
2. **Cirurgias / Centro Cirúrgico** — volume menor, equipe pequena, regras próprias.
3. **Consultas** — o maior volume, por último, quando o resto já roda há semanas.

Em cada virada:
- **duas semanas de sombra**: o módulo roda nos dois, com conferência diária de contagem;
- **data de corte anunciada**: a partir dela, o VoxComm entra em leitura para aquele módulo;
- **quem confere**: uma pessoa nomeada por módulo, com a lista do dia lado a lado.

---

## Fase 4 — Desligamento

O VoxComm fica **somente leitura** por um período (sugestão: 6 meses) para consulta de
histórico, enquanto:

- o **prontuário** migra para o SIVOE (já acordado);
- o **histórico de agendamentos e visitas** já está no HOG Gestão pela carga da Fase 2;
- o que não migrar vira **exportação em arquivo** guardada pela clínica.

---

## O que decide o ritmo

Não é a tecnologia, é a **confiança da equipe**. Por isso:

- nenhuma fase começa sem a anterior estar estável;
- toda virada tem volta atrás (o VoxComm continua funcionando até o desligamento);
- a coordenação decide a data de corte, não o sistema.

---

## Riscos conhecidos e o que fazer

| Risco | Mitigação |
|---|---|
| Dupla digitação cansa a equipe | fase 1 só pega o que hoje já é fora do sistema |
| Divergência de números entre os dois | conferência diária na sombra, antes do corte |
| Equipe usando o sistema errado | por módulo, com data de corte clara e cartaz na parede |
| Perder histórico ao desligar | carga da fase 2 + exportação final |
| Integração com SIVOE atrasar | não bloqueia: o prontuário segue no VoxComm até resolver |
