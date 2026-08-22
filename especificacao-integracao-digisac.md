# Integração HOG Gestão × DIGISAC

Documento para negociar com o DIGISAC e orientar o desenvolvimento.

## O problema, na linguagem da operação

> "A requisição vem em foto pelo DIGISAC na hora do agendamento."
> "O telefone pode bater ou não — às vezes o filho ou parente faz contato."
> "Hoje não conseguimos cruzar o paciente à conversa no WhatsApp."

Consequências de hoje:
- a foto da guia fica no WhatsApp e não no prontuário/faturamento;
- quem atende não sabe, ao abrir a conversa, **de qual paciente** se trata;
- não há histórico: a mesma pergunta é refeita a cada contato;
- o agendamento nasce fora do sistema e é redigitado.

## A ideia central

Não tentar adivinhar o paciente pelo telefone. Separar duas coisas:

```
CONTATO (quem fala)  ──N:N──  PACIENTE (por quem fala)
   telefone                      cadastro
   nome no WhatsApp              relação: próprio | filho | cônjuge | cuidador
```

O vínculo é **confirmado uma vez por um humano** e fica aprendido. Da segunda
conversa em diante o sistema já sabe — inclusive quando o mesmo filho cuida
do pai e da mãe (a conversa pergunta "é sobre qual?" e segue).

---

## Fase 1 — Entrada (o que resolve 80% da dor)

### 1.1 Webhook de mensagem recebida
DIGISAC → HOG Gestão, a cada mensagem:

```json
POST https://<projeto>.supabase.co/functions/v1/digisac-webhook
{
  "event": "message.created",
  "ticket_id": "abc123",
  "contact": { "id": "c789", "number": "5519998765432", "name": "Rita (filha)" },
  "message": { "id": "m456", "type": "image", "text": null,
               "file_url": "https://…/guia.jpg", "timestamp": "2026-08-22T10:31:00Z" }
}
```

O HOG Gestão:
1. cria/atualiza o **contato** pelo telefone;
2. abre/atualiza a **conversa**;
3. guarda a **mensagem** (e, se for imagem, cria o **anexo** tipo `requisicao`);
4. tenta identificar o paciente com `fn_sugere_pacientes(telefone)`:
   - vínculo já confirmado → liga sozinho;
   - telefone no cadastro do paciente ou do responsável → **sugere**;
   - nada → cai na fila **"conversas não identificadas"**.

### 1.2 Tela "Conversas não identificadas"
Uma fila curta para o call center: telefone, primeira mensagem, quantas fotos,
e o botão **"ligar ao paciente"** com busca. Um clique resolve — e nunca mais
se repete para aquele número.

### 1.3 O que muda no dia a dia
A foto da guia chega **já anexada ao paciente**, com data, telefone de origem e
quem recebeu. O call center digita só o número da requisição e a validade.

---

## Fase 2 — Saída (mensagens que a clínica manda)

```json
POST https://api.digisac.co/v1/messages
{ "number": "5519998765432", "text": "…", "file": { "url": "…" } }
```

Disparos do HOG Gestão:

| Gatilho | Mensagem |
|---|---|
| Agendamento criado | confirmação com data, hora, local e **preparo** (dilatação, suspender lente de contato 3 dias, jejum) |
| Véspera (D-1) | lembrete + **qual consultório**, já que a sala é definida na véspera |
| Agenda liberada | avisa quem estava na **lista de espera** |
| Requisição vencendo | alerta antes de perder a validade |
| Falta | mensagem de reagendamento |
| Pós-operatório | orientação e confirmação do retorno |

Cada disparo grava a mensagem na conversa — o histórico fica no paciente,
não no aparelho de quem atendeu.

---

## Fase 3 — Agendamento pelo WhatsApp

Com contato e paciente ligados, o próprio paciente (ou o filho) pode:
1. pedir agendamento → o bot mostra as **datas liberadas** daquela agenda;
2. mandar a **foto da requisição** → entra como anexo pendente de conferência;
3. escolher o horário → cria o agendamento **com as mesmas regras da tela**
   (vaga disponível, requisição válida, autorização com saldo);
4. receber a confirmação e o preparo.

Sem vaga, o bot oferece a **lista de espera** — e quando a coordenação liberar
novas datas, o aviso sai automaticamente para quem esperava.

> Nada disso pode furar as regras do sistema: o bot usa exatamente as mesmas
> validações da tela do call center, inclusive a de encaixe (que o bot **não**
> pode fazer — encaixe é decisão humana com autorização).

---

## O que precisamos do DIGISAC

1. **Webhook** de mensagem recebida (entrada), com URL configurável e segredo de assinatura.
2. **API de envio** de mensagem e arquivo, com token.
3. **URL do arquivo** acessível (ou base64) para a clínica arquivar a guia.
4. **Identificador estável de contato e de ticket**, para amarrar a conversa.
5. Confirmação do **plano/licença** que libera API e webhook.
6. Limites: mensagens por minuto, tamanho de arquivo, retenção do arquivo no
   servidor deles (precisamos saber por quanto tempo a URL vive).

## O que o HOG Gestão entrega

- Edge Function `digisac-webhook` (recebe) e `digisac-send` (envia);
- tabelas `contatos`, `contato_paciente`, `conversas`, `mensagens`, `anexos`;
- fila de conversas não identificadas com sugestão automática;
- disparos por gatilho, com registro no histórico do paciente.

## Ordem sugerida

1. Fase 1 (entrada + fila de identificação) — resolve a foto da requisição.
2. Fase 2 (confirmação e lembrete D-1) — reduz falta, que hoje é medida errada.
3. Fase 3 (agendamento pelo WhatsApp) — só depois das regras estarem rodando
   na tela, para o bot herdar validação madura.

---

## Dados confirmados do ambiente (22/08/2026)

| Item | Valor |
|---|---|
| DIGISAC da clínica | `https://hoguanabara.digisac.biz` |
| **URL base da API** | `https://hoguanabara.digisac.biz/api/v1` |
| Documentação | Postman — `documenter.getpostman.com/view/53282970/2sBXihpXmF` |
| Tokens | Configurações → API → aba **Tokens de acesso pessoal** |
| Webhooks | Configurações → API → aba **Webhooks** ✅ existe |
| Variáveis do iframe | `{{contactId}}`, `{{ticketId}}`, `{{userId}}` — **não manda telefone** |
| Deep link por conversa | **não existe** — a URL não muda ao trocar de conversa |

### Consequências para o desenho
1. O painel lateral funciona por **contactId** e aprende o vínculo com o paciente
   na primeira conversa (já implementado em `hog-digisac-painel.html`).
2. Para abrir/mandar mensagem a partir do sistema, o caminho é a **API**, não link.
3. O webhook existe → a **Fase 1 automática** (foto da requisição entrando sozinha)
   é viável.

### Endpoint que vamos usar (a confirmar na documentação)
```
POST {base}/messages          → enviar texto/arquivo
GET  {base}/contacts/{id}     → dados do contato (telefone, nome)
```
Com `GET /contacts/{id}` o painel deixa de precisar do telefone digitado: o
`contactId` do iframe basta para achar o paciente sozinho.

### Segurança
O token **não** pode ficar na página (o HTML é público no GitHub Pages).
Ele vai para os *secrets* das Edge Functions do Supabase, e o navegador chama
a Edge Function, nunca o DIGISAC direto.
