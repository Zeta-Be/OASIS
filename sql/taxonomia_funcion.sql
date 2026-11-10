-- =============================================================================
-- OASIS v2.0 — Una sola definición de la taxonomía del material
-- =============================================================================
-- La taxonomía de 11 piezas estaba escrita en v_materiales y, copiada, en
-- v_materiales_cliente (que no puede leerla de v_materiales: esa vista es
-- security_invoker y al Cliente le llegaría vacía). Ahora la fórmula vive en
-- fn_taxonomia_material y las dos vistas la llaman.
--
-- La función recibe los VALORES (mercado, cliente, proveedor…), no el id del
-- material: así no consulta ninguna tabla, no necesita permisos especiales y
-- Postgres la funde dentro de la vista (función SQL simple), sin costo por
-- fila. Con el id tendría que releer compras y materiales en cada fila y
-- saltarse RLS con SECURITY DEFINER.
--
-- v_materiales conserva exactamente sus columnas, su orden y su resultado: solo
-- cambia cómo se escribe la expresión de `taxonomia`. No toca las vistas de
-- inversión ni el contrato con BI.
--
-- ORDEN: va ANTES de sql/cliente_vistas.sql (v_materiales_cliente la usa).
-- Repetible. Una transacción.
-- =============================================================================

BEGIN;

-- Piezas: mercado _ BU _ PROVEEDOR-FORMATO _ CIUDAD _ CAMPAÑA _ X _ UBICACIÓN
--         _ SUB CAMPAÑA _ REFERENCIA _ código del material.
-- Una pieza nula se omite (concat_ws), igual que antes.
CREATE OR REPLACE FUNCTION public.fn_taxonomia_material(
    p_mercado      text,   -- código del mercado (MCO)
    p_cliente      text,   -- columna CLIENTE de la compra (ML, MP)
    p_proveedor    text,
    p_formato      text,
    p_ciudad       text,
    p_campana      text,   -- campaña de la compra: glosario, taxonomía o texto del Flow
    p_ubicacion    text,
    p_sub_campana  text,
    p_referencia   text,
    p_codigo       text    -- código del material (001-A)
)
RETURNS text
LANGUAGE sql STABLE
AS $$
    SELECT concat_ws('_',
        p_mercado,
        upper(regexp_replace(p_cliente, '[^A-Za-z0-9]', '', 'g')),
        upper(regexp_replace(p_proveedor, '[^A-Za-z0-9]', '', 'g')) || '-' || upper(regexp_replace(p_formato, '[^A-Za-z0-9]', '', 'g')),
        upper(regexp_replace(p_ciudad, '[^A-Za-z0-9]', '', 'g')),
        upper(p_campana),
        'X',
        upper(regexp_replace(split_part(p_ubicacion, '(', 1), '[^A-Za-z0-9]', '', 'g')),
        upper(coalesce(p_sub_campana, '')),
        upper(regexp_replace(coalesce(p_referencia, ''), '[^A-Za-z0-9]', '', 'g')),
        p_codigo)
$$;

REVOKE ALL ON FUNCTION public.fn_taxonomia_material(text, text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_taxonomia_material(text, text, text, text, text, text, text, text, text, text) TO authenticated, service_role;

-- v_materiales: idéntica, con la taxonomía por la función.
CREATE OR REPLACE VIEW public.v_materiales
WITH (security_invoker = true) AS
SELECT mt.id AS material_id,
       c.id AS compra_id,
       mk.codigo AS mercado,
       c.codigo AS compra_codigo,
       (c.codigo || '-') || chr(64 + mt.secuencia) AS material_codigo,
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
       public.fn_taxonomia_material(
           mk.codigo, c.cliente, p.nombre, c.formato, c.ciudad,
           COALESCE(ca.nombre_unico, c.campana_taxonomia, c.campana_texto),
           c.ubicacion, sc.nombre_unico, mt.referencia,
           (c.codigo || '-') || chr(64 + mt.secuencia)) AS taxonomia,
       c.mercado_id,
       mk.moneda,
       CASE
           WHEN COALESCE(ca.matt_campaign_type, split_part(c.campana_taxonomia, '_', 3)) = 'OTH-PF' THEN 'PARQUE FIJO'
           ELSE COALESCE(ca.nombre_unico, NULLIF(split_part(c.campana_taxonomia, '_', 5), ''), c.campana_texto)
       END AS campana_grupo
FROM public.materiales mt
JOIN public.compras c ON c.id = mt.compra_id
JOIN public.mercados mk ON mk.id = c.mercado_id
LEFT JOIN public.campanas ca ON ca.id = c.campana_id
LEFT JOIN public.proveedores p ON p.id = c.proveedor_id
LEFT JOIN public.campanas sc ON sc.id = mt.sub_campana_id;

COMMIT;
