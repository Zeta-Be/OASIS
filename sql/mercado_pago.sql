-- =============================================================================
-- OASIS v2.0 — Mercado Pago, paso (a): la taxonomía acepta la BU MP
-- =============================================================================
-- Las campañas de los Flows de Mercado Pago son taxonomías con MP en la segunda
-- pieza (MLC_MP_UF-AW_USUARIOS_CTAPRO_X). La regla solo aceptaba _ML_, así que
-- todas quedaban «campaña sin taxonomía» y las de parque fijo
-- (…_MP_OTH-PF_…) no contaban como OOH.
--
-- Cambia fn_taxonomia_de_texto para aceptar _(ML|MP)_. La usan la carga, la
-- corrección en Alertas (fn_asignar_taxonomia) y el trigger de Compras
-- (fn_compras_campana), así que las tres aceptan MP sin más cambios. Con eso,
-- v_materiales ya pone campana_grupo = 'PARQUE FIJO' a …_MP_OTH-PF_… (mira la
-- tercera pieza) y el dashboard toma la BU de la segunda.
--
-- La misma regla está en la app: reTaxonomia en app/js/compras.js y la
-- validación de app/js/alertas.js. Se cambian igual.
--
-- No cambia ninguna vista ni el contrato con BI. Repetible. Una transacción.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_taxonomia_de_texto(p_mercado text, p_texto text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT t FROM (SELECT upper(split_part(btrim(p_texto), ' ', 1)) AS t) x
    WHERE t ~ ('^' || upper(p_mercado) || '_(ML|MP)_[A-Z0-9-]+(_[A-Z0-9-]+){3,}$')
$$;

-- Mismo trigger de sql/compras_campana.sql; solo cambia el mensaje.
CREATE OR REPLACE FUNCTION public.fn_compras_campana()
RETURNS trigger
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_codigo text;
    v_tax    text;
BEGIN
    IF NEW.campana_taxonomia IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT codigo INTO v_codigo FROM mercados WHERE id = NEW.mercado_id;
    v_tax := public.fn_taxonomia_de_texto(v_codigo, NEW.campana_taxonomia);
    IF v_tax IS NULL OR v_tax <> upper(btrim(NEW.campana_taxonomia)) THEN
        RAISE EXCEPTION 'La campaña tiene que ser una taxonomía %_ML_TIPO_ALL_NOMBRE_X o %_MP_…, en mayúsculas y sin espacios', v_codigo, v_codigo
            USING ERRCODE = '22023';
    END IF;
    NEW.campana_taxonomia := v_tax;
    NEW.campana_id := public.fn_campana_de_taxonomia(NEW.mercado_id, v_tax);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_compras_campana() FROM PUBLIC, anon, authenticated;

COMMIT;
