-- =============================================================================
-- OASIS v2.0 — Campaña de la compra elegible en la pantalla Compras
-- =============================================================================
-- La pantalla deja elegir la campaña de una compra (nueva o existente) entre
-- las del mercado, o escribir una taxonomía nueva. Este trigger es la puerta
-- en la base, para que valga igual venga de donde venga (pantalla, carga,
-- corrección en Alertas):
--
--   * si la compra trae taxonomía, tiene que tener el formato del mercado
--     (fn_taxonomia_de_texto, la misma regla de la carga y de Alertas); si no,
--     se rechaza;
--   * con taxonomía, campana_id sale siempre de ella (fn_campana_de_taxonomia):
--     la campaña del glosario a la que apunta, o vacío si el glosario no la
--     tiene (entonces sale la alerta «campaña fuera del glosario»). Así nadie
--     puede dejar una taxonomía apuntando a otra campaña;
--   * sin taxonomía, campana_id es el que venga (una campaña del glosario
--     elegida tal cual).
--
-- No cambia ninguna vista ni el contrato con BI. Repetible. Una transacción.
-- =============================================================================

BEGIN;

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
        RAISE EXCEPTION 'La campaña tiene que ser una taxonomía %_ML_TIPO_ALL_NOMBRE_X, en mayúsculas y sin espacios', v_codigo
            USING ERRCODE = '22023';
    END IF;
    NEW.campana_taxonomia := v_tax;
    NEW.campana_id := public.fn_campana_de_taxonomia(NEW.mercado_id, v_tax);
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_compras_campana() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS compras_campana ON public.compras;
CREATE TRIGGER compras_campana
    BEFORE INSERT OR UPDATE OF campana_taxonomia, campana_id, mercado_id ON public.compras
    FOR EACH ROW EXECUTE FUNCTION public.fn_compras_campana();

COMMIT;
