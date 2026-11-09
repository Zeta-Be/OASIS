-- =============================================================================
-- OASIS v2.0 — QA del dashboard: nombre corto de campaña y BU por CLIENTE
-- =============================================================================
-- Tres arreglos del QA del 09-11-2026:
--
--   1. v_materiales.campana_grupo: cuando la campaña no está en el glosario del
--      mercado, antes caía a la taxonomía completa (MLC_ML_FE-GS_ALL_MDD_X);
--      ahora cae al nombre corto, la quinta pieza de la taxonomía (MDD). Sin
--      taxonomía sigue cayendo al texto del Flow. Es la columna 22 de
--      v_inversion_diaria (campana_grupo): cambia el valor mostrado, no el
--      orden ni los nombres de las columnas.
--   2. La BU es UNA sola regla en todas partes: la columna CLIENTE del Flow
--      (MP si dice MP; cualquier otra cosa es ML). v_inversion_diaria ya lo
--      hacía (bu = cliente); fn_dashboard_filas usaba la segunda pieza de la
--      taxonomía y aquí se corrige.
--   3. Alerta nueva «campaña de otra BU»: compras cuya taxonomía dice una BU
--      distinta de la del CLIENTE (hoy, 6 compras de MLA con taxonomía MP en
--      el Flow de ML). La pantalla Alertas la muestra sola.
--
-- Las vistas se regeneran completas desde la definición viva. Repetible.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_materiales
WITH (security_invoker = true)
AS
 SELECT mt.id AS material_id,
    c.id AS compra_id,
    mk.codigo AS mercado,
    c.codigo AS compra_codigo,
    (c.codigo || '-'::text) || chr(64 + mt.secuencia) AS material_codigo,
    c.cliente,
    COALESCE(ca.nombre_unico, c.campana_taxonomia, c.campana_texto) AS campana,
    sc.nombre_unico AS sub_campana,
    p.nombre AS proveedor,
    c.medio,
    c.tipo_costo,
    c.tipo_compra,
    c.formato,
    c.ubicacion,
    c.ciudad,
    c.valor_total,
    mt.referencia,
    mt.enlace,
    mt.reporte_implementacion,
    mt.evidencia_url,
    mt.fecha_inicio,
    mt.fecha_fin,
        CASE
            WHEN mt.fecha_inicio IS NULL THEN 0
            ELSE mt.fecha_fin - mt.fecha_inicio + 1
        END AS dias,
    concat_ws('_'::text, mk.codigo, upper(regexp_replace(c.cliente, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), (upper(regexp_replace(p.nombre, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)) || '-'::text) || upper(regexp_replace(c.formato, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), upper(regexp_replace(c.ciudad, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), upper(COALESCE(ca.nombre_unico, c.campana_taxonomia, c.campana_texto)), 'X', upper(regexp_replace(split_part(c.ubicacion, '('::text, 1), '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), upper(COALESCE(sc.nombre_unico, ''::text)), upper(regexp_replace(COALESCE(mt.referencia, ''::text), '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), (c.codigo || '-'::text) || chr(64 + mt.secuencia)) AS taxonomia,
    c.mercado_id,
    mk.moneda,
        CASE
            WHEN COALESCE(ca.matt_campaign_type, split_part(c.campana_taxonomia, '_'::text, 3)) = 'OTH-PF'::text THEN 'PARQUE FIJO'::text
            ELSE COALESCE(ca.nombre_unico, NULLIF(split_part(c.campana_taxonomia, '_'::text, 5), ''::text), c.campana_texto)
        END AS campana_grupo
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados mk ON mk.id = c.mercado_id
     LEFT JOIN campanas ca ON ca.id = c.campana_id
     LEFT JOIN proveedores p ON p.id = c.proveedor_id
     LEFT JOIN campanas sc ON sc.id = mt.sub_campana_id;

CREATE OR REPLACE VIEW public.v_alertas
WITH (security_invoker = true)
AS
 SELECT 'material sin fechas'::text AS alerta,
    (c.codigo || '-'::text) || chr(64 + mt.secuencia) AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    mt.id AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados m ON m.id = c.mercado_id
  WHERE mt.fecha_inicio IS NULL
UNION ALL
 SELECT 'material sin sub campaña'::text AS alerta,
    (c.codigo || '-'::text) || chr(64 + mt.secuencia) AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    mt.id AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados m ON m.id = c.mercado_id
  WHERE mt.sub_campana_id IS NULL
UNION ALL
 SELECT 'material fuera del periodo de su compra'::text AS alerta,
    (c.codigo || '-'::text) || chr(64 + mt.secuencia) AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    mt.id AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados m ON m.id = c.mercado_id
  WHERE mt.fecha_inicio IS NOT NULL AND (mt.fecha_inicio < c.fecha_inicio OR mt.fecha_fin > c.fecha_fin)
UNION ALL
 SELECT 'compra sin materiales'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM materiales mt
          WHERE mt.compra_id = c.id))
UNION ALL
 SELECT 'sub campaña de otro mercado'::text AS alerta,
    (c.codigo || '-'::text) || chr(64 + mt.secuencia) AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    mt.id AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados m ON m.id = c.mercado_id
     JOIN campanas sc ON sc.id = mt.sub_campana_id
  WHERE sc.mercado_id <> c.mercado_id
UNION ALL
 SELECT 'campaña sin taxonomía'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    c.campana_texto AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
  WHERE c.campana_id IS NULL AND c.campana_taxonomia IS NULL
UNION ALL
 SELECT 'campaña fuera del glosario'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    c.campana_taxonomia AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
  WHERE c.campana_id IS NULL AND c.campana_taxonomia IS NOT NULL
UNION ALL
 SELECT 'compra sin tipo de costo'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
  WHERE c.tipo_costo IS NULL AND NOT COALESCE(c.fuera_de_catalogo, '{}'::jsonb) ? 'tipo_costo'::text
UNION ALL
 SELECT 'compra sin valor'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    NULL::text AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
  WHERE c.valor_total = 0::numeric AND c.tarifa_neta = 0::numeric AND c.tipo_compra IS DISTINCT FROM 'BONIFICADO'::text
UNION ALL
 SELECT 'compra incompleta'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    'sin '::text || array_to_string(ARRAY[
        CASE
            WHEN c.fecha_inicio IS NULL THEN 'fechas'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.proveedor_id IS NULL THEN 'proveedor'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.formato IS NULL THEN 'formato'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.ubicacion IS NULL THEN 'ubicación'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.ciudad IS NULL THEN 'ciudad'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.medio IS NULL AND NOT COALESCE(c.fuera_de_catalogo, '{}'::jsonb) ? 'medio'::text THEN 'medio'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.tipo_compra IS NULL AND NOT COALESCE(c.fuera_de_catalogo, '{}'::jsonb) ? 'tipo_compra'::text THEN 'tipo de compra'::text
            ELSE NULL::text
        END,
        CASE
            WHEN c.cliente IS NULL THEN 'cliente'::text
            ELSE NULL::text
        END], ', '::text) AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
  WHERE c.fecha_inicio IS NULL OR c.proveedor_id IS NULL OR c.formato IS NULL OR c.ubicacion IS NULL OR c.ciudad IS NULL OR c.cliente IS NULL OR c.medio IS NULL AND NOT COALESCE(c.fuera_de_catalogo, '{}'::jsonb) ? 'medio'::text OR c.tipo_compra IS NULL AND NOT COALESCE(c.fuera_de_catalogo, '{}'::jsonb) ? 'tipo_compra'::text
UNION ALL
 SELECT 'valor fuera de catálogo'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    f.detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
     CROSS JOIN LATERAL ( SELECT string_agg(((replace(e.k, '_'::text, ' '::text) || ' «'::text) || e.v) || '»'::text, ', '::text ORDER BY e.k) AS detalle
           FROM jsonb_each_text(c.fuera_de_catalogo) e(k, v)
          WHERE e.k = 'tipo_compra'::text AND c.tipo_compra IS NULL OR e.k = 'tipo_costo'::text AND c.tipo_costo IS NULL OR e.k = 'medio'::text AND c.medio IS NULL) f
  WHERE c.fuera_de_catalogo IS NOT NULL AND f.detalle IS NOT NULL
UNION ALL
 SELECT 'formatos parecidos'::text AS alerta,
    g.formatos AS referencia,
    m.codigo AS mercado,
    NULL::bigint AS compra_id,
    NULL::bigint AS material_id,
    g.mercado_id,
    g.detalle
   FROM ( SELECT f.mercado_id,
            fn_clave_formato(f.formato) AS clave,
            string_agg(f.formato, ' / '::text ORDER BY f.formato) AS formatos,
            string_agg((f.formato || ': '::text) || f.n, ' · '::text ORDER BY f.formato) AS detalle
           FROM ( SELECT compras.mercado_id,
                    compras.formato,
                    count(*) AS n
                   FROM compras
                  WHERE compras.formato IS NOT NULL
                  GROUP BY compras.mercado_id, compras.formato) f
          GROUP BY f.mercado_id, (fn_clave_formato(f.formato))
         HAVING count(*) > 1) g
     JOIN mercados m ON m.id = g.mercado_id
UNION ALL
 SELECT 'formatos parecidos'::text AS alerta,
    (a.formato || ' / '::text) || b.formato AS referencia,
    m.codigo AS mercado,
    NULL::bigint AS compra_id,
    NULL::bigint AS material_id,
    a.mercado_id,
    (((((a.formato || ': '::text) || a.n) || ' · '::text) || b.formato) || ': '::text) || b.n AS detalle
   FROM ( SELECT compras.mercado_id,
            compras.formato,
            count(*) AS n,
            fn_clave_formato(compras.formato) AS clave
           FROM compras
          WHERE compras.formato IS NOT NULL
          GROUP BY compras.mercado_id, compras.formato) a
     JOIN ( SELECT compras.mercado_id,
            compras.formato,
            count(*) AS n,
            fn_clave_formato(compras.formato) AS clave
           FROM compras
          WHERE compras.formato IS NOT NULL
          GROUP BY compras.mercado_id, compras.formato) b ON b.mercado_id = a.mercado_id AND a.formato < b.formato AND a.clave <> b.clave AND length(a.clave) >= 6 AND length(b.clave) >= 6 AND levenshtein(a.clave, b.clave) = 1
     JOIN mercados m ON m.id = a.mercado_id
UNION ALL
 SELECT 'proveedores por confirmar'::text AS alerta,
    ( SELECT string_agg(e.value ->> 'texto'::text, ' / '::text ORDER BY (e.value ->> 'texto'::text)) AS string_agg
           FROM jsonb_array_elements(d.valores) e(value)) AS referencia,
    m.codigo AS mercado,
    NULL::bigint AS compra_id,
    NULL::bigint AS material_id,
    d.mercado_id,
    d.razon AS detalle
   FROM duplicados_propuestos d
     JOIN mercados m ON m.id = d.mercado_id
  WHERE d.tipo = 'PROVEEDOR'::text AND d.estado = 'PENDIENTE'::text UNION ALL
 SELECT 'campaña de otra BU'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    (('CLIENTE dice '::text || COALESCE(NULLIF(upper(btrim(c.cliente)), ''::text), '(vacío)'::text)) || ' y la campaña es '::text) || tx.tax AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
     CROSS JOIN LATERAL (
        -- La taxonomía guardada o, si la carga aún no la resolvió, la que se
        -- lee del texto del Flow (misma regla de la carga).
        SELECT COALESCE(c.campana_taxonomia, fn_taxonomia_de_texto(m.codigo, c.campana_texto)) AS tax
     ) tx
  WHERE tx.tax IS NOT NULL
    AND split_part(tx.tax, '_'::text, 2) <>
        CASE WHEN upper(btrim(c.cliente)) = 'MP'::text THEN 'MP'::text ELSE 'ML'::text END;

-- La BU del dashboard sale de CLIENTE, no de la taxonomía (regla única).
CREATE OR REPLACE FUNCTION public.fn_dashboard_filas(p_mercados smallint[], p_anio int)
RETURNS TABLE (mercado_id smallint, compra_id bigint, mes int, semana int, proveedor text, tipo_costo text,
               formato text, campana text, sub_campana text, bu text, medio text, ciudad text,
               parque_fijo boolean, costo numeric)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT t.mercado_id, t.compra_id,
           extract(month FROM t.fecha)::int,
           extract(week FROM t.fecha)::int,                       -- ISO, como ISOWEEKNUM
           coalesce(nullif(btrim(v.proveedor), ''), '—'),
           coalesce(v.tipo_costo, '—'),
           coalesce(nullif(btrim(v.formato), ''), '—'),
           coalesce(nullif(btrim(v.campana), ''), '—'),
           coalesce(nullif(btrim(v.sub_campana), ''), '—'),
           coalesce(nullif(upper(btrim(v.cliente)), ''), '—'),
           coalesce(v.medio::text, '—'),
           coalesce(nullif(upper(btrim(v.ciudad)), ''), '—'),
           v.campana_grupo = 'PARQUE FIJO',
           t.costo_proyectado
    FROM (SELECT id, public.fn_dashboard_corte(id) AS corte FROM public.mercados WHERE id = ANY (p_mercados)) k
    JOIN public.inversion_diaria t ON t.mercado_id = k.id AND t.fecha <= k.corte
    JOIN public.v_materiales v ON v.material_id = t.material_id
    WHERE t.fecha >= make_date(p_anio, 1, 1)
      AND t.fecha <  make_date(p_anio + 1, 1, 1)
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_filas(smallint[], int) FROM PUBLIC, anon, authenticated;

COMMIT;
