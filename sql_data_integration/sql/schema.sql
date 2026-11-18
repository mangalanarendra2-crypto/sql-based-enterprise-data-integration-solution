-- schema.sql : staging layer, warehouse layer and control tables
-- Safe to run on every ETL run (everything is CREATE IF NOT EXISTS).

-- ---------------------------------------------------------------------
-- STAGING: raw copies of the source files, every column kept as text
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stg_crm_customers (
    customer_id TEXT, full_name TEXT, email TEXT, country TEXT, signup_date TEXT
);
CREATE TABLE IF NOT EXISTS stg_erp_customers (
    erp_id TEXT, name TEXT, email TEXT, country TEXT, credit_limit TEXT
);
CREATE TABLE IF NOT EXISTS stg_products (
    sku TEXT, product_name TEXT, category TEXT, unit_cost TEXT
);
CREATE TABLE IF NOT EXISTS stg_orders (
    order_id TEXT, erp_id TEXT, sku TEXT, quantity TEXT,
    unit_price TEXT, order_date TEXT, status TEXT
);

-- ---------------------------------------------------------------------
-- REFERENCE DATA: maps the many spellings of a country to one ISO code
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS country_map (
    raw_name TEXT PRIMARY KEY,   -- upper-cased spelling found in source systems
    iso_code TEXT NOT NULL
);
INSERT OR REPLACE INTO country_map (raw_name, iso_code) VALUES
    ('INDIA', 'IN'), ('IN', 'IN'),
    ('USA', 'US'), ('US', 'US'), ('UNITED STATES', 'US'),
    ('UK', 'GB'), ('GB', 'GB'), ('UNITED KINGDOM', 'GB'),
    ('SPAIN', 'ES'), ('ES', 'ES'),
    ('CHINA', 'CN'), ('CN', 'CN');

-- ---------------------------------------------------------------------
-- WAREHOUSE: star schema (two dimensions and one fact table)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_customer (
    customer_key    INTEGER PRIMARY KEY AUTOINCREMENT,
    email           TEXT NOT NULL UNIQUE,     -- the business key used to match CRM and ERP
    full_name       TEXT,
    country         TEXT,
    crm_customer_id TEXT,
    erp_id          TEXT,
    signup_date     TEXT,
    credit_limit    REAL,
    source_system   TEXT NOT NULL             -- CRM, ERP or BOTH
);

CREATE TABLE IF NOT EXISTS dim_product (
    product_key  INTEGER PRIMARY KEY AUTOINCREMENT,
    sku          TEXT NOT NULL UNIQUE,
    product_name TEXT,
    category     TEXT,
    unit_cost    REAL
);

CREATE TABLE IF NOT EXISTS fact_sales (
    order_id     TEXT PRIMARY KEY,
    customer_key INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    product_key  INTEGER NOT NULL REFERENCES dim_product (product_key),
    order_date   TEXT NOT NULL,
    quantity     INTEGER NOT NULL,
    unit_price   REAL NOT NULL,
    revenue      REAL NOT NULL,
    cost         REAL NOT NULL,
    status       TEXT
);
CREATE INDEX IF NOT EXISTS ix_fact_customer ON fact_sales (customer_key);
CREATE INDEX IF NOT EXISTS ix_fact_product  ON fact_sales (product_key);
CREATE INDEX IF NOT EXISTS ix_fact_date     ON fact_sales (order_date);

-- ---------------------------------------------------------------------
-- CONTROL TABLES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rejected_records (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    source_table TEXT NOT NULL,
    record_key   TEXT,
    reason       TEXT NOT NULL,
    raw_data     TEXT,
    rejected_at  TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS etl_run_log (
    run_id          INTEGER PRIMARY KEY AUTOINCREMENT,
    run_at          TEXT DEFAULT CURRENT_TIMESTAMP,
    staged_orders   INTEGER,
    loaded_orders   INTEGER,
    rejected_orders INTEGER,
    checks_failed   INTEGER,
    status          TEXT
);
