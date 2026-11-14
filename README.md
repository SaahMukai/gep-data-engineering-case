# Public Procurement Data Engineering Technical Test

**Position:** Junior Data Engineer | Databricks  
**Reference run:** November 13, 2026  
**Candidate:** Sabrina Mukai Nishidate

## Overview

This project builds a small procurement-price pipeline on Databricks using the Bronze–Silver–Gold (Medallion) pattern. It ingests price records for 20 catalog codes from the Compras.gov.br API, checks and normalizes quantities and prices to canonical units, and publishes quantity-weighted monthly prices in a Delta Gold table.

As specified in the brief, ingestion requests **only page 1** with **up to 100 records per catalog code**. The results describe that extract, not all procurement transactions. The API is live and future runs may return different data; the figures below are linked to the **November 13, 2026** run.

## Architecture

```text
Compras.gov.br API  -- Python requests --> Bronze (raw JSON + metadata)
                                                |
Catalog CSV + unit conversion CSV --------------+--> Silver (quality, audit, canonical units)
                                                       |
                                                       v
                                                  Gold (monthly quantity-weighted price)
                                                       |
                                                       v
                                                Checks and evidence
```

The API request runs within the **`bronze` notebook**; Source/Ingestion is a logical architecture stage, not a fourth Lakeflow task. The solution uses Databricks Free Edition, Serverless compute, Unity Catalog and Delta tables. The Lakeflow Job has three ordered tasks: `bronze` → `silver` → `golden` (the last runs `gold_validacoes`). `exploracao_api` is exploratory and is not part of the Job.

## Repository layout

```text
README.md
.gitignore
data/
  public_procurement_catalog_items.csv
  public_procurement_unit_conversions.csv
notebooks/
  exploracao_api.ipynb
  bronze.ipynb
  silver.ipynb
  gold_validacoes.ipynb
sql/
  checks.sql
evidence/
  layer_counts.csv
  silver_step_audit.csv
  silver_quality.csv
  silver_conversions.csv
  gold_weighted_average.csv
  gold_duplicates.csv
  gold_10_rows.csv
  unit_conversion_tests.csv
  lakeflow_succeeded.png
  notebook_outputs/  # supporting outputs exported from notebooks
presentation/
  GEP_Case_Presentation.pptx
  GEP_Presentation_Script_10min.docx
```

## Setup and execution

1. In Databricks, select or create a Unity Catalog catalog with permission to create a schema, volume and Delta tables. The provided notebooks' main production references use **`workspace.gep_public_procurement`**; for a different catalog, update their `PREFIX`/catalog configuration consistently.
2. Import the four `.ipynb` notebooks from `notebooks/` into the workspace.
3. In the same catalog, prepare the schema `gep_public_procurement` and volume `arquivos` (the Bronze notebook also creates these if permissions allow). Upload the two CSV files from `data/` to `/Volumes/<catalog>/gep_public_procurement/arquivos/`, preserving the provided filenames.
4. Optionally run `exploracao_api` to inspect endpoint behavior (not required by the main orchestration).
5. For a **manual run**, execute `bronze`, then `silver`, then `gold_validacoes` in that order. The Bronze notebook loads reference CSVs, requests the live API and writes the Bronze and reference tables; subsequent notebooks read persisted Delta tables.
6. **Alternatively**, configure/run the Lakeflow Job with tasks `bronze` → `silver` → `golden` (pointing to `gold_validacoes`) and success dependencies. Do not needlessly run the manual sequence and the Job back-to-back.
7. To independently reproduce checks, run the numbered statements in `sql/checks.sql` in Databricks SQL Editor. The exact exported outputs of the reference execution are saved in `evidence/`.

**Note:** the notebooks write current snapshots with Delta `overwrite`, rather than maintaining incremental history. Rerunning against the live API can change the counts and results.

## Three-part Delta table names

All tables below are under `workspace.gep_public_procurement`:

| Table | Purpose |
|---|---|
| `ref_catalogo` | Catalog reference supplied with the brief |
| `ref_conversoes` | Unit-conversion reference supplied with the brief |
| `bronze_precos` | Original API JSON record and extraction metadata |
| `log_extracao` | HTTP request/status logs |
| `silver_precos` | Clean, validated and normalized records |
| `auditoria_silver` | Rows in/out/removed by Silver rule |
| `testes_conversao` | Five controlled unit-conversion test cases |
| `gold_precos_mensais` | Final monthly weighted metrics |
| `validacoes_pipeline` | Pipeline validation outcomes |

## Bronze and Silver rules

**Bronze:** `requests` performs a `GET` to `https://dadosabertos.compras.gov.br/modulo-pesquisa-preco/1_consultarMaterial` per catalog item, using `tipo=codigoItemCatalogo`, the code, `pagina=1`, and `tamanhoPagina=100`. It preserves each returned record as JSON plus requested code, run metadata, and extraction timestamp. HTTP failures are logged and the request loop continues, per brief.

**Silver:** the steps are executed in the required order. Row counts below are from the November 13 run, supported by `evidence/silver_step_audit.csv`.

| Step | Rule | Input | Output | Removed |
|---|---|---:|---:|---:|
| 1 | Match catalog by code and trimmed, uppercase supply-unit name | 2,000 | 1,461 | 539 |
| 2 | Parse types; keep valid dates, finite positive quantities and prices | 1,461 | 1,461 | 0 |
| 3 | Remove exact-JSON duplicates, excluding execution metadata | 1,461 | 1,461 | 0 |
| 4 | Match source unit and compatible canonical target | 1,461 | 1,439 | 22 |
| 5 | Convert to canonical quantity and price | 1,439 | 1,439 | 0 |

The catalog description is used for orientation only; it is not a substitute for catalog codes and API record fields. Source unit labels are trimmed and uppercased before the conversion join.

If `capacidadeUnidadeFornecimento` is positive, use it as `effective_capacity`; otherwise use 1, per the brief. `conversion_factor` converts source units to the catalog's canonical unit:

```text
canonical_quantity = quantidade * effective_capacity * conversion_factor
canonical_price    = precoUnitario / (effective_capacity * conversion_factor)
```

Thus the transaction's financial value is preserved within floating-point tolerance. For example, 10 packages of 500 g at R$ 10/package represent 5 kg at R$ 20/kg, still R$ 100 total. This example is illustrative, not an actual API row.

## Gold metric and grain

The Gold table stores `codigoItemCatalogo`, `nomeUnidadeFornecimento`, `mes` (calendar month, first day), `unidade_canonica`, `valor_medio`, `qtd_transacoes`, `quantidade_canonica_total`, and `qtd_fornecedores`. The aggregation uses catalog item, supply-unit name, month and canonical unit; a separate check ensures **exactly one row per (`codigoItemCatalogo`, `nomeUnidadeFornecimento`, `mes`)**, as required in the brief.

```text
valor_medio = SUM(canonical_quantity * canonical_price) / SUM(canonical_quantity)
qtd_transacoes = COUNT(*)
quantidade_canonica_total = SUM(canonical_quantity)
qtd_fornecedores = COUNT(DISTINCT niFornecedor)
```

Stored Gold values are not deliberately rounded.

## Results — November 13, 2026

| Layer | Rows |
|---|---:|
| Bronze | **2,000** |
| Silver | **1,439** |
| Gold | **292** |

Silver excludes **561 records**: 539 from catalog matching and 22 from incompatible unit conversion. Gold has fewer rows because it aggregates Silver transactions; this is **not** another removal step. The demonstrated Lakeflow Job completed with status **Succeeded** in approximately **3 minutes 20 seconds** (`evidence/lakeflow_succeeded.png`). The extraction is a time-specific snapshot of the live API.

## Checks and actual outputs

The SQL used for the eight exported results is in [`sql/checks.sql`](sql/checks.sql). The files below are **actual exported outputs**, not expected-value examples:

| SQL check | Evidence file | Observed result |
|---|---|---|
| 1. Layer counts | [`layer_counts.csv`](evidence/layer_counts.csv) | 2,000 / 1,439 / 292 |
| 2. Silver step audit | [`silver_step_audit.csv`](evidence/silver_step_audit.csv) | 539 and 22 removals; 561 total |
| 3. Silver required-field quality | [`silver_quality.csv`](evidence/silver_quality.csv) | 1,439 records; 0 occurrences in 12 checks |
| 4. Canonical conversion math | [`silver_conversions.csv`](evidence/silver_conversions.csv) | 1,439 records; 0 quantity and 0 price mismatches |
| 5. Weighted Gold average vs Silver | [`gold_weighted_average.csv`](evidence/gold_weighted_average.csv) | 292 groups, 0 unmatched, 0 mismatched |
| 6. Gold required-key duplicates | [`gold_duplicates.csv`](evidence/gold_duplicates.csv) | 0 duplicated groups |
| 7. Gold sample | [`gold_10_rows.csv`](evidence/gold_10_rows.csv) | 10 actual Gold rows |
| 8. Conversion unit tests | [`unit_conversion_tests.csv`](evidence/unit_conversion_tests.csv) | 5/5 `OK` |

Notebook-level validation additionally checks Silver codes against the catalog, non-finite Gold values, and reconciliation of transaction counts between Silver and Gold. Their saved outputs are included in the notebooks and supporting CSV files in `evidence/notebook_outputs/`.

The numerical comparison queries use an absolute tolerance of **0.0001**. A tolerance check is not the same as proof of exact decimal identity. These checks establish the stated invariants; they do not constitute an exhaustive audit of every business-rule edge case.

## Assumptions and limitations

- The brief deliberately limits ingestion to page 1 (up to 100 records per each of 20 catalog items); other pages are out of scope.
- A live API snapshot is time-dependent; results can differ on a future run.
- Silver deduplication currently identifies exact JSON duplicates; semantic duplicates may need a defined business key.
- The current tables represent snapshots written with `overwrite`; production would use an agreed incremental-load strategy, idempotency and retention policy.
- The audit reports counts per step; individual rejected records and reasons could be persisted for deeper investigation.
- Some validations currently run after the Gold write; validating before publication would be safer in production.
- For production monetary calculations, evaluate `DECIMAL` precision and rounding policy; add retry/backoff, observability and alerts.

## AI tool usage

I used ChatGPT as a supporting tool during the development of this case study, primarily for code review, documentation, and exploring potential improvements.

The implementation, technical decisions, and validation of the results were carried out by me, using the Databricks environment.

During quality checks, I identified an inconsistency in an SQL query related to the "effective_capacity" field. After reviewing the calculation logic and adjusting the query, I re-ran the validations, confirming that there were no discrepancies across the 1,439 records in the Silver layer.

All results and evidence presented in the repository correspond to actual executions within Databricks.
