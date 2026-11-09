-- =============================================================================
-- OASIS v2.0 — Pruebas de la edición de usuarios y tasas (sql/usuarios_edicion.sql)
-- =============================================================================
-- Correr en el SQL Editor (o con la conexión de .env). Crea usuarios de prueba
-- (@oasis.invalid), simula sus sesiones como la API y termina con un error a
-- propósito que revierte todo; el informe sale en el mensaje del error: una
-- línea OK o FALLA por prueba.
--
-- Revisa:
--   * un ZB al que se le quita MLC deja de ver las compras de MLC; sus
--     sesiones se cierran y la auditoría guarda antes y después;
--   * un CLIENTE al que se le agrega MLA ve MLA en fn_dashboard_portada;
--   * un PROVEEDOR al que se le cambia el proveedor ve en v_materiales_externos
--     solo los materiales del proveedor nuevo;
--   * reglas: mercados por rol, proveedor activo, PLANNING, un ADMIN no cambia
--     su propio rol, nunca sin un ADMIN activo, solo ADMIN ejecuta (42501);
--   * cambiar solo el nombre no cierra sesiones;
--   * tasas_cambio: auditoría con antes y después, no se borra la única tasa
--     de un mercado ni la que rige hoy si no queda otra;
--   * borrar usuarios (sql/usuarios_borrar.sql): un activo con login no se
--     borra; un desactivado sí, con sus mercados y su sesión fuera, la fila
--     (baja) en auditoría con el ADMIN, las FKs de rastro en NULL y sus filas
--     históricas de auditoría marcadas con «nombre · correo (borrado)» (las de
--     otros autores quedan sin marca); un ADMIN inactivo se borra sin tocar la
--     regla del último activo; el alta a medias (sin login) se borra aunque
--     esté activa; solo ADMIN (42501).
--
-- Requiere sql/usuarios.sql, sql/dashboard.sql, sql/usuarios_edicion.sql y
-- sql/usuarios_borrar.sql.
-- =============================================================================

DO $pruebas$
DECLARE
    r         text[] := '{}';
    v_anio    int := extract(year FROM current_date)::int;
    -- logins de prueba
    a_adm     uuid := gen_random_uuid();
    a_adm2    uuid := gen_random_uuid();
    a_zb      uuid := gen_random_uuid();
    a_cli     uuid := gen_random_uuid();
    a_prov    uuid := gen_random_uuid();
    a_lec     uuid := gen_random_uuid();
    a_sesion  uuid;
    -- ids
    u_adm     bigint;
    u_adm2    bigint;
    u_zb      bigint;
    u_cli     bigint;
    u_prov    bigint;
    u_lec     bigint;
    v_mco     smallint;
    v_mlc     smallint;
    v_mla     smallint;
    v_sin     smallint;     -- un mercado sin tasas, para probar las reglas de borrado
    v_efect   integer;
    v_otro    integer;      -- el proveedor nuevo
    v_otro_nombre text;
    v_inact   integer;      -- un proveedor inactivo, si hay
    e_otro    integer;      -- materiales del proveedor nuevo, contados como postgres
    t1        bigint;
    t2        bigint;
    t3        bigint;
    d_id      bigint;    -- fila de duplicados_propuestos para la FK de rastro
    -- auxiliares
    j         jsonb;
    n         integer;
    n2        integer;
    t         text;
    x         text;
    num       numeric;
BEGIN
    -- -------------------------------------------------------------- Preparación
    SELECT id INTO v_mco FROM public.mercados WHERE codigo = 'MCO';
    SELECT id INTO v_mlc FROM public.mercados WHERE codigo = 'MLC';
    SELECT id INTO v_mla FROM public.mercados WHERE codigo = 'MLA';
    SELECT id INTO v_sin FROM public.mercados WHERE id NOT IN (SELECT mercado_id FROM public.tasas_cambio) ORDER BY id LIMIT 1;
    SELECT id INTO v_efect FROM public.proveedores WHERE nombre = 'EFECTIMEDIOS' AND mercado_id = v_mco;
    -- Proveedor nuevo: el activo de MCO con más materiales, que no sea EFECTIMEDIOS.
    SELECT p.id, p.nombre, count(*) INTO v_otro, v_otro_nombre, e_otro
    FROM public.proveedores p
    JOIN public.compras c ON c.proveedor_id = p.id
    JOIN public.materiales m ON m.compra_id = c.id
    WHERE p.activo AND p.mercado_id = v_mco AND p.id <> v_efect
    GROUP BY p.id, p.nombre ORDER BY 3 DESC LIMIT 1;
    SELECT id INTO v_inact FROM public.proveedores WHERE NOT activo ORDER BY id LIMIT 1;

    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo) VALUES
        ('prueba.admin@oasis.invalid',     'Prueba admin',     'ADMIN',     NULL,    true),
        ('prueba.admin2@oasis.invalid',    'Prueba admin 2',   'ADMIN',     NULL,    true),
        ('prueba.zb@oasis.invalid',        'Prueba ZB',        'ZB',        NULL,    true),
        ('prueba.cliente@oasis.invalid',   'Prueba cliente',   'CLIENTE',   NULL,    true),
        ('prueba.proveedor@oasis.invalid', 'Prueba proveedor', 'PROVEEDOR', v_efect, true),
        ('prueba.lectura@oasis.invalid',   'Prueba lectura',   'LECTURA',   NULL,    true);
    SELECT id INTO u_adm  FROM public.usuarios WHERE correo = 'prueba.admin@oasis.invalid';
    SELECT id INTO u_adm2 FROM public.usuarios WHERE correo = 'prueba.admin2@oasis.invalid';
    SELECT id INTO u_zb   FROM public.usuarios WHERE correo = 'prueba.zb@oasis.invalid';
    SELECT id INTO u_cli  FROM public.usuarios WHERE correo = 'prueba.cliente@oasis.invalid';
    SELECT id INTO u_prov FROM public.usuarios WHERE correo = 'prueba.proveedor@oasis.invalid';
    SELECT id INTO u_lec  FROM public.usuarios WHERE correo = 'prueba.lectura@oasis.invalid';
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id) VALUES
        (u_zb, v_mco), (u_zb, v_mlc), (u_cli, v_mco), (u_lec, v_mco);

    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_adm,  'prueba.admin@oasis.invalid',     'authenticated', 'authenticated'),
        (a_adm2, 'prueba.admin2@oasis.invalid',    'authenticated', 'authenticated'),
        (a_zb,   'prueba.zb@oasis.invalid',        'authenticated', 'authenticated'),
        (a_cli,  'prueba.cliente@oasis.invalid',   'authenticated', 'authenticated'),
        (a_prov, 'prueba.proveedor@oasis.invalid', 'authenticated', 'authenticated'),
        (a_lec,  'prueba.lectura@oasis.invalid',   'authenticated', 'authenticated');

    -- Sesiones abiertas: dos del ZB y una del cliente, cada una con su token de renovación.
    WITH s AS (
        INSERT INTO auth.sessions (id, user_id, created_at, updated_at)
        SELECT gen_random_uuid(), u, now(), now() FROM unnest(ARRAY[a_zb, a_zb, a_cli]) u
        RETURNING id, user_id)
    INSERT INTO auth.refresh_tokens (token, user_id, session_id, revoked, created_at, updated_at)
    SELECT gen_random_uuid()::text, s.user_id::text, s.id, false, now(), now() FROM s;

    SELECT count(*) INTO n FROM public.usuarios WHERE correo LIKE 'prueba.%@oasis.invalid' AND auth_user_id IS NOT NULL;
    r := r || format('%s  Trigger vincula los %s logins de prueba', CASE WHEN n = 6 THEN 'OK   ' ELSE 'FALLA' END, n);
    r := r || format('%s  Proveedor nuevo para la prueba: %s (%s materiales)',
                     CASE WHEN v_otro IS NOT NULL AND e_otro > 0 THEN 'OK   ' ELSE 'FALLA' END, v_otro_nombre, e_otro);

    -- ============================================================== ZB pierde MLC
    r := r || text '--- Equipo ZB con MCO y MLC: se le quita MLC';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) FILTER (WHERE mercado_id = v_mlc), count(*) FILTER (WHERE mercado_id = v_mco) INTO n, n2 FROM public.compras;
    r := r || format('%s  Antes: ve %s compras de MLC y %s de MCO', CASE WHEN n > 0 AND n2 > 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_zb, 'Prueba ZB', 'ZB', NULL, ARRAY[v_mco]::smallint[]);
    r := r || format('%s  ADMIN le quita MLC: acceso_cambio %s · %s sesiones cerradas · mercados %s',
                     CASE WHEN (j ->> 'acceso_cambio')::boolean AND (j ->> 'sesiones_cerradas')::int = 2
                               AND j -> 'mercados' = to_jsonb(ARRAY[v_mco]) THEN 'OK   ' ELSE 'FALLA' END,
                     j ->> 'acceso_cambio', j ->> 'sesiones_cerradas', j -> 'mercados');
    RESET ROLE;

    SELECT count(*) INTO n FROM auth.sessions WHERE user_id = a_zb;
    SELECT count(*) INTO n2 FROM auth.refresh_tokens WHERE user_id = a_zb::text;
    r := r || format('%s  Sus sesiones (%s) y tokens de renovación (%s) ya no existen',
                     CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM auth.sessions WHERE user_id = a_cli;
    r := r || format('%s  Las sesiones de otros usuarios siguen (%s del cliente)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) FILTER (WHERE mercado_id = v_mlc), count(*) FILTER (WHERE mercado_id = v_mco) INTO n, n2 FROM public.compras;
    r := r || format('%s  Después: ve %s compras de MLC y %s de MCO', CASE WHEN n = 0 AND n2 > 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM public.v_inversion_diaria WHERE mercado_id = v_mlc;
    r := r || format('%s  Tampoco ve inversión de MLC (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;

    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_zb AND campo = 'mercados' AND usuario_id = u_adm
      AND valor_anterior = 'MCO,MLC' AND valor_nuevo = 'MCO';
    SELECT count(*) INTO n2 FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_zb AND campo = '(sesiones cerradas)' AND usuario_id = u_adm AND valor_nuevo = '2';
    r := r || format('%s  Auditoría: mercados MCO,MLC → MCO (%s) y sesiones cerradas (%s), con el ADMIN',
                     CASE WHEN n = 1 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2);

    -- Solo el nombre: no cierra sesiones.
    INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), a_zb, now(), now());
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_zb, '  Prueba ZB editado ', 'ZB', NULL, ARRAY[v_mco]::smallint[]);
    RESET ROLE;
    SELECT count(*) INTO n FROM auth.sessions WHERE user_id = a_zb;
    SELECT count(*) INTO n2 FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_zb AND campo = 'nombre' AND usuario_id = u_adm
      AND valor_anterior = 'Prueba ZB' AND valor_nuevo = 'Prueba ZB editado';
    r := r || format('%s  Cambiar solo el nombre: acceso_cambio %s, la sesión sigue (%s), auditoría nombre antes/después (%s)',
                     CASE WHEN NOT (j ->> 'acceso_cambio')::boolean AND n = 1 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END,
                     j ->> 'acceso_cambio', n, n2);

    -- ============================================================== CLIENTE gana MLA
    r := r || text '--- CLIENTE con MCO: se le agrega MLA';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_cli, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_dashboard_portada(v_anio);
    SELECT string_agg(e ->> 'codigo', ',' ORDER BY e ->> 'codigo') INTO t FROM jsonb_array_elements(j -> 'mercados') e;
    BEGIN
        PERFORM public.fn_dashboard_mercado('MLA', v_anio);
        x := 'lo ve';
    EXCEPTION WHEN insufficient_privilege THEN
        x := 'error 42501';
    END;
    r := r || format('%s  Antes: portada %s · mercado MLA: %s', CASE WHEN t = 'MCO' AND x = 'error 42501' THEN 'OK   ' ELSE 'FALLA' END, t, x);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_cli, 'Prueba cliente', 'CLIENTE', NULL, ARRAY[v_mla, v_mco]::smallint[]);
    r := r || format('%s  ADMIN le agrega MLA: %s sesión cerrada',
                     CASE WHEN (j ->> 'sesiones_cerradas')::int = 1 THEN 'OK   ' ELSE 'FALLA' END, j ->> 'sesiones_cerradas');
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_cli, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_dashboard_portada(v_anio);
    SELECT string_agg(e ->> 'codigo', ',' ORDER BY e ->> 'codigo') INTO t FROM jsonb_array_elements(j -> 'mercados') e;
    j := public.fn_dashboard_mercado('MLA', v_anio);
    r := r || format('%s  Después: portada %s · mercado MLA con total %s',
                     CASE WHEN t = 'MCO,MLA' AND (j ->> 't')::numeric > 0 THEN 'OK   ' ELSE 'FALLA' END, t,
                     CASE WHEN (j ->> 't')::numeric > 0 THEN '> 0' ELSE j ->> 't' END);
    SELECT count(*) INTO n FROM public.compras;
    r := r || format('%s  Sigue sin leer compras (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_cli AND campo = 'mercados' AND valor_anterior = 'MCO' AND valor_nuevo = 'MCO,MLA';
    r := r || format('%s  Auditoría: mercados MCO → MCO,MLA (%s)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- ============================================================== PROVEEDOR cambia
    r := r || format('--- PROVEEDOR: de EFECTIMEDIOS a %s', v_otro_nombre);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_prov, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*), count(*) FILTER (WHERE proveedor <> 'EFECTIMEDIOS') INTO n, n2 FROM public.v_materiales_externos;
    r := r || format('%s  Antes: ve %s materiales, %s de otro proveedor', CASE WHEN n > 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_prov, 'Prueba proveedor', 'PROVEEDOR', v_otro, ARRAY[v_mla]::smallint[]);
    r := r || format('%s  ADMIN le cambia el proveedor (los mercados que lleguen se ignoran: %s)',
                     CASE WHEN (j ->> 'acceso_cambio')::boolean AND j -> 'mercados' = '[]'::jsonb
                               AND (j -> 'usuario' ->> 'proveedor_id')::int = v_otro THEN 'OK   ' ELSE 'FALLA' END, j -> 'mercados');
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_prov, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*), count(*) FILTER (WHERE proveedor <> v_otro_nombre) INTO n, n2 FROM public.v_materiales_externos;
    r := r || format('%s  Después: ve %s materiales (esperado %s), %s de otro proveedor',
                     CASE WHEN n = e_otro AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, e_otro, n2);
    RESET ROLE;
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_prov AND campo = 'proveedor_id' AND usuario_id = u_adm
      AND valor_anterior = v_efect::text AND valor_nuevo = v_otro::text;
    r := r || format('%s  Auditoría: proveedor_id %s → %s (%s)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, v_efect, v_otro, n);

    -- ============================================================== Rol y mercados
    r := r || text '--- Cambios de rol y reglas de mercados';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    -- ZB → LECTURA: ve todos, sus usuario_mercados se borran.
    j := public.fn_admin_editar_usuario(u_zb, 'Prueba ZB editado', 'LECTURA', NULL, ARRAY[v_mco]::smallint[]);
    RESET ROLE;
    SELECT count(*) INTO n FROM public.usuario_mercados WHERE usuario_id = u_zb;
    SELECT count(*) INTO n2 FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_zb AND campo = 'rol' AND valor_anterior = 'ZB' AND valor_nuevo = 'LECTURA' AND usuario_id = u_adm;
    r := r || format('%s  ZB → Lectura: sin usuario_mercados (%s), auditoría rol ZB → LECTURA (%s)',
                     CASE WHEN n = 0 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(DISTINCT mercado_id) INTO n FROM public.compras;
    r := r || format('%s  Como Lectura ve compras de %s mercados (todos los que tienen)', CASE WHEN n >= 5 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;

    -- Un LECTURA que solo cambia de nombre: sus mercados viejos se limpian, pero no cuenta como cambio de acceso.
    INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), a_lec, now(), now());
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_lec, 'Prueba lectura 2', 'LECTURA', NULL, NULL);
    RESET ROLE;
    SELECT count(*) INTO n FROM auth.sessions WHERE user_id = a_lec;
    r := r || format('%s  Lectura con un mercado viejo, cambio de nombre: acceso_cambio %s, la sesión sigue (%s)',
                     CASE WHEN NOT (j ->> 'acceso_cambio')::boolean AND n = 1 THEN 'OK   ' ELSE 'FALLA' END, j ->> 'acceso_cambio', n);

    -- Validaciones: cada una tiene que dar 22023.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    FOR t, x IN SELECT * FROM (VALUES
            ('ZB sin mercados',              format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', u_cli, 'X', 'ZB', '{}')),
            ('Cliente sin mercados',         format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, NULL)', u_cli, 'X', 'CLIENTE')),
            ('Agencia sin mercados',         format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', u_cli, 'X', 'AGENCIA', '{}')),
            ('Proveedor sin proveedor',      format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', u_cli, 'X', 'PROVEEDOR', ARRAY[v_mco])),
            ('ZB con proveedor',             format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, %s, %L)', u_cli, 'X', 'ZB', v_efect, ARRAY[v_mco])),
            ('pasar a Planning',             format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', u_cli, 'X', 'PLANNING', ARRAY[v_mco])),
            ('nombre vacío',                 format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', u_cli, '  ', 'CLIENTE', ARRAY[v_mco])),
            ('mercado que no existe',        format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', u_cli, 'X', 'CLIENTE', '{999}')),
            ('usuario que no existe',        format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, NULL, %L)', -1, 'X', 'CLIENTE', ARRAY[v_mco])),
            ('proveedor inactivo (nuevo)',   CASE WHEN v_inact IS NOT NULL THEN
                format('SELECT public.fn_admin_editar_usuario(%s, %L, %L, %s, NULL)', u_prov, 'X', 'PROVEEDOR', v_inact) END),
            ('crear Cliente sin mercados',   format('SELECT public.fn_admin_crear_usuario(%L, %L, %L, NULL, %L)',
                                                    'prueba.nuevo@oasis.invalid', 'X', 'CLIENTE', '{}'))
        ) v(nombre, sql) LOOP
        IF x IS NULL THEN
            r := r || format('OK     Rechaza %s: no hay proveedores inactivos para probarlo', t);
            CONTINUE;
        END IF;
        BEGIN
            EXECUTE x;
            r := r || format('FALLA  Rechaza %s: lo aceptó', t);
        EXCEPTION WHEN SQLSTATE '22023' THEN
            r := r || format('OK     Rechaza %s: %s', t, SQLERRM);
        END;
    END LOOP;

    -- Crear: Lectura no guarda mercados aunque lleguen.
    PERFORM public.fn_admin_crear_usuario('prueba.lectura2@oasis.invalid', 'Prueba lectura nueva', 'LECTURA', NULL, ARRAY[v_mco]::smallint[]);
    RESET ROLE;
    SELECT count(*) INTO n FROM public.usuario_mercados um JOIN public.usuarios u ON u.id = um.usuario_id
    WHERE u.correo = 'prueba.lectura2@oasis.invalid';
    r := r || format('%s  Crear Lectura: no se le guardan mercados (%s), ve todos', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- ============================================================== ADMIN
    r := r || text '--- ADMIN: su propio rol y el último ADMIN activo';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        PERFORM public.fn_admin_editar_usuario(u_adm, 'Prueba admin', 'LECTURA', NULL, NULL);
        r := r || text 'FALLA  Un ADMIN se cambia su propio rol';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('OK     Un ADMIN no se cambia su propio rol: %s', SQLERRM);
    END;
    j := public.fn_admin_editar_usuario(u_adm, 'Prueba admin (yo)', 'ADMIN', NULL, NULL);
    r := r || format('%s  Sí cambia su propio nombre (%s)', CASE WHEN j -> 'usuario' ->> 'nombre' = 'Prueba admin (yo)' THEN 'OK   ' ELSE 'FALLA' END,
                     j -> 'usuario' ->> 'nombre');
    -- Con otro ADMIN activo, a ese sí se le puede bajar el rol (y volver a subir).
    j := public.fn_admin_editar_usuario(u_adm2, 'Prueba admin 2', 'LECTURA', NULL, NULL);
    j := public.fn_admin_editar_usuario(u_adm2, 'Prueba admin 2', 'ADMIN', NULL, NULL);
    r := r || format('%s  Baja y sube el rol de otro ADMIN (queda %s)', CASE WHEN j -> 'usuario' ->> 'rol' = 'ADMIN' THEN 'OK   ' ELSE 'FALLA' END,
                     j -> 'usuario' ->> 'rol');
    RESET ROLE;

    -- Dejar a prueba.admin como el único ADMIN activo (dentro de esta transacción).
    UPDATE public.usuarios SET activo = false WHERE rol = 'ADMIN' AND activo AND id <> u_adm;
    SELECT count(*) INTO n FROM public.usuarios WHERE rol = 'ADMIN' AND activo;
    r := r || format('%s  Preparación: queda %s ADMIN activo', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        PERFORM public.fn_admin_cambiar_activo(u_adm, false);
        r := r || text 'FALLA  El último ADMIN se desactiva a sí mismo';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('OK     El último ADMIN no se desactiva: %s', SQLERRM);
    END;
    -- A un ADMIN inactivo sí se le puede cambiar el rol: no es el que sostiene el acceso.
    j := public.fn_admin_editar_usuario(u_adm2, 'Prueba admin 2', 'ZB', NULL, ARRAY[v_mco]::smallint[]);
    r := r || format('%s  Un ADMIN inactivo pasa a ZB sin problema', CASE WHEN j -> 'usuario' ->> 'rol' = 'ZB' THEN 'OK   ' ELSE 'FALLA' END);
    RESET ROLE;

    -- El trigger cuida también la conexión directa (postgres).
    FOREACH t IN ARRAY ARRAY['rol', 'activo', 'borrar'] LOOP
        BEGIN
            IF t = 'rol' THEN
                UPDATE public.usuarios SET rol = 'LECTURA' WHERE id = u_adm;
            ELSIF t = 'activo' THEN
                UPDATE public.usuarios SET activo = false WHERE id = u_adm;
            ELSE
                DELETE FROM public.usuarios WHERE id = u_adm;
            END IF;
            r := r || format('FALLA  Conexión directa: %s del último ADMIN, lo aceptó', t);
        EXCEPTION WHEN SQLSTATE '22023' THEN
            r := r || format('OK     Conexión directa: %s del último ADMIN, rechazado', t);
        END;
    END LOOP;
    UPDATE public.usuarios SET rol = 'ADMIN', proveedor_id = NULL, activo = true WHERE id = u_adm2;
    UPDATE public.usuarios SET activo = false WHERE id = u_adm;
    SELECT count(*) INTO n FROM public.usuarios WHERE id = u_adm AND NOT activo;
    r := r || format('%s  Con otro ADMIN activo, sí se desactiva', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);
    UPDATE public.usuarios SET activo = true WHERE id = u_adm;

    -- ============================================================== Sin permiso
    r := r || text '--- Solo ADMIN';
    FOR t, a_sesion IN SELECT * FROM (VALUES ('Lectura (antes ZB)', a_zb), ('Cliente', a_cli), ('Proveedor', a_prov)) v(n, a) LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sesion, 'role', 'authenticated')::text, true);
        SET LOCAL ROLE authenticated;
        BEGIN
            PERFORM public.fn_admin_editar_usuario(u_cli, 'X', 'ADMIN', NULL, NULL);
            r := r || format('FALLA  %s ejecuta fn_admin_editar_usuario', t);
        EXCEPTION WHEN insufficient_privilege THEN
            r := r || format('OK     %s llama a fn_admin_editar_usuario: 42501', t);
        END;
        RESET ROLE;
    END LOOP;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        PERFORM public.fn_cerrar_sesiones(a_cli);
        r := r || text 'FALLA  Un no-ADMIN ejecuta fn_cerrar_sesiones';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     fn_cerrar_sesiones no se ejecuta desde la API (42501)';
    END;
    RESET ROLE;
    SET LOCAL ROLE anon;
    BEGIN
        PERFORM public.fn_admin_editar_usuario(u_cli, 'X', 'ADMIN', NULL, NULL);
        r := r || text 'FALLA  anon ejecuta fn_admin_editar_usuario';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     anon no ejecuta fn_admin_editar_usuario';
    END;
    RESET ROLE;
    SELECT rol::text INTO t FROM public.usuarios WHERE id = u_cli;
    r := r || format('%s  El cliente sigue siendo %s', CASE WHEN t = 'CLIENTE' THEN 'OK   ' ELSE 'FALLA' END, t);

    -- ============================================================== Tasas de cambio
    r := r || format('--- Tasas de cambio (mercado sin tasas para probar: %s)',
                     (SELECT codigo FROM public.mercados WHERE id = v_sin));
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    -- Editar el valor de una tasa existente: auditoría con antes y después.
    SELECT id, valor_por_usd INTO t1, num FROM public.tasas_cambio
    WHERE mercado_id = v_mco AND vigente_desde <= current_date ORDER BY vigente_desde DESC LIMIT 1;
    UPDATE public.tasas_cambio SET valor_por_usd = valor_por_usd + 1 WHERE id = t1;
    RESET ROLE;
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'tasas_cambio' AND fila_id = t1 AND campo = 'valor_por_usd' AND usuario_id = u_adm
      AND valor_anterior::numeric = num AND valor_nuevo::numeric = num + 1;
    r := r || format('%s  Editar la tasa de MCO (%s → %s): auditoría con antes y después y el ADMIN (%s)',
                     CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, num, num + 1, n);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    IF v_sin IS NULL THEN
        r := r || text 'FALLA  No hay un mercado sin tasas para probar el borrado';
    ELSE
        INSERT INTO public.tasas_cambio (mercado_id, moneda, valor_por_usd, vigente_desde)
        VALUES (v_sin, 'X', 5, DATE '2026-01-01') RETURNING id INTO t1;
        BEGIN
            DELETE FROM public.tasas_cambio WHERE id = t1;
            r := r || text 'FALLA  Borra la única tasa de un mercado';
        EXCEPTION WHEN SQLSTATE '23514' THEN
            r := r || format('OK     No borra la única tasa: %s', SQLERRM);
        END;
        BEGIN
            UPDATE public.tasas_cambio SET vigente_desde = current_date + 10 WHERE id = t1;
            r := r || text 'FALLA  Pasa al futuro la única tasa que rige';
        EXCEPTION WHEN SQLSTATE '23514' THEN
            r := r || format('OK     No pasa al futuro la única que rige: %s', SQLERRM);
        END;
        INSERT INTO public.tasas_cambio (mercado_id, moneda, valor_por_usd, vigente_desde)
        VALUES (v_sin, 'X', 6, current_date + 30) RETURNING id INTO t2;
        BEGIN
            DELETE FROM public.tasas_cambio WHERE id = t1;
            r := r || text 'FALLA  Borra la que rige hoy dejando solo una futura';
        EXCEPTION WHEN SQLSTATE '23514' THEN
            r := r || format('OK     No borra la que rige si solo queda una futura: %s', SQLERRM);
        END;
        DELETE FROM public.tasas_cambio WHERE id = t2;
        GET DIAGNOSTICS n = ROW_COUNT;
        r := r || format('%s  Sí borra la futura (%s fila)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
        INSERT INTO public.tasas_cambio (mercado_id, moneda, valor_por_usd, vigente_desde)
        VALUES (v_sin, 'X', 7, DATE '2026-02-01') RETURNING id INTO t3;
        DELETE FROM public.tasas_cambio WHERE id = t1;
        GET DIAGNOSTICS n = ROW_COUNT;
        r := r || format('%s  Con otra que rige, sí borra la anterior (%s fila)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
        BEGIN
            UPDATE public.tasas_cambio SET mercado_id = v_mco WHERE id = t3;
            r := r || text 'FALLA  Una tasa cambia de mercado';
        EXCEPTION WHEN SQLSTATE '23514' THEN
            r := r || format('OK     Una tasa no cambia de mercado: %s', SQLERRM);
        END;
        UPDATE public.tasas_cambio SET valor_por_usd = 7.5, vigente_desde = DATE '2026-03-01' WHERE id = t3;
        GET DIAGNOSTICS n = ROW_COUNT;
        r := r || format('%s  Edita valor y fecha de la única tasa si sigue rigiendo (%s fila)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
    END IF;
    RESET ROLE;
    IF v_sin IS NOT NULL THEN
        SELECT string_agg(campo, ',' ORDER BY campo) INTO t FROM (
            SELECT DISTINCT campo FROM public.auditoria
            WHERE tabla = 'tasas_cambio' AND fila_id IN (t1, t2, t3) AND usuario_id = u_adm) s;
        r := r || format('%s  Auditoría de tasas: %s', CASE WHEN t ~ '\(alta\)' AND t ~ '\(baja\)' AND t ~ 'valor_por_usd' AND t ~ 'vigente_desde'
                                                        THEN 'OK   ' ELSE 'FALLA' END, t);
    END IF;

    -- Otro rol no toca las tasas (RLS: cero filas).
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_cli, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    UPDATE public.tasas_cambio SET valor_por_usd = 1;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM public.tasas_cambio;
    GET DIAGNOSTICS n2 = ROW_COUNT;
    r := r || format('%s  Un no-ADMIN edita %s y borra %s tasas', CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    RESET ROLE;


    -- ============================================================== Borrar usuarios
    r := r || text '--- Borrar usuarios (sql/usuarios_borrar.sql)';
    r := r || format('%s  fn_admin_borrar_usuario_sin_login quedó absorbida (ya no existe)',
                     CASE WHEN to_regproc('public.fn_admin_borrar_usuario_sin_login') IS NULL THEN 'OK   ' ELSE 'FALLA' END);
    SELECT count(*) INTO n FROM pg_constraint c
    WHERE c.contype = 'f' AND c.confrelid = 'public.usuarios'::regclass AND c.confdeltype NOT IN ('n', 'c');
    r := r || format('%s  Ninguna FK hacia usuarios sin SET NULL o CASCADE (%s)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- Preparación del rastro: una tasa tocada por u_adm2 y una propuesta resuelta por u_cli.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm2, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    UPDATE public.tasas_cambio SET valor_por_usd = valor_por_usd + 0.5
    WHERE id = (SELECT id FROM public.tasas_cambio WHERE mercado_id = v_mco ORDER BY vigente_desde DESC LIMIT 1)
    RETURNING id INTO t1;
    RESET ROLE;
    SELECT count(*) INTO n FROM public.tasas_cambio WHERE id = t1 AND actualizado_por = u_adm2;
    r := r || format('%s  Preparación: la tasa %s quedó con actualizado_por = u_adm2', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, t1);
    INSERT INTO public.duplicados_propuestos (mercado_id, tipo, valores, canonico, confianza, estado, resuelto_en, resuelto_por)
    VALUES (v_mco, 'PROVEEDOR', '["X","Y"]', 'X', 'ALTA', 'RECHAZADO', now(), u_cli)
    RETURNING id INTO d_id;
    INSERT INTO auth.sessions (id, user_id, created_at, updated_at) VALUES (gen_random_uuid(), a_cli, now(), now());

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    -- Rechazos
    BEGIN
        PERFORM public.fn_admin_borrar_usuario(u_cli);
        r := r || text 'FALLA  Borra un usuario activo con login';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('OK     No borra un activo con login: %s', SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_admin_borrar_usuario(u_adm);
        r := r || text 'FALLA  Un ADMIN se borra a sí mismo';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('OK     Nadie se borra a sí mismo: %s', SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_admin_borrar_usuario(-1);
        r := r || text 'FALLA  Borra un usuario que no existe';
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('OK     Usuario inexistente: %s', SQLERRM);
    END;

    -- Un ADMIN inactivo sí se borra (u_adm sigue activo: el trigger ultimo_admin no corta).
    PERFORM public.fn_admin_cambiar_activo(u_adm2, false);
    j := public.fn_admin_borrar_usuario(u_adm2);
    r := r || format('%s  Borra un ADMIN inactivo y devuelve correo y login (%s)',
                     CASE WHEN j ->> 'correo' = 'prueba.admin2@oasis.invalid' AND (j ->> 'auth_user_id')::uuid = a_adm2
                          THEN 'OK   ' ELSE 'FALLA' END, j ->> 'correo');

    -- Un CLIENTE desactivado, con mercados, sesión y rastro.
    PERFORM public.fn_admin_cambiar_activo(u_cli, false);
    j := public.fn_admin_borrar_usuario(u_cli);
    RESET ROLE;
    SELECT count(*) INTO n FROM public.usuarios WHERE id IN (u_adm2, u_cli);
    SELECT count(*) INTO n2 FROM public.usuario_mercados WHERE usuario_id = u_cli;
    r := r || format('%s  Las filas ya no existen (%s) y sus mercados tampoco (%s)',
                     CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM auth.sessions WHERE user_id = a_cli;
    r := r || format('%s  Su sesión abierta se cerró (%s)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id IN (u_adm2, u_cli) AND campo = '(baja)' AND usuario_id = u_adm;
    SELECT count(*) INTO n2 FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_cli AND campo = 'mercados' AND valor_anterior = 'MCO,MLA' AND valor_nuevo IS NULL;
    r := r || format('%s  Auditoría: %s filas (baja) con el ADMIN y mercados MCO,MLA → NULL (%s)',
                     CASE WHEN n = 2 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM public.tasas_cambio WHERE id = t1 AND actualizado_por IS NULL;
    SELECT count(*) INTO n2 FROM public.duplicados_propuestos WHERE id = d_id AND resuelto_por IS NULL;
    r := r || format('%s  Las FKs de rastro no estorban: tasas_cambio.actualizado_por (%s) y duplicados_propuestos.resuelto_por (%s) en NULL',
                     CASE WHEN n = 1 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    -- Las filas históricas del borrado conservan quién era; las de otros, sin marca.
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'tasas_cambio' AND fila_id = t1 AND campo = 'valor_por_usd' AND usuario_id IS NULL
      AND usuario_borrado = 'Prueba admin 2 · prueba.admin2@oasis.invalid (borrado)';
    SELECT count(*) INTO n2 FROM public.auditoria WHERE usuario_id = u_adm AND usuario_borrado IS NOT NULL;
    r := r || format('%s  Su auditoría histórica queda marcada «(borrado)» con nombre y correo (%s) y la de otros sin marca (%s con marca)',
                     CASE WHEN n = 1 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);

    -- El alta a medias (sin login) se borra aunque esté activa: lo usa la Edge Function.
    INSERT INTO public.usuarios (correo, nombre, rol, activo) VALUES ('prueba.sinlogin@oasis.invalid', 'Alta a medias', 'ZB', true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_borrar_usuario((SELECT id FROM public.usuarios WHERE correo = 'prueba.sinlogin@oasis.invalid'));
    r := r || format('%s  Un alta a medias (activa, sin login) sí se borra (login devuelto: %s)',
                     CASE WHEN j ->> 'auth_user_id' IS NULL THEN 'OK   ' ELSE 'FALLA' END, coalesce(j ->> 'auth_user_id', 'ninguno'));
    RESET ROLE;
    SELECT count(*) INTO n FROM public.usuarios WHERE correo = 'prueba.sinlogin@oasis.invalid';
    r := r || format('%s  Y su fila ya no existe (%s)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- Solo ADMIN.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        PERFORM public.fn_admin_borrar_usuario(u_prov);
        r := r || text 'FALLA  Un no-ADMIN borra usuarios';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     Un no-ADMIN llama a fn_admin_borrar_usuario: 42501';
    END;
    RESET ROLE;

    RAISE EXCEPTION E'PRUEBAS TERMINADAS — % FALLAS — todo revertido\n%',
        (SELECT count(*) FROM unnest(r) l WHERE l LIKE 'FALLA%'), array_to_string(r, E'\n');
END;
$pruebas$;
