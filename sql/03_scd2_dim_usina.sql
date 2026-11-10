/* 
   Regras:
   - TIPO 2 (preserva histórico, cria nova versão): potencia_mw, situacao, cod_submercado.
       * potência muda o denominador do fator de capacidade;
       * submercado muda o PLD usado na valoração;
       * situação explica disponibilidade e paradas por período.
   - TIPO 1 (sobrescreve em todas as versões): nome, UF, município, coordenadas,
       data de início, atributos da fonte e do ponto de clima, flags de qualidade.
       São rótulos ou correções de erro: não mudam nenhuma medida no passado.
   - A primeira versão de cada usina começa em 1900-01-01, para que todo fato
     histórico encontre uma versão. Mudanças posteriores valem a partir da data
     da carga que as detectou (a origem não informa a data real da mudança).
   - Membro desconhecido: sk_usina = -1.
*/

SET search_path TO dw_campo_real, public;

-- Origem da dimensão: usinas já limpas (Etapa 2) + fonte, submercado e ponto de clima
CREATE OR REPLACE VIEW stg_usina AS
SELECT u.cod_usina, u.nome,
       f.cod_fonte, f.descricao AS descricao_fonte, f.renovavel, f.intermitente,
       u.cod_submercado, s.nome AS nome_submercado,
       u.uf, u.municipio, u.latitude, u.longitude, u.potencia_mw,
       u.data_inicio_operacao, u.situacao,
       cp.latitude_usada AS lat_clima, cp.longitude_usada AS lon_clima,
       cp.lat_grade AS lat_grade_clima, cp.lon_grade AS lon_grade_clima,
       cp.elevacao_m, cp.criterio AS criterio_ponto_clima,
       u.flags AS flags_qualidade
FROM qualidade.usina_tratada u
JOIN campo_real_energia.fonte_energia f ON f.id_fonte = u.id_fonte
JOIN campo_real_energia.submercado s ON s.cod_submercado = u.cod_submercado
LEFT JOIN externo.clima_ponto cp ON cp.cod_usina = u.cod_usina;

-- 0) Membro desconhecido
INSERT INTO dim_usina (sk_usina, cod_usina, nome, cod_fonte, descricao_fonte, cod_submercado, nome_submercado,
                       uf, municipio, situacao, dt_inicio_vigencia, dt_fim_vigencia, registro_atual)
VALUES (-1, 'DESCONHECIDA', 'Usina desconhecida', 'N/D', 'Desconhecida', '??', 'Desconhecido',
        '??', 'Desconhecido', 'Desconhecida', DATE '1900-01-01', DATE '9999-12-31', TRUE)
ON CONFLICT (sk_usina) DO NOTHING;

-- 1) Tipo 2: fecha a versão atual se algum atributo Tipo 2 mudou
UPDATE dim_usina d
SET dt_fim_vigencia = CURRENT_DATE,
    registro_atual = FALSE
FROM stg_usina s
WHERE d.cod_usina = s.cod_usina
  AND d.registro_atual
  AND (d.potencia_mw IS DISTINCT FROM s.potencia_mw
    OR d.situacao IS DISTINCT FROM s.situacao
    OR d.cod_submercado IS DISTINCT FROM s.cod_submercado);

-- 2) Insere a nova versão: usinas novas (desde 1900) ou versões recém-fechadas 
INSERT INTO dim_usina (cod_usina, nome, cod_fonte, descricao_fonte, renovavel, intermitente,
                       cod_submercado, nome_submercado, uf, municipio, latitude, longitude, potencia_mw,
                       data_inicio_operacao, situacao, lat_clima, lon_clima, lat_grade_clima, lon_grade_clima,
                       elevacao_m, criterio_ponto_clima, flags_qualidade,
                       dt_inicio_vigencia, dt_fim_vigencia, registro_atual)
SELECT s.cod_usina, s.nome, s.cod_fonte, s.descricao_fonte, s.renovavel, s.intermitente,
       s.cod_submercado, s.nome_submercado, s.uf, s.municipio, s.latitude, s.longitude, s.potencia_mw,
       s.data_inicio_operacao, s.situacao, s.lat_clima, s.lon_clima, s.lat_grade_clima, s.lon_grade_clima,
       s.elevacao_m, s.criterio_ponto_clima, s.flags_qualidade,
       CASE WHEN EXISTS (SELECT 1 FROM dim_usina x WHERE x.cod_usina = s.cod_usina)
            THEN CURRENT_DATE ELSE DATE '1900-01-01' END,
       DATE '9999-12-31',
       TRUE
FROM stg_usina s
WHERE NOT EXISTS (SELECT 1 FROM dim_usina d WHERE d.cod_usina = s.cod_usina AND d.registro_atual);

-- 3) Tipo 1: sobrescreve os demais atributos em todas as versões da usina
--    (nome_submercado fica de fora: depende do atributo Tipo 2 cod_submercado)
UPDATE dim_usina d
SET nome = s.nome,
    cod_fonte = s.cod_fonte,
    descricao_fonte = s.descricao_fonte,
    renovavel = s.renovavel,
    intermitente = s.intermitente,
    uf = s.uf,
    municipio = s.municipio,
    latitude = s.latitude,
    longitude = s.longitude,
    data_inicio_operacao = s.data_inicio_operacao,
    lat_clima = s.lat_clima,
    lon_clima = s.lon_clima,
    lat_grade_clima = s.lat_grade_clima,
    lon_grade_clima = s.lon_grade_clima,
    elevacao_m = s.elevacao_m,
    criterio_ponto_clima = s.criterio_ponto_clima,
    flags_qualidade = s.flags_qualidade
FROM stg_usina s
WHERE d.cod_usina = s.cod_usina;
