-- =============================================================================
-- OASIS v2.0 — Pantalla Usuarios: borrar un usuario
-- =============================================================================
-- Borrar es definitivo y por eso tiene dos puertas: solo un ADMIN, y solo un
-- usuario DESACTIVADO (primero Desactivar, después Borrar). Nadie se borra a
-- sí mismo, y el trigger ultimo_admin (sql/usuarios_edicion.sql) ya impide
-- quedarse sin un ADMIN activo por cualquier camino, también por DELETE.
--
-- Qué se lleva el borrado: la fila de usuarios, sus usuario_mercados (CASCADE)
-- y, desde la Edge Function, su login en Auth. Qué queda: la auditoría. El
-- trigger auditar registra la baja como una fila (baja) con el ADMIN que la
-- hizo y el usuario completo en JSON.
--
-- **El rastro del borrado no pierde al autor:** las columnas que apuntan a
-- usuarios(id) (auditoria.usuario_id, evidencias.subido_por,
-- tasas_cambio.actualizado_por, duplicados_propuestos.resuelto_por,
-- campanas_alias.creado_por) pasan a NULL con ON DELETE SET NULL, que aquí se
-- completa donde faltaba, para que ninguna FK impida el DELETE. Pero en la
-- auditoría, antes de borrar, cada fila del usuario queda marcada en la columna
-- nueva usuario_borrado con «nombre · correo (borrado)»: usuario_id en NULL con
-- usuario_borrado vacío sigue siendo «cambio sin login» (la carga).
-- usuario_mercados conserva su CASCADE.
--
-- Excepción documentada: un usuario SIN login (auth_user_id nulo) se puede
-- borrar aunque esté activo. Es el alta a medias: la Edge Function lo usa para
-- deshacer un alta cuyo login no se pudo crear en Auth. Esta función absorbe a
-- fn_admin_borrar_usuario_sin_login, que se elimina.
--
-- Depende de sql/usuarios.sql y sql/usuarios_edicion.sql.
-- Repetible. Una transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Las FKs de rastro hacia usuarios(id) pasan a ON DELETE SET NULL
-- -----------------------------------------------------------------------------
-- Recorre todas las llaves foráneas que apuntan a usuarios y corrige las que no
-- son SET NULL ni CASCADE (todas son de una sola columna). Hoy les falta a
-- tasas_cambio.actualizado_por y duplicados_propuestos.resuelto_por; si mañana
-- se agrega otra columna de rastro sin SET NULL, volver a correr esto la arregla.

DO $fks$
DECLARE
    f record;
BEGIN
    FOR f IN
        SELECT c.conrelid::regclass AS tabla, c.conname,
               (SELECT a.attname FROM pg_attribute a
                WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) AS columna
        FROM pg_constraint c
        WHERE c.contype = 'f'
          AND c.confrelid = 'public.usuarios'::regclass
          AND c.confdeltype NOT IN ('n', 'c')   -- ni SET NULL ni CASCADE
    LOOP
        EXECUTE format('ALTER TABLE %s ALTER COLUMN %I DROP NOT NULL', f.tabla, f.columna);
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', f.tabla, f.conname);
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) '
                       || 'REFERENCES public.usuarios (id) ON DELETE SET NULL',
                       f.tabla, f.conname, f.columna);
        RAISE NOTICE 'FK % de % pasa a ON DELETE SET NULL', f.conname, f.tabla;
    END LOOP;
END;
$fks$;


-- -----------------------------------------------------------------------------
-- 2. Quién era: la auditoría conserva al autor borrado
-- -----------------------------------------------------------------------------

ALTER TABLE public.auditoria ADD COLUMN IF NOT EXISTS usuario_borrado text;

COMMENT ON COLUMN public.auditoria.usuario_borrado IS
    'Identifica al autor cuando su usuario ya se borró: «nombre · correo (borrado)». '
    'La FK deja usuario_id en NULL al borrar; esta etiqueta, escrita justo antes, conserva quién era. '
    'NULL para todo lo demás (con usuario_id en NULL y esto vacío, el cambio fue sin login: la carga).';


-- -----------------------------------------------------------------------------
-- 3. El SET NULL de la FK no se re-atribuye a quien borra
-- -----------------------------------------------------------------------------
-- Redefine fn_tasas_cambio_autor (nació en sql/dashboard.sql) con una sola
-- línea nueva: cuando el UPDATE no viene de la app sino del ON DELETE SET NULL
-- de la FK (un UPDATE interno, pg_trigger_depth() > 1), la fila se deja tal
-- cual. Sin esto, el trigger pisaba el NULL con el ADMIN que borraba y la tasa
-- cambiaba de autor (lo encontró la batería de pruebas). Ojo: si se vuelve a
-- correr sql/dashboard.sql, volver a correr esta migración después.

CREATE OR REPLACE FUNCTION public.fn_tasas_cambio_autor()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- UPDATE interno de una FK (ON DELETE SET NULL al borrar un usuario): no es
    -- una edición, el autor pasa a NULL y lo demás no se toca.
    IF TG_OP = 'UPDATE' AND pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;
    SELECT moneda INTO NEW.moneda FROM public.mercados WHERE id = NEW.mercado_id;
    NEW.actualizado_por := (SELECT id FROM public.fn_usuario_actual());
    NEW.actualizado_en := now();
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_tasas_cambio_autor() FROM PUBLIC, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4. Borrar
-- -----------------------------------------------------------------------------
-- Devuelve { correo, auth_user_id }: con auth_user_id la Edge Function borra el
-- login en Auth. Si ese segundo paso fallara, un login sin fila en usuarios no
-- tiene acceso a nada (fn_usuario_actual no lo encuentra); se borra a mano en
-- Authentication → Users.

CREATE OR REPLACE FUNCTION public.fn_admin_borrar_usuario(p_usuario_id bigint)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin    bigint := public.fn_exigir_admin();
    v_u        public.usuarios;
    v_mercados text;
BEGIN
    IF p_usuario_id = v_admin THEN
        RAISE EXCEPTION 'No puedes borrarte a ti mismo' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_u FROM public.usuarios WHERE id = p_usuario_id FOR UPDATE;
    IF v_u.id IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario_id USING ERRCODE = '22023';
    END IF;
    -- Activo con login no se borra: primero Desactivar. (Activo sin login es el
    -- alta a medias y sí se borra: lo usa la Edge Function al deshacer un alta.)
    IF v_u.activo AND v_u.auth_user_id IS NOT NULL THEN
        RAISE EXCEPTION 'Desactívalo primero: borrar es definitivo' USING ERRCODE = '22023';
    END IF;

    -- Sus mercados, a la auditoría antes de que el CASCADE se los lleve.
    v_mercados := (SELECT string_agg(m.codigo, ',' ORDER BY m.id)
                   FROM public.usuario_mercados um
                   JOIN public.mercados m ON m.id = um.mercado_id
                   WHERE um.usuario_id = p_usuario_id);
    IF v_mercados IS NOT NULL THEN
        PERFORM public.fn_auditar_usuario(p_usuario_id, 'mercados', v_mercados, NULL, v_admin);
    END IF;

    -- Sus filas históricas de auditoría conservan quién era: la FK va a poner
    -- usuario_id en NULL, y esta etiqueta queda. La fila (baja) del propio
    -- borrado no la necesita: lleva el usuario completo en JSON.
    UPDATE public.auditoria
    SET usuario_borrado = v_u.nombre || ' · ' || v_u.correo || ' (borrado)'
    WHERE usuario_id = p_usuario_id AND usuario_borrado IS NULL;

    -- Por si Auth no acompaña: sin sesiones, un login huérfano tampoco entra.
    PERFORM public.fn_cerrar_sesiones(v_u.auth_user_id);

    -- Aquí pasan el trigger ultimo_admin (nunca sin ADMIN activo) y el trigger
    -- auditar, que escribe la fila (baja) con el ADMIN y el usuario en JSON.
    DELETE FROM public.usuarios WHERE id = p_usuario_id;

    RETURN jsonb_build_object('correo', v_u.correo, 'auth_user_id', v_u.auth_user_id);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_admin_borrar_usuario(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_borrar_usuario(bigint) TO authenticated;

-- Absorbida: el caso «sin login» es la excepción documentada de la nueva.
DROP FUNCTION IF EXISTS public.fn_admin_borrar_usuario_sin_login(bigint);

COMMIT;
