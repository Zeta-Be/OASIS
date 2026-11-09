-- =============================================================================
-- OASIS v2.0 — Varios mercados: MLC, MLU, MLA y MLM junto a MCO
-- =============================================================================
-- Regla de esta entrega: todo se carga. Lo incompleto o inconsistente no se
-- deja fuera: entra, y v_alertas lo muestra en Alertas de su mercado hasta que
-- alguien lo corrija.
--
--   1. mercados.moneda: cada cifra con su moneda; nunca se suman mercados.
--   2. Campaña por compra (columna CAMPAÑA del Flow), ya no la fija el mercado:
--      compras.campana_texto (tal cual), compras.campana_taxonomia (válida) y
--      campana_id (del glosario). campanas_alias traduce textos sin taxonomía.
--   3. Columnas de compras que pasan a admitir vacío (la compra entra con
--      alerta): tipo de costo, tipo de compra, medio, campaña, proveedor,
--      formato, ubicación, ciudad, cliente y fechas. Los CHECK de fechas se
--      quedan: una compra o un material con fechas invertidas entra sin fechas.
--      compras.fuera_de_catalogo guarda lo que el Sheets trae y el enum no
--      admite (MLM: tipo de compra FACTURABLE / PAGO ANTICIPADO).
--   4. fn_mis_mercados(): LECTURA ve todos los mercados, como ADMIN.
--   5. Vistas: v_materiales sigue mostrando compras incompletas (LEFT JOIN);
--      las de inversión agregan al final moneda, mercado_id y campana_grupo
--      (OTH-PF = «PARQUE FIJO» para filtros). Las 19 columnas anteriores de
--      v_inversion_diaria quedan igual: contrato con BI.
--   6. v_alertas: mercado_id y detalle al final, y los tipos nuevos. v_cuadre
--      cruza por código y mercado (antes solo por código: con varios mercados
--      la 001 de MCO se mezclaba con la 001 de MLC).
--   7. fn_asignar_taxonomia: escribir la taxonomía correcta desde Alertas.
--
-- Requiere sql/mercados_enum.sql confirmado antes (COLOCACION).
-- Repetible. Una transacción.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA extensions;

-- -----------------------------------------------------------------------------
-- 1. Moneda por mercado
-- -----------------------------------------------------------------------------

ALTER TABLE public.mercados ADD COLUMN IF NOT EXISTS moneda text;

UPDATE public.mercados m SET moneda = v.moneda
FROM (VALUES ('MCO', 'COP'), ('MLB', 'BRL'), ('MLM', 'MXN'), ('MLA', 'ARS'),
             ('MLC', 'CLP'), ('MLU', 'UYU'), ('MPE', 'PEN')) AS v(codigo, moneda)
WHERE m.codigo = v.codigo AND m.moneda IS DISTINCT FROM v.moneda;

ALTER TABLE public.mercados ALTER COLUMN moneda SET NOT NULL;
ALTER TABLE public.mercados DROP CONSTRAINT IF EXISTS mercados_moneda;
ALTER TABLE public.mercados ADD CONSTRAINT mercados_moneda CHECK (moneda ~ '^[A-Z]{3}$');

-- Campaña con la que la pantalla Compras crea compras nuevas en cada mercado
-- (la de parque fijo del glosario). MCO ya la tenía.
UPDATE public.mercados m SET campana_ooh_id = c.id
FROM public.campanas c, (VALUES ('MLC', 'ALTO-IMPACTO'), ('MLU', 'PARQUE-FIJO'),
                                ('MLA', 'PARQUE-FIJO'), ('MLM', 'PLANTA-FIJA')) AS v(codigo, nombre)
WHERE m.codigo = v.codigo AND c.mercado_id = m.id AND c.nombre_unico = v.nombre
  AND m.campana_ooh_id IS NULL;


-- -----------------------------------------------------------------------------
-- 2. Taxonomía de campaña
-- -----------------------------------------------------------------------------
-- Formato: {MERCADO}_ML_{tipo}_{…}_{nombre}_{sufijo}, en mayúsculas, sin
-- espacios, al menos cinco piezas. Ej. MLC_ML_OTH-PF_ALL_ALTO-IMPACTO_X.
-- Si el Flow trae texto después (MLA: «…_INTERIOR_X  5», «… del 01/01/20»), se
-- toma la primera palabra; el resto se ignora y la carga lo reporta.

CREATE OR REPLACE FUNCTION public.fn_taxonomia_de_texto(p_mercado text, p_texto text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT t FROM (SELECT upper(split_part(btrim(p_texto), ' ', 1)) AS t) x
    WHERE t ~ ('^' || upper(p_mercado) || '_ML_[A-Z0-9-]+(_[A-Z0-9-]+){3,}$')
$$;

-- Campaña del glosario a la que apunta una taxonomía, o null. Prueba, en
-- orden: lo que va después de la cuarta pieza, eso sin el sufijo final, la
-- penúltima pieza y las mismas sin guiones bajos (HS_DUR → HSDUR).
CREATE OR REPLACE FUNCTION public.fn_campana_de_taxonomia(p_mercado_id smallint, p_taxonomia text)
RETURNS integer
LANGUAGE sql STABLE
SET search_path = public
AS $$
    WITH p AS (SELECT string_to_array(p_taxonomia, '_') AS a),
    cand AS (
        SELECT 1 AS orden, array_to_string(a[5:], '_') AS nombre FROM p
        UNION ALL SELECT 2, array_to_string(a[5:cardinality(a) - 1], '_') FROM p
        UNION ALL SELECT 3, a[cardinality(a) - 1] FROM p
        UNION ALL SELECT 4, array_to_string(a[5:], '') FROM p
        UNION ALL SELECT 5, array_to_string(a[5:cardinality(a) - 1], '') FROM p
    )
    SELECT c.id
    FROM cand JOIN public.campanas c ON c.mercado_id = p_mercado_id AND upper(c.nombre_unico) = cand.nombre
    WHERE p_taxonomia IS NOT NULL AND cand.nombre <> ''
    ORDER BY cand.orden
    LIMIT 1
$$;

-- Textos del Flow sin taxonomía y su equivalencia. La alimentan la precarga y
-- la corrección en Alertas; la carga la consulta antes de dar la alerta.
CREATE TABLE IF NOT EXISTS public.campanas_alias (
    id          bigserial   PRIMARY KEY,
    mercado_id  smallint    NOT NULL REFERENCES public.mercados(id),
    texto_flow  text        NOT NULL,
    taxonomia   text        NOT NULL,
    creado_por  bigint      REFERENCES public.usuarios(id) ON DELETE SET NULL,
    creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS campanas_alias_texto
    ON public.campanas_alias (mercado_id, upper(btrim(texto_flow)));

ALTER TABLE public.campanas_alias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.campanas_alias FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.campanas_alias TO authenticated;
GRANT USAGE ON SEQUENCE public.campanas_alias_id_seq TO authenticated;

DROP POLICY IF EXISTS lectura_mercado ON public.campanas_alias;
CREATE POLICY lectura_mercado ON public.campanas_alias
    FOR SELECT TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN')
        AND mercado_id IN (SELECT public.fn_mis_mercados())
    );
DROP POLICY IF EXISTS escritura_mercado ON public.campanas_alias;
CREATE POLICY escritura_mercado ON public.campanas_alias
    FOR ALL TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'ADMIN')
        AND mercado_id IN (SELECT public.fn_mis_mercados())
    )
    WITH CHECK (
        (SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'ADMIN')
        AND mercado_id IN (SELECT public.fn_mis_mercados())
    );

INSERT INTO public.campanas_alias (mercado_id, texto_flow, taxonomia)
SELECT id, 'PARQUE FIJO', 'MLU_ML_OTH-PF_ALL_PARQUE-FIJO_X' FROM public.mercados WHERE codigo = 'MLU'
ON CONFLICT (mercado_id, upper(btrim(texto_flow))) DO NOTHING;


-- -----------------------------------------------------------------------------
-- 3. Compras: todo entra
-- -----------------------------------------------------------------------------

ALTER TABLE public.compras
    ALTER COLUMN tipo_costo   DROP NOT NULL,
    ALTER COLUMN tipo_compra  DROP NOT NULL,
    ALTER COLUMN medio        DROP NOT NULL,
    ALTER COLUMN campana_id   DROP NOT NULL,
    ALTER COLUMN proveedor_id DROP NOT NULL,
    ALTER COLUMN formato      DROP NOT NULL,
    ALTER COLUMN ubicacion    DROP NOT NULL,
    ALTER COLUMN ciudad       DROP NOT NULL,
    ALTER COLUMN cliente      DROP NOT NULL,
    ALTER COLUMN fecha_inicio DROP NOT NULL,
    ALTER COLUMN fecha_fin    DROP NOT NULL;

ALTER TABLE public.compras
    ADD COLUMN IF NOT EXISTS campana_texto     text,
    ADD COLUMN IF NOT EXISTS campana_taxonomia text,
    ADD COLUMN IF NOT EXISTS fuera_de_catalogo jsonb;

-- Las dos fechas o ninguna (como materiales). Invertidas siguen prohibidas.
ALTER TABLE public.compras DROP CONSTRAINT IF EXISTS compras_fechas_par;
ALTER TABLE public.compras ADD CONSTRAINT compras_fechas_par CHECK ((fecha_inicio IS NULL) = (fecha_fin IS NULL));

-- Las compras de MCO ya cargadas: todas son parque fijo. La recarga lo
-- reescribe con lo que diga el Flow.
UPDATE public.compras c
SET campana_texto = 'MCO_ML_OTH-PF_ALL_PARQUE-FIJO_X', campana_taxonomia = 'MCO_ML_OTH-PF_ALL_PARQUE-FIJO_X'
FROM public.mercados m
WHERE m.id = c.mercado_id AND m.codigo = 'MCO' AND c.campana_id = m.campana_ooh_id
  AND c.campana_taxonomia IS NULL;


-- -----------------------------------------------------------------------------
-- 4. LECTURA ve todos los mercados
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_mis_mercados()
RETURNS SETOF smallint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT m.id
    FROM public.mercados m
    WHERE public.fn_rol_actual() IN ('ADMIN', 'LECTURA')
    UNION
    SELECT um.mercado_id
    FROM public.usuario_mercados um
    JOIN public.fn_usuario_actual() u ON u.id = um.usuario_id
    WHERE u.rol <> 'PROVEEDOR'
    UNION
    SELECT p.mercado_id
    FROM public.proveedores p
    JOIN public.fn_usuario_actual() u ON u.proveedor_id = p.id
    WHERE u.rol = 'PROVEEDOR'
$$;


-- -----------------------------------------------------------------------------
-- 5. Vistas
-- -----------------------------------------------------------------------------
-- CREATE OR REPLACE: mismas columnas en el mismo orden, las nuevas al final.
-- LEFT JOIN a campañas y proveedores: una compra incompleta sigue repartiendo
-- su valor (si tiene materiales con fechas) y no desaparece de inversión.
-- La campaña que se muestra: la del glosario; si no hay, la taxonomía; si no,
-- el texto del Flow tal cual.

CREATE OR REPLACE VIEW public.v_materiales
WITH (security_invoker = true)
AS
SELECT mt.id AS material_id,
    c.id AS compra_id,
    mk.codigo AS mercado,
    c.codigo AS compra_codigo,
    ((c.codigo || '-'::text) || chr((64 + mt.secuencia))) AS material_codigo,
    c.cliente,
    coalesce(ca.nombre_unico, c.campana_taxonomia, c.campana_texto) AS campana,
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
            WHEN (mt.fecha_inicio IS NULL) THEN 0
            ELSE ((mt.fecha_fin - mt.fecha_inicio) + 1)
        END AS dias,
    concat_ws('_'::text, mk.codigo, upper(regexp_replace(c.cliente, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), ((upper(regexp_replace(p.nombre, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)) || '-'::text) || upper(regexp_replace(c.formato, '[^A-Za-z0-9]'::text, ''::text, 'g'::text))), upper(regexp_replace(c.ciudad, '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), upper(coalesce(ca.nombre_unico, c.campana_taxonomia, c.campana_texto)), 'X', upper(regexp_replace(split_part(c.ubicacion, '('::text, 1), '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), upper(COALESCE(sc.nombre_unico, ''::text)), upper(regexp_replace(COALESCE(mt.referencia, ''::text), '[^A-Za-z0-9]'::text, ''::text, 'g'::text)), ((c.codigo || '-'::text) || chr((64 + mt.secuencia)))) AS taxonomia,
    -- nuevas
    c.mercado_id,
    mk.moneda,
    CASE WHEN coalesce(ca.matt_campaign_type, split_part(c.campana_taxonomia, '_', 3)) = 'OTH-PF'
         THEN 'PARQUE FIJO'
         ELSE coalesce(ca.nombre_unico, c.campana_taxonomia, c.campana_texto)
    END AS campana_grupo
   FROM materiales mt
     JOIN compras c ON c.id = mt.compra_id
     JOIN mercados mk ON mk.id = c.mercado_id
     LEFT JOIN campanas ca ON ca.id = c.campana_id
     LEFT JOIN proveedores p ON p.id = c.proveedor_id
     LEFT JOIN campanas sc ON sc.id = mt.sub_campana_id;

-- Igual que antes; las tres columnas nuevas al final, después de mes_compra.
CREATE OR REPLACE VIEW public.v_inversion_diaria
WITH (security_invoker = true)
AS
 WITH dias AS (
         SELECT mt.id AS material_id,
            mt.compra_id,
            (d.d)::date AS fecha
           FROM (materiales mt
             CROSS JOIN LATERAL generate_series((mt.fecha_inicio)::timestamp with time zone, (mt.fecha_fin)::timestamp with time zone, '1 day'::interval) d(d))
          WHERE (mt.fecha_inicio IS NOT NULL)
        ), pesos AS (
         SELECT d.material_id,
            d.compra_id,
            d.fecha,
            (1.0 / (count(*) OVER (PARTITION BY d.compra_id, d.fecha))::numeric) AS peso
           FROM dias d
        ), normalizado AS (
         SELECT p.material_id,
            p.compra_id,
            p.fecha,
            p.peso,
            sum(p.peso) OVER (PARTITION BY p.compra_id) AS peso_compra
           FROM pesos p
        ), corte AS (
         SELECT COALESCE((NULLIF(( SELECT configuracion.valor
                   FROM configuracion
                  WHERE (configuracion.clave = 'fecha_corte'::text)), ''::text))::date, CURRENT_DATE) AS fecha_corte
        )
 SELECT v.mercado AS site,
    v.cliente AS bu,
    (EXTRACT(year FROM n.fecha))::integer AS year,
    (EXTRACT(month FROM n.fecha))::integer AS month,
    (EXTRACT(week FROM n.fecha))::integer AS week,
    n.fecha AS date,
    v.proveedor,
    v.tipo_costo,
    v.formato,
    v.valor_total,
    v.compra_codigo AS id,
    v.material_codigo AS id_ejecucion,
    v.campana,
    v.sub_campana,
    (((v.valor_total * n.peso) / n.peso_compra) / NULLIF(v.valor_total, (0)::numeric)) AS pct_participacion,
    round(((v.valor_total * n.peso) / n.peso_compra), 2) AS costo_proyectado,
        CASE
            WHEN (n.fecha <= k.fecha_corte) THEN 'EJECUTADO'::text
            ELSE 'PROGRAMADO'::text
        END AS estado,
        CASE
            WHEN (n.fecha <= k.fecha_corte) THEN round(((v.valor_total * n.peso) / n.peso_compra), 2)
            ELSE (0)::numeric
        END AS costo_ejecutado,
    (date_trunc('month'::text, (cm.fecha_inicio)::timestamp with time zone))::date AS mes_compra,
    v.moneda,
    v.mercado_id,
    v.campana_grupo
   FROM (((normalizado n
     JOIN v_materiales v ON ((v.material_id = n.material_id)))
     JOIN compras cm ON ((cm.id = v.compra_id)))
     CROSS JOIN corte k);

CREATE OR REPLACE VIEW public.v_inversion_semanal
WITH (security_invoker = true)
AS
SELECT site, bu, year, month, week, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion,
    campana, sub_campana,
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
GROUP BY site, bu, year, month, week, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion,
    campana, sub_campana, mes_compra, moneda, mercado_id, campana_grupo;

CREATE OR REPLACE VIEW public.v_inversion_total
WITH (security_invoker = true)
AS
SELECT site, bu, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion, campana, sub_campana,
    min(date) AS fecha_inicio,
    max(date) AS fecha_fin,
    count(*) AS dias,
    (sum(costo_proyectado) / NULLIF(valor_total, (0)::numeric)) AS pct_participacion,
    sum(costo_proyectado) AS costo_proyectado,
    sum(costo_ejecutado) AS costo_ejecutado,
    mes_compra,
    moneda,
    mercado_id,
    campana_grupo
FROM v_inversion_diaria
GROUP BY site, bu, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion, campana, sub_campana,
    mes_compra, moneda, mercado_id, campana_grupo;

-- v_cuadre cruzaba compras e inversión solo por el código (001). Con varios
-- mercados, la 001 de MCO se mezclaría con la 001 de MLC: ahora va por código
-- y mercado. Mismas columnas.
CREATE OR REPLACE VIEW public.v_cuadre
WITH (security_invoker = true)
AS
SELECT c.codigo,
    c.valor_total,
    COALESCE(sum(d.costo_proyectado), (0)::numeric) AS asignado,
    (COALESCE(sum(d.costo_proyectado), (0)::numeric) - c.valor_total) AS diferencia
   FROM compras c
     LEFT JOIN v_inversion_diaria d ON d.id = c.codigo AND d.mercado_id = c.mercado_id
  WHERE EXISTS (SELECT 1 FROM materiales mt WHERE mt.compra_id = c.id AND mt.fecha_inicio IS NOT NULL)
  GROUP BY c.id, c.codigo, c.valor_total
 HAVING abs(COALESCE(sum(d.costo_proyectado), (0)::numeric) - c.valor_total) > (1)::numeric;

-- La vista de externos: una compra sin proveedor no debe esconderle el material
-- a la agencia de su mercado. Mismas columnas.
CREATE OR REPLACE VIEW public.v_materiales_externos
WITH (security_invoker = false, security_barrier = true)
AS
SELECT
    mt.id,
    (c.codigo || '-' || chr(64 + mt.secuencia)) AS codigo,
    sc.nombre_unico AS sub_campana,
    mt.referencia,
    mt.fecha_inicio,
    mt.fecha_fin,
    mt.enlace,
    mt.reporte_implementacion,
    mt.evidencia_url,
    c.codigo        AS compra,
    p.nombre        AS proveedor,
    c.formato,
    c.ubicacion,
    c.ciudad,
    c.tipo_costo
FROM public.materiales mt
JOIN public.compras     c  ON c.id  = mt.compra_id
LEFT JOIN public.proveedores p  ON p.id  = c.proveedor_id
LEFT JOIN public.campanas sc ON sc.id = mt.sub_campana_id
WHERE mt.compra_id IN (SELECT public.fn_mis_compras());


-- -----------------------------------------------------------------------------
-- 6. Alertas
-- -----------------------------------------------------------------------------

-- Clave para comparar formatos: sin tildes ni signos, y cada palabra en
-- singular (PANTALLAS DIGITALES → PANTALLA DIGITAL, COMERCIALES → COMERCIAL).
CREATE OR REPLACE FUNCTION public.fn_clave_formato(p text)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_limpio text := upper(translate(coalesce(p, ''), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'));
    v_palabra text;
    v_salida text[] := '{}';
BEGIN
    v_limpio := btrim(regexp_replace(regexp_replace(v_limpio, '[^A-Z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'));
    FOREACH v_palabra IN ARRAY string_to_array(v_limpio, ' ') LOOP
        IF length(v_palabra) > 4 AND v_palabra ~ '[LRNDZS]ES$' THEN
            v_palabra := left(v_palabra, -2);
        ELSIF length(v_palabra) > 3 AND v_palabra ~ 'S$' THEN
            v_palabra := left(v_palabra, -1);
        END IF;
        v_salida := v_salida || v_palabra;
    END LOOP;
    RETURN array_to_string(v_salida, ' ');
END;
$$;

-- Mismas cinco columnas de antes y, al final, mercado_id y detalle (lo que
-- hace falta para leer o resolver la alerta sin abrir la compra).
CREATE OR REPLACE VIEW public.v_alertas
WITH (security_invoker = true)
AS
SELECT 'material sin fechas'::text AS alerta,
    ((c.codigo || '-'::text) || chr((64 + mt.secuencia))) AS referencia,
    m.codigo AS mercado, c.id AS compra_id, mt.id AS material_id,
    c.mercado_id, NULL::text AS detalle
FROM materiales mt JOIN compras c ON c.id = mt.compra_id JOIN mercados m ON m.id = c.mercado_id
WHERE mt.fecha_inicio IS NULL
UNION ALL
SELECT 'material sin sub campaña',
    ((c.codigo || '-'::text) || chr((64 + mt.secuencia))),
    m.codigo, c.id, mt.id, c.mercado_id, NULL
FROM materiales mt JOIN compras c ON c.id = mt.compra_id JOIN mercados m ON m.id = c.mercado_id
WHERE mt.sub_campana_id IS NULL
UNION ALL
SELECT 'material fuera del periodo de su compra',
    ((c.codigo || '-'::text) || chr((64 + mt.secuencia))),
    m.codigo, c.id, mt.id, c.mercado_id, NULL
FROM materiales mt JOIN compras c ON c.id = mt.compra_id JOIN mercados m ON m.id = c.mercado_id
WHERE mt.fecha_inicio IS NOT NULL AND (mt.fecha_inicio < c.fecha_inicio OR mt.fecha_fin > c.fecha_fin)
UNION ALL
SELECT 'compra sin materiales', c.codigo, m.codigo, c.id, NULL::bigint, c.mercado_id, NULL
FROM compras c JOIN mercados m ON m.id = c.mercado_id
WHERE NOT EXISTS (SELECT 1 FROM materiales mt WHERE mt.compra_id = c.id)
UNION ALL
SELECT 'sub campaña de otro mercado',
    ((c.codigo || '-'::text) || chr((64 + mt.secuencia))),
    m.codigo, c.id, mt.id, c.mercado_id, NULL
FROM materiales mt JOIN compras c ON c.id = mt.compra_id JOIN mercados m ON m.id = c.mercado_id
     JOIN campanas sc ON sc.id = mt.sub_campana_id
WHERE sc.mercado_id <> c.mercado_id
-- ---- nuevas
UNION ALL
SELECT 'campaña sin taxonomía', c.codigo, m.codigo, c.id, NULL, c.mercado_id, c.campana_texto
FROM compras c JOIN mercados m ON m.id = c.mercado_id
WHERE c.campana_id IS NULL AND c.campana_taxonomia IS NULL
UNION ALL
SELECT 'campaña fuera del glosario', c.codigo, m.codigo, c.id, NULL, c.mercado_id, c.campana_taxonomia
FROM compras c JOIN mercados m ON m.id = c.mercado_id
WHERE c.campana_id IS NULL AND c.campana_taxonomia IS NOT NULL
UNION ALL
SELECT 'compra sin tipo de costo', c.codigo, m.codigo, c.id, NULL, c.mercado_id, NULL
FROM compras c JOIN mercados m ON m.id = c.mercado_id
WHERE c.tipo_costo IS NULL AND NOT (coalesce(c.fuera_de_catalogo, '{}') ? 'tipo_costo')
UNION ALL
-- Sin valor ni tarifa. Las BONIFICADO valen 0 a propósito: no son alerta.
SELECT 'compra sin valor', c.codigo, m.codigo, c.id, NULL, c.mercado_id, NULL
FROM compras c JOIN mercados m ON m.id = c.mercado_id
WHERE c.valor_total = 0 AND c.tarifa_neta = 0 AND c.tipo_compra IS DISTINCT FROM 'BONIFICADO'
UNION ALL
SELECT 'compra incompleta', c.codigo, m.codigo, c.id, NULL, c.mercado_id,
    'sin ' || array_to_string(ARRAY[
        CASE WHEN c.fecha_inicio IS NULL THEN 'fechas' END,
        CASE WHEN c.proveedor_id IS NULL THEN 'proveedor' END,
        CASE WHEN c.formato IS NULL THEN 'formato' END,
        CASE WHEN c.ubicacion IS NULL THEN 'ubicación' END,
        CASE WHEN c.ciudad IS NULL THEN 'ciudad' END,
        CASE WHEN c.medio IS NULL AND NOT (coalesce(c.fuera_de_catalogo, '{}') ? 'medio') THEN 'medio' END,
        CASE WHEN c.tipo_compra IS NULL AND NOT (coalesce(c.fuera_de_catalogo, '{}') ? 'tipo_compra') THEN 'tipo de compra' END,
        CASE WHEN c.cliente IS NULL THEN 'cliente' END
    ], ', ')
FROM compras c JOIN mercados m ON m.id = c.mercado_id
WHERE c.fecha_inicio IS NULL OR c.proveedor_id IS NULL OR c.formato IS NULL OR c.ubicacion IS NULL
   OR c.ciudad IS NULL OR c.cliente IS NULL
   OR (c.medio IS NULL AND NOT (coalesce(c.fuera_de_catalogo, '{}') ? 'medio'))
   OR (c.tipo_compra IS NULL AND NOT (coalesce(c.fuera_de_catalogo, '{}') ? 'tipo_compra'))
UNION ALL
-- Lo que el Sheets trae y el enum no admite. Se va en cuanto alguien elige un
-- valor válido en Compras (la columna deja de estar vacía).
SELECT 'valor fuera de catálogo', c.codigo, m.codigo, c.id, NULL, c.mercado_id, f.detalle
FROM compras c JOIN mercados m ON m.id = c.mercado_id
CROSS JOIN LATERAL (
    SELECT string_agg(replace(k, '_', ' ') || ' «' || v || '»', ', ' ORDER BY k) AS detalle
    FROM jsonb_each_text(c.fuera_de_catalogo) AS e(k, v)
    WHERE (k = 'tipo_compra' AND c.tipo_compra IS NULL)
       OR (k = 'tipo_costo'  AND c.tipo_costo  IS NULL)
       OR (k = 'medio'       AND c.medio       IS NULL)
) f
WHERE c.fuera_de_catalogo IS NOT NULL AND f.detalle IS NOT NULL
UNION ALL
-- Formatos con la misma clave (plural, tildes, signos) en un mercado.
SELECT 'formatos parecidos', g.formatos, m.codigo, NULL, NULL, g.mercado_id, g.detalle
FROM (
    SELECT mercado_id, public.fn_clave_formato(formato) AS clave,
        string_agg(formato, ' / ' ORDER BY formato) AS formatos,
        string_agg(formato || ': ' || n, ' · ' ORDER BY formato) AS detalle
    FROM (SELECT mercado_id, formato, count(*) n FROM compras WHERE formato IS NOT NULL GROUP BY 1, 2) f
    GROUP BY 1, 2 HAVING count(*) > 1
) g JOIN mercados m ON m.id = g.mercado_id
UNION ALL
-- Erratas de una letra (PASAELA / PASARELA) que la clave no junta.
SELECT 'formatos parecidos', a.formato || ' / ' || b.formato, m.codigo, NULL, NULL, a.mercado_id,
    a.formato || ': ' || a.n || ' · ' || b.formato || ': ' || b.n
FROM (SELECT mercado_id, formato, count(*) n, public.fn_clave_formato(formato) clave FROM compras WHERE formato IS NOT NULL GROUP BY 1, 2) a
JOIN (SELECT mercado_id, formato, count(*) n, public.fn_clave_formato(formato) clave FROM compras WHERE formato IS NOT NULL GROUP BY 1, 2) b
  ON b.mercado_id = a.mercado_id AND a.formato < b.formato AND a.clave <> b.clave
 AND length(a.clave) >= 6 AND length(b.clave) >= 6
 AND extensions.levenshtein(a.clave, b.clave) = 1
JOIN mercados m ON m.id = a.mercado_id
UNION ALL
SELECT 'proveedores por confirmar',
    (SELECT string_agg(e ->> 'texto', ' / ' ORDER BY e ->> 'texto') FROM jsonb_array_elements(d.valores) e),
    m.codigo, NULL, NULL, d.mercado_id, d.razon
FROM duplicados_propuestos d JOIN mercados m ON m.id = d.mercado_id
WHERE d.tipo = 'PROVEEDOR' AND d.estado = 'PENDIENTE';


-- -----------------------------------------------------------------------------
-- 7. Escribir la taxonomía correcta desde Alertas
-- -----------------------------------------------------------------------------
-- Guarda la equivalencia (la próxima carga ya no da alerta) y corrige las
-- compras del mercado con ese mismo texto. Con permisos del usuario: RLS
-- decide si puede escribir en ese mercado, y la auditoría registra quién.

CREATE OR REPLACE FUNCTION public.fn_asignar_taxonomia(p_mercado_id smallint, p_texto text, p_taxonomia text)
RETURNS integer
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_codigo text;
    v_tax    text;
    v_n      integer;
BEGIN
    IF coalesce((SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'ADMIN'), false) = false
       OR p_mercado_id NOT IN (SELECT public.fn_mis_mercados()) THEN
        RAISE EXCEPTION 'Tu rol no puede corregir campañas en este mercado' USING ERRCODE = '42501';
    END IF;
    SELECT codigo INTO v_codigo FROM mercados WHERE id = p_mercado_id;
    v_tax := public.fn_taxonomia_de_texto(v_codigo, p_taxonomia);
    IF v_tax IS NULL OR v_tax <> upper(btrim(p_taxonomia)) THEN
        RAISE EXCEPTION 'No tiene formato de taxonomía: %_ML_TIPO_ALL_NOMBRE_X', v_codigo USING ERRCODE = '22023';
    END IF;
    IF nullif(btrim(p_texto), '') IS NULL THEN
        RAISE EXCEPTION 'Falta el texto del Flow' USING ERRCODE = '22023';
    END IF;

    INSERT INTO campanas_alias (mercado_id, texto_flow, taxonomia, creado_por)
    VALUES (p_mercado_id, btrim(p_texto), v_tax, (SELECT id FROM public.fn_usuario_actual()))
    ON CONFLICT (mercado_id, upper(btrim(texto_flow))) DO UPDATE
        SET taxonomia = EXCLUDED.taxonomia, creado_por = EXCLUDED.creado_por, creado_en = now();

    UPDATE compras
    SET campana_taxonomia = v_tax,
        campana_id = public.fn_campana_de_taxonomia(p_mercado_id, v_tax),
        actualizado_en = now()
    WHERE mercado_id = p_mercado_id
      AND upper(btrim(campana_texto)) = upper(btrim(p_texto))
      AND campana_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_asignar_taxonomia(smallint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_asignar_taxonomia(smallint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_taxonomia_de_texto(text, text) TO authenticated;

COMMIT;
