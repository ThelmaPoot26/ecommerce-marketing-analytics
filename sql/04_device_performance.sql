-- ============================================================
-- 04_device_performance.sql
-- E-commerce Marketing Analytics
--
-- Objetivo:
-- Comparar volumen, conversión e ingresos por dispositivo.
--
-- Categorías analizadas:
-- desktop, mobile, tablet
-- ============================================================

WITH base_events AS (
  SELECT
    user_pseudo_id,
    event_name,
    device.category AS device_category,
    (
      SELECT value.int_value
      FROM UNNEST(event_params)
      WHERE key = 'ga_session_id'
    ) AS ga_session_id,
    ecommerce.transaction_id AS transaction_id,
    ecommerce.purchase_revenue AS purchase_revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

session_level AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    ANY_VALUE(device_category) AS device_category,
    MAX(IF(event_name = 'purchase', 1, 0)) AS had_purchase
  FROM base_events
  WHERE ga_session_id IS NOT NULL
  GROUP BY user_pseudo_id, ga_session_id
),

purchase_events AS (
  SELECT
    device_category,
    transaction_id,
    purchase_revenue
  FROM base_events
  WHERE event_name = 'purchase'
),

valid_transactions AS (
  SELECT
    transaction_id,
    ANY_VALUE(device_category) AS device_category,
    MAX(COALESCE(purchase_revenue, 0)) AS valid_order_revenue
  FROM purchase_events
  WHERE
    transaction_id IS NOT NULL
    AND TRIM(transaction_id) != ''
    AND LOWER(TRIM(transaction_id)) != '(not set)'
  GROUP BY transaction_id
),

session_summary AS (
  SELECT
    device_category,
    COUNT(DISTINCT user_pseudo_id) AS users,
    COUNT(*) AS sessions,
    COUNTIF(had_purchase = 1) AS purchase_sessions
  FROM session_level
  GROUP BY device_category
),

revenue_summary AS (
  SELECT
    device_category,
    ROUND(SUM(COALESCE(purchase_revenue, 0)), 2) AS total_revenue_usd
  FROM purchase_events
  GROUP BY device_category
),

valid_order_summary AS (
  SELECT
    device_category,
    COUNT(*) AS valid_orders,
    ROUND(SUM(valid_order_revenue), 2) AS valid_order_revenue_usd
  FROM valid_transactions
  GROUP BY device_category
)

SELECT
  s.device_category,
  s.users,
  s.sessions,
  s.purchase_sessions,
  COALESCE(v.valid_orders, 0) AS valid_orders,
  COALESCE(r.total_revenue_usd, 0) AS total_revenue_usd,
  COALESCE(v.valid_order_revenue_usd, 0) AS valid_order_revenue_usd,
  ROUND(SAFE_DIVIDE(s.purchase_sessions, s.sessions) * 100, 2) AS conversion_rate,
  ROUND(
    SAFE_DIVIDE(v.valid_order_revenue_usd, v.valid_orders),
    2
  ) AS average_order_value,
  ROUND(
    SAFE_DIVIDE(r.total_revenue_usd, s.sessions),
    2
  ) AS revenue_per_session
FROM session_summary s
LEFT JOIN revenue_summary r
  USING (device_category)
LEFT JOIN valid_order_summary v
  USING (device_category)
ORDER BY sessions DESC;
