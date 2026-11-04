-- ============================================================
-- 07_weekly_performance.sql
-- E-commerce Marketing Analytics
--
-- Objetivo:
-- Analizar la evolución semanal del negocio con mayor detalle.
--
-- La semana se considera de lunes a domingo.
-- ============================================================

WITH base_events AS (
  SELECT
    PARSE_DATE('%Y%m%d', event_date) AS event_date,
    user_pseudo_id,
    event_name,
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
    DATE_TRUNC(event_date, WEEK(MONDAY)) AS week_start,
    user_pseudo_id,
    ga_session_id,
    MAX(IF(event_name = 'purchase', 1, 0)) AS had_purchase
  FROM base_events
  WHERE ga_session_id IS NOT NULL
  GROUP BY week_start, user_pseudo_id, ga_session_id
),

purchase_events AS (
  SELECT
    DATE_TRUNC(event_date, WEEK(MONDAY)) AS week_start,
    transaction_id,
    purchase_revenue
  FROM base_events
  WHERE event_name = 'purchase'
),

valid_transactions AS (
  SELECT
    transaction_id,
    ANY_VALUE(week_start) AS week_start,
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
    week_start,
    COUNT(DISTINCT user_pseudo_id) AS users,
    COUNT(*) AS sessions,
    COUNTIF(had_purchase = 1) AS purchase_sessions
  FROM session_level
  GROUP BY week_start
),

revenue_summary AS (
  SELECT
    week_start,
    ROUND(SUM(COALESCE(purchase_revenue, 0)), 2) AS total_revenue_usd
  FROM purchase_events
  GROUP BY week_start
),

valid_order_summary AS (
  SELECT
    week_start,
    COUNT(*) AS valid_orders,
    ROUND(SUM(valid_order_revenue), 2) AS valid_order_revenue_usd
  FROM valid_transactions
  GROUP BY week_start
)

SELECT
  s.week_start,
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
  USING (week_start)
LEFT JOIN valid_order_summary v
  USING (week_start)
ORDER BY week_start;
