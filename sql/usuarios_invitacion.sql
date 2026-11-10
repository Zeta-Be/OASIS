-- =============================================================================
-- OASIS v2.0 — Invitación por correo al crear usuarios
-- =============================================================================
-- La Edge Function gestionar-usuarios ahora puede crear el login con una
-- invitación por correo (auth.admin.inviteUserByEmail) en vez de una contraseña
-- temporal: la persona recibe un enlace a clave.html y crea su contraseña.
--
-- En la base solo hace falta dejar rastro: cada envío (y cada intento fallido)
-- queda en auditoria, tabla 'usuarios', campo '(invitación)', con el ADMIN que
-- lo pidió, a quién se envió, cuándo (auditoria.en) y el resultado.
-- Un reenvío a alguien que ya tenía login lo borra y lo crea de nuevo (Auth no
-- reinvita a un login confirmado): eso queda aparte, campo '(login)', valor
-- 'login recreado por reenvío de invitación'.
--
-- Nada más cambia: el usuario invitado nace con debe_cambiar_clave = true, como
-- hoy (fn_admin_crear_usuario), y la marca se apaga con fn_clave_cambiada()
-- cuando crea su contraseña en clave.html.
--
-- Depende de sql/usuarios.sql (fn_exigir_admin, fn_auditar_usuario).
-- Repetible. Una transacción. No toca vistas ni el contrato con BI.
-- =============================================================================

BEGIN;

-- Una sola firma (la primera versión, de 3 argumentos, nunca se aplicó).
DROP FUNCTION IF EXISTS public.fn_admin_registrar_invitacion(bigint, boolean, text);

CREATE OR REPLACE FUNCTION public.fn_admin_registrar_invitacion(
    p_usuario_id bigint, p_enviada boolean, p_detalle text DEFAULT NULL,
    p_login_recreado boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin  bigint := public.fn_exigir_admin();
    v_correo text;
BEGIN
    SELECT correo INTO v_correo FROM public.usuarios WHERE id = p_usuario_id;
    IF v_correo IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario_id USING ERRCODE = '22023';
    END IF;
    IF coalesce(p_login_recreado, false) THEN
        PERFORM public.fn_auditar_usuario(
            p_usuario_id, '(login)', NULL, 'login recreado por reenvío de invitación', v_admin);
    END IF;
    PERFORM public.fn_auditar_usuario(
        p_usuario_id, '(invitación)', NULL,
        CASE WHEN coalesce(p_enviada, false)
             THEN 'enviada a ' || v_correo
             ELSE 'no se envió a ' || v_correo || coalesce(': ' || left(btrim(p_detalle), 300), '')
        END,
        v_admin);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_admin_registrar_invitacion(bigint, boolean, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_registrar_invitacion(bigint, boolean, text, boolean) TO authenticated;

COMMIT;
