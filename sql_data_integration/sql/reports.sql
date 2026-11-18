-- reports.sql : business reports run against the warehouse.
-- Each query starts with a "-- name:" line; the runner prints them in order.

-- name: revenue_by_country
SELECT c.country,
       COUNT(*)                          AS orders,
       ROUND(SUM(f.revenue), 2)          AS revenue,
       ROUND(SUM(f.revenue - f.cost), 2) AS margin
FROM fact_sales f
JOIN dim_customer c USING (customer_key)
WHERE f.status <> 'CANCELLED'
GROUP BY c.country
ORDER BY revenue DESC;

-- name: top_products
SELECT p.product_name,
       p.category,
       SUM(f.quantity)                   AS units,
       ROUND(SUM(f.revenue), 2)          AS revenue,
       ROUND(SUM(f.revenue - f.cost), 2) AS margin
FROM fact_sales f
JOIN dim_product p USING (product_key)
WHERE f.status <> 'CANCELLED'
GROUP BY p.product_key
ORDER BY revenue DESC;

-- name: monthly_revenue
SELECT strftime('%Y-%m', order_date) AS month,
       COUNT(*)                      AS orders,
       ROUND(SUM(revenue), 2)        AS revenue
FROM fact_sales
WHERE status <> 'CANCELLED'
GROUP BY month
ORDER BY month;

-- name: customer_sources
SELECT source_system, COUNT(*) AS customers
FROM dim_customer
GROUP BY source_system
ORDER BY customers DESC;

-- name: rejected_orders
SELECT record_key AS order_id, reason
FROM rejected_records
ORDER BY id;
