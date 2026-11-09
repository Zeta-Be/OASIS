-- =============================================================================
-- OASIS v2.0 — Catálogos de tipo de compra y tipo de costo en tablas
-- =============================================================================
-- Noticias de los equipos (19-10-2026):
--   * Tipo de compra queda en tres valores: DIRECTO, BONIFICADO y PAGO
--     ANTICIPADO. FACTURABLE era lo mismo que DIRECTO (MLM ya lo corrigió en su
--     Sheets): sus compras pasan a DIRECTO y el valor sale del catálogo. La
--     carga traduce FACTURABLE → DIRECTO en silencio si vuelve a aparecer.
--   * COLOCACION es un tipo de costo que solo existe en Argentina. Cada tipo
--     de costo tiene sus mercados permitidos.
--
-- Postgres no deja quitar un valor de un enum. Así que las dos columnas pasan
-- de enum a texto validado contra una tabla de catálogo:
--   tipos_compra (tipo)               DIRECTO, BONIFICADO, PAGO ANTICIPADO
--   tipos_costo  (tipo, mercados)     mercados = códigos permitidos; vacío = todos
-- Desde aquí, agregar o quitar un tipo, o cambiar sus mercados, es un INSERT o
-- un UPDATE en el catálogo: sin migración y sin el archivo aparte que pedía el
-- enum. Un ADMIN puede hacerlo; RLS como los demás catálogos.
--
-- Para cambiar el tipo de las columnas hay que rehacer las vistas que las usan
-- (v_materiales, y sobre ella la diaria, semanal y total con sus funciones;
-- v_alertas; v_materiales_externos). Se recrean con su definición exacta de hoy
-- (sacada de la base con pg_get_viewdef); lo único que cambia es el cast
-- 'BONIFICADO'::tipo_compra_enum → ::text en v_alertas. Contrato con BI: mismas
-- columnas en el mismo orden; tipo_costo pasa de enum a texto (mismos valores).
--
-- Repetible solo la primera vez: después de aplicada, los enums ya no existen.
-- Una transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Catálogos
-- -----------------------------------------------------------------------------

CREATE TABLE public.tipos_compra (
    tipo  text     PRIMARY KEY CHECK (tipo = upper(btrim(tipo))),
    orden smallint NOT NULL
);
INSERT INTO public.tipos_compra (tipo, orden) VALUES
    ('DIRECTO', 1), ('BONIFICADO', 2), ('PAGO ANTICIPADO', 3);

-- mercados: códigos (MCO, MLA…) donde se permite. NULL = en todos.
CREATE TABLE public.tipos_costo (
    tipo     text     PRIMARY KEY CHECK (tipo = upper(btrim(tipo))),
    mercados text[],
    orden    smallint NOT NULL
);
INSERT INTO public.tipos_costo (tipo, mercados, orden) VALUES
    ('EXHIBICION', NULL, 1), ('PRODUCCION', NULL, 2), ('IMPUESTOS', NULL, 3),
    ('COLOCACION', ARRAY['MLA'], 4);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tipos_compra', 'tipos_costo'] LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC, anon, authenticated', t);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.%I TO authenticated', t);
        EXECUTE format($p$CREATE POLICY lectura_internos ON public.%I FOR SELECT TO authenticated
            USING ((SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN'))$p$, t);
        EXECUTE format($p$CREATE POLICY escritura_admin ON public.%I FOR ALL TO authenticated
            USING ((SELECT public.fn_rol_actual()) = 'ADMIN') WITH CHECK ((SELECT public.fn_rol_actual()) = 'ADMIN')$p$, t);
    END LOOP;
END
$$;


-- -----------------------------------------------------------------------------
-- 2. Las vistas y funciones que usan las columnas se van (vuelven en el 4)
-- -----------------------------------------------------------------------------
-- CASCADE desde v_materiales se lleva v_inversion_diaria, v_inversion_semanal,
-- v_inversion_total y fn_inversion_diaria, _semanal, _total y _filtrada (que
-- devuelven filas de esas vistas). fn_inversion_resumen y v_cuadre no dependen
-- de ellas y se quedan.

DROP VIEW public.v_alertas;
DROP VIEW public.v_materiales_externos;
DROP VIEW public.v_materiales CASCADE;


-- -----------------------------------------------------------------------------
-- 3. Columnas a texto, FACTURABLE → DIRECTO, validación por catálogo
-- -----------------------------------------------------------------------------

ALTER TABLE public.compras
    ALTER COLUMN tipo_compra TYPE text USING tipo_compra::text,
    ALTER COLUMN tipo_costo  TYPE text USING tipo_costo::text;

-- Queda en auditoría (usuario vacío: lo hizo esta migración).
UPDATE public.compras SET tipo_compra = 'DIRECTO', actualizado_en = now() WHERE tipo_compra = 'FACTURABLE';

ALTER TABLE public.compras
    ADD CONSTRAINT compras_tipo_compra_fkey FOREIGN KEY (tipo_compra) REFERENCES public.tipos_compra(tipo) ON UPDATE CASCADE,
    ADD CONSTRAINT compras_tipo_costo_fkey  FOREIGN KEY (tipo_costo)  REFERENCES public.tipos_costo(tipo)  ON UPDATE CASCADE;

-- El tipo de costo tiene que estar permitido en el mercado de la compra.
CREATE OR REPLACE FUNCTION public.fn_validar_tipo_costo()
RETURNS trigger
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_codigo text;
BEGIN
    IF NEW.tipo_costo IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT codigo INTO v_codigo FROM mercados WHERE id = NEW.mercado_id;
    IF NOT EXISTS (SELECT 1 FROM tipos_costo t
                   WHERE t.tipo = NEW.tipo_costo AND (t.mercados IS NULL OR v_codigo = ANY (t.mercados))) THEN
        RAISE EXCEPTION 'El tipo de costo % no se usa en %', NEW.tipo_costo, v_codigo USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_validar_tipo_costo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS validar_tipo_costo ON public.compras;
CREATE TRIGGER validar_tipo_costo BEFORE INSERT OR UPDATE OF tipo_costo, mercado_id ON public.compras
    FOR EACH ROW EXECUTE FUNCTION public.fn_validar_tipo_costo();

DROP TYPE public.tipo_compra_enum;
DROP TYPE public.tipo_costo_enum;


-- -----------------------------------------------------------------------------
-- 4. Las vistas y funciones de vuelta, con su definición de hoy
-- -----------------------------------------------------------------------------

CREATE VIEW public.v_materiales
WITH (security_invoker=true)
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
            ELSE COALESCE(ca.nombre_unico, c.campana_taxonomia, c.campana_texto)
        END AS campana_grupo
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados mk ON mk.id = c.mercado_id
     LEFT JOIN campanas ca ON ca.id = c.campana_id
     LEFT JOIN proveedores p ON p.id = c.proveedor_id
     LEFT JOIN campanas sc ON sc.id = mt.sub_campana_id;

CREATE VIEW public.v_inversion_diaria
WITH (security_invoker=true)
AS
WITH corte AS (
         SELECT COALESCE(NULLIF(( SELECT configuracion.valor
                   FROM configuracion
                  WHERE configuracion.clave = 'fecha_corte'::text), ''::text)::date, CURRENT_DATE) AS fecha_corte
        )
 SELECT v.mercado AS site,
    v.cliente AS bu,
    EXTRACT(year FROM t.fecha)::integer AS year,
    EXTRACT(month FROM t.fecha)::integer AS month,
    EXTRACT(week FROM t.fecha)::integer AS week,
    t.fecha AS date,
    v.proveedor,
    v.tipo_costo,
    v.formato,
    v.valor_total,
    v.compra_codigo AS id,
    v.material_codigo AS id_ejecucion,
    v.campana,
    v.sub_campana,
    t.pct_participacion,
    t.costo_proyectado,
        CASE
            WHEN t.fecha <= k.fecha_corte THEN 'EJECUTADO'::text
            ELSE 'PROGRAMADO'::text
        END AS estado,
        CASE
            WHEN t.fecha <= k.fecha_corte THEN t.costo_proyectado
            ELSE 0::numeric
        END AS costo_ejecutado,
    date_trunc('month'::text, cm.fecha_inicio::timestamp with time zone)::date AS mes_compra,
    v.moneda,
    v.mercado_id,
    v.campana_grupo
   FROM inversion_diaria t
     JOIN v_materiales v ON v.material_id = t.material_id
     JOIN compras cm ON cm.id = t.compra_id
     CROSS JOIN corte k;

CREATE VIEW public.v_inversion_semanal
WITH (security_invoker=true)
AS
SELECT site,
    bu,
    year,
    month,
    week,
    proveedor,
    tipo_costo,
    formato,
    valor_total,
    id,
    id_ejecucion,
    campana,
    sub_campana,
    min(date) AS fecha_inicio,
    max(date) AS fecha_fin,
    count(*) AS dias,
    sum(costo_proyectado) AS costo_proyectado,
    sum(costo_ejecutado) AS costo_ejecutado,
    mes_compra,
    moneda,
    mercado_id,
    campana_grupo
   FROM v_inversion_diaria
  GROUP BY site, bu, year, month, week, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion, campana, sub_campana, mes_compra, moneda, mercado_id, campana_grupo;

CREATE VIEW public.v_inversion_total
WITH (security_invoker=true)
AS
SELECT site,
    bu,
    proveedor,
    tipo_costo,
    formato,
    valor_total,
    id,
    id_ejecucion,
    campana,
    sub_campana,
    min(date) AS fecha_inicio,
    max(date) AS fecha_fin,
    count(*) AS dias,
    sum(costo_proyectado) / NULLIF(valor_total, 0::numeric) AS pct_participacion,
    sum(costo_proyectado) AS costo_proyectado,
    sum(costo_ejecutado) AS costo_ejecutado,
    mes_compra,
    moneda,
    mercado_id,
    campana_grupo
   FROM v_inversion_diaria
  GROUP BY site, bu, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion, campana, sub_campana, mes_compra, moneda, mercado_id, campana_grupo;

CREATE VIEW public.v_materiales_externos
WITH (security_invoker=false, security_barrier=true)
AS
SELECT mt.id,
    (c.codigo || '-'::text) || chr(64 + mt.secuencia) AS codigo,
    sc.nombre_unico AS sub_campana,
    mt.referencia,
    mt.fecha_inicio,
    mt.fecha_fin,
    mt.enlace,
    mt.reporte_implementacion,
    mt.evidencia_url,
    c.codigo AS compra,
    p.nombre AS proveedor,
    c.formato,
    c.ubicacion,
    c.ciudad,
    c.tipo_costo
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     LEFT JOIN proveedores p ON p.id = c.proveedor_id
     LEFT JOIN campanas sc ON sc.id = mt.sub_campana_id
  WHERE (mt.compra_id IN ( SELECT fn_mis_compras() AS fn_mis_compras));

CREATE VIEW public.v_alertas
WITH (security_invoker=true)
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
  WHERE d.tipo = 'PROVEEDOR'::text AND d.estado = 'PENDIENTE'::text;

CREATE OR REPLACE FUNCTION public.fn_inversion_diaria()
 RETURNS SETOF v_inversion_diaria
 LANGUAGE sql
 STABLE
 SET enable_nestloop TO 'off'
AS $function$ SELECT * FROM public.v_inversion_diaria $function$;

CREATE OR REPLACE FUNCTION public.fn_inversion_semanal()
 RETURNS SETOF v_inversion_semanal
 LANGUAGE sql
 STABLE
 SET enable_nestloop TO 'off'
AS $function$ SELECT * FROM public.v_inversion_semanal $function$;

CREATE OR REPLACE FUNCTION public.fn_inversion_total()
 RETURNS SETOF v_inversion_total
 LANGUAGE sql
 STABLE
 SET enable_nestloop TO 'off'
AS $function$ SELECT * FROM public.v_inversion_total $function$;

CREATE OR REPLACE FUNCTION public.fn_inversion_filtrada(p_mercado smallint, p_filtros jsonb DEFAULT '{}'::jsonb)
 RETURNS SETOF v_inversion_diaria
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
    SELECT d.*
    FROM v_inversion_diaria d
    WHERE d.mercado_id = p_mercado
      AND (NOT (p_filtros ? 'meses') OR jsonb_array_length(p_filtros -> 'meses') = 0
           OR to_char(CASE WHEN p_filtros ->> 'ver_por' = 'compra' THEN d.mes_compra ELSE d.date END, 'YYYY-MM')
              IN (SELECT jsonb_array_elements_text(p_filtros -> 'meses')))
      AND (NOT (p_filtros ? 'proveedores') OR jsonb_array_length(p_filtros -> 'proveedores') = 0
           OR d.proveedor IN (SELECT jsonb_array_elements_text(p_filtros -> 'proveedores')))
      AND (NOT (p_filtros ? 'tipos_costo') OR jsonb_array_length(p_filtros -> 'tipos_costo') = 0
           OR d.tipo_costo::text IN (SELECT jsonb_array_elements_text(p_filtros -> 'tipos_costo')))
      AND (NOT (p_filtros ? 'campanas') OR jsonb_array_length(p_filtros -> 'campanas') = 0
           OR d.campana_grupo IN (SELECT jsonb_array_elements_text(p_filtros -> 'campanas')))
      AND (NOT (p_filtros ? 'sub_campanas') OR jsonb_array_length(p_filtros -> 'sub_campanas') = 0
           OR coalesce(d.sub_campana, '__sin__') IN (SELECT jsonb_array_elements_text(p_filtros -> 'sub_campanas')))
$function$;

-- Permisos: los de antes. Supabase da acceso a anon en todo objeto nuevo de
-- public; se quita.
ALTER VIEW public.v_materiales_externos OWNER TO postgres;
REVOKE ALL ON public.v_materiales, public.v_inversion_diaria, public.v_inversion_semanal,
              public.v_inversion_total, public.v_alertas FROM PUBLIC, anon;
GRANT SELECT ON public.v_materiales, public.v_inversion_diaria, public.v_inversion_semanal,
                public.v_inversion_total, public.v_alertas TO authenticated;
REVOKE ALL ON public.v_materiales_externos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_materiales_externos TO authenticated;

REVOKE ALL ON FUNCTION public.fn_inversion_diaria(), public.fn_inversion_semanal(), public.fn_inversion_total(),
                       public.fn_inversion_filtrada(smallint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_inversion_diaria(), public.fn_inversion_semanal(), public.fn_inversion_total(),
                          public.fn_inversion_filtrada(smallint, jsonb) TO authenticated;

COMMIT;
