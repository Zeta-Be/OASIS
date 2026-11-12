-- =============================================================================
-- OASIS v2.0 — Campañas reconocidas por familia, por año y por equivalencia
-- =============================================================================
-- El glosario de ZetaBé no se toca. Una compra cuya taxonomía no coincide
-- exacto con una campaña del glosario (campana_id vacío) se reconoce dentro de
-- OASIS por una de estas reglas, en este orden, comparando el nombre corto de la
-- taxonomía (de la quinta pieza a la penúltima, MLU_ML_FE-T1_ALL_CM_X → CM):
--
--   AÑO          el año de 2 y 4 dígitos al final es el mismo:
--                PPS-04-26 = PPS-04-2026.
--   FAMILIA      la misma base sin fase ni numeración al final (PRE, DUR, EXT,
--                -2, -02): CM ↔ CMPRE / CMDUR / CM-02, MDD ↔ MDDDUR.
--   EQUIVALENCIA una equivalencia manual por mercado y BU (tabla
--                campanas_equivalencias, solo ADMIN, con auditoría):
--                CYBERMONDAY → familia CM.
--
-- No se adivina la fase: la compra conserva su taxonomía, su campana_id sigue
-- vacío y su campana_grupo sigue siendo el nombre corto (CM). Nada de esto
-- cambia compras, la inversión ni las columnas de v_inversion_diaria (BI).
-- Lo único que cambia es que «campaña fuera del glosario» sale solo cuando no
-- hay ninguna coincidencia. v_campanas_sin_glosario dice, por campaña, qué
-- regla la reconoció (o ninguna) y cuántas compras tiene.
--
-- La BU de la equivalencia es la segunda pieza de la taxonomía (ML o MP).
-- Repetible. Pruebas: sql/campanas_familia_pruebas.sql (se revierte sola).
-- =============================================================================

BEGIN;

-- ------------------------------------------------------------- Normalizaciones
-- Año: un -20YY al final cuenta como -YY.
CREATE OR REPLACE FUNCTION public.fn_campana_anio(p_nombre text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT regexp_replace(upper(btrim(p_nombre)), '-20([0-9]{2})$', '-\1')
$$;

-- Familia: con el año normalizado, sin numeración final pegada a una letra
-- (CM-02, HS-2, CMDUR-2; no toca PPS-04-26, cuyo final va después de un número)
-- y después sin la fase PRE, DUR o EXT (debe quedar algo antes).
CREATE OR REPLACE FUNCTION public.fn_campana_familia(p_nombre text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT nullif(regexp_replace(
                    regexp_replace(public.fn_campana_anio(p_nombre), '([A-Z])-?[0-9]{1,2}$', '\1'),
                  '(.)(PRE|DUR|EXT)$', '\1'), '')
$$;

-- --------------------------------------------------- Equivalencias manuales
CREATE TABLE IF NOT EXISTS public.campanas_equivalencias (
    id          bigserial   PRIMARY KEY,
    mercado_id  smallint    NOT NULL REFERENCES public.mercados(id),
    bu          text        NOT NULL CHECK (bu IN ('ML', 'MP')),
    texto       text        NOT NULL,   -- nombre corto del Flow: CYBERMONDAY
    familia     text        NOT NULL,   -- familia del glosario: CM
    nota        text,
    creado_por  bigint      REFERENCES public.usuarios(id) ON DELETE SET NULL,
    creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS campanas_equivalencias_texto
    ON public.campanas_equivalencias (mercado_id, bu, texto);

-- Normaliza, exige que la familia exista en el glosario del mercado y que el
-- texto no esté ya reconocido por las reglas (sería una equivalencia muerta).
CREATE OR REPLACE FUNCTION public.fn_campanas_equivalencias_validar()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.texto   := upper(btrim(NEW.texto));
    NEW.familia := public.fn_campana_familia(NEW.familia);
    IF NEW.texto !~ '^[A-Z0-9][A-Z0-9_-]*$' THEN
        RAISE EXCEPTION 'El texto del Flow es el nombre corto de la campaña (por ejemplo CYBERMONDAY), sin espacios'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.familia IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.campanas c
        WHERE c.mercado_id = NEW.mercado_id AND public.fn_campana_familia(c.nombre_unico) = NEW.familia) THEN
        RAISE EXCEPTION 'La familia % no está en el glosario de este mercado', coalesce(NEW.familia, '(vacía)')
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.campanas c
        WHERE c.mercado_id = NEW.mercado_id
          AND public.fn_campana_familia(c.nombre_unico) = public.fn_campana_familia(NEW.texto)) THEN
        RAISE EXCEPTION '% ya se reconoce sola en el glosario (exacta, por año o por familia): no hace falta equivalencia', NEW.texto
            USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'INSERT' THEN
        NEW.creado_por := (SELECT id FROM public.fn_usuario_actual());
        NEW.creado_en  := now();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validar ON public.campanas_equivalencias;
CREATE TRIGGER validar
    BEFORE INSERT OR UPDATE ON public.campanas_equivalencias
    FOR EACH ROW EXECUTE FUNCTION public.fn_campanas_equivalencias_validar();

DROP TRIGGER IF EXISTS auditar ON public.campanas_equivalencias;
CREATE TRIGGER auditar
    AFTER INSERT OR UPDATE OR DELETE ON public.campanas_equivalencias
    FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();

-- Leen los internos de sus mercados (ADMIN y LECTURA, todos); escribe solo ADMIN.
ALTER TABLE public.campanas_equivalencias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.campanas_equivalencias FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.campanas_equivalencias TO authenticated;
GRANT USAGE ON SEQUENCE public.campanas_equivalencias_id_seq TO authenticated;

DROP POLICY IF EXISTS lectura_mercado ON public.campanas_equivalencias;
CREATE POLICY lectura_mercado ON public.campanas_equivalencias FOR SELECT TO authenticated
    USING ((SELECT public.fn_rol_actual()) = ANY (ARRAY['PLANNING', 'ZB', 'LECTURA', 'ADMIN']::public.rol_enum[])
           AND mercado_id IN (SELECT public.fn_mis_mercados()));
DROP POLICY IF EXISTS admin_todo ON public.campanas_equivalencias;
CREATE POLICY admin_todo ON public.campanas_equivalencias FOR ALL TO authenticated
    USING ((SELECT public.fn_rol_actual()) = 'ADMIN')
    WITH CHECK ((SELECT public.fn_rol_actual()) = 'ADMIN');

-- ------------------------------------------------------------ Reconocimiento
-- Regla con la que OASIS reconoce una taxonomía que no coincide exacto, la
-- familia y las campañas del glosario que la forman. Sin filas = no se reconoce.
CREATE OR REPLACE FUNCTION public.fn_campana_reconocida(p_mercado_id smallint, p_taxonomia text)
RETURNS TABLE (regla text, familia text, glosario text[])
LANGUAGE sql STABLE
SET search_path = public
AS $$
    WITH p AS (SELECT string_to_array(upper(p_taxonomia), '_') AS a),
    cand AS (
        SELECT DISTINCT x AS nombre
        FROM p, unnest(ARRAY[array_to_string(a[5:cardinality(a) - 1], '_'),
                             a[cardinality(a) - 1],
                             array_to_string(a[5:cardinality(a) - 1], '')]) x
        WHERE x <> ''
    ),
    glos AS (SELECT upper(nombre_unico) AS n FROM public.campanas WHERE mercado_id = p_mercado_id),
    reglas AS (
        SELECT 1 AS orden, 'AÑO'::text AS regla, public.fn_campana_anio(c.nombre) AS familia, array_agg(DISTINCT g.n) AS glosario
        FROM cand c JOIN glos g ON public.fn_campana_anio(g.n) = public.fn_campana_anio(c.nombre)
        GROUP BY 1, 2, 3
        UNION ALL
        SELECT 2, 'FAMILIA', public.fn_campana_familia(c.nombre), array_agg(DISTINCT g.n)
        FROM cand c JOIN glos g ON public.fn_campana_familia(g.n) = public.fn_campana_familia(c.nombre)
        GROUP BY 1, 2, 3
        UNION ALL
        SELECT 3, 'EQUIVALENCIA', e.familia, array_agg(DISTINCT g.n)
        FROM p, cand c
        JOIN public.campanas_equivalencias e ON e.mercado_id = p_mercado_id AND e.texto = c.nombre
        JOIN glos g ON public.fn_campana_familia(g.n) = e.familia
        WHERE e.bu = (SELECT a[2] FROM p)
        GROUP BY 1, 2, 3
    )
    SELECT regla, familia, glosario FROM reglas
    WHERE p_taxonomia IS NOT NULL
    ORDER BY orden, familia
    LIMIT 1
$$;

-- Una fila por campaña que no coincide exacto con el glosario: con qué regla
-- se reconoce (regla vacía = sigue en la alerta) y cuántas compras la usan.
DROP VIEW IF EXISTS public.v_campanas_sin_glosario CASCADE;
CREATE VIEW public.v_campanas_sin_glosario WITH (security_invoker = true) AS
SELECT t.mercado_id,
       m.codigo AS mercado,
       split_part(t.taxonomia, '_', 2) AS bu,
       t.taxonomia,
       array_to_string((string_to_array(t.taxonomia, '_'))[5:cardinality(string_to_array(t.taxonomia, '_')) - 1], '_') AS nombre_corto,
       r.regla,
       r.familia,
       r.glosario,
       t.compras
FROM (SELECT mercado_id, campana_taxonomia AS taxonomia, count(*)::integer AS compras
      FROM public.compras
      WHERE campana_id IS NULL AND campana_taxonomia IS NOT NULL
      GROUP BY 1, 2) t
JOIN public.mercados m ON m.id = t.mercado_id
LEFT JOIN LATERAL public.fn_campana_reconocida(t.mercado_id, t.taxonomia) r ON true;

REVOKE ALL ON public.v_campanas_sin_glosario FROM anon;
GRANT SELECT ON public.v_campanas_sin_glosario TO authenticated;

-- ------------------------------------------------------------------ v_alertas
-- Igual que la vista viva, salvo «campaña fuera del glosario», que ahora excluye
-- lo que v_campanas_sin_glosario reconoce.
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
  WHERE c.campana_id IS NULL AND c.campana_taxonomia IS NOT NULL
    AND NOT ((c.mercado_id, c.campana_taxonomia) IN ( SELECT r.mercado_id, r.taxonomia
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
        END;

COMMIT;
