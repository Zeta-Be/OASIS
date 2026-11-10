-- =============================================================================
-- OASIS v2.0 — Vistas adicionales por usuario (rol Cliente: Materiales)
-- =============================================================================
-- Un Cliente ve solo el dashboard. Con esta migración un ADMIN puede habilitarle
-- pantallas adicionales, una por una, en usuarios.vistas. Hoy existe una sola:
-- 'materiales' (el Tracking, solo lectura). Los demás roles no cambian.
--
--   * usuarios.vistas (text[]): las vistas adicionales del usuario. Qué vistas
--     admite cada rol lo dice fn_vistas_de_rol (hoy: CLIENTE → {materiales};
--     los demás, ninguna) y lo hace cumplir un CHECK. Para sumar otra vista
--     después: agregarla en fn_vistas_de_rol y darle su vista/funciones.
--   * fn_tengo_vista('materiales'): ¿el usuario de la sesión la tiene?
--   * v_materiales_cliente: lo ÚNICO que lee un Cliente de los materiales.
--     Mismo patrón que v_materiales_externos (dueño postgres, security_invoker
--     = false, security_barrier = true): el filtro va dentro de la vista y el
--     Cliente sigue sin ninguna política sobre compras ni materiales (las
--     tablas base le dan 0 filas). Devuelve filas solo si el usuario tiene la
--     vista 'materiales', y solo de sus mercados (fn_mis_mercados).
--     Columnas: las del Tracking, más la taxonomía del material, con la misma
--     función que v_materiales (fn_taxonomia_material, sql/taxonomia_funcion.sql,
--     que va ANTES de esta migración): una sola definición.
--     NADA financiero: ni tarifa, ni descuento, ni
--     cantidad, ni valor total, ni costo, ni fechas de la compra. Agregar una
--     columna aquí es decidir mostrársela al cliente.
--   * Evidencias: fn_veo_material gana la rama CLIENTE (con la vista y en sus
--     mercados), así que lee las filas de `evidencias` y los archivos de esos
--     materiales, como la agencia. No sube ni borra (esas políticas nombran
--     PROVEEDOR y ADMIN).
--   * fn_admin_crear_usuario y fn_admin_editar_usuario reciben p_vistas.
--     Cambiar las vistas cuenta como cambio de acceso: cierra las sesiones y
--     queda en auditoría (campo vistas, antes y después, con el ADMIN).
--     Si el rol deja de admitir la vista (Cliente → otro rol), se vacía.
--
-- Compatible con la Edge Function ya desplegada (p_vistas tiene DEFAULT).
-- Repetible. Una transacción. No toca las vistas de inversión ni el contrato
-- con BI. Pruebas: sql/cliente_vistas_pruebas.sql (se revierten solas).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. usuarios.vistas y qué vistas admite cada rol
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_vistas_de_rol(p_rol public.rol_enum)
RETURNS text[]
LANGUAGE sql IMMUTABLE
SET search_path = public
AS $$
    SELECT CASE WHEN p_rol = 'CLIENTE' THEN ARRAY['materiales'] ELSE '{}'::text[] END
$$;

ALTER TABLE public.usuarios
    ADD COLUMN IF NOT EXISTS vistas text[] NOT NULL DEFAULT '{}';

ALTER TABLE public.usuarios DROP CONSTRAINT IF EXISTS usuarios_vistas;
ALTER TABLE public.usuarios
    ADD CONSTRAINT usuarios_vistas CHECK (vistas <@ public.fn_vistas_de_rol(rol));

COMMENT ON COLUMN public.usuarios.vistas IS
    'Pantallas adicionales habilitadas (hoy solo Cliente: materiales). Las válidas por rol: fn_vistas_de_rol.';

-- ¿El usuario de la sesión (activo) tiene esta vista adicional?
CREATE OR REPLACE FUNCTION public.fn_tengo_vista(p_vista text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (SELECT 1 FROM public.fn_usuario_actual() u WHERE p_vista = ANY (u.vistas))
$$;

REVOKE ALL ON FUNCTION public.fn_tengo_vista(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_tengo_vista(text) TO authenticated;


-- -----------------------------------------------------------------------------
-- 2. v_materiales_cliente: el Tracking para el Cliente, sin nada financiero
-- -----------------------------------------------------------------------------

DROP VIEW IF EXISTS public.v_materiales_cliente;
CREATE VIEW public.v_materiales_cliente
WITH (security_invoker = false, security_barrier = true) AS
SELECT mt.id,
       c.codigo || '-' || chr(64 + mt.secuencia) AS codigo,
       c.mercado_id,
       m.codigo  AS mercado,
       m.nombre  AS mercado_nombre,
       mt.compra_id,
       c.codigo  AS compra,
       mt.secuencia,
       p.nombre  AS proveedor,
       c.formato,
       c.ubicacion,
       c.ciudad,
       c.tipo_costo,
       sc.nombre_unico AS sub_campana,
       mt.referencia,
       mt.fecha_inicio,
       mt.fecha_fin,
       mt.enlace,
       mt.reporte_implementacion,
       mt.grupo_tramo,
       public.fn_taxonomia_material(
           m.codigo, c.cliente, p.nombre, c.formato, c.ciudad,
           coalesce(ca.nombre_unico, c.campana_taxonomia, c.campana_texto),
           c.ubicacion, sc.nombre_unico, mt.referencia,
           c.codigo || '-' || chr(64 + mt.secuencia)) AS taxonomia
FROM public.materiales mt
JOIN public.compras c ON c.id = mt.compra_id
JOIN public.mercados m ON m.id = c.mercado_id
LEFT JOIN public.proveedores p ON p.id = c.proveedor_id
LEFT JOIN public.campanas sc ON sc.id = mt.sub_campana_id
LEFT JOIN public.campanas ca ON ca.id = c.campana_id
WHERE (SELECT public.fn_tengo_vista('materiales'))
  AND c.mercado_id IN (SELECT public.fn_mis_mercados());

REVOKE ALL ON public.v_materiales_cliente FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_materiales_cliente TO authenticated;

COMMENT ON VIEW public.v_materiales_cliente IS
    'Lo único que un Cliente lee de los materiales: solo con la vista «materiales» y solo sus mercados. Sin columnas financieras.';


-- -----------------------------------------------------------------------------
-- 3. Evidencias: el Cliente con la vista ve las de los materiales de sus mercados
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_veo_material(p_material_id bigint)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.materiales mt
        JOIN public.compras c ON c.id = mt.compra_id
        WHERE mt.id = p_material_id
          AND CASE
                WHEN public.fn_rol_actual() IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN')
                    THEN c.mercado_id IN (SELECT public.fn_mis_mercados())
                WHEN public.fn_rol_actual() IN ('PROVEEDOR', 'AGENCIA')
                    THEN c.id IN (SELECT public.fn_mis_compras())
                WHEN public.fn_rol_actual() = 'CLIENTE'
                    THEN public.fn_tengo_vista('materiales')
                         AND c.mercado_id IN (SELECT public.fn_mis_mercados())
                ELSE false
              END
    )
$$;


-- -----------------------------------------------------------------------------
-- 4. Alta y edición con vistas
-- -----------------------------------------------------------------------------
-- Una sola firma de cada una: con la vieja al lado, la llamada rpc sería ambigua.

DROP FUNCTION IF EXISTS public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[]);
DROP FUNCTION IF EXISTS public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[]);

CREATE OR REPLACE FUNCTION public.fn_admin_crear_usuario(
    p_correo       text,
    p_nombre       text,
    p_rol          public.rol_enum,
    p_proveedor_id integer,
    p_mercados     smallint[],
    p_vistas       text[] DEFAULT NULL
)
RETURNS public.usuarios
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin    bigint := public.fn_exigir_admin();
    v_correo   text := lower(btrim(p_correo));
    v_nombre   text := btrim(p_nombre);
    v_mercados smallint[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_mercados, '{}')) ORDER BY 1);
    v_vistas   text[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_vistas, '{}')) ORDER BY 1);
    v_u        public.usuarios;
BEGIN
    IF v_correo IS NULL OR v_correo !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' THEN
        RAISE EXCEPTION 'El correo no tiene un formato válido' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.usuarios WHERE lower(correo) = v_correo) THEN
        RAISE EXCEPTION 'Ya existe un usuario con el correo %', v_correo USING ERRCODE = '23505';
    END IF;
    IF v_nombre IS NULL OR v_nombre = '' THEN
        RAISE EXCEPTION 'Falta el nombre' USING ERRCODE = '22023';
    END IF;
    IF p_rol IS NULL OR p_rol = 'PLANNING' THEN
        RAISE EXCEPTION 'Elige un rol: Equipo ZB, Agencia, Proveedor, Lectura, Cliente o Admin' USING ERRCODE = '22023';
    END IF;

    IF p_rol = 'PROVEEDOR' THEN
        IF p_proveedor_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM public.proveedores WHERE id = p_proveedor_id AND activo
        ) THEN
            RAISE EXCEPTION 'Un proveedor necesita su proveedor (activo)' USING ERRCODE = '22023';
        END IF;
        v_mercados := '{}';
    ELSE
        IF p_proveedor_id IS NOT NULL THEN
            RAISE EXCEPTION 'Solo el rol Proveedor lleva proveedor' USING ERRCODE = '22023';
        END IF;
        IF p_rol IN ('ADMIN', 'LECTURA') THEN
            v_mercados := '{}';
        ELSIF cardinality(v_mercados) = 0 THEN
            RAISE EXCEPTION 'Elige al menos un mercado' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM unnest(v_mercados) m WHERE m NOT IN (SELECT id FROM public.mercados)) THEN
            RAISE EXCEPTION 'Hay un mercado que no existe' USING ERRCODE = '22023';
        END IF;
    END IF;

    IF NOT v_vistas <@ public.fn_vistas_de_rol(p_rol) THEN
        RAISE EXCEPTION 'Ese rol no admite las vistas adicionales pedidas (%)', array_to_string(v_vistas, ', ')
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo, debe_cambiar_clave, vistas)
    VALUES (v_correo, v_nombre, p_rol, p_proveedor_id, true, true, v_vistas)
    RETURNING * INTO v_u;

    IF cardinality(v_mercados) > 0 THEN
        INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
        SELECT v_u.id, unnest(v_mercados);
        PERFORM public.fn_auditar_usuario(v_u.id, 'mercados', NULL, public.fn_codigos_mercados(v_mercados), v_admin);
    END IF;

    RETURN v_u;
END;
$$;

-- p_vistas NULL = no tocar las vistas (si el rol no cambia). Con otro rol, o si
-- el rol nuevo no las admite, quedan vacías.
CREATE OR REPLACE FUNCTION public.fn_admin_editar_usuario(
    p_usuario_id   bigint,
    p_nombre       text,
    p_rol          public.rol_enum,
    p_proveedor_id integer,
    p_mercados     smallint[],
    p_vistas       text[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin       bigint := public.fn_exigir_admin();
    v_nombre      text := btrim(p_nombre);
    v_mercados    smallint[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_mercados, '{}')) ORDER BY 1);
    v_vistas      text[];
    v_antes       public.usuarios;
    v_u           public.usuarios;
    v_merc_antes  smallint[];
    v_acceso      boolean;
    v_sesiones    integer := 0;
BEGIN
    SELECT * INTO v_antes FROM public.usuarios WHERE id = p_usuario_id FOR UPDATE;
    IF v_antes.id IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario_id USING ERRCODE = '22023';
    END IF;
    IF v_nombre IS NULL OR v_nombre = '' THEN
        RAISE EXCEPTION 'Falta el nombre' USING ERRCODE = '22023';
    END IF;
    IF p_rol IS NULL THEN
        RAISE EXCEPTION 'Elige el rol' USING ERRCODE = '22023';
    END IF;
    IF p_rol = 'PLANNING' AND v_antes.rol <> 'PLANNING' THEN
        RAISE EXCEPTION 'El rol Planning ya no se asigna: usa Equipo ZB' USING ERRCODE = '22023';
    END IF;
    IF p_usuario_id = v_admin AND p_rol <> v_antes.rol THEN
        RAISE EXCEPTION 'No puedes cambiar tu propio rol: pídeselo a otro ADMIN' USING ERRCODE = '22023';
    END IF;
    IF v_antes.rol = 'ADMIN' AND v_antes.activo AND p_rol <> 'ADMIN'
       AND NOT EXISTS (SELECT 1 FROM public.usuarios WHERE rol = 'ADMIN' AND activo AND id <> v_antes.id) THEN
        RAISE EXCEPTION 'OASIS no puede quedar sin un ADMIN activo: % es el último', v_antes.correo
            USING ERRCODE = '22023';
    END IF;

    IF p_rol = 'PROVEEDOR' THEN
        IF p_proveedor_id IS NULL THEN
            RAISE EXCEPTION 'Un proveedor necesita su proveedor' USING ERRCODE = '22023';
        END IF;
        IF p_proveedor_id IS DISTINCT FROM v_antes.proveedor_id
           AND NOT EXISTS (SELECT 1 FROM public.proveedores WHERE id = p_proveedor_id AND activo) THEN
            RAISE EXCEPTION 'El proveedor elegido no existe o está inactivo' USING ERRCODE = '22023';
        END IF;
        v_mercados := '{}';
    ELSE
        IF p_proveedor_id IS NOT NULL THEN
            RAISE EXCEPTION 'Solo el rol Proveedor lleva proveedor' USING ERRCODE = '22023';
        END IF;
        IF p_rol IN ('ADMIN', 'LECTURA') THEN
            v_mercados := '{}';
        ELSIF cardinality(v_mercados) = 0 THEN
            RAISE EXCEPTION 'Elige al menos un mercado' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM unnest(v_mercados) m WHERE m NOT IN (SELECT id FROM public.mercados)) THEN
            RAISE EXCEPTION 'Hay un mercado que no existe' USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Vistas adicionales: las pedidas; sin pedir, las que tenía si el rol sigue igual.
    IF p_vistas IS NOT NULL THEN
        v_vistas := ARRAY(SELECT DISTINCT unnest(p_vistas) ORDER BY 1);
        IF NOT v_vistas <@ public.fn_vistas_de_rol(p_rol) THEN
            RAISE EXCEPTION 'Ese rol no admite las vistas adicionales pedidas (%)', array_to_string(v_vistas, ', ')
                USING ERRCODE = '22023';
        END IF;
    ELSIF p_rol = v_antes.rol THEN
        v_vistas := v_antes.vistas;
    ELSE
        v_vistas := '{}';
    END IF;

    v_merc_antes := ARRAY(SELECT mercado_id FROM public.usuario_mercados
                          WHERE usuario_id = p_usuario_id ORDER BY 1);

    -- Nombre, rol, proveedor y vistas: el trigger auditar registra cada campo que cambie.
    UPDATE public.usuarios
    SET nombre = v_nombre,
        rol = p_rol,
        proveedor_id = CASE WHEN p_rol = 'PROVEEDOR' THEN p_proveedor_id END,
        vistas = v_vistas
    WHERE id = p_usuario_id
    RETURNING * INTO v_u;

    -- Mercados: solo la diferencia; en auditoría, antes y después.
    IF v_mercados IS DISTINCT FROM v_merc_antes THEN
        DELETE FROM public.usuario_mercados
        WHERE usuario_id = p_usuario_id AND mercado_id <> ALL (v_mercados);
        INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
        SELECT p_usuario_id, m FROM unnest(v_mercados) m
        ON CONFLICT DO NOTHING;
        PERFORM public.fn_auditar_usuario(p_usuario_id, 'mercados',
            public.fn_codigos_mercados(v_merc_antes), public.fn_codigos_mercados(v_mercados), v_admin);
    END IF;

    -- ¿Cambió lo que puede ver? Para ADMIN y LECTURA los mercados no cuentan.
    v_acceso := v_u.rol IS DISTINCT FROM v_antes.rol
             OR v_u.proveedor_id IS DISTINCT FROM v_antes.proveedor_id
             OR v_u.vistas IS DISTINCT FROM v_antes.vistas
             OR (v_u.rol NOT IN ('ADMIN', 'LECTURA') AND v_mercados IS DISTINCT FROM v_merc_antes);

    IF v_acceso AND v_u.auth_user_id IS NOT NULL THEN
        v_sesiones := public.fn_cerrar_sesiones(v_u.auth_user_id);
        PERFORM public.fn_auditar_usuario(p_usuario_id, '(sesiones cerradas)', NULL, v_sesiones::text, v_admin);
    END IF;

    RETURN jsonb_build_object(
        'usuario', to_jsonb(v_u),
        'mercados', to_jsonb(v_mercados),
        'vistas', to_jsonb(v_u.vistas),
        'acceso_cambio', v_acceso,
        'sesiones_cerradas', v_sesiones);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[], text[])   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[], text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[], text[])   TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[], text[]) TO authenticated;

COMMIT;
