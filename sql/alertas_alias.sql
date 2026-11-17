-- =============================================================================
-- OASIS v2.0 — «Taxonomía por confirmar» como alerta
-- =============================================================================
-- Los alias provisionales (campanas_alias.por_confirmar) son un pendiente: alguien
-- tiene que confirmar la taxonomía con el equipo del mercado. Hasta ahora solo se
-- veían en su card de Alertas y no sumaban en el número de la barra, que cuenta
-- v_alertas. Esta migración agrega una rama a v_alertas: una fila por alias por
-- confirmar (referencia = texto del Flow; detalle = BU y taxonomía provisional;
-- sin compra ni material). La card «Taxonomías por confirmar» sigue siendo la
-- que la muestra y la resuelve (fn_asignar_taxonomia apaga por_confirmar, y la
-- fila sale de la vista).
--
-- Igual que la vista viva, más la rama nueva al final. Mismas columnas, mismo
-- orden: nada cambia para BI (no lee v_alertas) ni para los externos (RLS de
-- campanas_alias: solo internos de sus mercados).
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_alertas WITH (security_invoker = true) AS
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
  WHERE c.campana_id IS NULL AND c.campana_taxonomia IS NOT NULL AND NOT ((c.mercado_id, c.campana_taxonomia) IN ( SELECT r.mercado_id,
            r.taxonomia
           FROM v_campanas_sin_glosario r
          WHERE r.regla IS NOT NULL))
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
  WHERE d.tipo = 'PROVEEDOR'::text AND d.estado = 'PENDIENTE'::text
UNION ALL
 SELECT 'campaña de otra BU'::text AS alerta,
    c.codigo AS referencia,
    m.codigo AS mercado,
    c.id AS compra_id,
    NULL::bigint AS material_id,
    c.mercado_id,
    (('CLIENTE dice '::text || COALESCE(NULLIF(upper(btrim(c.cliente)), ''::text), '(vacío)'::text)) || ' y la campaña es '::text) || tx.tax AS detalle
   FROM compras c
     JOIN mercados m ON m.id = c.mercado_id
     CROSS JOIN LATERAL ( SELECT COALESCE(c.campana_taxonomia, fn_taxonomia_de_texto(m.codigo, c.campana_texto)) AS tax) tx
  WHERE tx.tax IS NOT NULL AND split_part(tx.tax, '_'::text, 2) <>
        CASE
            WHEN upper(btrim(c.cliente)) = 'MP'::text THEN 'MP'::text
            ELSE 'ML'::text
        END
UNION ALL
 SELECT 'taxonomía por confirmar'::text AS alerta,
    a.texto_flow AS referencia,
    m.codigo AS mercado,
    NULL::bigint AS compra_id,
    NULL::bigint AS material_id,
    a.mercado_id,
    (a.bu || ' · provisional: '::text) || a.taxonomia AS detalle
   FROM campanas_alias a
     JOIN mercados m ON m.id = a.mercado_id
  WHERE a.por_confirmar;

COMMIT;
