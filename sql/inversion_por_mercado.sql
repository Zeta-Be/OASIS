-- Inversión: Total y Semanal de UN mercado, en una sola respuesta.
--
-- Problema (19-11-2026): la pantalla Inversión no cargaba en ningún mercado
-- («canceling statement due to statement timeout»). La pantalla pedía
-- fn_inversion_total() y fn_inversion_semanal() de a 1.000 filas, filtrando el
-- mercado por la API. Esas funciones llevan SET enable_nestloop, lo que impide
-- que Postgres meta el filtro adentro: cada página recalculaba los cinco
-- mercados completos (~3 s cada una desde que entró Mercado Pago y
-- inversion_diaria pasó de ~58 mil a ~184 mil filas). MLM Semanal son ~15
-- páginas en paralelo, más la Total y el resumen: juntas pasaban los 8 s del
-- rol authenticated.
--
-- Arreglo: el mercado entra como parámetro (el filtro se aplica antes de
-- agregar) y las filas vuelven en un solo json, ya ordenadas, sin el tope de
-- 1.000 filas de la API. SECURITY INVOKER: RLS aplica igual que antes (un
-- usuario sin ese mercado recibe []). Las columnas son las que muestra la
-- pantalla (PESTANAS en app/js/inversion.js) más campana_grupo.
--
-- fn_inversion_total() y fn_inversion_semanal() sin parámetros siguen
-- existiendo (las usan las pruebas); la pantalla ya no.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_inversion_total_mercado(p_mercado smallint)
 RETURNS json
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
 SET enable_nestloop TO 'off'
AS $function$
    SELECT coalesce(json_agg(r ORDER BY r.site, r.id_ejecucion), '[]'::json)
    FROM (
        SELECT site, bu, proveedor, tipo_costo, formato, valor_total, id, id_ejecucion,
               campana, sub_campana, fecha_inicio, fecha_fin, dias, pct_participacion,
               costo_proyectado, costo_ejecutado, mes_compra, moneda, campana_grupo
        FROM v_inversion_total
        WHERE mercado_id = p_mercado
    ) r
$function$;

CREATE OR REPLACE FUNCTION public.fn_inversion_semanal_mercado(p_mercado smallint)
 RETURNS json
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
 SET enable_nestloop TO 'off'
AS $function$
    SELECT coalesce(json_agg(r ORDER BY r.site, r.id_ejecucion, r.year, r.month, r.week), '[]'::json)
    FROM (
        SELECT site, bu, year, month, week, proveedor, tipo_costo, formato, valor_total,
               id, id_ejecucion, campana, sub_campana, fecha_inicio, fecha_fin, dias,
               costo_proyectado, costo_ejecutado, mes_compra, moneda, campana_grupo
        FROM v_inversion_semanal
        WHERE mercado_id = p_mercado
    ) r
$function$;

REVOKE ALL ON FUNCTION public.fn_inversion_total_mercado(smallint),
                       public.fn_inversion_semanal_mercado(smallint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_inversion_total_mercado(smallint),
                          public.fn_inversion_semanal_mercado(smallint) TO authenticated;

COMMIT;
