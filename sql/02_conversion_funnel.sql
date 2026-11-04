-- ============================================================
-- 02_conversion_funnel.sql
-- E-commerce Marketing Analytics
--
-- Objetivo:
-- Construir el funnel secuencial (strict funnel) por sesión.
--
-- Secuencia requerida:
-- Session -> View Item -> Add to Cart -> Begin Checkout -> Purchase
--
-- Una etapa solo cuenta si ocurrió después de la etapa anterior
-- dentro de la misma sesión.
-- ============================================================

WITH base_events AS (
  SELECT
    user_pseudo_id,
    event_name,
    event_timestamp,
    (
      SELECT value.int_value
      FROM UNNEST(event_params)
      WHERE key = 'ga_session_id'
    ) AS ga_session_id
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),

session_events AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    MIN(IF(event_name = 'view_item', event_timestamp, NULL)) AS view_ts
  FROM base_events
  WHERE ga_session_id IS NOT NULL
  GROUP BY user_pseudo_id, ga_session_id
),

with_cart AS (
  SELECT
    s.*,
    MIN(
      IF(
        b.event_name = 'add_to_cart'
        AND b.event_timestamp > s.view_ts,
        b.event_timestamp,
        NULL
      )
    ) AS cart_ts
  FROM session_events s
  LEFT JOIN base_events b
    USING (user_pseudo_id, ga_session_id)
  GROUP BY user_pseudo_id, ga_session_id, view_ts
),

with_checkout AS (
  SELECT
    s.*,
    MIN(
      IF(
        b.event_name = 'begin_checkout'
        AND b.event_timestamp > s.cart_ts,
        b.event_timestamp,
        NULL
      )
    ) AS checkout_ts
  FROM with_cart s
  LEFT JOIN base_events b
    USING (user_pseudo_id, ga_session_id)
  GROUP BY user_pseudo_id, ga_session_id, view_ts, cart_ts
),

strict_funnel AS (
  SELECT
    s.*,
    MIN(
      IF(
        b.event_name = 'purchase'
        AND b.event_timestamp > s.checkout_ts,
        b.event_timestamp,
        NULL
      )
    ) AS purchase_ts
  FROM with_checkout s
  LEFT JOIN base_events b
    USING (user_pseudo_id, ga_session_id)
  GROUP BY
    user_pseudo_id,
    ga_session_id,
    view_ts,
    cart_ts,
    checkout_ts
),

stage_counts AS (
  SELECT 1 AS stage_order, 'Sessions' AS stage, COUNT(*) AS sessions_count
  FROM strict_funnel

  UNION ALL

  SELECT 2, 'View Item', COUNTIF(view_ts IS NOT NULL)
  FROM strict_funnel

  UNION ALL

  SELECT 3, 'Add to Cart', COUNTIF(cart_ts IS NOT NULL)
  FROM strict_funnel

  UNION ALL

  SELECT 4, 'Begin Checkout', COUNTIF(checkout_ts IS NOT NULL)
  FROM strict_funnel

  UNION ALL

  SELECT 5, 'Purchase', COUNTIF(purchase_ts IS NOT NULL)
  FROM strict_funnel
),

final AS (
  SELECT
    stage_order,
    stage,
    sessions_count,
    LAG(sessions_count) OVER (ORDER BY stage_order) AS previous_stage_count
  FROM stage_counts
)

SELECT
  stage_order,
  stage,
  sessions_count,
  ROUND(
    IF(
      stage_order = 1,
      100,
      SAFE_DIVIDE(sessions_count, previous_stage_count) * 100
    ),
    2
  ) AS conversion_from_previous_stage,
  ROUND(
    IF(
      stage_order = 1,
      0,
      (1 - SAFE_DIVIDE(sessions_count, previous_stage_count)) * 100
    ),
    2
  ) AS dropoff_rate
FROM final
ORDER BY stage_order;
