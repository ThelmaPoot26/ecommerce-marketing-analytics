-- ============================================================
-- 03_acquisition_performance.sql
-- E-commerce Marketing Analytics
--
-- Objetivo:
-- Evaluar usuarios, sesiones, compras e ingresos según la
-- adquisición inicial del usuario (source / medium).
--
-- Se utiliza traffic_source.source y traffic_source.medium
-- para mantener una sola fuente inicial por usuario.
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
    traffic_source.source AS source,
    traffic_source.medium AS medium,
    ecommerce.transaction_id AS transaction_id,
    ecommerce.purchase_revenue AS purchase_revenue
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

user_acquisition AS (
  SELECT
    user_pseudo_id,
    ANY_VALUE(source) AS source,
    ANY_VALUE(medium) AS medium
  FROM base_events
  GROUP BY user_pseudo_id
),

session_level AS (
  SELECT
    b.user_pseudo_id,
    b.ga_session_id,
    MAX(IF(b.event_name = 'purchase', 1, 0)) AS had_purchase
  FROM base_events b
  WHERE b.ga_session_id IS NOT NULL
  GROUP BY b.user_pseudo_id, b.ga_session_id
),

purchase_events AS (
  SELECT
    b.user_pseudo_id,
    b.transaction_id,
    b.purchase_revenue
  FROM base_events b
  WHERE b.event_name = 'purchase'
),

valid_transactions AS (
  SELECT
    user_pseudo_id,
    transaction_id,
    MAX(COALESCE(purchase_revenue, 0)) AS valid_order_revenue
  FROM purchase_events
  WHERE
    transaction_id IS NOT NULL
    AND TRIM(transaction_id) != ''
    AND LOWER(TRIM(transaction_id)) != '(not set)'
  GROUP BY user_pseudo_id, transaction_id
),

user_summary AS (
  SELECT
    u.user_pseudo_id,
    u.source,
    u.medium,

    CASE
      WHEN u.source = 'google' AND u.medium = 'organic'
        THEN 'Búsqueda orgánica'
      WHEN u.source = '(direct)' AND u.medium = '(none)'
        THEN 'Directo'
      WHEN u.source = 'google' AND u.medium = 'cpc'
        THEN 'Búsqueda pagada'
      WHEN u.source LIKE 'shop.googlemerchandisestore%' AND u.medium = 'referral'
        THEN 'Referral interno'
      WHEN u.medium = 'referral'
        THEN 'Referral'
      ELSE 'Otros / No identificado'
    END AS channel_group,

    COUNT(DISTINCT STRUCT(s.user_pseudo_id, s.ga_session_id)) AS sessions,
    COUNTIF(s.had_purchase = 1) AS purchase_sessions

  FROM user_acquisition u
  LEFT JOIN session_level s
    USING (user_pseudo_id)

  GROUP BY
    u.user_pseudo_id,
    u.source,
    u.medium,
    channel_group
),

acquisition_sessions AS (
  SELECT
    channel_group,
    source,
    medium,
    COUNT(DISTINCT user_pseudo_id) AS users,
    SUM(sessions) AS sessions,
    SUM(purchase_sessions) AS purchase_sessions
  FROM user_summary
  GROUP BY channel_group, source, medium
),

acquisition_revenue AS (
  SELECT
    CASE
      WHEN u.source = 'google' AND u.medium = 'organic'
        THEN 'Búsqueda orgánica'
      WHEN u.source = '(direct)' AND u.medium = '(none)'
        THEN 'Directo'
      WHEN u.source = 'google' AND u.medium = 'cpc'
        THEN 'Búsqueda pagada'
      WHEN u.source LIKE 'shop.googlemerchandisestore%' AND u.medium = 'referral'
        THEN 'Referral interno'
      WHEN u.medium = 'referral'
        THEN 'Referral'
      ELSE 'Otros / No identificado'
    END AS channel_group,
    u.source,
    u.medium,
    ROUND(SUM(COALESCE(p.purchase_revenue, 0)), 2) AS total_revenue_usd
  FROM purchase_events p
  JOIN user_acquisition u
    USING (user_pseudo_id)
  GROUP BY channel_group, u.source, u.medium
),

valid_order_summary AS (
  SELECT
    CASE
      WHEN u.source = 'google' AND u.medium = 'organic'
        THEN 'Búsqueda orgánica'
      WHEN u.source = '(direct)' AND u.medium = '(none)'
        THEN 'Directo'
      WHEN u.source = 'google' AND u.medium = 'cpc'
        THEN 'Búsqueda pagada'
      WHEN u.source LIKE 'shop.googlemerchandisestore%' AND u.medium = 'referral'
        THEN 'Referral interno'
      WHEN u.medium = 'referral'
        THEN 'Referral'
      ELSE 'Otros / No identificado'
    END AS channel_group,
    u.source,
    u.medium,
    COUNT(*) AS valid_orders,
    ROUND(SUM(v.valid_order_revenue), 2) AS valid_order_revenue_usd
  FROM valid_transactions v
  JOIN user_acquisition u
    USING (user_pseudo_id)
  GROUP BY channel_group, u.source, u.medium
)

SELECT
  s.channel_group,
  s.source,
  s.medium,
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
    SAFE_DIVIDE(r.total_revenue_usd, s.users),
    2
  ) AS revenue_per_user
FROM acquisition_sessions s
LEFT JOIN acquisition_revenue r
  USING (channel_group, source, medium)
LEFT JOIN valid_order_summary v
  USING (channel_group, source, medium)
ORDER BY total_revenue_usd DESC;
