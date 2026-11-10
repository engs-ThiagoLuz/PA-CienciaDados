/* 
   Cada fato escolhe a VERSÃO da dim_usina vigente na data do fato
   (dt_inicio_vigencia <= data < dt_fim_vigencia). Se não houver
   correspondência, usa o membro desconhecido (-1).
   Tempo é INNER JOIN: a camada tratada só tem horas dentro de dim_tempo, e o
   notebook confere que nenhuma linha foi perdida.
*/

SET search_path TO dw_campo_real, public;

TRUNCATE fato_geracao_horaria, fato_pld_horario, fato_clima_horario, fato_indisponibilidade_horaria,
         fato_qualidade_regra, fato_impacto_limpeza;


/* 
   fato_geracao_horaria
*/
INSERT INTO fato_geracao_horaria
      (sk_tempo, sk_usina, sk_submercado, sk_origem_dado, id_medicao_origem,
       energia_mwh, energia_mwh_original, disponibilidade_mw, capacidade_mwh,
       recebido_em, atraso_recebimento_min,
       flag_energia_ausente, flag_valor_corrigido, flag_recebimento_atrasado, flag_recebido_antes_do_fato,
       flags_qualidade)
SELECT t.sk_tempo,
       COALESCE(du.sk_usina, -1),
       COALESCE(ds.sk_submercado, -1),
       COALESCE(o.sk_origem_dado, -1),
       m.id_medicao,
       m.energia_mwh,
       m.energia_mwh_original,
       m.disponibilidade_mw,
       COALESCE(du.potencia_mw, 0), -- potência vigente x 1 hora
       m.recebido_em,
       CASE WHEN m.recebido_em IS NULL THEN NULL
            ELSE (EXTRACT(EPOCH FROM (m.recebido_em - m.data_hora)) / 60)::int END,
       COALESCE(m.flags, '') LIKE '%energia_ausente%',
       COALESCE(m.flags, '') LIKE '%energia_corrigida%' OR COALESCE(m.flags, '') LIKE '%energia_negativa_zerada%',
       COALESCE(m.flags, '') LIKE '%recebimento_atrasado%',
       COALESCE(m.flags, '') LIKE '%recebido_antes_do_fato%',
       NULLIF(m.flags, '')
FROM qualidade.medicao_geracao_tratada m
JOIN qualidade.usina_tratada ut ON ut.id_usina = m.id_usina
JOIN dim_tempo t ON t.data_hora = m.data_hora
LEFT JOIN dim_usina du ON du.cod_usina = ut.cod_usina
                               AND m.data_hora::date >= du.dt_inicio_vigencia
                               AND m.data_hora::date <  du.dt_fim_vigencia
LEFT JOIN dim_submercado ds ON ds.cod_submercado = du.cod_submercado
LEFT JOIN dim_origem_dado o ON o.origem = m.origem;


/* 
   fato_pld_horario
 */
INSERT INTO fato_pld_horario (sk_tempo, sk_submercado, pld_rs_mwh)
SELECT t.sk_tempo, COALESCE(ds.sk_submercado, -1), p.pld_rs_mwh
FROM externo.pld_horario p
JOIN dim_tempo t ON t.data_hora = p.data_hora
LEFT JOIN dim_submercado ds ON ds.cod_submercado = p.cod_submercado;


/* 
   fato_clima_horario  (ponto de clima = usina; ver clima_ponto e dim_usina)
*/
INSERT INTO fato_clima_horario
      (sk_tempo, sk_usina, sk_submercado, temperatura_c, precipitacao_mm, cobertura_nuvens_pct,
       radiacao_w_m2, vento_10m_ms, vento_100m_ms, dir_vento_100m_graus)
SELECT t.sk_tempo,
       COALESCE(du.sk_usina, -1),
       COALESCE(ds.sk_submercado, -1),
       c.temperatura_c, c.precipitacao_mm, c.cobertura_nuvens_pct,
       c.radiacao_w_m2, c.vento_10m_ms, c.vento_100m_ms, c.dir_vento_100m_graus
FROM externo.clima_horario c
JOIN dim_tempo t ON t.data_hora = c.data_hora
LEFT JOIN dim_usina du ON du.cod_usina = c.cod_usina
                           AND c.data_hora::date >= du.dt_inicio_vigencia
                           AND c.data_hora::date <  du.dt_fim_vigencia
LEFT JOIN dim_submercado ds ON ds.cod_submercado = du.cod_submercado;


/*
   fato_indisponibilidade_horaria

   A energia não gerada é estimada: mediana da geração da
   mesma usina, na mesma hora do dia, nos +-14 dias vizinhos, usando só horas
   com energia medida e disponibilidade > 0.
   Sem vizinhança utilizável a estimativa fica NULL e tem_referencia = FALSE.
*/
INSERT INTO fato_indisponibilidade_horaria
      (sk_tempo, sk_usina, sk_submercado, sk_tipo_parada, id_parada_origem, motivo,
       horas_indisponiveis, energia_nao_gerada_estimada_mwh, n_horas_referencia, tem_referencia,
       pld_rs_mwh, receita_nao_gerada_estimada_rs)
WITH horas AS (
    SELECT DISTINCT ON (du.sk_usina, t.sk_tempo)
           t.sk_tempo, t.data_hora, t.hora,
           du.sk_usina, du.cod_usina, du.cod_submercado,
           p.id_parada, p.motivo, p.tipo
    FROM qualidade.parada_tratada p
    JOIN qualidade.usina_tratada ut ON ut.id_usina = p.id_usina
    JOIN dim_tempo t ON t.data_hora BETWEEN date_trunc('hour', p.inicio) AND p.fim
    JOIN dim_usina du ON du.cod_usina = ut.cod_usina
                                   AND t.data >= du.dt_inicio_vigencia
                                   AND t.data <  du.dt_fim_vigencia
    ORDER BY du.sk_usina, t.sk_tempo, p.id_parada
),
est AS (
    SELECT h.*, r.mediana, r.n
    FROM horas h
    LEFT JOIN LATERAL (
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY g.energia_mwh) AS mediana,
               COUNT(*) AS n
        FROM fato_geracao_horaria g
        JOIN dim_usina du2 ON du2.sk_usina = g.sk_usina AND du2.cod_usina = h.cod_usina
        JOIN dim_tempo t2  ON t2.sk_tempo = g.sk_tempo
        WHERE t2.hora = h.hora
          AND t2.data_hora BETWEEN h.data_hora - INTERVAL '14 days' AND h.data_hora + INTERVAL '14 days'
          AND g.energia_mwh IS NOT NULL
          AND g.disponibilidade_mw > 0
    ) r ON TRUE
)
SELECT e.sk_tempo, e.sk_usina,
       COALESCE(ds.sk_submercado, -1),
       COALESCE(tp.sk_tipo_parada, -1),
       e.id_parada, e.motivo,
       1,
       ROUND(e.mediana::numeric, 3),
       COALESCE(e.n, 0)::smallint,
       (e.mediana IS NOT NULL),
       pld.pld_rs_mwh,
       ROUND(e.mediana::numeric * pld.pld_rs_mwh, 2)
FROM est e
LEFT JOIN dim_submercado ds ON ds.cod_submercado = e.cod_submercado
LEFT JOIN dim_tipo_parada tp ON tp.tipo = e.tipo
LEFT JOIN fato_pld_horario pld ON pld.sk_tempo = e.sk_tempo AND pld.sk_submercado = ds.sk_submercado;


/* 
   Qualidade: copia para o DW os resultados da Etapa 2, para o painel ler só do DW
*/
INSERT INTO fato_qualidade_regra
      (fase, id_regra, id_execucao, regra, dimensao_qualidade, tabela,
       registros_avaliados, registros_falha, percentual_falha, decisao, executado_em)
SELECT m.fase, m.id_regra, m.id_execucao, m.regra, m.dimensao, m.tabela,
       m.registros_avaliados, m.registros_falha, m.percentual_falha, d.decisao, m.executado_em
FROM qualidade.metricas_qualidade m
JOIN (SELECT fase, MAX(id_execucao) AS id_execucao
      FROM qualidade.metricas_qualidade GROUP BY fase) u
  ON u.fase = m.fase AND u.id_execucao = m.id_execucao
LEFT JOIN qualidade.decisoes_qualidade d ON d.id_regra = m.id_regra
WHERE m.erro IS NULL;

INSERT INTO fato_impacto_limpeza (nivel, chave, indicador, antes, depois, delta, delta_pct)
SELECT nivel, chave, indicador, antes, depois, delta, delta_pct
FROM qualidade.impacto_negocio;
