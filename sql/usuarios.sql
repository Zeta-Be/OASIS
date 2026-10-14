-- =============================================================================
-- OASIS v2.0 — Pantalla Usuarios: alta y gestión de usuarios por un ADMIN
-- =============================================================================
-- Reemplaza el alta manual en tres pasos (fila en usuarios, filas en
-- usuario_mercados, login en Supabase Auth). La pantalla usuarios.html llama a
-- la Edge Function gestionar-usuarios, que:
--   * con la llave secreta (solo en Secrets) hace lo de Auth: crear el login,
--     bloquearlo o desbloquearlo, poner una contraseña temporal;
--   * con el JWT del ADMIN que llama ejecuta las funciones de abajo, así que la
--     auditoría registra a ese ADMIN, no a un «sistema» anónimo.
--
-- Cada función vuelve a revisar que quien llama sea ADMIN activo: la Edge
-- Function ya lo revisa, esto es la segunda puerta.
--
-- Nuevo: usuarios.debe_cambiar_clave. Con true, el login manda a cambiar la
-- contraseña antes de dejar entrar a cualquier pantalla.
--
-- Depende de sql/fase3_portal.sql (auditoria, fn_auditar).
-- Repetible. Una transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Columna y auditoría de usuarios
-- -----------------------------------------------------------------------------

ALTER TABLE public.usuarios
    ADD COLUMN IF NOT EXISTS debe_cambiar_clave boolean NOT NULL DEFAULT false;

-- Altas, bajas y cambios de usuarios quedan en auditoria (mismo trigger que
-- compras y materiales). usuario_mercados no tiene id propio: sus cambios los
-- registran a mano las funciones de abajo, como campo 'mercados' del usuario.
DROP TRIGGER IF EXISTS auditar ON public.usuarios;
CREATE TRIGGER auditar
    AFTER INSERT OR UPDATE OR DELETE ON public.usuarios
    FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


-- -----------------------------------------------------------------------------
-- 2. Ayudantes
-- -----------------------------------------------------------------------------

-- Corta si quien llama no es ADMIN activo. Devuelve su id.
CREATE OR REPLACE FUNCTION public.fn_exigir_admin()
RETURNS bigint
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_u public.usuarios;
BEGIN
    SELECT * INTO v_u FROM public.fn_usuario_actual();
    IF v_u.id IS NULL OR v_u.rol <> 'ADMIN' THEN
        RAISE EXCEPTION 'Solo un ADMIN puede gestionar usuarios' USING ERRCODE = '42501';
    END IF;
    RETURN v_u.id;
END;
$$;

-- Fila de auditoría escrita a mano (lo que el trigger no ve).
CREATE OR REPLACE FUNCTION public.fn_auditar_usuario(
    p_usuario_id bigint, p_campo text, p_antes text, p_despues text, p_admin bigint
)
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO public.auditoria (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id)
    VALUES ('usuarios', p_usuario_id, p_campo, p_antes, p_despues, p_admin)
$$;

REVOKE ALL ON FUNCTION public.fn_exigir_admin()                                    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.fn_auditar_usuario(bigint, text, text, text, bigint) FROM PUBLIC, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 3. Crear
-- -----------------------------------------------------------------------------
-- La fila va antes que el login: al crearlo, el trigger vincular_usuario_auth
-- completa auth_user_id por el correo. Nace con debe_cambiar_clave = true.
--
-- Reglas: correo con formato válido y que no exista (sin distinguir
-- mayúsculas). PROVEEDOR: proveedor activo obligatorio y sin mercados (su
-- mercado sale del proveedor). ZB, AGENCIA, LECTURA: al menos un mercado.
-- ADMIN: mercados opcionales (ve todos). PLANNING sigue en el enum por
-- compatibilidad, pero ya no se da de alta.

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
        RAISE EXCEPTION 'Elige un rol: Equipo ZB, Agencia, Proveedor, Lectura o Admin' USING ERRCODE = '22023';
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
        IF p_rol <> 'ADMIN' AND cardinality(v_mercados) = 0 THEN
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
        PERFORM public.fn_auditar_usuario(v_u.id, 'mercados', NULL,
            (SELECT string_agg(codigo, ',' ORDER BY id) FROM public.mercados WHERE id = ANY (v_mercados)), v_admin);
    END IF;

    RETURN v_u;
END;
$$;


-- -----------------------------------------------------------------------------
-- 4. Desactivar, reactivar, contraseña temporal, borrar
-- -----------------------------------------------------------------------------

-- activo = false deja al usuario sin acceso a nada en el acto (todas las
-- políticas pasan por fn_usuario_actual, que exige activo). La Edge Function
-- además bloquea el login en Auth. Un ADMIN no se desactiva a sí mismo.
CREATE OR REPLACE FUNCTION public.fn_admin_cambiar_activo(p_usuario_id bigint, p_activo boolean)
RETURNS public.usuarios
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin bigint := public.fn_exigir_admin();
    v_u     public.usuarios;
BEGIN
    IF p_usuario_id = v_admin AND NOT p_activo THEN
        RAISE EXCEPTION 'No puedes desactivarte a ti mismo' USING ERRCODE = '22023';
    END IF;
    UPDATE public.usuarios SET activo = p_activo WHERE id = p_usuario_id RETURNING * INTO v_u;
    IF v_u.id IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario_id USING ERRCODE = '22023';
    END IF;
    RETURN v_u;
END;
$$;

-- Después de poner una contraseña temporal en Auth: obliga a cambiarla al
-- entrar. Queda en auditoría aunque la marca ya estuviera en true.
CREATE OR REPLACE FUNCTION public.fn_admin_marcar_clave_temporal(p_usuario_id bigint)
RETURNS public.usuarios
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin bigint := public.fn_exigir_admin();
    v_u     public.usuarios;
BEGIN
    UPDATE public.usuarios SET debe_cambiar_clave = true WHERE id = p_usuario_id RETURNING * INTO v_u;
    IF v_u.id IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario_id USING ERRCODE = '22023';
    END IF;
    PERFORM public.fn_auditar_usuario(v_u.id, '(contraseña temporal)', NULL, 'generada por ADMIN', v_admin);
    RETURN v_u;
END;
$$;

-- Deshace un alta cuyo login no se pudo crear en Auth. Solo usuarios sin login:
-- uno que ya entró se desactiva, no se borra (conserva su rastro).
CREATE OR REPLACE FUNCTION public.fn_admin_borrar_usuario_sin_login(p_usuario_id bigint)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin bigint := public.fn_exigir_admin();
BEGIN
    DELETE FROM public.usuarios WHERE id = p_usuario_id AND auth_user_id IS NULL AND id <> v_admin;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Solo se borra un usuario sin login; los demás se desactivan' USING ERRCODE = '22023';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_admin_cambiar_activo(bigint, boolean)                              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_admin_marcar_clave_temporal(bigint)                                FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_admin_borrar_usuario_sin_login(bigint)                             FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_cambiar_activo(bigint, boolean)                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_marcar_clave_temporal(bigint)                                TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_borrar_usuario_sin_login(bigint)                             TO authenticated;


-- -----------------------------------------------------------------------------
-- 5. El usuario cambió su contraseña
-- -----------------------------------------------------------------------------
-- La llama la pantalla de cambio de contraseña después de que Auth aceptó la
-- nueva. Cada uno solo apaga su propia marca.

CREATE OR REPLACE FUNCTION public.fn_clave_cambiada()
RETURNS void
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
    UPDATE public.usuarios SET debe_cambiar_clave = false
    WHERE id = (SELECT id FROM public.fn_usuario_actual()) AND debe_cambiar_clave
$$;

REVOKE ALL ON FUNCTION public.fn_clave_cambiada() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_clave_cambiada() TO authenticated;

COMMIT;
