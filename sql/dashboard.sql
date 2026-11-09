-- =============================================================================
-- OASIS v2.0 — Dashboard regional (app/dashboard.html)
-- =============================================================================
-- Requiere sql/dashboard_enum.sql aplicado antes (rol CLIENTE).
--
-- El dashboard no tiene datos pegados: después del login pide a la base, por
-- estas funciones, solo los mercados del usuario.
--
--   fn_dashboard_portada(año)          tarjetas por mercado: total, OOH, campañas
--   fn_dashboard_mercado(mercado, año) filas agrupadas en el formato del original
--                                      {f, n, c, t, pf, ci, sp, s, r}
--   fn_dashboard_latam(año)            proveedor × tipo de costo × BU × mes por
--                                      mercado, en moneda local y en USD
--
-- Las tres leen la inversión precalculada (inversion_diaria) con lo descriptivo
-- de v_materiales, igual que v_inversion_diaria: no recalculan el reparto.
-- Acceso: ADMIN, LECTURA, ZB y CLIENTE, cada uno con fn_mis_mercados(). AGENCIA,
-- PROVEEDOR, PLANNING o sin login → error 42501.
--
-- La métrica es el costo ejecutado: días con fecha ≤ la fecha de corte de OASIS
-- (configuracion.fecha_corte) o, si está vacía, ≤ hoy en la zona horaria del
-- mercado (mercados.zona_horaria). Así un día que en Chile ya empezó y en UTC
-- todavía no (o al revés) no se corre.
--
-- También: mercados.zona_horaria, mercados.bandera, mercados.ultima_carga (la
-- pone cargar_oasis.py al terminar cada mercado) y la tabla tasas_cambio.
--
-- Repetible. Una transacción. No cambia ninguna vista ni el contrato con BI.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Mercados: zona horaria, bandera y última carga
-- -----------------------------------------------------------------------------

ALTER TABLE public.mercados ADD COLUMN IF NOT EXISTS zona_horaria text NOT NULL DEFAULT 'America/Bogota';
ALTER TABLE public.mercados ADD COLUMN IF NOT EXISTS bandera text;
ALTER TABLE public.mercados ADD COLUMN IF NOT EXISTS ultima_carga timestamptz;

UPDATE public.mercados m SET zona_horaria = v.zona, bandera = v.bandera
FROM (VALUES ('MCO', 'America/Bogota',                 '🇨🇴'),
             ('MLC', 'America/Santiago',               '🇨🇱'),
             ('MLU', 'America/Montevideo',             '🇺🇾'),
             ('MLM', 'America/Mexico_City',            '🇲🇽'),
             ('MLA', 'America/Argentina/Buenos_Aires', '🇦🇷'),
             ('MLB', 'America/Sao_Paulo',              '🇧🇷'),
             ('MPE', 'America/Lima',                   '🇵🇪')) AS v(codigo, zona, bandera)
WHERE m.codigo = v.codigo;

-- Una zona mal escrita haría fallar el dashboard de ese mercado: se valida aquí.
CREATE OR REPLACE FUNCTION public.fn_validar_zona_horaria()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.zona_horaria) THEN
        RAISE EXCEPTION 'Zona horaria desconocida: %', NEW.zona_horaria USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mercados_zona_horaria ON public.mercados;
CREATE TRIGGER mercados_zona_horaria
    BEFORE INSERT OR UPDATE OF zona_horaria ON public.mercados
    FOR EACH ROW EXECUTE FUNCTION public.fn_validar_zona_horaria();

-- Hasta la próxima carga: la última vez que cambió una compra del mercado.
UPDATE public.mercados m
SET ultima_carga = (SELECT max(c.actualizado_en) FROM public.compras c WHERE c.mercado_id = m.id)
WHERE m.ultima_carga IS NULL;


-- -----------------------------------------------------------------------------
-- 2. Tasas de cambio
-- -----------------------------------------------------------------------------
-- Una fila por mercado y fecha de vigencia: cambiar la tasa es agregar una fila
-- nueva, así queda la historia. El dashboard usa la vigente (la de vigente_desde
-- más reciente que no sea futura) para todo el año. Solo ADMIN lee y escribe
-- directo; el dashboard la lee por sus funciones.

CREATE TABLE IF NOT EXISTS public.tasas_cambio (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mercado_id       smallint NOT NULL REFERENCES public.mercados (id),
    moneda           text NOT NULL,
    valor_por_usd    numeric(14, 4) NOT NULL CHECK (valor_por_usd > 0),
    vigente_desde    date NOT NULL DEFAULT current_date,
    actualizado_por  bigint REFERENCES public.usuarios (id),
    actualizado_en   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (mercado_id, vigente_desde)
);

COMMENT ON TABLE public.tasas_cambio IS
    'Moneda local por 1 USD, por mercado y fecha de vigencia. La usa el dashboard para la vista LATAM en USD.';

-- La moneda sale del mercado y el autor del login: no los decide quien escribe.
CREATE OR REPLACE FUNCTION public.fn_tasas_cambio_autor()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    SELECT moneda INTO NEW.moneda FROM public.mercados WHERE id = NEW.mercado_id;
    NEW.actualizado_por := (SELECT id FROM public.fn_usuario_actual());
    NEW.actualizado_en := now();
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_tasas_cambio_autor() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tasas_cambio_autor ON public.tasas_cambio;
CREATE TRIGGER tasas_cambio_autor
    BEFORE INSERT OR UPDATE ON public.tasas_cambio
    FOR EACH ROW EXECUTE FUNCTION public.fn_tasas_cambio_autor();

ALTER TABLE public.tasas_cambio ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tasas_cambio FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.tasas_cambio TO authenticated;

DROP POLICY IF EXISTS admin_todo ON public.tasas_cambio;
CREATE POLICY admin_todo ON public.tasas_cambio
    FOR ALL TO authenticated
    USING ((SELECT public.fn_rol_actual()) = 'ADMIN')
    WITH CHECK ((SELECT public.fn_rol_actual()) = 'ADMIN');

-- Las del dashboard original (TRM), vigentes desde el 1 de enero de 2026.
INSERT INTO public.tasas_cambio (mercado_id, moneda, valor_por_usd, vigente_desde)
SELECT m.id, m.moneda, v.valor, DATE '2026-01-01'
FROM (VALUES ('MLC', 876.19), ('MLU', 40.58), ('MLM', 17.93), ('MCO', 3695.04), ('MLA', 1585.00)) AS v(codigo, valor)
JOIN public.mercados m ON m.codigo = v.codigo
ON CONFLICT (mercado_id, vigente_desde) DO NOTHING;


-- -----------------------------------------------------------------------------
-- 3. Funciones de apoyo
-- -----------------------------------------------------------------------------

-- Solo ADMIN, LECTURA, ZB y CLIENTE activos. Se compara como texto para no
-- depender de que el valor CLIENTE exista al crear la función.
CREATE OR REPLACE FUNCTION public.fn_dashboard_acceso()
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF coalesce(public.fn_rol_actual()::text, '') NOT IN ('ADMIN', 'LECTURA', 'ZB', 'CLIENTE') THEN
        RAISE EXCEPTION 'Tu usuario no tiene acceso al dashboard' USING ERRCODE = '42501';
    END IF;
END;
$$;

-- Último día que cuenta como ejecutado en un mercado.
CREATE OR REPLACE FUNCTION public.fn_dashboard_corte(p_mercado_id smallint)
RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT coalesce(
        nullif((SELECT valor FROM public.configuracion WHERE clave = 'fecha_corte'), '')::date,
        (now() AT TIME ZONE (SELECT zona_horaria FROM public.mercados WHERE id = p_mercado_id))::date)
$$;

-- Filas ejecutadas de un año, con lo descriptivo de v_materiales. BU (ML/MP):
-- la segunda pieza de la taxonomía de la campaña; si la campaña no es
-- taxonomía, la columna CLIENTE de la compra. Textos vacíos como '—'.
-- Interna: la usan las tres funciones del dashboard, que ya filtraron mercados.
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
           CASE WHEN split_part(v.campana, '_', 2) IN ('ML', 'MP') THEN split_part(v.campana, '_', 2)
                ELSE coalesce(nullif(upper(btrim(v.cliente)), ''), '—') END,
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

-- Tasa vigente de cada mercado.
CREATE OR REPLACE FUNCTION public.fn_dashboard_tasas()
RETURNS TABLE (mercado_id smallint, moneda text, valor_por_usd numeric, vigente_desde date)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT DISTINCT ON (tc.mercado_id) tc.mercado_id, tc.moneda, tc.valor_por_usd, tc.vigente_desde
    FROM public.tasas_cambio tc
    WHERE tc.vigente_desde <= current_date
    ORDER BY tc.mercado_id, tc.vigente_desde DESC
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_corte(smallint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_dashboard_filas(smallint[], int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_dashboard_tasas() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_dashboard_acceso() FROM PUBLIC, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4. Funciones del dashboard
-- -----------------------------------------------------------------------------

-- Portada: una tarjeta por mercado del usuario con inversión ejecutada en el año.
CREATE OR REPLACE FUNCTION public.fn_dashboard_portada(p_anio int DEFAULT extract(year FROM current_date)::int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_mercados smallint[];
    v          jsonb;
BEGIN
    PERFORM public.fn_dashboard_acceso();
    SELECT array_agg(id) INTO v_mercados FROM public.mercados WHERE id IN (SELECT public.fn_mis_mercados());

    WITH f AS (SELECT * FROM public.fn_dashboard_filas(v_mercados, p_anio)),
    agg AS (
        SELECT f.mercado_id, sum(f.costo) AS t,
               coalesce(sum(f.costo) FILTER (WHERE f.parque_fijo), 0) AS pf,
               coalesce(sum(f.costo) FILTER (WHERE NOT f.parque_fijo), 0) AS ci,
               count(DISTINCT f.compra_id) AS sp
        FROM f GROUP BY f.mercado_id
    )
    SELECT jsonb_build_object(
        'anio', p_anio,
        'ultima_carga', (SELECT max(ultima_carga) FROM public.mercados WHERE id = ANY (v_mercados)),
        'mercados', coalesce(jsonb_agg(jsonb_build_object(
            'codigo', m.codigo, 'nombre', m.nombre, 'bandera', m.bandera, 'moneda', m.moneda,
            't', round(a.t, 2), 'pf', round(a.pf, 2), 'ci', round(a.ci, 2), 'sp', a.sp,
            'corte', public.fn_dashboard_corte(m.id), 'ultima_carga', m.ultima_carga)
            ORDER BY m.codigo), '[]'::jsonb))
    INTO v
    FROM agg a JOIN public.mercados m ON m.id = a.mercado_id;
    RETURN v;
END;
$$;

-- Un mercado: el formato del original {f, n, c, t, pf, ci, sp, s, r}, con las
-- filas agrupadas. Cada fila r = [mes, semana, prov, tipo_costo, formato,
-- campaña, subcampaña, costo, bu, medio, ciudad]; los textos son índices en s.
CREATE OR REPLACE FUNCTION public.fn_dashboard_mercado(p_mercado text, p_anio int DEFAULT extract(year FROM current_date)::int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_m  public.mercados;
    v    jsonb;
BEGIN
    PERFORM public.fn_dashboard_acceso();
    SELECT * INTO v_m FROM public.mercados WHERE codigo = upper(btrim(p_mercado));
    IF v_m.id IS NULL OR v_m.id NOT IN (SELECT public.fn_mis_mercados()) THEN
        RAISE EXCEPTION 'No tienes acceso al mercado %', p_mercado USING ERRCODE = '42501';
    END IF;

    WITH f AS MATERIALIZED (SELECT * FROM public.fn_dashboard_filas(ARRAY[v_m.id], p_anio)),
    g AS (
        SELECT f.mes, f.semana, f.proveedor, f.tipo_costo, f.formato, f.campana, f.sub_campana,
               f.bu, f.medio, f.ciudad, bool_or(f.parque_fijo) AS pf, sum(f.costo) AS costo
        FROM f
        GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
    ),
    textos AS (
        SELECT x, (row_number() OVER (ORDER BY x) - 1)::int AS i
        FROM (SELECT DISTINCT unnest(ARRAY[proveedor, tipo_costo, formato, campana, sub_campana, bu, medio, ciudad]) AS x FROM g) d
    ),
    idx AS (SELECT jsonb_object_agg(x, i) AS j FROM textos)
    SELECT jsonb_build_object(
        'codigo', v_m.codigo, 'f', v_m.bandera, 'n', v_m.nombre, 'c', v_m.moneda,
        'anio', p_anio, 'corte', public.fn_dashboard_corte(v_m.id), 'ultima_carga', v_m.ultima_carga,
        't',  coalesce(round((SELECT sum(costo) FROM g), 2), 0),
        'pf', coalesce(round((SELECT sum(costo) FROM g WHERE pf), 2), 0),
        'ci', coalesce(round((SELECT sum(costo) FROM g WHERE NOT pf), 2), 0),
        'sp', (SELECT count(DISTINCT compra_id) FROM f),
        's',  coalesce((SELECT jsonb_agg(x ORDER BY i) FROM textos), '[]'::jsonb),
        'r',  coalesce((SELECT jsonb_agg(jsonb_build_array(
                  g.mes, g.semana, (idx.j ->> g.proveedor)::int, (idx.j ->> g.tipo_costo)::int,
                  (idx.j ->> g.formato)::int, (idx.j ->> g.campana)::int, (idx.j ->> g.sub_campana)::int,
                  round(g.costo, 2), (idx.j ->> g.bu)::int, (idx.j ->> g.medio)::int, (idx.j ->> g.ciudad)::int)
                  ORDER BY g.mes, g.semana)
              FROM g, idx), '[]'::jsonb))
    INTO v;
    RETURN v;
END;
$$;

-- LATAM: proveedor × tipo de costo × BU × mes, por mercado, en moneda local y
-- en USD a la tasa vigente. Trae las tasas usadas para mostrarlas.
CREATE OR REPLACE FUNCTION public.fn_dashboard_latam(p_anio int DEFAULT extract(year FROM current_date)::int)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_mercados smallint[];
    v          jsonb;
BEGIN
    PERFORM public.fn_dashboard_acceso();
    SELECT array_agg(id) INTO v_mercados FROM public.mercados WHERE id IN (SELECT public.fn_mis_mercados());

    WITH g AS (
        SELECT f.mercado_id, f.proveedor, f.tipo_costo, f.bu, f.mes, sum(f.costo) AS inv
        FROM public.fn_dashboard_filas(v_mercados, p_anio) f
        GROUP BY 1, 2, 3, 4, 5
    )
    SELECT jsonb_build_object(
        'anio', p_anio,
        'ultima_carga', (SELECT max(ultima_carga) FROM public.mercados WHERE id = ANY (v_mercados)),
        'tasas', coalesce((SELECT jsonb_agg(jsonb_build_object('mercado', m.codigo, 'moneda', tc.moneda,
                              'valor_por_usd', tc.valor_por_usd, 'vigente_desde', tc.vigente_desde) ORDER BY m.codigo)
                           FROM public.fn_dashboard_tasas() tc JOIN public.mercados m ON m.id = tc.mercado_id
                           WHERE tc.mercado_id = ANY (v_mercados)), '[]'::jsonb),
        'filas', coalesce((SELECT jsonb_agg(jsonb_build_object(
                     'prov', g.proveedor, 'tc', g.tipo_costo, 'cli', g.bu, 'mes', g.mes,
                     'pais', m.nombre, 'mercado', m.codigo, 'moneda', m.moneda,
                     'inv', round(g.inv, 2), 'usd', round(g.inv / tc.valor_por_usd, 2))
                     ORDER BY m.codigo, g.mes, g.proveedor)
                   FROM g JOIN public.mercados m ON m.id = g.mercado_id
                   LEFT JOIN public.fn_dashboard_tasas() tc ON tc.mercado_id = g.mercado_id), '[]'::jsonb))
    INTO v;
    RETURN v;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_portada(int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_dashboard_mercado(text, int) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_dashboard_latam(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_portada(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_mercado(text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_latam(int) TO authenticated;

COMMIT;
