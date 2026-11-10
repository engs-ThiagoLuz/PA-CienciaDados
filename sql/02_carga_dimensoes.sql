/* =====================================================================
   CAMPO REAL ENERGIA · DATA WAREHOUSE
   Script 02 · Carga das dimensões simples (tempo, submercado, tipo de
   parada, origem do dado). Reexecutável.

   Lê apenas da camada tratada (schemas qualidade e externo) e do cadastro
   de submercados/feriados da origem. A dim_usina (SCD2) é o script 03.
   ===================================================================== */

SET search_path TO dw_campo_real, public;

-- Os fatos precisam ser esvaziados junto com as dimensões que eles referenciam.
-- A dim_usina NÃO é esvaziada (preserva o histórico SCD2).
TRUNCATE fato_geracao_horaria, fato_pld_horario, fato_clima_horario, fato_indisponibilidade_horaria,
         dim_tempo, dim_submercado, dim_tipo_parada, dim_origem_dado, stg_feriado
RESTART IDENTITY;


/* ---------------------------------------------------------------------
   Feriados: 2025 da origem + 2026 complementado pelo grupo (a origem só tem 2025)
   CONFERIR as datas de 2026 num calendário oficial antes de publicar.
   --------------------------------------------------------------------- */
INSERT INTO stg_feriado (data, descricao, tipo, origem_dado)
SELECT data, descricao, tipo, 'origem' FROM campo_real_energia.feriado_nacional;

INSERT INTO stg_feriado (data, descricao, tipo, origem_dado) VALUES
  ('2026-01-01', 'Confraternização Universal', 'Feriado', 'complemento_grupo'),
  ('2026-02-16', 'Carnaval', 'Ponto facultativo', 'complemento_grupo'),
  ('2026-02-17', 'Carnaval', 'Ponto facultativo', 'complemento_grupo'),
  ('2026-04-03', 'Sexta-feira Santa', 'Feriado', 'complemento_grupo'),
  ('2026-04-21', 'Tiradentes', 'Feriado', 'complemento_grupo'),
  ('2026-05-01', 'Dia do Trabalho', 'Feriado', 'complemento_grupo'),
  ('2026-06-04', 'Corpus Christi', 'Ponto facultativo', 'complemento_grupo'),
  ('2026-09-07', 'Independência do Brasil', 'Feriado', 'complemento_grupo'),
  ('2026-10-12', 'Nossa Senhora Aparecida', 'Feriado', 'complemento_grupo'),
  ('2026-11-02', 'Finados', 'Feriado', 'complemento_grupo'),
  ('2026-11-15', 'Proclamação da República', 'Feriado', 'complemento_grupo'),
  ('2026-11-20', 'Dia da Consciência Negra', 'Feriado', 'complemento_grupo'),
  ('2026-12-25', 'Natal', 'Feriado', 'complemento_grupo')
ON CONFLICT (data) DO NOTHING;


/*
   dim_submercado
 */
INSERT INTO dim_submercado (sk_submercado, cod_submercado, nome, regioes)
VALUES (-1, '??', 'Desconhecido', 'Desconhecido');

INSERT INTO dim_submercado (cod_submercado, nome, regioes)
SELECT cod_submercado, nome, regioes
FROM campo_real_energia.submercado
ORDER BY CASE cod_submercado WHEN 'SE' THEN 1 WHEN 'S' THEN 2 WHEN 'NE' THEN 3 ELSE 4 END;


/*
   dim_tipo_parada
*/
INSERT INTO dim_tipo_parada (sk_tipo_parada, tipo, descricao)
VALUES (-1, 'Desconhecido', 'Tipo de parada desconhecido');

INSERT INTO dim_tipo_parada (tipo, descricao)
SELECT DISTINCT p.tipo,
       CASE p.tipo WHEN 'Programada' THEN 'Manutenção planejada'
                   WHEN 'Forçada' THEN 'Falha ou restrição não planejada'
                   ELSE p.tipo END
FROM qualidade.parada_tratada p
ORDER BY 1;


/*
   dim_origem_dado
*/
INSERT INTO dim_origem_dado (sk_origem_dado, origem, automatica)
VALUES (-1, 'Desconhecida', NULL);

INSERT INTO dim_origem_dado (origem, automatica)
SELECT DISTINCT m.origem, (m.origem = 'SCADA')
FROM qualidade.medicao_geracao_tratada m
WHERE m.origem IS NOT NULL
ORDER BY 1;


/*
   dim_tempo: 1 linha por hora, de 2025-01-01 00:00 a 2026-12-31 23:00

   Premissas simplificadas:
   - dia_util: segunda a sexta, exceto feriado nacional e ponto facultativo nacional;
   - estacao_ano: hemisfério sul, datas fixas (21/12, 21/03, 21/06, 23/09);
   - periodo_hidrologico: Úmido de novembro a abril, Seco de maio a outubro;
   - patamar_carga: Leve (0h-6h, domingos e feriados), Pesada (18h-20h em dia útil),
     Média (demais). Ajustar conforme o PMO/ONS se o grupo quiser.
*/
INSERT INTO dim_tempo (sk_tempo, nome_mes, ano_mes, nome_dia_semana, faixa_horaria,
                       estacao_ano, periodo_hidrologico, patamar_carga)
VALUES (-1, 'Desconhecido', 'N/D', 'Desconhecido', 'Desconhecida',
        'Desconhecida', 'N/D', 'N/D');

INSERT INTO dim_tempo (sk_tempo, data_hora, data, ano, trimestre, mes, nome_mes, ano_mes, dia, dia_do_ano,
                       semana_iso, dia_da_semana, nome_dia_semana, hora, faixa_horaria, fim_de_semana,
                       feriado, nome_feriado, tipo_feriado, ponto_facultativo, dia_util,
                       estacao_ano, periodo_hidrologico, patamar_carga)
WITH b AS (
    SELECT g.data_hora,
           g.data_hora::date AS dt,
           EXTRACT(YEAR FROM g.data_hora)::int AS ano,
           EXTRACT(QUARTER FROM g.data_hora)::int AS trimestre,
           EXTRACT(MONTH FROM g.data_hora)::int AS mes,
           EXTRACT(DAY FROM g.data_hora)::int AS dia,
           EXTRACT(DOY FROM g.data_hora)::int AS dia_do_ano,
           EXTRACT(WEEK FROM g.data_hora)::int AS semana_iso,
           EXTRACT(ISODOW FROM g.data_hora)::int AS dow,
           EXTRACT(HOUR FROM g.data_hora)::int AS hora,
           f.descricao AS nome_feriado,
           f.tipo AS tipo_feriado
    FROM generate_series(TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2026-12-31 23:00:00',
                         INTERVAL '1 hour') AS g(data_hora)
    LEFT JOIN stg_feriado f ON f.data = g.data_hora::date
),
c AS (
    SELECT b.*,
           (b.dow >= 6) AS fim_de_semana,
           (b.nome_feriado IS NOT NULL) AS feriado,
           (b.dow < 6 AND b.nome_feriado IS NULL) AS dia_util
    FROM b
)
SELECT ROW_NUMBER() OVER (ORDER BY c.data_hora)::int,
       c.data_hora, c.dt, c.ano::smallint, c.trimestre::smallint, c.mes::smallint,
       (ARRAY['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto',
              'Setembro','Outubro','Novembro','Dezembro'])[c.mes],
       to_char(c.data_hora, 'YYYY-MM'),
       c.dia::smallint, c.dia_do_ano::smallint, c.semana_iso::smallint, c.dow::smallint,
       (ARRAY['Segunda-feira','Terça-feira','Quarta-feira','Quinta-feira','Sexta-feira','Sábado','Domingo'])[c.dow],
       c.hora::smallint,
       CASE WHEN c.hora < 6 THEN 'Madrugada' WHEN c.hora < 12 THEN 'Manhã'
            WHEN c.hora < 18 THEN 'Tarde' ELSE 'Noite' END,
       c.fim_de_semana,
       c.feriado, c.nome_feriado, c.tipo_feriado,
       COALESCE(c.tipo_feriado = 'Ponto facultativo', FALSE),
       c.dia_util,
       CASE WHEN (c.mes = 12 AND c.dia >= 21) OR c.mes IN (1, 2) OR (c.mes = 3 AND c.dia <= 20) THEN 'Verão'
            WHEN (c.mes = 3 AND c.dia >= 21) OR c.mes IN (4, 5) OR (c.mes = 6 AND c.dia <= 20) THEN 'Outono'
            WHEN (c.mes = 6 AND c.dia >= 21) OR c.mes IN (7, 8) OR (c.mes = 9 AND c.dia <= 22) THEN 'Inverno'
            ELSE 'Primavera' END,
       CASE WHEN c.mes IN (11, 12, 1, 2, 3, 4) THEN 'Úmido' ELSE 'Seco' END,
       CASE WHEN c.dow = 7 OR c.feriado THEN 'Leve'
            WHEN c.dia_util AND c.hora BETWEEN 18 AND 20 THEN 'Pesada'
            WHEN c.hora BETWEEN 0 AND 6 THEN 'Leve'
            ELSE 'Média' END
FROM c;
