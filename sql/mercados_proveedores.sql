-- =============================================================================
-- OASIS v2.0 — Varios mercados: proveedores confirmados como iguales
-- =============================================================================
-- Decisión de Nicolás Orjuela (ADMIN), 19 de octubre de 2026, al revisar los
-- dry-runs de la carga de varios mercados:
--
--   MCO  JCDX               → JCDECAUX
--   MCO  PUBLICIDAD BQUILLA → PUBLICIDAD BARRANQUILLA
--   MLC  POWER GRAPHIC      → POWER GRAPHICS
--
-- Quedan como propuestas UNIFICADO en duplicados_propuestos, que es lo que
-- cargar_oasis.py respeta: la próxima carga pasa las compras al nombre
-- canónico y apaga el proveedor absorbido. Este archivo no mueve compras.
-- Lo demás (MASSIVA y variantes, LATIN AD/ADS, PC, WALL STREET) sigue en
-- Alertas para que cada mercado decida.
--
-- Va después de sql/mercados.sql y antes de la carga. Repetible.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    v_nicolas bigint := (SELECT id FROM usuarios WHERE correo = 'nicolas.orjuela@zetabe.com');
    v_razon   text   := 'Confirmado por Nicolás Orjuela (19-10-2026) al revisar la carga de varios mercados.';
    d         record;
    v_id      bigint;
BEGIN
    FOR d IN SELECT * FROM (VALUES
        ('MCO', 'JCDX', 'JCDECAUX'),
        ('MCO', 'PUBLICIDAD BQUILLA', 'PUBLICIDAD BARRANQUILLA'),
        ('MLC', 'POWER GRAPHIC', 'POWER GRAPHICS')
    ) AS t(mercado, variante, canonico)
    LOOP
        -- La propuesta pendiente con exactamente esos dos nombres, si existe.
        UPDATE duplicados_propuestos p
        SET estado = 'UNIFICADO', canonico = d.canonico, resuelto_en = now(), resuelto_por = v_nicolas,
            razon = coalesce(p.razon || ' ', '') || v_razon
        FROM mercados m
        WHERE m.codigo = d.mercado AND p.mercado_id = m.id AND p.tipo = 'PROVEEDOR' AND p.estado = 'PENDIENTE'
          AND (SELECT array_agg(e ->> 'texto' ORDER BY e ->> 'texto') FROM jsonb_array_elements(p.valores) e)
              = (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[d.variante, d.canonico]) x)
        RETURNING p.id INTO v_id;

        -- Si no había, una nueva ya resuelta (repetible: no duplica).
        IF v_id IS NULL THEN
            SELECT p.id INTO v_id FROM duplicados_propuestos p JOIN mercados m ON m.id = p.mercado_id
            WHERE m.codigo = d.mercado AND p.tipo = 'PROVEEDOR' AND p.estado = 'UNIFICADO' AND p.canonico = d.canonico
              AND p.valores @> jsonb_build_array(jsonb_build_object('texto', d.variante));
            IF v_id IS NOT NULL THEN
                CONTINUE;   -- ya estaba
            END IF;
            INSERT INTO duplicados_propuestos (mercado_id, tipo, valores, canonico, confianza, razon, estado, resuelto_en, resuelto_por)
            SELECT m.id, 'PROVEEDOR',
                   jsonb_build_array(jsonb_build_object('texto', d.canonico), jsonb_build_object('texto', d.variante)),
                   d.canonico, 'ALTA', v_razon, 'UNIFICADO', now(), v_nicolas
            FROM mercados m WHERE m.codigo = d.mercado
            RETURNING id INTO v_id;
        END IF;

        INSERT INTO auditoria (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id)
        VALUES ('duplicados_propuestos', v_id, '(proveedor unificado por decisión)', d.mercado || ': ' || d.variante, d.canonico, v_nicolas);
        v_id := NULL;
    END LOOP;
END
$$;

COMMIT;
