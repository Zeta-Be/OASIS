-- =============================================================================
-- OASIS v2.0 — Fase 3: portal externo (PROVEEDOR y AGENCIA)
-- =============================================================================
-- Primera vez que entran usuarios de fuera de ZetaBé. Lo primero es que no vean
-- un peso que no les corresponde:
--
--   * Nada del Flow. Los externos no reciben política sobre compras ni hay
--     vista de compras para ellos. Ven sus materiales como hoy ven el Tracking:
--     v_materiales_externos (dueño postgres) trae las columnas del material y
--     las que el Tracking hereda por VLOOKUP (código de compra, proveedor,
--     formato, ubicación, ciudad, tipo de costo). Ni fechas de la compra, ni
--     tarifas, ni valor total. Es lo único que consulta el portal.
--   * Qué compras son de cada externo vive en un solo lugar: fn_mis_compras().
--     La usan la política de materiales y la vista.
--   * materiales: solo SELECT, sobre los materiales de esas compras.
--   * Escritura: solo por fn_reportar_implementacion (PROVEEDOR) y
--     fn_actualizar_enlace (AGENCIA), que revisan rol y pertenencia.
--   * Las vistas de inversión cruzan materiales con compras: sin compras
--     visibles, un externo recibe cero filas. No se les da nada nuevo.
--   * auditoria: cada cambio en compras y materiales, de cualquier rol.
--
-- Por qué la política de materiales usa fn_mis_compras() y no compras: la
-- subconsulta de una política también pasa por RLS. Un externo no ve ninguna
-- compra, así que «EXISTS (SELECT … FROM compras …)» siempre le daría falso.
--
-- No cambia v_inversion_diaria ni ninguna vista de inversión (contrato con BI).
-- Repetible. Se ejecuta en una sola transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Identidad: mercados de los externos
-- -----------------------------------------------------------------------------
-- PROVEEDOR: el mercado de su proveedor (no usa usuario_mercados).
-- AGENCIA:   sus usuario_mercados, igual que los internos.
-- ADMIN:     todos.
-- Las políticas internas ya exigen rol interno, así que esto no les abre nada.

CREATE OR REPLACE FUNCTION public.fn_mis_mercados()
RETURNS SETOF smallint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT m.id
    FROM public.mercados m
    WHERE public.fn_rol_actual() = 'ADMIN'
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
-- 2. fn_mis_compras: qué compras son de un externo
-- -----------------------------------------------------------------------------
-- PROVEEDOR: las de su proveedor. AGENCIA: las de sus mercados.
-- Solo ids. Para un interno no devuelve nada: ellos leen compras con su RLS.
-- SECURITY DEFINER: lee compras saltándose RLS (el externo no tiene política).

CREATE OR REPLACE FUNCTION public.fn_mis_compras()
RETURNS SETOF bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.id
    FROM public.compras c
    JOIN public.fn_usuario_actual() u
      ON (u.rol = 'PROVEEDOR' AND c.proveedor_id = u.proveedor_id)
      OR (u.rol = 'AGENCIA'   AND c.mercado_id IN (SELECT public.fn_mis_mercados()))
$$;

REVOKE ALL ON FUNCTION public.fn_mis_compras() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_mis_compras() TO authenticated;


-- -----------------------------------------------------------------------------
-- 3. v_materiales_externos: el Tracking de un externo
-- -----------------------------------------------------------------------------
-- security_invoker = false: corre como postgres (salta RLS) y el filtro va
-- dentro de la vista. security_barrier: los filtros que mande el usuario por la
-- API no se evalúan antes que el de la vista.
-- id es la llave del material (las funciones de escritura la piden).
-- Para un interno devuelve cero filas.

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
JOIN public.proveedores p  ON p.id  = c.proveedor_id
LEFT JOIN public.campanas sc ON sc.id = mt.sub_campana_id
WHERE mt.compra_id IN (SELECT public.fn_mis_compras());

ALTER VIEW public.v_materiales_externos OWNER TO postgres;

REVOKE ALL ON public.v_materiales_externos FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_materiales_externos TO authenticated;


-- -----------------------------------------------------------------------------
-- 4. Políticas para externos
-- -----------------------------------------------------------------------------
-- compras: ninguna. Sin política, RLS no deja ver ni tocar ninguna fila.

-- 4.1 materiales: solo lectura, los de sus compras ---------------------------
-- Sin política de INSERT, UPDATE ni DELETE: la única escritura es por funciones.
-- El portal no lee la tabla: lee v_materiales_externos. La política de campanas
-- de abajo sí se apoya en ella.

DROP POLICY IF EXISTS lectura_externos ON public.materiales;
CREATE POLICY lectura_externos ON public.materiales
    FOR SELECT TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) IN ('PROVEEDOR', 'AGENCIA')
        AND compra_id IN (SELECT public.fn_mis_compras())
    );

-- 4.2 campanas: solo las sub campañas de los materiales que ve ---------------
-- El portal muestra el nombre de la sub campaña. La subconsulta a materiales
-- pasa por su RLS: no le da el glosario completo del mercado.

DROP POLICY IF EXISTS lectura_externos ON public.campanas;
CREATE POLICY lectura_externos ON public.campanas
    FOR SELECT TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) IN ('PROVEEDOR', 'AGENCIA')
        AND id IN (SELECT sub_campana_id FROM public.materiales)
    );

-- 4.3 usuarios: cualquier usuario activo lee su propia fila ------------------
-- Antes solo los internos. El login la necesita para saber a dónde mandarlo.

DROP POLICY IF EXISTS lectura_propia ON public.usuarios;
CREATE POLICY lectura_propia ON public.usuarios
    FOR SELECT TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) IS NOT NULL
        AND auth_user_id = (SELECT auth.uid())
    );

-- proveedores, mercados, usuario_mercados, configuracion, duplicados_propuestos:
-- nada para externos. Siguen solo para internos.


-- -----------------------------------------------------------------------------
-- 5. Escritura de externos
-- -----------------------------------------------------------------------------
-- SECURITY DEFINER: actualizan sin pasar por RLS, así que todo el control está
-- aquí: rol, pertenencia del material (fn_mis_compras, la misma regla de la
-- política y la vista) y formato. Tocan solo sus campos.

-- Enlace https:// con dominio y sin espacios. Vacío = null (borra el valor).
CREATE OR REPLACE FUNCTION public.fn_es_url(p text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT p ~* '^https://[^\s/?#]+\.[^\s/?#]+([/?#]\S*)?$' AND length(p) <= 2000
$$;

-- 5.1 PROVEEDOR: reporte de implementación y evidencia -----------------------

CREATE OR REPLACE FUNCTION public.fn_reportar_implementacion(
    p_material_id   bigint,
    p_reporte       text,
    p_evidencia_url text
)
RETURNS public.materiales
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_u       public.usuarios;
    v_reporte text := nullif(btrim(p_reporte), '');
    v_url     text := nullif(btrim(p_evidencia_url), '');
    v_m       public.materiales;
BEGIN
    SELECT * INTO v_u FROM public.fn_usuario_actual();
    IF v_u.id IS NULL OR v_u.rol <> 'PROVEEDOR' OR v_u.proveedor_id IS NULL THEN
        RAISE EXCEPTION 'Solo un proveedor puede reportar la implementación' USING ERRCODE = '42501';
    END IF;

    PERFORM 1 FROM public.materiales
    WHERE id = p_material_id
      AND compra_id IN (SELECT public.fn_mis_compras())
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El material % no existe o no es de tu proveedor', p_material_id USING ERRCODE = '42501';
    END IF;

    IF length(v_reporte) > 2000 THEN
        RAISE EXCEPTION 'El reporte pasa de 2.000 caracteres' USING ERRCODE = '22023';
    END IF;
    IF v_url IS NOT NULL AND NOT public.fn_es_url(v_url) THEN
        RAISE EXCEPTION 'La evidencia tiene que ser un enlace que empiece por https://' USING ERRCODE = '22023';
    END IF;

    UPDATE public.materiales SET
        reporte_implementacion = v_reporte,
        evidencia_url          = v_url,
        actualizado_en         = now()
    WHERE id = p_material_id
    RETURNING * INTO v_m;

    RETURN v_m;
END;
$$;

-- 5.2 AGENCIA: enlace -------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_actualizar_enlace(
    p_material_id bigint,
    p_enlace      text
)
RETURNS public.materiales
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rol    public.rol_enum := public.fn_rol_actual();
    v_enlace text := nullif(btrim(p_enlace), '');
    v_m      public.materiales;
BEGIN
    IF v_rol IS DISTINCT FROM 'AGENCIA' THEN
        RAISE EXCEPTION 'Solo una agencia puede cambiar el enlace desde el portal' USING ERRCODE = '42501';
    END IF;

    PERFORM 1 FROM public.materiales
    WHERE id = p_material_id
      AND compra_id IN (SELECT public.fn_mis_compras())
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El material % no existe o no es de tus mercados', p_material_id USING ERRCODE = '42501';
    END IF;

    IF v_enlace IS NOT NULL AND NOT public.fn_es_url(v_enlace) THEN
        RAISE EXCEPTION 'El enlace tiene que empezar por https://' USING ERRCODE = '22023';
    END IF;

    UPDATE public.materiales SET
        enlace         = v_enlace,
        actualizado_en = now()
    WHERE id = p_material_id
    RETURNING * INTO v_m;

    RETURN v_m;
END;
$$;

-- fn_es_url solo la usan estas dos funciones (corren como postgres).
REVOKE ALL ON FUNCTION public.fn_es_url(text)                                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_reportar_implementacion(bigint, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_actualizar_enlace(bigint, text)             FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_reportar_implementacion(bigint, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_actualizar_enlace(bigint, text)             TO authenticated;


-- -----------------------------------------------------------------------------
-- 6. Auditoría
-- -----------------------------------------------------------------------------
-- Una fila por campo cambiado. Alta y baja: una fila con la fila completa en
-- JSON (campo '(alta)' o '(baja)'). actualizado_en no se registra: cambia en
-- cada guardado y no dice nada. Un número con otra escala (125000000 y
-- 125000000.00) no es un cambio: la carga desde Sheets reescribe así los montos.
-- usuario_id nulo = cambio hecho sin login de la app (carga desde Sheets,
-- conexión directa con postgres).
-- Nadie escribe en la tabla por la API: solo el trigger. Solo ADMIN la lee.

CREATE TABLE IF NOT EXISTS public.auditoria (
    id             bigserial PRIMARY KEY,
    tabla          text        NOT NULL,
    fila_id        bigint      NOT NULL,
    campo          text        NOT NULL,
    valor_anterior text,
    valor_nuevo    text,
    usuario_id     bigint      REFERENCES public.usuarios(id) ON DELETE SET NULL,
    en             timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS auditoria_fila_idx ON public.auditoria (tabla, fila_id, en DESC);
CREATE INDEX IF NOT EXISTS auditoria_en_idx   ON public.auditoria (en DESC);

ALTER TABLE public.auditoria ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.auditoria FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.auditoria TO authenticated;

DROP POLICY IF EXISTS lectura_admin ON public.auditoria;
CREATE POLICY lectura_admin ON public.auditoria
    FOR SELECT TO authenticated
    USING ((SELECT public.fn_rol_actual()) = 'ADMIN');

CREATE OR REPLACE FUNCTION public.fn_auditar()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario bigint := (SELECT id FROM public.fn_usuario_actual());
    v_ant     jsonb;
    v_nue     jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.auditoria (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id)
        VALUES (TG_TABLE_NAME, NEW.id, '(alta)', NULL, to_jsonb(NEW)::text, v_usuario);
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.auditoria (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id)
        VALUES (TG_TABLE_NAME, OLD.id, '(baja)', to_jsonb(OLD)::text, NULL, v_usuario);
        RETURN OLD;
    END IF;

    v_ant := to_jsonb(OLD);
    v_nue := to_jsonb(NEW);
    INSERT INTO public.auditoria (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id)
    SELECT TG_TABLE_NAME, NEW.id, k, v_ant ->> k, v_nue ->> k, v_usuario
    FROM jsonb_object_keys(v_nue) k
    WHERE k <> 'actualizado_en'
      AND CASE
            WHEN jsonb_typeof(v_ant -> k) = 'number' AND jsonb_typeof(v_nue -> k) = 'number'
                THEN (v_ant ->> k)::numeric <> (v_nue ->> k)::numeric
            ELSE (v_ant -> k) IS DISTINCT FROM (v_nue -> k)
          END;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_auditar() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS auditar ON public.compras;
CREATE TRIGGER auditar
    AFTER INSERT OR UPDATE OR DELETE ON public.compras
    FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();

DROP TRIGGER IF EXISTS auditar ON public.materiales;
CREATE TRIGGER auditar
    AFTER INSERT OR UPDATE OR DELETE ON public.materiales
    FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();

COMMIT;
