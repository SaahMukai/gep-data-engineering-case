-- GEP | REPRODUCIBLE DATA QUALITY CHECKS
-- Execute each query separately in Databricks SQL Editor and export the actual outputs.
-- All statements are read-only.

-- 1) Layer counts | compare with the audit and current run
SELECT 'bronze' AS camada, COUNT(*) AS total_registros
FROM workspace.gep_public_procurement.bronze_precos
UNION ALL
SELECT 'silver', COUNT(*) FROM workspace.gep_public_procurement.silver_precos
UNION ALL
SELECT 'gold', COUNT(*) FROM workspace.gep_public_procurement.gold_precos_mensais;

-- 2) Removals per rule | export output
SELECT run_id, ordem, etapa, linhas_entrada, linhas_saida, linhas_removidas
FROM workspace.gep_public_procurement.auditoria_silver
ORDER BY ordem;

-- 3) Silver required-field quality | expected: current Silver total and zeros
SELECT COUNT(*) AS total_registros,
SUM(CASE WHEN codigoItemCatalogo IS NULL THEN 1 ELSE 0 END) AS catalogo_nulo,
SUM(CASE WHEN dataResultado IS NULL THEN 1 ELSE 0 END) AS data_nula,
SUM(CASE WHEN quantidade IS NULL THEN 1 ELSE 0 END) AS quantidade_nula,
SUM(CASE WHEN quantidade <= 0 THEN 1 ELSE 0 END) AS quantidade_invalida,
SUM(CASE WHEN precoUnitario IS NULL THEN 1 ELSE 0 END) AS preco_nulo,
SUM(CASE WHEN precoUnitario <= 0 THEN 1 ELSE 0 END) AS preco_invalido,
SUM(CASE WHEN canonical_quantity IS NULL THEN 1 ELSE 0 END) AS quantidade_canonica_nula,
SUM(CASE WHEN canonical_quantity <= 0 THEN 1 ELSE 0 END) AS quantidade_canonica_invalida,
SUM(CASE WHEN canonical_price IS NULL THEN 1 ELSE 0 END) AS preco_canonico_nulo,
SUM(CASE WHEN canonical_price <= 0 THEN 1 ELSE 0 END) AS preco_canonico_invalido,
SUM(CASE WHEN conversion_factor IS NULL THEN 1 ELSE 0 END) AS conversao_nula,
SUM(CASE WHEN conversion_factor <= 0 THEN 1 ELSE 0 END) AS conversao_invalida
FROM workspace.gep_public_procurement.silver_precos;

-- 4) Silver conversions per notebook formula | expected: current Silver total / 0 / 0
SELECT COUNT(*) AS total_registros,
SUM(CASE WHEN ABS(canonical_quantity - quantidade * effective_capacity * conversion_factor) > 0.0001 THEN 1 ELSE 0 END)
  AS erros_quantidade_convertida,
SUM(CASE WHEN ABS(canonical_price - precoUnitario / (effective_capacity * conversion_factor)) > 0.0001 THEN 1 ELSE 0 END)
  AS erros_preco_convertido
FROM workspace.gep_public_procurement.silver_precos;

-- 5) Gold: recompute weighted averages from Silver | expected: 292 / 0 / 0
WITH silver_agregada AS (
 SELECT codigoItemCatalogo, nomeUnidadeFornecimento,
   CAST(DATE_TRUNC('MONTH', dataResultado) AS DATE) AS mes,
   unidade_canonica,
   SUM(canonical_price * canonical_quantity) / SUM(canonical_quantity) AS media_recalculada
 FROM workspace.gep_public_procurement.silver_precos
 GROUP BY codigoItemCatalogo, nomeUnidadeFornecimento,
   CAST(DATE_TRUNC('MONTH', dataResultado) AS DATE), unidade_canonica
), comparacao AS (
 SELECT g.valor_medio, s.media_recalculada
 FROM workspace.gep_public_procurement.gold_precos_mensais g
 FULL OUTER JOIN silver_agregada s
 ON g.codigoItemCatalogo <=> s.codigoItemCatalogo
 AND g.nomeUnidadeFornecimento <=> s.nomeUnidadeFornecimento
 AND g.mes <=> s.mes
 AND g.unidade_canonica <=> s.unidade_canonica
)
SELECT COUNT(*) AS total_grupos_comparados,
SUM(CASE WHEN valor_medio IS NULL OR media_recalculada IS NULL THEN 1 ELSE 0 END)
 AS grupos_sem_correspondencia,
SUM(CASE WHEN valor_medio IS NOT NULL AND media_recalculada IS NOT NULL
 AND ABS(valor_medio - media_recalculada) > 0.0001 THEN 1 ELSE 0 END)
 AS medias_divergentes
FROM comparacao;

-- 6) Gold: duplicate keys | expected: 0
SELECT COUNT(*) AS grupos_duplicados FROM (
 SELECT codigoItemCatalogo, nomeUnidadeFornecimento, mes, COUNT(*) AS ocorrencias
 FROM workspace.gep_public_procurement.gold_precos_mensais
 GROUP BY codigoItemCatalogo, nomeUnidadeFornecimento, mes
 HAVING COUNT(*) > 1
) duplicados;

-- 7) Required evidence: at least 10 ACTUAL Gold rows | export CSV
SELECT codigoItemCatalogo, nomeUnidadeFornecimento, mes, unidade_canonica,
       valor_medio, qtd_transacoes, quantidade_canonica_total, qtd_fornecedores
FROM workspace.gep_public_procurement.gold_precos_mensais
ORDER BY codigoItemCatalogo, nomeUnidadeFornecimento, mes, unidade_canonica
LIMIT 10;

-- 8) Five conversion function tests | export CSV
SELECT * FROM workspace.gep_public_procurement.testes_conversao
ORDER BY caso;
