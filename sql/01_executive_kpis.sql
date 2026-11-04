-- ============================================================
-- 01_executive_kpis.sql
-- E-commerce Marketing Analytics
--
-- Objetivo:
-- Calcular los KPIs ejecutivos del periodo analizado.
--
-- Fuente:
-- bigquery-public-data.ga4_obfuscated_sample_ecommerce
--
-- Periodo:
-- 2020-11-01 a 2021-01-31
--
-- Definiciones:
-- - Sesión: combinación única de user_pseudo_id + ga_session_id
-- - Sesión con compra: sesión con al menos un evento purchase
-- - Orden válida: transaction_id no nulo, distinto de "(not set)"
--   y deduplicado por transaction_id
-- ============================================================

WITH base_events AS (
  SELECT
    user_pseudo_id,
    event_name,
    (
      SELECT value.int_value
      FROM UNNEST(event_params)
      WHERE key = 'ga_session_id'
    ) AS ga_session_id,
    ecommerce.transaction_id AS transaction_id,
    ecommerce.purchase_revenue AS purchase_revenue
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

session_level AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    MAX(IF(event_name = 'purchase', 1, 0)) AS had_purchase
  FROM base_events
  WHERE ga_session_id IS NOT NULL
  GROUP BY
    user_pseudo_id,
    ga_session_id
),

purchase_events AS (
  SELECT
    transaction_id,
    purchase_revenue
  FROM base_events
  WHERE event_name = 'purchase'
),

valid_transactions AS (
  SELECT
    transaction_id,
    MAX(COALESCE(purchase_revenue, 0)) AS valid_order_revenue
  FROM purchase_events
  WHERE
    transaction_id IS NOT NULL
    AND TRIM(transaction_id) != ''
    AND LOWER(TRIM(transaction_id)) != '(not set)'
  GROUP BY transaction_id
)

SELECT
  (SELECT COUNT(DISTINCT user_pseudo_id) FROM base_events) AS users,

  (SELECT COUNT(*) FROM session_level) AS sessions,

  (SELECT COUNTIF(had_purchase = 1) FROM session_level) AS purchase_sessions,

  (SELECT COUNT(*) FROM valid_transactions) AS valid_orders,

  ROUND(
    (SELECT SUM(COALESCE(purchase_revenue, 0)) FROM purchase_events),
    2
  ) AS total_revenue_usd,

  ROUND(
    (SELECT SUM(valid_order_revenue) FROM valid_transactions),
    2
  ) AS valid_order_revenue_usd,

  ROUND(
    SAFE_DIVIDE(
      (SELECT COUNTIF(had_purchase = 1) FROM session_level),
      (SELECT COUNT(*) FROM session_level)
    ) * 100,
    2
  ) AS conversion_rate,

  ROUND(
    SAFE_DIVIDE(
      (SELECT SUM(valid_order_revenue) FROM valid_transactions),
      (SELECT COUNT(*) FROM valid_transactions)
    ),
    2
  ) AS average_order_value;
