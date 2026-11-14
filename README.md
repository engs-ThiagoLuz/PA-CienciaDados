# Data Warehouse da Campo Real Energia

Trabalho prático · Centro Universitário Campo Real · Data Warehouse

**Grupo:** Thiago Ferreira da Luz 

Pipeline completo, dos dados abertos aos indicadores: extração do PLD (CCEE) e do clima (Open-Meteo), qualidade de dados em Python, star schema em PostgreSQL (Neon) e painel no Tableau. A pergunta da diretoria: *quanto a nossa geração vale, onde e quando ganhamos ou perdemos dinheiro, e podemos confiar nos números?*

## Estrutura

```
.
├── README.md
├── config.yaml                      configuração (criado pelos notebooks)
├── .env                             credencial do banco (NÃO versionar)
├── .gitignore                       deve conter .env
├── campo_real_energia_postgres.sql  banco de origem fornecido
├── etapa1_extracao_pld.ipynb        Etapa 1A: PLD horário da CCEE
├── etapa1b_extracao_openmeteo.ipynb Etapa 1B: clima horário (Open-Meteo)
├── etapa2_qualidade.ipynb           Etapa 2: profiling, regras, limpeza, impacto
├── etapa3_carga_dw.ipynb            Etapa 3: executa os scripts do DW e valida
├── sql/
│   ├── 01_ddl_dw_campo_real.sql     cria o star schema (apaga o schema se existir)
│   ├── 02_carga_dimensoes.sql       tempo, submercado, tipo de parada, origem do dado
│   ├── 03_scd2_dim_usina.sql        dim_usina com SCD Tipo 2 + Tipo 1
│   ├── 04_carga_fatos.sql           fatos e resultados de qualidade
│   └── 05_views_painel.sql          views planas para o painel
├── docs/                            documento de modelagem e relatório de qualidade
└── painel/                          arquivo .twbx do Tableau
```

Todos os notebooks e o `config.yaml` ficam na **raiz**. Abra o Jupyter a partir dela.

## Requisitos

- Python 3.10 ou superior e Jupyter (`pip install notebook`).
- Bibliotecas (instalação em cada notebook): `psycopg2-binary`, `pyyaml`, `requests`, `curl_cffi`, `pandas`, `numpy`.
- Um banco PostgreSQL 13 ou superior. O trabalho usa o **Neon**.
- Tableau Desktop para o painel.

## Configuração

1. Crie um projeto no Neon e copie a *connection string*.
2. Crie o arquivo `.env` na raiz:

   ```
   NEON_DATABASE_URL="postgresql://usuario:senha@host/banco?sslmode=require"
   ```

3. Coloque `.env` no `.gitignore`.
4. O `config.yaml` é criado automaticamente pelos notebooks, com parâmetros como anos do PLD, período do clima e limites de qualidade. Nada de credenciais ou caminhos de máquina no código.

## Ordem de execução

Rode na ordem. Cada etapa depende da anterior e pode ser reexecutada.

| # | Arquivo | O que faz | Resultado no banco |
|---|---|---|---|
| 1 | `etapa1_extracao_pld.ipynb` | carrega a origem, extrai o PLD horário 2025 e 2026 pela API da CCEE (raw e tratada) | schemas `campo_real_energia` e `externo` |
| 2 | `etapa1b_extracao_openmeteo.ipynb` | define o ponto de clima de cada usina e extrai o clima horário | `externo.clima_*` |
| 3 | `etapa2_qualidade.ipynb` | profiling, 33 regras (7 dimensões), decisões, limpeza, impacto antes e depois | schema `qualidade` |
| 4 | `etapa3_carga_dw.ipynb` | executa `sql/01` a `sql/04`, valida a carga e roda consultas de teste | schema `dw_campo_real` |
| 5 | `sql/05_views_painel.sql` | no notebook da Etapa 3: `rodar_sql("05_views_painel.sql")` | views `vw_*` do painel |
| 6 | Tableau | conecta ao `dw_campo_real` (ver abaixo) | `painel/*.twbx` |

Observações:

- O script `sql/01` **apaga** o schema `dw_campo_real` (inclusive o histórico da `dim_usina`). O notebook da Etapa 3 só o executa se o schema não existir ou se `dw.recriar_dw: true` no `config.yaml`.
- As tabelas de origem **nunca são alteradas**; a limpeza acontece no caminho até o DW.

## Modelo dimensional (resumo)

- **Fatos (grão):** geração horária (usina × hora), PLD horário (submercado × hora), clima horário (usina × hora) e indisponibilidade horária (usina × hora em parada).
- **Dimensões:** tempo (hora), usina (SCD Tipo 2 em potência, submercado e situação; Tipo 1 nos demais), submercado, tipo de parada e origem do dado. Todas têm chave substituta e o membro `-1` "Desconhecido".
- Detalhes, matriz de barramento e diagrama estão no documento de modelagem (`docs/`).

## Painel (Tableau)

O painel lê **somente** do schema `dw_campo_real`. Use o Tableau Desktop, conecte em PostgreSQL com os dados do Neon (Require SSL), escolha o schema `dw_campo_real` e trabalhe com **Extrato** (o `.twbx` leva o extrato e abre sem acesso ao banco). Cada fonte de dados usa uma view do script `sql/05` ou uma tabela de qualidade. O passo a passo e as fórmulas estão no guia do painel.

## Principais resultados

- Receita valorada ao PLD em 2025: **R$ 637,6 mi** para **3,12 TWh** de geração (preço capturado de R$ 204,45/MWh).
- Razão de captura por fonte: térmica a gás 1,25 e solar 0,78 (a solar vende cerca de 22% abaixo do PLD médio).
- Sem a limpeza, a receita seria **R$ 803,9 mi (26% maior)**; um único erro de unidade (planilha em kWh) responde por quase toda a diferença.
- Perdas estimadas por paradas: cerca de R$ 11,9 mi (R$ 8,6 mi sem a parada da biomassa, cuja estimativa superestima a perda).

## Comportamento diante de falhas das fontes

- **CCEE:** o portal retornou 403 ("Acesso bloqueado") para o cliente `requests` padrão, no Colab e na máquina local. O cliente HTTP usa `curl_cffi` (que imita o handshake TLS de um navegador), com `requests` como alternativa. Há retry com backoff, tratamento de 429, timeout, resposta vazia e mudança de colunas, e cada execução é registrada em `externo.log_extracao`.
- **Open-Meteo:** retry com backoff, tratamento de 429 e de erro explícito da API, validação de unidades e reaproveitamento do que já foi baixado (status `PULADO` no log).
- **Neon:** o banco hospedado "dorme" quando ocioso; a primeira conexão pode demorar (`connect_timeout` de 30 s).

## Fontes de dados e atribuição

- **CCEE · Dados Abertos · PLD horário.** https://dadosabertos.ccee.org.br/dataset/pld_horario 
- **Open-Meteo · API histórica.** https://open-meteo.com · *Weather data by Open-Meteo.com* 
- **ANEEL** (limites regulatórios do PLD 2025 e 2026, usados na regra de validade V07).

Os dados de geração, cadastro de usinas e paradas são sintéticos, fornecidos pela professora.


