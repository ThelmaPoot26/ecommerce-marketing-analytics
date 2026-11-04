-- ============================================================
-- 05_product_performance.sql
-- E-commerce Marketing Analytics
--
-- Objetivo:
-- Analizar el rendimiento de productos a lo largo del funnel.
--
-- Decisiones metodológicas:
-- - Se normaliza item_name y se utiliza como llave principal,
--   debido a inconsistencias detectadas en item_id.
-- - La tabla final parte de productos presentes en view_item.
-- - Las órdenes válidas excluyen transaction_id nulos, vacíos
--   y "(not set)".
-- - La segmentación utiliza cuartiles para evitar umbrales
--   arbitrarios.
-- ============================================================

WITH item_events AS (
  SELECT
    e.user_pseudo_id,
    e.event_name,
    (
      SELECT value.int_value
      FROM UNNEST(e.event_params)
      WHERE key = 'ga_session_id'
    ) AS ga_session_id,
    e.ecommerce.transaction_id AS transaction_id,
    LOWER(
      TRIM(
        REGEXP_REPLACE(i.item_name, r'\s+', ' ')
      )
    ) AS product_name,
    i.item_name AS item_name,
    COALESCE(i.quantity, 0) AS quantity,
    COALESCE(i.item_revenue, i.price * i.quantity, 0) AS item_revenue
  FROM
    `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` e,
    UNNEST(e.items) AS i
  WHERE
    _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
    AND e.event_name IN ('view_item', 'add_to_cart', 'begin_checkout', 'purchase')
    AND i.item_name IS NOT NULL
),

valid_transaction_ids AS (
  SELECT DISTINCT transaction_id
  FROM item_events
  WHERE
    event_name = 'purchase'
    AND transaction_id IS NOT NULL
    AND TRIM(transaction_id) != ''
    AND LOWER(TRIM(transaction_id)) != '(not set)'
),

product_names AS (
  SELECT
    product_name,
    ANY_VALUE(item_name) AS item_name
  FROM item_events
  WHERE event_name = 'view_item'
  GROUP BY product_name
),

view_metrics AS (
  SELECT
    product_name,
    COUNT(DISTINCT STRUCT(user_pseudo_id, ga_session_id)) AS view_sessions
  FROM item_events
  WHERE event_name = 'view_item'
    AND ga_session_id IS NOT NULL
  GROUP BY product_name
),

cart_metrics AS (
  SELECT
    product_name,
    COUNT(DISTINCT STRUCT(user_pseudo_id, ga_session_id)) AS cart_sessions
  FROM item_events
  WHERE event_name = 'add_to_cart'
    AND ga_session_id IS NOT NULL
  GROUP BY product_name
),

checkout_metrics AS (
  SELECT
    product_name,
    COUNT(DISTINCT STRUCT(user_pseudo_id, ga_session_id)) AS checkout_sessions
  FROM item_events
  WHERE event_name = 'begin_checkout'
    AND ga_session_id IS NOT NULL
  GROUP BY product_name
),

purchase_session_metrics AS (
  SELECT
    product_name,
    COUNT(DISTINCT STRUCT(user_pseudo_id, ga_session_id)) AS purchase_sessions
  FROM item_events
  WHERE event_name = 'purchase'
    AND ga_session_id IS NOT NULL
  GROUP BY product_name
),

valid_purchase_metrics AS (
  SELECT
    e.product_name,
    COUNT(DISTINCT e.transaction_id) AS valid_orders,
    SUM(e.quantity) AS units_sold,
    ROUND(SUM(e.item_revenue), 2) AS product_revenue_usd
  FROM item_events e
  JOIN valid_transaction_ids v
    USING (transaction_id)
  WHERE e.event_name = 'purchase'
  GROUP BY e.product_name
),

product_metrics AS (
  SELECT
    n.product_name,
    n.item_name,
    v.view_sessions,
    COALESCE(c.cart_sessions, 0) AS cart_sessions,
    COALESCE(ch.checkout_sessions, 0) AS checkout_sessions,
    COALESCE(p.purchase_sessions, 0) AS purchase_sessions,
    COALESCE(vp.valid_orders, 0) AS valid_orders,
    COALESCE(vp.units_sold, 0) AS units_sold,
    COALESCE(vp.product_revenue_usd, 0) AS product_revenue_usd,

    ROUND(
      SAFE_DIVIDE(COALESCE(c.cart_sessions, 0), v.view_sessions) * 100,
      2
    ) AS view_to_cart_rate,

    ROUND(
      SAFE_DIVIDE(COALESCE(ch.checkout_sessions, 0), COALESCE(c.cart_sessions, 0)) * 100,
      2
    ) AS cart_to_checkout_rate,

    ROUND(
      SAFE_DIVIDE(COALESCE(p.purchase_sessions, 0), COALESCE(ch.checkout_sessions, 0)) * 100,
      2
    ) AS checkout_to_purchase_rate

  FROM product_names n
  JOIN view_metrics v
    USING (product_name)
  LEFT JOIN cart_metrics c
    USING (product_name)
  LEFT JOIN checkout_metrics ch
    USING (product_name)
  LEFT JOIN purchase_session_metrics p
    USING (product_name)
  LEFT JOIN valid_purchase_metrics vp
    USING (product_name)
),

quartiles AS (
  SELECT
    *,
    NTILE(4) OVER (ORDER BY view_sessions) AS views_quartile,
    NTILE(4) OVER (ORDER BY valid_orders) AS orders_quartile,
    NTILE(4) OVER (ORDER BY product_revenue_usd) AS revenue_quartile,
    NTILE(4) OVER (ORDER BY view_to_cart_rate) AS view_to_cart_quartile,
    NTILE(4) OVER (ORDER BY checkout_to_purchase_rate) AS checkout_to_purchase_quartile
  FROM product_metrics
)

SELECT
  product_name,
  item_name,
  view_sessions,
  cart_sessions,
  checkout_sessions,
  purchase_sessions,
  valid_orders,
  units_sold,
  product_revenue_usd,
  view_to_cart_rate,
  cart_to_checkout_rate,
  checkout_to_purchase_rate,

  CASE
    WHEN revenue_quartile = 4
      AND orders_quartile = 4
      THEN 'Producto estrella'

    WHEN views_quartile = 4
      AND view_to_cart_quartile = 1
      THEN 'Oportunidad de conversión'

    WHEN revenue_quartile = 4
      THEN 'Alto valor'

    WHEN view_to_cart_quartile = 4
      AND checkout_to_purchase_quartile = 4
      THEN 'Alta eficiencia'

    ELSE 'Desempeño estándar'
  END AS product_segment

FROM quartiles
ORDER BY product_revenue_usd DESC;
