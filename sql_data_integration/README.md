# SQL-Based Enterprise Data Integration Solution

A small ETL pipeline that integrates data from several source systems into a
SQLite data warehouse. The business logic (cleansing, matching, validation,
loading, quality checks, reporting) is written in SQL; Python (`etl.py`) only
orchestrates the steps. Python 3.8+, no external packages.

## Architecture
```
 data/*.csv  ->  STAGING (raw text)  ->  transform.sql  ->  WAREHOUSE (star schema)
 CRM customers   stg_crm_customers       cleanse            dim_customer
 ERP customers   stg_erp_customers       match & merge      dim_product
 Product master  stg_products            validate           fact_sales
 ERP orders      stg_orders                                 rejected_records (error table)
                                         quality_checks.sql  -> PASS / FAIL per check
                                         reports.sql         -> business reports
                                                             etl_run_log (audit)
```

## Project layout
| Path | Purpose |
|---|---|
| `etl.py` | Orchestrator and CLI |
| `sql/schema.sql` | Staging, warehouse, reference and control tables |
| `sql/transform.sql` | Cleansing, customer matching, order validation, loading |
| `sql/quality_checks.sql` | Data quality checks (0 failures expected) |
| `sql/reports.sql` | Business reports |
| `data/*.csv` | Sample source files |
| `test_etl.py` | Unit tests |

## Run
```bash
python etl.py
python -m unittest test_etl.py -v
```
Creates `warehouse.db` and `rejected_records.csv`. The pipeline does a full
refresh, so running it repeatedly gives the same result.

## What the transform does
- **Customer integration:** CRM and ERP customers are matched on a cleaned
  e-mail address (trimmed, lower-cased). Duplicates inside one system are
  collapsed. `source_system` shows CRM, ERP or BOTH.
- **Standardisation:** country names such as `USA`, `United States` and `US`
  all map to `US` through the `country_map` reference table. Missing product
  categories become `Uncategorized`. SKUs are upper-cased.
- **Order validation:** an order is rejected, with a reason, if it is a
  duplicate, has an unknown customer or product, a non-positive quantity or
  price, or an invalid date. Rejects land in `rejected_records`.
- **Reconciliation:** staged orders must equal loaded plus rejected orders.

## Adding your own source
1. Add a staging table in `schema.sql` and an entry in `STAGING_FILES` in `etl.py`.
2. Write the cleansing and load SQL in `transform.sql`.
3. Add a check in `quality_checks.sql` and a report in `reports.sql`.

## Ideas to extend
- Swap SQLite for PostgreSQL, SQL Server or MySQL (the SQL is mostly standard)
- Incremental loads using a high-water mark instead of full refresh
- Slowly changing dimensions (history of customer changes)
- Scheduling with cron or Airflow
- More sources: REST APIs, JSON files or other databases
