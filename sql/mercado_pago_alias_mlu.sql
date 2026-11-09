-- =============================================================================
-- OASIS v2.0 — Alias de campañas del Flow MP de Uruguay
-- =============================================================================
-- Requiere sql/mercado_pago_alias.sql. El Flow MP de MLU trae tres textos sin
-- taxonomía; estos alias los traducen para que la carga no se frene.
--
--   * PARQUE FIJO: confirmado por Nicolás (09-11-2026).
--   * POINT y CTAREM F2V1: PROVISIONALES (por_confirmar), con la estructura de
--     las campañas MP ya existentes en MLC y MLM (Nicolás, 09-11-2026); se corrigen
--     desde Alertas («Taxonomías por confirmar») cuando el equipo de Uruguay
--     confirme, y las compras ya cargadas se re-apuntan solas.
--
-- ORDEN: aplicar solo después de redesplegar el job diario (el cargador debe
-- filtrar alias por BU antes de que exista un alias MP). Repetible: si el
-- alias ya existe, no lo toca.
-- =============================================================================

BEGIN;

INSERT INTO public.campanas_alias (mercado_id, bu, texto_flow, taxonomia, por_confirmar, nota)
SELECT m.id, 'MP', v.texto, v.taxonomia, v.pc, v.nota
FROM (VALUES
    ('PARQUE FIJO',  'MLU_MP_OTH-PF_USUARIOS_PARQUE-FIJO_X', false, NULL),
    ('POINT',        'MLU_MP_UF-CON_ALLS_POINTSMART_X',      true,
     'Estructura de MLC_MP_UF-CON_ALLS_TUNEG-02_X y MLM_MP_UF-CON_ALLS_CTA-NEG-LANZ_X (decisión de Nicolás, 09-11-2026); confirmar con el equipo de Uruguay'),
    ('CTAREM F2V1',  'MLU_MP_UF-AW_USUARIOS_CTAREM-2_X',     true,
     'Estructura de MLC_MP_UF-AW_USUARIOS_CUENTAREM_X (cuenta remunerada); el nombre CTAREM-2 sale de las fechas del Glosario (decisión de Nicolás, 09-11-2026); confirmar con el equipo de Uruguay')
) AS v(texto, taxonomia, pc, nota)
JOIN public.mercados m ON m.codigo = 'MLU'
ON CONFLICT (mercado_id, bu, upper(btrim(texto_flow))) DO NOTHING;

COMMIT;
