-- =============================================================================
-- OASIS v2.0 — Mercado Pago, paso (b): campanas_alias por BU
-- =============================================================================
-- Requiere sql/mercado_pago.sql (paso a). El mismo texto del Flow puede
-- significar campañas distintas según la BU: en MLU, «PARQUE FIJO» es
-- MLU_ML_OTH-PF_ALL_PARQUE-FIJO_X en el Flow de Mercado Libre y será una
-- taxonomía MP en el de Mercado Pago. Por eso:
--
--   * campanas_alias gana la columna bu (ML o MP) y su llave única pasa a ser
--     mercado + BU + texto: los dos «PARQUE FIJO» conviven sin pisarse;
--   * fn_asignar_taxonomia saca la BU de la segunda pieza de la taxonomía (la
--     pantalla Alertas no cambia: sigue mandando solo la taxonomía). Con
--     p_bu explícito, exige que coincida. Corrige solo las compras de esa BU:
--     una compra es MP cuando su columna CLIENTE dice MP; lo demás es ML.
--     La firma vieja de 3 argumentos se elimina: dos firmas a la vez dejarían
--     ambigua la llamada rpc de la pantalla.
--
-- cargar_oasis.py lee los alias filtrando bu = 'ML' en cuanto ve la columna
-- (los Flows que carga hoy son de Mercado Libre; la carga MP la pasará como
-- parámetro cuando exista).
--
-- ORDEN AL APLICAR: (1) esta migración; (2) redesplegar el job diario, para
-- que el cargador filtre por BU; (3) recién entonces crear alias MP (los de
-- MLU). Un alias MP creado antes de (2) podría pisar al ML en la carga.
--
-- Ojo: si un mismo texto queda sin taxonomía en las dos BUs, la corrección en
-- Alertas se hace dos veces, una por BU (la pantalla agrupa por texto).
--
-- No cambia ninguna vista ni el contrato con BI. Repetible. Una transacción.
-- =============================================================================

BEGIN;

ALTER TABLE public.campanas_alias
    ADD COLUMN IF NOT EXISTS bu text NOT NULL DEFAULT 'ML' CHECK (bu IN ('ML', 'MP'));

-- Los alias existentes toman la BU de su taxonomía (hoy, todos ML).
UPDATE public.campanas_alias
SET bu = split_part(taxonomia, '_', 2)
WHERE split_part(taxonomia, '_', 2) IN ('ML', 'MP') AND bu <> split_part(taxonomia, '_', 2);

DROP INDEX IF EXISTS public.campanas_alias_texto;
CREATE UNIQUE INDEX IF NOT EXISTS campanas_alias_texto
    ON public.campanas_alias (mercado_id, bu, upper(btrim(texto_flow)));

-- Una sola firma: con la de 3 argumentos al lado, la llamada de la pantalla
-- (rpc con nombres) sería ambigua para PostgREST.
DROP FUNCTION IF EXISTS public.fn_asignar_taxonomia(smallint, text, text);

CREATE OR REPLACE FUNCTION public.fn_asignar_taxonomia(
    p_mercado_id smallint, p_texto text, p_taxonomia text, p_bu text DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql VOLATILE
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_codigo text;
    v_tax    text;
    v_bu     text;
    v_n      integer;
BEGIN
    IF coalesce((SELECT public.fn_rol_actual()) IN ('PLANNING', 'ZB', 'ADMIN'), false) = false
       OR p_mercado_id NOT IN (SELECT public.fn_mis_mercados()) THEN
        RAISE EXCEPTION 'Tu rol no puede corregir campañas en este mercado' USING ERRCODE = '42501';
    END IF;
    SELECT codigo INTO v_codigo FROM mercados WHERE id = p_mercado_id;
    v_tax := public.fn_taxonomia_de_texto(v_codigo, p_taxonomia);
    IF v_tax IS NULL OR v_tax <> upper(btrim(p_taxonomia)) THEN
        RAISE EXCEPTION 'No tiene formato de taxonomía: %_ML_TIPO_ALL_NOMBRE_X (o %_MP_…)', v_codigo, v_codigo
            USING ERRCODE = '22023';
    END IF;
    v_bu := split_part(v_tax, '_', 2);
    IF p_bu IS NOT NULL AND upper(btrim(p_bu)) <> v_bu THEN
        RAISE EXCEPTION 'La taxonomía es de % y el alias se pidió para %', v_bu, upper(btrim(p_bu))
            USING ERRCODE = '22023';
    END IF;
    IF nullif(btrim(p_texto), '') IS NULL THEN
        RAISE EXCEPTION 'Falta el texto del Flow' USING ERRCODE = '22023';
    END IF;

    INSERT INTO campanas_alias (mercado_id, bu, texto_flow, taxonomia, creado_por)
    VALUES (p_mercado_id, v_bu, btrim(p_texto), v_tax, (SELECT id FROM public.fn_usuario_actual()))
    ON CONFLICT (mercado_id, bu, upper(btrim(texto_flow))) DO UPDATE
        SET taxonomia = EXCLUDED.taxonomia, creado_por = EXCLUDED.creado_por, creado_en = now();

    -- Corrige solo las compras de esa BU en el mercado.
    UPDATE compras
    SET campana_taxonomia = v_tax,
        campana_id = public.fn_campana_de_taxonomia(p_mercado_id, v_tax),
        actualizado_en = now()
    WHERE mercado_id = p_mercado_id
      AND upper(btrim(campana_texto)) = upper(btrim(p_texto))
      AND campana_id IS NULL
      AND CASE WHEN upper(btrim(cliente)) = 'MP' THEN 'MP' ELSE 'ML' END = v_bu;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_asignar_taxonomia(smallint, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_asignar_taxonomia(smallint, text, text, text) TO authenticated;

COMMIT;
