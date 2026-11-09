-- =============================================================================
-- OASIS v2.0 — La portada del dashboard trae las tasas de cambio
-- =============================================================================
-- Decisión de Nicolás (09-11-2026): el bloque de KPIs de la portada muestra los
-- totales regionales EN USD a la tasa vigente (nunca sumando monedas locales),
-- con la nota «a TRM del dd/mm/aaaa»; las tarjetas por país siguen en su moneda.
--
-- Para eso fn_dashboard_portada devuelve también `tasas`, con el mismo formato
-- que fn_dashboard_latam: [{mercado, moneda, valor_por_usd, vigente_desde}],
-- solo de los mercados del usuario. El total en USD lo arma la página; un
-- mercado sin tasa vigente no entra y se avisa, como en LATAM.
--
-- Repetible. Una transacción. No cambia vistas ni el contrato con BI.
-- =============================================================================

BEGIN;

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
        'tasas', coalesce((SELECT jsonb_agg(jsonb_build_object('mercado', m.codigo, 'moneda', tc.moneda,
                              'valor_por_usd', tc.valor_por_usd, 'vigente_desde', tc.vigente_desde) ORDER BY m.codigo)
                           FROM public.fn_dashboard_tasas() tc JOIN public.mercados m ON m.id = tc.mercado_id
                           WHERE tc.mercado_id = ANY (v_mercados)), '[]'::jsonb),
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

COMMIT;
