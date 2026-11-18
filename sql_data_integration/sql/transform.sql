-- transform.sql : cleanse, integrate and load the warehouse (full refresh each run)

-- ---------------------------------------------------------------------
-- 0. Clear the warehouse tables so the run is repeatable
-- ---------------------------------------------------------------------
DELETE FROM fact_sales;
DELETE FROM rejected_records;
DELETE FROM dim_customer;
DELETE FROM dim_product;
DELETE FROM sqlite_sequence WHERE name IN ('dim_customer', 'dim_product', 'rejected_records');

DROP VIEW IF EXISTS temp.v_crm;
DROP VIEW IF EXISTS temp.v_erp;
DROP VIEW IF EXISTS temp.v_orders_checked;

-- ---------------------------------------------------------------------
-- 1. Cleansed customer views (one row per e-mail, per source system)
--    - e-mails are trimmed and lower-cased
--    - countries are mapped to ISO codes
--    - duplicates inside a source system are collapsed
-- ---------------------------------------------------------------------
CREATE TEMP VIEW v_crm AS
SELECT lower(trim(s.email))                                   AS email,
       MIN(s.customer_id)                                     AS crm_id,
       MIN(trim(s.full_name))                                 AS full_name,
       MIN(COALESCE(m.iso_code, upper(trim(s.country))))      AS country,
       MIN(date(trim(s.signup_date)))                         AS signup_date
FROM stg_crm_customers s
LEFT JOIN country_map m ON m.raw_name = upper(trim(s.country))
WHERE s.email IS NOT NULL AND trim(s.email) <> ''
GROUP BY lower(trim(s.email));

CREATE TEMP VIEW v_erp AS
SELECT lower(trim(s.email))                                   AS email,
       MIN(s.erp_id)                                          AS erp_id,
       MIN(trim(s.name))                                      AS full_name,
       MIN(COALESCE(m.iso_code, upper(trim(s.country))))      AS country,
       MAX(CAST(s.credit_limit AS REAL))                      AS credit_limit
FROM stg_erp_customers s
LEFT JOIN country_map m ON m.raw_name = upper(trim(s.country))
WHERE s.email IS NOT NULL AND trim(s.email) <> ''
GROUP BY lower(trim(s.email));

-- ---------------------------------------------------------------------
-- 2. dim_customer: merge CRM and ERP on e-mail (CRM wins for name/country)
-- ---------------------------------------------------------------------
INSERT INTO dim_customer
    (email, full_name, country, crm_customer_id, erp_id, signup_date, credit_limit, source_system)
SELECT k.email,
       COALESCE(c.full_name, e.full_name),
       COALESCE(c.country, e.country),
       c.crm_id,
       e.erp_id,
       c.signup_date,
       e.credit_limit,
       CASE WHEN c.email IS NOT NULL AND e.email IS NOT NULL THEN 'BOTH'
            WHEN c.email IS NOT NULL THEN 'CRM'
            ELSE 'ERP' END
FROM (SELECT email FROM v_crm UNION SELECT email FROM v_erp) k
LEFT JOIN v_crm c ON c.email = k.email
LEFT JOIN v_erp e ON e.email = k.email
ORDER BY k.email;

-- ---------------------------------------------------------------------
-- 3. dim_product
-- ---------------------------------------------------------------------
INSERT INTO dim_product (sku, product_name, category, unit_cost)
SELECT upper(trim(sku)),
       MIN(trim(product_name)),
       MIN(COALESCE(NULLIF(trim(category), ''), 'Uncategorized')),
       MIN(CAST(unit_cost AS REAL))
FROM stg_products
WHERE sku IS NOT NULL AND trim(sku) <> ''
GROUP BY upper(trim(sku))
ORDER BY upper(trim(sku));

-- ---------------------------------------------------------------------
-- 4. Validate orders. reject_reason is NULL for a good order; the first
--    rule that fails wins.
-- ---------------------------------------------------------------------
CREATE TEMP VIEW v_orders_checked AS
SELECT x.order_id, x.erp_id, x.sku, x.quantity, x.unit_price, x.order_date, x.status,
       c.customer_key, p.product_key,
       CASE
           WHEN x.rn > 1                                 THEN 'Duplicate order'
           WHEN c.customer_key IS NULL                   THEN 'Unknown customer'
           WHEN p.product_key IS NULL                    THEN 'Unknown product'
           WHEN CAST(x.quantity AS REAL) <= 0            THEN 'Invalid quantity'
           WHEN CAST(x.unit_price AS REAL) <= 0          THEN 'Invalid unit price'
           WHEN date(trim(x.order_date)) IS NULL         THEN 'Invalid order date'
       END AS reject_reason
FROM (
    SELECT o.*, ROW_NUMBER() OVER (PARTITION BY o.order_id ORDER BY o.rowid) AS rn
    FROM stg_orders o
) x
LEFT JOIN dim_customer c ON c.erp_id = trim(x.erp_id)
LEFT JOIN dim_product  p ON p.sku    = upper(trim(x.sku));

-- ---------------------------------------------------------------------
-- 5. Rejected orders go to the error table, good ones to the fact table
-- ---------------------------------------------------------------------
INSERT INTO rejected_records (source_table, record_key, reason, raw_data)
SELECT 'stg_orders', order_id, reject_reason,
       COALESCE(order_id, '') || '|' || COALESCE(erp_id, '') || '|' || COALESCE(sku, '') || '|' ||
       COALESCE(quantity, '') || '|' || COALESCE(unit_price, '') || '|' || COALESCE(order_date, '')
FROM v_orders_checked
WHERE reject_reason IS NOT NULL;

INSERT INTO fact_sales
    (order_id, customer_key, product_key, order_date, quantity, unit_price, revenue, cost, status)
SELECT v.order_id,
       v.customer_key,
       v.product_key,
       date(trim(v.order_date)),
       CAST(v.quantity AS INTEGER),
       CAST(v.unit_price AS REAL),
       ROUND(CAST(v.quantity AS INTEGER) * CAST(v.unit_price AS REAL), 2),
       ROUND(CAST(v.quantity AS INTEGER) * p.unit_cost, 2),
       upper(trim(v.status))
FROM v_orders_checked v
JOIN dim_product p ON p.product_key = v.product_key
WHERE v.reject_reason IS NULL;
