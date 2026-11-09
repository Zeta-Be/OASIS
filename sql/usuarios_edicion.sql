-- =============================================================================
-- OASIS v2.0 — Pantalla Usuarios: editar accesos y tasas de cambio
-- =============================================================================
-- Lo que agrega:
--   1. fn_admin_editar_usuario: un ADMIN cambia nombre, rol, mercados y
--      proveedor de un usuario (el correo no: si cambia, se crea otro usuario).
--      Si cambia el acceso (rol, mercados o proveedor), cierra las sesiones
--      abiertas de ese login para que la pantalla siga los permisos nuevos.
--   2. Reglas de mercados por rol, iguales al crear y al editar:
--        ADMIN y LECTURA  ven todos los mercados: no llevan usuario_mercados;
--        ZB, CLIENTE, AGENCIA (y PLANNING, el antiguo): al menos un mercado;
--        PROVEEDOR: su proveedor (activo); su mercado sale del proveedor.
--      fn_admin_crear_usuario se redefine con esta regla (antes LECTURA exigía
--      un mercado y ADMIN lo aceptaba opcional).
--   3. OASIS nunca queda sin un ADMIN activo: un trigger en usuarios lo impide
--      para cualquier camino (la pantalla, la API o una conexión directa).
--      Además un ADMIN no cambia su propio rol (ni se desactiva, ya existía).
--   4. tasas_cambio: auditoría (el mismo fn_auditar de compras y materiales) y
--      un trigger que no deja borrar la única tasa de un mercado, ni dejarlo
--      sin una tasa que rija hoy.
--
-- Todo queda en auditoria: rol, nombre y proveedor por el trigger auditar de
-- usuarios; los mercados y las sesiones cerradas, a mano, como en el alta.
--
-- Sobre las sesiones: RLS lee la base en cada consulta, así que el acceso a
-- los datos cambia en el acto aunque la sesión siga abierta. Cerrarla sirve
-- para que la pantalla (a qué página manda el login, qué menú muestra) siga el
-- rol nuevo: el token que ya tiene el navegador vale hasta una hora más, pero
-- no se puede renovar y al vencer vuelve al login.
--
-- Depende de sql/usuarios.sql, sql/fase3_portal.sql (auditoria, fn_auditar) y
-- sql/dashboard.sql (tasas_cambio, rol CLIENTE).
-- Repetible. Una transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Ayudantes
-- -----------------------------------------------------------------------------

-- Códigos de mercado separados por coma, para la auditoría ('MCO,MLC').
-- NULL si no hay ninguno.
CREATE OR REPLACE FUNCTION public.fn_codigos_mercados(p_ids smallint[])
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT string_agg(codigo, ',' ORDER BY id) FROM public.mercados WHERE id = ANY (p_ids)
$$;

-- Cierra todas las sesiones de un login: lo mismo que hace cambiar_clave.py.
-- Primero lo que cuelga de cada sesión. Devuelve cuántas sesiones cerró.
CREATE OR REPLACE FUNCTION public.fn_cerrar_sesiones(p_auth_user_id uuid)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    n integer;
BEGIN
    IF p_auth_user_id IS NULL THEN
        RETURN 0;
    END IF;
    DELETE FROM auth.refresh_tokens WHERE user_id = p_auth_user_id::text;
    DELETE FROM auth.mfa_amr_claims
    WHERE session_id IN (SELECT id FROM auth.sessions WHERE user_id = p_auth_user_id);
    DELETE FROM auth.sessions WHERE user_id = p_auth_user_id;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_codigos_mercados(smallint[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_cerrar_sesiones(uuid)        FROM PUBLIC, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 2. Nunca sin un ADMIN activo
-- -----------------------------------------------------------------------------
-- Corta cualquier cambio que deje a OASIS sin ADMIN activo: bajarle el rol,
-- desactivarlo o borrarlo. Bloquea las filas de los ADMIN activos para que dos
-- ADMIN que se quitan el rol al mismo tiempo no se salten la regla.

CREATE OR REPLACE FUNCTION public.fn_usuarios_ultimo_admin()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF OLD.rol = 'ADMIN' AND OLD.activo
       AND (TG_OP = 'DELETE' OR NEW.rol <> 'ADMIN' OR NOT NEW.activo) THEN
        PERFORM 1 FROM public.usuarios WHERE rol = 'ADMIN' AND activo FOR UPDATE;
        IF NOT EXISTS (SELECT 1 FROM public.usuarios WHERE rol = 'ADMIN' AND activo AND id <> OLD.id) THEN
            RAISE EXCEPTION 'OASIS no puede quedar sin un ADMIN activo: % es el último', OLD.correo
                USING ERRCODE = '22023';
        END IF;
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_usuarios_ultimo_admin() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS ultimo_admin ON public.usuarios;
CREATE TRIGGER ultimo_admin
    BEFORE UPDATE OF rol, activo OR DELETE ON public.usuarios
    FOR EACH ROW EXECUTE FUNCTION public.fn_usuarios_ultimo_admin();


-- -----------------------------------------------------------------------------
-- 3. Crear (redefinida): ADMIN y LECTURA sin mercados
-- -----------------------------------------------------------------------------
-- Igual que en sql/usuarios.sql salvo la regla de mercados: ADMIN y LECTURA
-- ven todos, así que no se les guardan (si llegan, se ignoran).

CREATE OR REPLACE FUNCTION public.fn_admin_crear_usuario(
    p_correo       text,
    p_nombre       text,
    p_rol          public.rol_enum,
    p_proveedor_id integer,
    p_mercados     smallint[]
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

    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo, debe_cambiar_clave)
    VALUES (v_correo, v_nombre, p_rol, p_proveedor_id, true, true)
    RETURNING * INTO v_u;

    IF cardinality(v_mercados) > 0 THEN
        INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
        SELECT v_u.id, unnest(v_mercados);
        PERFORM public.fn_auditar_usuario(v_u.id, 'mercados', NULL, public.fn_codigos_mercados(v_mercados), v_admin);
    END IF;

    RETURN v_u;
END;
$$;


-- -----------------------------------------------------------------------------
-- 4. Editar
-- -----------------------------------------------------------------------------
-- Cambia nombre, rol, proveedor y mercados en una sola transacción. El correo
-- no se toca. Reglas (además de las del alta):
--   * un ADMIN no cambia su propio rol;
--   * no se le quita el rol al último ADMIN activo (también lo cuida el
--     trigger ultimo_admin);
--   * PLANNING ya no se asigna, pero quien ya lo tiene se puede editar sin
--     cambiarle el rol;
--   * el proveedor nuevo tiene que estar activo; si no cambia, vale aunque
--     se haya desactivado después (por una unificación, por ejemplo);
--   * al pasar a ADMIN o LECTURA se borran sus usuario_mercados: ven todos y
--     esas filas ya no decidirían nada. Su pantalla abre con el último mercado
--     elegido en el navegador.
-- Si cambia el acceso (rol, proveedor, o mercados en un rol que los usa),
-- cierra las sesiones del login. Devuelve un jsonb:
--   { usuario, mercados, acceso_cambio, sesiones_cerradas }

CREATE OR REPLACE FUNCTION public.fn_admin_editar_usuario(
    p_usuario_id   bigint,
    p_nombre       text,
    p_rol          public.rol_enum,
    p_proveedor_id integer,
    p_mercados     smallint[]
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin       bigint := public.fn_exigir_admin();
    v_nombre      text := btrim(p_nombre);
    v_mercados    smallint[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_mercados, '{}')) ORDER BY 1);
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

    v_merc_antes := ARRAY(SELECT mercado_id FROM public.usuario_mercados
                          WHERE usuario_id = p_usuario_id ORDER BY 1);

    -- Nombre, rol y proveedor: el trigger auditar registra cada campo que cambie.
    UPDATE public.usuarios
    SET nombre = v_nombre,
        rol = p_rol,
        proveedor_id = CASE WHEN p_rol = 'PROVEEDOR' THEN p_proveedor_id END
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
             OR (v_u.rol NOT IN ('ADMIN', 'LECTURA') AND v_mercados IS DISTINCT FROM v_merc_antes);

    IF v_acceso AND v_u.auth_user_id IS NOT NULL THEN
        v_sesiones := public.fn_cerrar_sesiones(v_u.auth_user_id);
        PERFORM public.fn_auditar_usuario(p_usuario_id, '(sesiones cerradas)', NULL, v_sesiones::text, v_admin);
    END IF;

    RETURN jsonb_build_object(
        'usuario', to_jsonb(v_u),
        'mercados', to_jsonb(v_mercados),
        'acceso_cambio', v_acceso,
        'sesiones_cerradas', v_sesiones);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[]) TO authenticated;


-- -----------------------------------------------------------------------------
-- 5. Tasas de cambio: auditoría y no quedarse sin tasa
-- -----------------------------------------------------------------------------
-- Editar una tasa corrige una mal escrita (valor o fecha); un cambio de tasa
-- de verdad se registra agregando otra con su fecha, y así queda la historia.
-- Las dos cosas quedan en auditoria (tabla 'tasas_cambio') con antes y después.

DROP TRIGGER IF EXISTS auditar ON public.tasas_cambio;
CREATE TRIGGER auditar
    AFTER INSERT OR UPDATE OR DELETE ON public.tasas_cambio
    FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();

-- Un mercado no se queda sin tasa:
--   * no se borra su única tasa;
--   * no se borra ni se pasa al futuro la tasa que rige hoy si no queda otra
--     que rija (sin ella, el mercado sale de los totales en USD del dashboard);
--   * una tasa no cambia de mercado: para otro mercado se agrega otra.
CREATE OR REPLACE FUNCTION public.fn_tasas_cambio_minimo()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_codigo text := (SELECT codigo FROM public.mercados WHERE id = OLD.mercado_id);
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.mercado_id <> OLD.mercado_id THEN
        RAISE EXCEPTION 'Una tasa no cambia de mercado: agrega una nueva para el otro' USING ERRCODE = '23514';
    END IF;

    IF TG_OP = 'DELETE' AND NOT EXISTS (
        SELECT 1 FROM public.tasas_cambio WHERE mercado_id = OLD.mercado_id AND id <> OLD.id
    ) THEN
        RAISE EXCEPTION 'No se borra la única tasa de %: corrígela con Editar', v_codigo USING ERRCODE = '23514';
    END IF;

    -- La fila deja de regir hoy (se borra o se pasa al futuro) y no queda otra que rija.
    IF OLD.vigente_desde <= current_date
       AND (TG_OP = 'DELETE' OR NEW.vigente_desde > current_date)
       AND NOT EXISTS (
            SELECT 1 FROM public.tasas_cambio
            WHERE mercado_id = OLD.mercado_id AND id <> OLD.id AND vigente_desde <= current_date) THEN
        RAISE EXCEPTION '% quedaría sin una tasa que rija hoy', v_codigo USING ERRCODE = '23514';
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_tasas_cambio_minimo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS tasas_cambio_minimo ON public.tasas_cambio;
CREATE TRIGGER tasas_cambio_minimo
    BEFORE UPDATE OF mercado_id, vigente_desde OR DELETE ON public.tasas_cambio
    FOR EACH ROW EXECUTE FUNCTION public.fn_tasas_cambio_minimo();

COMMIT;
