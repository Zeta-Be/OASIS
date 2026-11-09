-- =============================================================================
-- OASIS v2.0 — Inversión precalculada
-- =============================================================================
-- Con cinco mercados, v_inversion_diaria (casi 60.000 filas) se calculaba
-- completa en cada consulta: repartir cada material día por día con dos
-- funciones de ventana. La pantalla lanza muchas consultas a la vez y alguna
-- pasaba los 8 s de authenticated («canceling statement due to statement
-- timeout»).
--
--   1. Tabla inversion_diaria: el reparto ya calculado, una fila por material y
--      día. Guarda solo lo caro de calcular (costo proyectado y % de
--      participación) y las llaves. Lo descriptivo (proveedor, campaña,
--      formato, moneda…) y lo que depende de la fecha (estado, costo
--      ejecutado) lo pone la vista al leer: así no queda viejo cuando se
--      unifica un proveedor, cambia el glosario o simplemente pasa un día.
--   2. fn_recalcular_inversion(compra): reescribe solo las filas de esa
--      compra, con la misma regla de reparto de siempre (CLAUDE.md, «Reparto
--      de inversión»). Triggers en compras y materiales la llaman; la carga la
--      apaga mientras escribe y recalcula su mercado al final.
--   3. v_inversion_diaria: misma vista, mismas 22 columnas en el mismo orden
--      (contrato con BI), ahora sobre la tabla. Semanal y total siguen
--      agregándose desde ella; v_cuadre lee la tabla directo.
--   4. RLS en la tabla: internos de sus mercados (ADMIN y LECTURA, todos).
--      Externos: 0 filas. BI se conecta como postgres y no se ve afectado.
--   5. Para la pantalla: fn_inversion_filtrada (las filas de un mercado con
--      los filtros, para paginar y exportar) y fn_inversion_resumen (los
--      agregados para KPIs y gráficos, sin traer filas).
--
-- No cambia la regla de reparto: el cálculo es el mismo SQL de antes, ahora
-- por compra. sql/inversion_pruebas.sql lo compara contra la fórmula vieja.
-- Repetible. Una transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. La tabla
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.inversion_diaria (
    material_id       bigint   NOT NULL REFERENCES public.materiales(id) ON DELETE CASCADE,
    fecha             date     NOT NULL,
    compra_id         bigint   NOT NULL REFERENCES public.compras(id) ON DELETE CASCADE,
    mercado_id        smallint NOT NULL REFERENCES public.mercados(id),
    costo_proyectado  numeric  NOT NULL,
    pct_participacion numeric,
    PRIMARY KEY (material_id, fecha)          -- sirve también como índice por material
);
CREATE INDEX IF NOT EXISTS inversion_diaria_mercado_fecha ON public.inversion_diaria (mercado_id, fecha);
CREATE INDEX IF NOT EXISTS inversion_diaria_compra        ON public.inversion_diaria (compra_id);

ALTER TABLE public.inversion_diaria ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inversion_diaria FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.inversion_diaria TO authenticated;

DROP POLICY IF EXISTS lectura_mercado ON public.inversion_diaria;
CREATE POLICY lectura_mercado ON public.inversion_diaria
    FOR SELECT TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN')
        AND mercado_id IN (SELECT public.fn_mis_mercados())
    );


-- -----------------------------------------------------------------------------
-- 2. Recalcular
-- -----------------------------------------------------------------------------
-- El reparto, igual que la vista de antes: cada material ocupa sus días de
-- calendario; el costo de un día de la compra se divide en partes iguales
-- entre los materiales activos ese día; el total de la compra se reparte en
-- proporción a esos pesos. Mismas expresiones y mismo redondeo a centavos.
-- Corre como postgres (SECURITY DEFINER): quien edita un material no puede
-- escribir en la tabla, pero su cambio sí la tiene que actualizar.

CREATE OR REPLACE FUNCTION public.fn_recalcular_inversion_compras(p_compras bigint[])
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_n integer;
BEGIN
    -- Una compra a la vez: dos ediciones simultáneas de la misma compra se
    -- esperan en vez de chocar al escribir las mismas filas.
    PERFORM 1 FROM compras WHERE id = ANY (p_compras) ORDER BY id FOR UPDATE;
    DELETE FROM inversion_diaria WHERE compra_id = ANY (p_compras);

    WITH dias AS (
        SELECT mt.id AS material_id, mt.compra_id, (d.d)::date AS fecha
        FROM materiales mt
        CROSS JOIN LATERAL generate_series(mt.fecha_inicio::timestamptz, mt.fecha_fin::timestamptz, '1 day'::interval) d(d)
        WHERE mt.fecha_inicio IS NOT NULL AND mt.compra_id = ANY (p_compras)
    ), pesos AS (
        SELECT d.material_id, d.compra_id, d.fecha,
               1.0 / (count(*) OVER (PARTITION BY d.compra_id, d.fecha))::numeric AS peso
        FROM dias d
    ), normalizado AS (
        SELECT p.*, sum(p.peso) OVER (PARTITION BY p.compra_id) AS peso_compra
        FROM pesos p
    )
    INSERT INTO inversion_diaria (material_id, fecha, compra_id, mercado_id, costo_proyectado, pct_participacion)
    SELECT n.material_id, n.fecha, n.compra_id, c.mercado_id,
           round((c.valor_total * n.peso) / n.peso_compra, 2),
           ((c.valor_total * n.peso) / n.peso_compra) / NULLIF(c.valor_total, 0::numeric)
    FROM normalizado n
    JOIN compras c ON c.id = n.compra_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_recalcular_inversion(p_compra_id bigint)
RETURNS integer
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$ SELECT public.fn_recalcular_inversion_compras(ARRAY[p_compra_id]) $$;

-- La carga: todo un mercado de una vez, al final.
CREATE OR REPLACE FUNCTION public.fn_recalcular_inversion_mercado(p_mercado_id smallint)
RETURNS integer
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT public.fn_recalcular_inversion_compras(
        coalesce((SELECT array_agg(id) FROM compras WHERE mercado_id = p_mercado_id), '{}'))
$$;

REVOKE ALL ON FUNCTION public.fn_recalcular_inversion_compras(bigint[])  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_recalcular_inversion(bigint)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_recalcular_inversion_mercado(smallint)  FROM PUBLIC, anon, authenticated;

-- Triggers. La carga pone oasis.sin_recalculo = 'on' en su transacción: así no
-- recalcula la misma compra una vez por cada material que escribe, y al final
-- llama a fn_recalcular_inversion_mercado.
CREATE OR REPLACE FUNCTION public.fn_inversion_al_cambiar()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF current_setting('oasis.sin_recalculo', true) = 'on' THEN
        RETURN NULL;
    END IF;

    IF TG_TABLE_NAME = 'compras' THEN
        PERFORM public.fn_recalcular_inversion(NEW.id);
    ELSIF TG_OP = 'INSERT' THEN
        PERFORM public.fn_recalcular_inversion(NEW.compra_id);
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM public.fn_recalcular_inversion(OLD.compra_id);   -- los demás materiales cambian de peso
    ELSE
        PERFORM public.fn_recalcular_inversion(NEW.compra_id);
        IF OLD.compra_id IS DISTINCT FROM NEW.compra_id THEN
            PERFORM public.fn_recalcular_inversion(OLD.compra_id);
        END IF;
    END IF;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_inversion_al_cambiar() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS inversion_alta ON public.materiales;
CREATE TRIGGER inversion_alta AFTER INSERT ON public.materiales
    FOR EACH ROW EXECUTE FUNCTION public.fn_inversion_al_cambiar();

DROP TRIGGER IF EXISTS inversion_baja ON public.materiales;
CREATE TRIGGER inversion_baja AFTER DELETE ON public.materiales
    FOR EACH ROW EXECUTE FUNCTION public.fn_inversion_al_cambiar();

DROP TRIGGER IF EXISTS inversion_cambio ON public.materiales;
CREATE TRIGGER inversion_cambio AFTER UPDATE OF fecha_inicio, fecha_fin, compra_id ON public.materiales
    FOR EACH ROW
    WHEN (OLD.fecha_inicio IS DISTINCT FROM NEW.fecha_inicio OR OLD.fecha_fin IS DISTINCT FROM NEW.fecha_fin
          OR OLD.compra_id IS DISTINCT FROM NEW.compra_id)
    EXECUTE FUNCTION public.fn_inversion_al_cambiar();

-- Compras: solo cambia el reparto si cambia el valor (o el mercado). Una
-- compra nueva no tiene materiales; una borrada se lleva sus filas (CASCADE).
DROP TRIGGER IF EXISTS inversion_cambio ON public.compras;
CREATE TRIGGER inversion_cambio AFTER UPDATE OF valor_total, mercado_id ON public.compras
    FOR EACH ROW
    WHEN (OLD.valor_total IS DISTINCT FROM NEW.valor_total OR OLD.mercado_id IS DISTINCT FROM NEW.mercado_id)
    EXECUTE FUNCTION public.fn_inversion_al_cambiar();

-- Llenado inicial (todas las compras).
SELECT public.fn_recalcular_inversion_compras((SELECT coalesce(array_agg(id), '{}') FROM public.compras));


-- -----------------------------------------------------------------------------
-- 3. Vistas sobre la tabla
-- -----------------------------------------------------------------------------
-- Mismas 22 columnas, mismo orden y mismos tipos que antes (contrato con BI).
-- estado y costo_ejecutado se calculan al leer con la fecha de corte de hoy.

CREATE OR REPLACE VIEW public.v_inversion_diaria
WITH (security_invoker = true)
AS
WITH corte AS (
    SELECT COALESCE(NULLIF((SELECT valor FROM configuracion WHERE clave = 'fecha_corte'), '')::date, CURRENT_DATE) AS fecha_corte
)
SELECT v.mercado AS site,
    v.cliente AS bu,
    (EXTRACT(year FROM t.fecha))::integer AS year,
    (EXTRACT(month FROM t.fecha))::integer AS month,
    (EXTRACT(week FROM t.fecha))::integer AS week,
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
    CASE WHEN t.fecha <= k.fecha_corte THEN 'EJECUTADO'::text ELSE 'PROGRAMADO'::text END AS estado,
    CASE WHEN t.fecha <= k.fecha_corte THEN t.costo_proyectado ELSE 0::numeric END AS costo_ejecutado,
    (date_trunc('month', cm.fecha_inicio::timestamptz))::date AS mes_compra,
    v.moneda,
    v.mercado_id,
    v.campana_grupo
FROM inversion_diaria t
JOIN v_materiales v ON v.material_id = t.material_id
JOIN compras cm ON cm.id = t.compra_id
CROSS JOIN corte k;

-- v_cuadre directo de la tabla: misma salida, sin pasar por la vista diaria.
CREATE OR REPLACE VIEW public.v_cuadre
WITH (security_invoker = true)
AS
SELECT c.codigo,
    c.valor_total,
    COALESCE(sum(t.costo_proyectado), 0::numeric) AS asignado,
    COALESCE(sum(t.costo_proyectado), 0::numeric) - c.valor_total AS diferencia
FROM compras c
LEFT JOIN inversion_diaria t ON t.compra_id = c.id
WHERE EXISTS (SELECT 1 FROM materiales mt WHERE mt.compra_id = c.id AND mt.fecha_inicio IS NOT NULL)
GROUP BY c.id, c.codigo, c.valor_total
HAVING abs(COALESCE(sum(t.costo_proyectado), 0::numeric) - c.valor_total) > 1::numeric;

-- v_inversion_semanal y v_inversion_total no cambian: se agregan desde
-- v_inversion_diaria, que ya lee la tabla.


-- -----------------------------------------------------------------------------
-- 4. Para la pantalla
-- -----------------------------------------------------------------------------
-- Filtros (jsonb, todos opcionales):
--   ver_por       'ejecucion' (mes del día, por defecto) o 'compra' (mes de compra)
--   meses         ['2026-03', …] en la lectura de ver_por
--   proveedores, tipos_costo, campanas (campana_grupo), sub_campanas
--                 ('__sin__' = sin sub campaña)
-- Con permisos del usuario (RLS): nadie ve lo de un mercado ajeno.

CREATE OR REPLACE FUNCTION public.fn_inversion_filtrada(p_mercado smallint, p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS SETOF public.v_inversion_diaria
LANGUAGE sql STABLE
SET search_path = public
AS $$
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
$$;

-- Agregados para KPIs y gráficos: un mercado, sin traer filas.
--   total        { proyectado, ejecutado }
--   periodos     por mes (o por semana con agrupar = 'semana'), en la lectura de ver_por
--   sub_campanas, proveedores   las barras de los gráficos
--   opciones     valores para los filtros (del mercado completo, sin filtrar)
--   por_material solo con filtro de meses: lo que suma cada material dentro de
--                esos meses (la columna «Costo en el mes» de la pestaña Total)
CREATE OR REPLACE FUNCTION public.fn_inversion_resumen(p_mercado smallint, p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public
AS $$
    WITH f AS (
        SELECT *,
            CASE WHEN p_filtros ->> 'agrupar' = 'semana'
                 THEN to_char(date, 'IYYY-"S"IW')
                 ELSE to_char(CASE WHEN p_filtros ->> 'ver_por' = 'compra' THEN mes_compra ELSE date END, 'YYYY-MM')
            END AS periodo
        FROM public.fn_inversion_filtrada(p_mercado, p_filtros)
    ),
    base AS (
        SELECT proveedor, sub_campana, campana_grupo,
               to_char(CASE WHEN p_filtros ->> 'ver_por' = 'compra' THEN mes_compra ELSE date END, 'YYYY-MM') AS mes
        FROM public.v_inversion_diaria WHERE mercado_id = p_mercado
    )
    SELECT jsonb_build_object(
        'total', (SELECT jsonb_build_object('proyectado', coalesce(sum(costo_proyectado), 0),
                                            'ejecutado',  coalesce(sum(costo_ejecutado), 0)) FROM f),
        'periodos', coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'clave') FROM (
            SELECT jsonb_build_object('clave', periodo, 'proyectado', sum(costo_proyectado), 'ejecutado', sum(costo_ejecutado)) x
            FROM f GROUP BY periodo) s), '[]'),
        'sub_campanas', coalesce((SELECT jsonb_agg(x) FROM (
            SELECT jsonb_build_object('clave', coalesce(sub_campana, ''), 'proyectado', sum(costo_proyectado), 'ejecutado', sum(costo_ejecutado)) x
            FROM f GROUP BY sub_campana) s), '[]'),
        'proveedores', coalesce((SELECT jsonb_agg(x) FROM (
            SELECT jsonb_build_object('clave', coalesce(proveedor, ''), 'proyectado', sum(costo_proyectado), 'ejecutado', sum(costo_ejecutado)) x
            FROM f GROUP BY proveedor) s), '[]'),
        'filas', (SELECT count(*) FROM f),
        'por_material', CASE WHEN jsonb_array_length(coalesce(p_filtros -> 'meses', '[]')) > 0 THEN
            coalesce((SELECT jsonb_object_agg(id_ejecucion, s) FROM (
                SELECT id_ejecucion, sum(costo_proyectado) s FROM f GROUP BY id_ejecucion) x), '{}') END,
        'opciones', (SELECT jsonb_build_object(
            'meses',        coalesce(jsonb_agg(DISTINCT mes) FILTER (WHERE mes IS NOT NULL), '[]'),
            'proveedores',  coalesce(jsonb_agg(DISTINCT proveedor) FILTER (WHERE proveedor IS NOT NULL), '[]'),
            'sub_campanas', coalesce(jsonb_agg(DISTINCT sub_campana) FILTER (WHERE sub_campana IS NOT NULL), '[]'),
            'campanas',     coalesce(jsonb_agg(DISTINCT campana_grupo) FILTER (WHERE campana_grupo IS NOT NULL), '[]'))
          FROM base)
    )
$$;

REVOKE ALL ON FUNCTION public.fn_inversion_filtrada(smallint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_inversion_resumen(smallint, jsonb)  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_inversion_filtrada(smallint, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_inversion_resumen(smallint, jsonb)  TO authenticated;

COMMIT;
