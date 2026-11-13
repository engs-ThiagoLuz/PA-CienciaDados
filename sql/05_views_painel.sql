/* 
   Script 05 · Views para o painel
*/



SET search_path TO dw_campo_real, public;

-- PLD médio por submercado e ano (base da razão de captura)
CREATE OR REPLACE VIEW vw_pld_medio_submercado_ano AS
SELECT t.ano, p.sk_submercado, AVG(p.pld_rs_mwh) AS pld_medio
FROM fato_pld_horario p
JOIN dim_tempo t ON t.sk_tempo = p.sk_tempo
GROUP BY t.ano, p.sk_submercado;

-- P1, P2, P3: geração, receita valorada e razão de captura (1 linha = usina x hora)
--   preço capturado   = SUM(receita_rs) / SUM(energia_mwh)
--   razão de captura  = SUM(receita_rs) / SUM(receita_ao_pld_medio_rs)
--   fator de capacidade = SUM(energia_mwh) / SUM(capacidade_mwh)
CREATE OR REPLACE VIEW vw_geracao_detalhe AS
SELECT t.data_hora, t.data, t.ano, t.mes, t.nome_mes, t.ano_mes, t.hora, t.faixa_horaria,
       t.dia_util, t.feriado, t.patamar_carga, t.estacao_ano, t.periodo_hidrologico,
       u.cod_usina, u.nome AS nome_usina, u.cod_fonte, u.descricao_fonte, u.renovavel, u.intermitente,
       s.cod_submercado, s.nome AS nome_submercado, u.potencia_mw,
       g.energia_mwh, g.capacidade_mwh, g.disponibilidade_mw,
       p.pld_rs_mwh,
       g.energia_mwh * p.pld_rs_mwh AS receita_rs,
       pm.pld_medio AS pld_medio_submercado_ano,
       g.energia_mwh * pm.pld_medio AS receita_ao_pld_medio_rs,
       g.flag_energia_ausente, g.flag_valor_corrigido, g.flag_recebimento_atrasado, g.flags_qualidade
FROM fato_geracao_horaria g
JOIN dim_tempo t ON t.sk_tempo = g.sk_tempo
JOIN dim_usina u ON u.sk_usina = g.sk_usina
JOIN dim_submercado s  ON s.sk_submercado = g.sk_submercado
LEFT JOIN fato_pld_horario p ON p.sk_tempo = g.sk_tempo AND p.sk_submercado = g.sk_submercado
LEFT JOIN vw_pld_medio_submercado_ano pm ON pm.ano = t.ano AND pm.sk_submercado = g.sk_submercado;

-- P4: mapa de calor do PLD (hora x mês x submercado)
CREATE OR REPLACE VIEW vw_pld_mapa_calor AS
SELECT t.ano, t.mes, t.nome_mes, t.ano_mes, t.hora, s.cod_submercado,
       ROUND(AVG(p.pld_rs_mwh), 2) AS pld_medio,
       COUNT(*) AS horas
FROM fato_pld_horario p
JOIN dim_tempo t ON t.sk_tempo = p.sk_tempo
JOIN dim_submercado s ON s.sk_submercado = p.sk_submercado
GROUP BY t.ano, t.mes, t.nome_mes, t.ano_mes, t.hora, s.cod_submercado;

-- P4: perfil horário de geração por fonte e mês (2025)
CREATE OR REPLACE VIEW vw_perfil_horario_fonte AS
SELECT u.cod_fonte, u.descricao_fonte, t.mes, t.nome_mes, t.hora,
       SUM(g.energia_mwh) AS energia_mwh,
       SUM(g.capacidade_mwh) AS capacidade_mwh,
       ROUND(100 * SUM(g.energia_mwh) / NULLIF(SUM(g.capacidade_mwh), 0), 2) AS fator_capacidade_pct
FROM fato_geracao_horaria g
JOIN dim_tempo t ON t.sk_tempo = g.sk_tempo
JOIN dim_usina u ON u.sk_usina = g.sk_usina
WHERE t.ano = 2025
GROUP BY u.cod_fonte, u.descricao_fonte, t.mes, t.nome_mes, t.hora;

-- P5: perda por paradas (1 linha = usina x hora em parada). A coluna entressafra permite
-- tirar do total a parada da biomassa, cuja estimativa tende a superestimar a perda.
CREATE OR REPLACE VIEW vw_perda_parada AS
SELECT t.data_hora, t.data, t.ano, t.mes, t.nome_mes, t.hora, t.patamar_carga,
       u.cod_usina, u.nome AS nome_usina, u.cod_fonte, s.cod_submercado,
       tp.tipo AS tipo_parada, f.id_parada_origem, f.motivo,
       COALESCE(f.motivo ILIKE '%entressafra%', FALSE) AS entressafra,
       f.horas_indisponiveis, f.energia_nao_gerada_estimada_mwh,
       f.pld_rs_mwh, f.receita_nao_gerada_estimada_rs,
       f.tem_referencia, f.n_horas_referencia
FROM fato_indisponibilidade_horaria f
JOIN dim_tempo t ON t.sk_tempo = f.sk_tempo
JOIN dim_usina u ON u.sk_usina = f.sk_usina
JOIN dim_submercado s ON s.sk_submercado = f.sk_submercado
JOIN dim_tipo_parada tp ON tp.sk_tipo_parada = f.sk_tipo_parada;

-- P6: clima x geração (1 linha = usina x hora com energia medida), com desvios em relação
-- à média da mesma hora do dia no mesmo mês. Os desvios tiram o ciclo diário e a sazonalidade,
-- que dominam a correlação bruta.
CREATE OR REPLACE VIEW vw_clima_geracao AS
WITH base AS (
    SELECT g.sk_usina, t.data_hora, t.ano, t.mes, t.hora, u.cod_usina, u.cod_fonte,
           g.energia_mwh, c.radiacao_w_m2, c.vento_100m_ms, c.temperatura_c, c.cobertura_nuvens_pct
    FROM fato_geracao_horaria g
    JOIN fato_clima_horario c ON c.sk_tempo = g.sk_tempo AND c.sk_usina = g.sk_usina
    JOIN dim_tempo t ON t.sk_tempo = g.sk_tempo
    JOIN dim_usina u ON u.sk_usina = g.sk_usina
    WHERE g.energia_mwh IS NOT NULL
)
SELECT b.*,
       b.energia_mwh   - AVG(b.energia_mwh)   OVER (PARTITION BY b.sk_usina, b.mes, b.hora) AS energia_desvio_mes_hora,
       b.radiacao_w_m2 - AVG(b.radiacao_w_m2) OVER (PARTITION BY b.sk_usina, b.mes, b.hora) AS radiacao_desvio_mes_hora,
       b.vento_100m_ms - AVG(b.vento_100m_ms) OVER (PARTITION BY b.sk_usina, b.mes, b.hora) AS vento100_desvio_mes_hora
FROM base b;

-- P6: correlação por usina, bruta e sem o ciclo diário/sazonal
CREATE OR REPLACE VIEW vw_correlacao_clima_geracao AS
SELECT cod_usina, cod_fonte,
       ROUND(corr(energia_mwh::float8, radiacao_w_m2::float8)::numeric, 3)                   AS corr_radiacao_bruta,
       ROUND(corr(energia_desvio_mes_hora::float8, radiacao_desvio_mes_hora::float8)::numeric, 3) AS corr_radiacao_sem_ciclo,
       ROUND(corr(energia_mwh::float8, vento_100m_ms::float8)::numeric, 3)                   AS corr_vento100_bruta,
       ROUND(corr(energia_desvio_mes_hora::float8, vento100_desvio_mes_hora::float8)::numeric, 3) AS corr_vento100_sem_ciclo
FROM vw_clima_geracao
GROUP BY cod_usina, cod_fonte;
