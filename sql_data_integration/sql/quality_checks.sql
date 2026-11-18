-- quality_checks.sql : every row is one check; failures must be 0 for the check to pass

SELECT 'dim_customer: duplicate e-mails' AS check_name, COUNT(*) AS failures
FROM (SELECT email FROM dim_customer GROUP BY email HAVING COUNT(*) > 1)

UNION ALL
SELECT 'dim_customer: malformed e-mail', COUNT(*)
FROM dim_customer WHERE email NOT LIKE '_%@_%._%'

UNION ALL
SELECT 'dim_customer: missing country', COUNT(*)
FROM dim_customer WHERE country IS NULL OR country = ''

UNION ALL
SELECT 'dim_product: duplicate SKUs', COUNT(*)
FROM (SELECT sku FROM dim_product GROUP BY sku HAVING COUNT(*) > 1)

UNION ALL
SELECT 'fact_sales: orphan customer keys', COUNT(*)
FROM fact_sales f LEFT JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_key IS NULL

UNION ALL
SELECT 'fact_sales: orphan product keys', COUNT(*)
FROM fact_sales f LEFT JOIN dim_product p ON p.product_key = f.product_key
WHERE p.product_key IS NULL

UNION ALL
SELECT 'fact_sales: non-positive quantity or price', COUNT(*)
FROM fact_sales WHERE quantity <= 0 OR unit_price <= 0

UNION ALL
SELECT 'reconciliation: staged orders <> loaded + rejected',
       CASE WHEN (SELECT COUNT(*) FROM stg_orders) =
                 (SELECT COUNT(*) FROM fact_sales) +
                 (SELECT COUNT(*) FROM rejected_records WHERE source_table = 'stg_orders')
            THEN 0 ELSE 1 END;
