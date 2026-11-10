-- =============================================================================
-- OASIS v2.0 — Pruebas de las vistas adicionales del Cliente (sql/cliente_vistas.sql)
-- =============================================================================
-- Correr en el SQL Editor (o con la conexión de .env). Crea usuarios de prueba,
-- simula sus sesiones como la API y termina con un error a propósito que
-- revierte todo; el informe sale en el mensaje del error: una línea OK o FALLA
-- por prueba.
--
-- Revisa:
--   * un Cliente SIN la vista: 0 filas en v_materiales_cliente, en materiales,
--     en compras y en evidencias;
--   * un Cliente de MCO CON la vista: ve los materiales de MCO y ninguno de
--     MLC; la vista no tiene columnas financieras; las tablas base y las vistas
--     de inversión siguen en 0; no puede editar por ningún camino;
--   * un Cliente de MCO + MLC con la vista ve los dos mercados;
--   * los demás roles no leen nada por esta vista; anon no tiene permiso;
--   * solo Cliente admite vistas (CHECK y funciones); un ADMIN la habilita con
--     fn_admin_editar_usuario: cuenta como cambio de acceso y queda en
--     auditoría; al pasar a otro rol se vacía.
-- =============================================================================

DO $pruebas$
DECLARE
    COLUMNAS constant text[] := ARRAY['id', 'codigo', 'mercado_id', 'mercado', 'mercado_nombre', 'compra_id', 'compra',
        'secuencia', 'proveedor', 'formato', 'ubicacion', 'ciudad', 'tipo_costo', 'sub_campana', 'referencia',
        'fecha_inicio', 'fecha_fin', 'enlace', 'reporte_implementacion', 'grupo_tramo', 'taxonomia'];
    r        text[] := '{}';
    a_sin    uuid := gen_random_uuid();   -- Cliente MCO sin vistas
    a_mco    uuid := gen_random_uuid();   -- Cliente MCO con materiales
    a_dos    uuid := gen_random_uuid();   -- Cliente MCO + MLC con materiales
    a_adm    uuid := gen_random_uuid();
    a_zb     uuid := gen_random_uuid();
    a_ag     uuid := gen_random_uuid();
    a_prov   uuid := gen_random_uuid();
    u_sin    bigint;
    u_adm    bigint;
    v_mco    smallint;
    v_mlc    smallint;
    v_efect  integer;
    e_mco    integer;   -- esperado, contado como postgres
    e_mlc    integer;
    e_ev_mco integer;
    m_mco    bigint;    -- un material de cada mercado
    m_mlc    bigint;
    n        integer;
    n2       integer;
    t        text;
    b        boolean;
    j        jsonb;
    ok       text := 'OK   ';
    mal      text := 'FALLA';
BEGIN
    -- -------------------------------------------------------------- Preparación
    SELECT id INTO v_mco FROM public.mercados WHERE codigo = 'MCO';
    SELECT id INTO v_mlc FROM public.mercados WHERE codigo = 'MLC';
    SELECT id INTO v_efect FROM public.proveedores WHERE nombre = 'EFECTIMEDIOS' AND mercado_id = v_mco;
    SELECT count(*) INTO e_mco FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.mercado_id = v_mco;
    SELECT count(*) INTO e_mlc FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.mercado_id = v_mlc;
    SELECT count(*) INTO e_ev_mco FROM public.evidencias e JOIN public.materiales mt ON mt.id = e.material_id
        JOIN public.compras c ON c.id = mt.compra_id WHERE c.mercado_id = v_mco;
    SELECT min(mt.id) INTO m_mco FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.mercado_id = v_mco;
    SELECT min(mt.id) INTO m_mlc FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.mercado_id = v_mlc;

    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo, vistas) VALUES
        ('prueba.cli.sin@oasis.invalid', 'Prueba cliente sin vista', 'CLIENTE',   NULL,    true, '{}'),
        ('prueba.cli.mco@oasis.invalid', 'Prueba cliente MCO',       'CLIENTE',   NULL,    true, '{materiales}'),
        ('prueba.cli.dos@oasis.invalid', 'Prueba cliente MCO + MLC', 'CLIENTE',   NULL,    true, '{materiales}'),
        ('prueba.admin@oasis.invalid',   'Prueba admin',             'ADMIN',     NULL,    true, '{}'),
        ('prueba.zb@oasis.invalid',      'Prueba ZB',                'ZB',        NULL,    true, '{}'),
        ('prueba.agencia@oasis.invalid', 'Prueba agencia',           'AGENCIA',   NULL,    true, '{}'),
        ('prueba.proveedor@oasis.invalid','Prueba proveedor',        'PROVEEDOR', v_efect, true, '{}');
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
    SELECT u.id, v_mco FROM public.usuarios u
    WHERE u.correo IN ('prueba.cli.sin@oasis.invalid', 'prueba.cli.mco@oasis.invalid', 'prueba.cli.dos@oasis.invalid',
                       'prueba.zb@oasis.invalid', 'prueba.agencia@oasis.invalid')
    UNION ALL
    SELECT u.id, v_mlc FROM public.usuarios u WHERE u.correo = 'prueba.cli.dos@oasis.invalid';

    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_sin,  'prueba.cli.sin@oasis.invalid',   'authenticated', 'authenticated'),
        (a_mco,  'prueba.cli.mco@oasis.invalid',   'authenticated', 'authenticated'),
        (a_dos,  'prueba.cli.dos@oasis.invalid',   'authenticated', 'authenticated'),
        (a_adm,  'prueba.admin@oasis.invalid',     'authenticated', 'authenticated'),
        (a_zb,   'prueba.zb@oasis.invalid',        'authenticated', 'authenticated'),
        (a_ag,   'prueba.agencia@oasis.invalid',   'authenticated', 'authenticated'),
        (a_prov, 'prueba.proveedor@oasis.invalid', 'authenticated', 'authenticated');
    SELECT id INTO u_sin FROM public.usuarios WHERE correo = 'prueba.cli.sin@oasis.invalid';
    SELECT id INTO u_adm FROM public.usuarios WHERE correo = 'prueba.admin@oasis.invalid';

    r := r || format('%s  Hay datos para probar: %s materiales en MCO, %s en MLC, %s evidencias en MCO',
                     CASE WHEN e_mco > 0 AND e_mlc > 0 THEN ok ELSE mal END, e_mco, e_mlc, e_ev_mco);

    -- ============================================================== La vista no trae nada financiero
    r := r || text '--- Columnas de v_materiales_cliente';
    SELECT array_agg(column_name::text ORDER BY ordinal_position) = COLUMNAS,
           string_agg(column_name::text, ', ' ORDER BY ordinal_position)
    INTO b, t FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_materiales_cliente';
    r := r || format('%s  Columnas, exactamente: %s', CASE WHEN b THEN ok ELSE mal END, t);
    SELECT string_agg(column_name::text, ', ') INTO t FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'v_materiales_cliente' AND column_name <> 'tipo_costo'
      AND column_name ~ '(tarifa|descuento|valor|costo|cantidad|semanas|precio|monto|inversion|pct)';
    r := r || format('%s  Ninguna columna financiera (tarifa, descuento, cantidad, valor, costo)%s',
                     CASE WHEN t IS NULL THEN ok ELSE mal END, coalesce(': ' || t, ''));
    SELECT reloptions::text INTO t FROM pg_class WHERE oid = 'public.v_materiales_cliente'::regclass;
    r := r || format('%s  Vista con security_barrier y dueño postgres: %s',
                     CASE WHEN t LIKE '%security_barrier=true%' AND t LIKE '%security_invoker=false%' THEN ok ELSE mal END, t);

    -- ============================================================== Cliente SIN la vista
    r := r || text '--- Cliente de MCO sin la vista «materiales»';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sin, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.v_materiales_cliente;
    r := r || format('%s  v_materiales_cliente: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    SELECT (SELECT count(*) FROM public.materiales) + (SELECT count(*) FROM public.compras)
         + (SELECT count(*) FROM public.evidencias) + (SELECT count(*) FROM public.v_materiales_externos) INTO n;
    r := r || format('%s  materiales, compras, evidencias y v_materiales_externos: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    r := r || format('%s  fn_veo_material de un material de MCO: %s (esperado false)',
                     CASE WHEN NOT public.fn_veo_material(m_mco) THEN ok ELSE mal END, public.fn_veo_material(m_mco));
    RESET ROLE;

    -- ============================================================== Cliente de MCO CON la vista
    r := r || text '--- Cliente de MCO con la vista «materiales»';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mco, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*), count(*) FILTER (WHERE mercado <> 'MCO') INTO n, n2 FROM public.v_materiales_cliente;
    r := r || format('%s  Ve los %s materiales de MCO (esperado %s) y %s de otro mercado',
                     CASE WHEN n = e_mco AND n2 = 0 THEN ok ELSE mal END, n, e_mco, n2);
    -- La taxonomía que ve el Cliente, para compararla después (como postgres) con la de v_materiales.
    CREATE TEMP TABLE tax_cliente ON COMMIT DROP AS SELECT id, taxonomia FROM public.v_materiales_cliente;
    SELECT count(*) INTO n FROM public.v_materiales_cliente WHERE id = m_mlc;
    r := r || format('%s  Un material de MLC pedido por id: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    SELECT (SELECT count(*) FROM public.materiales) + (SELECT count(*) FROM public.compras)
         + (SELECT count(*) FROM public.v_materiales) + (SELECT count(*) FROM public.v_materiales_externos)
         + (SELECT count(*) FROM public.v_inversion_diaria) + (SELECT count(*) FROM public.inversion_diaria)
         + (SELECT count(*) FROM public.proveedores) + (SELECT count(*) FROM public.campanas) INTO n;
    r := r || format('%s  Tablas base y demás vistas (materiales, compras, v_materiales, inversión, proveedores, campañas): %s filas (esperado 0)',
                     CASE WHEN n = 0 THEN ok ELSE mal END, n);
    SELECT count(*) INTO n FROM public.evidencias;
    r := r || format('%s  Evidencias: lee %s (las %s de materiales de MCO)', CASE WHEN n = e_ev_mco THEN ok ELSE mal END, n, e_ev_mco);
    r := r || format('%s  fn_veo_material: MCO %s, MLC %s (esperado true, false)',
                     CASE WHEN public.fn_veo_material(m_mco) AND NOT public.fn_veo_material(m_mlc) THEN ok ELSE mal END,
                     public.fn_veo_material(m_mco), public.fn_veo_material(m_mlc));

    -- No edita por ningún camino.
    UPDATE public.materiales SET referencia = 'x' WHERE id = m_mco;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  UPDATE a materiales: %s filas cambiadas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    BEGIN
        UPDATE public.v_materiales_cliente SET referencia = 'x' WHERE id = m_mco;
        r := r || (mal || '  UPDATE a v_materiales_cliente pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  UPDATE a v_materiales_cliente: rechazado (%s)', ok, SQLSTATE);
    END;
    BEGIN
        INSERT INTO public.materiales (compra_id, secuencia) SELECT compra_id, 99 FROM public.v_materiales_cliente WHERE id = m_mco;
        r := r || (mal || '  INSERT en materiales pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  INSERT en materiales: rechazado (%s)', ok, SQLSTATE);
    END;
    DELETE FROM public.materiales WHERE id = m_mco;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  DELETE en materiales: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    BEGIN
        PERFORM public.fn_actualizar_enlace(m_mco, 'https://example.com/x');
        r := r || (mal || '  fn_actualizar_enlace pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  fn_actualizar_enlace: rechazado (%s)', ok, SQLSTATE);
    END;
    BEGIN
        PERFORM public.fn_reportar_implementacion(m_mco, 'x');
        r := r || (mal || '  fn_reportar_implementacion pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  fn_reportar_implementacion: rechazado (%s)', ok, SQLSTATE);
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_mco, 'ENLACE', 'https://example.com/x');
        r := r || (mal || '  INSERT en evidencias pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  INSERT en evidencias: rechazado (%s)', ok, SQLSTATE);
    END;
    -- No se da la vista a sí mismo ni cambia sus mercados.
    UPDATE public.usuarios SET vistas = '{}' WHERE auth_user_id = a_mco;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  UPDATE a su propia fila de usuarios: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    -- El dashboard le sigue funcionando.
    j := public.fn_dashboard_portada(extract(year FROM current_date)::int);
    r := r || format('%s  El dashboard sigue: portada con %s mercado(s)',
                     CASE WHEN jsonb_array_length(j -> 'mercados') = 1 THEN ok ELSE mal END, jsonb_array_length(j -> 'mercados'));
    RESET ROLE;

    SELECT count(*), count(*) FILTER (WHERE t.taxonomia IS DISTINCT FROM vm.taxonomia) INTO n, n2
    FROM tax_cliente t JOIN public.v_materiales vm ON vm.material_id = t.id;
    r := r || format('%s  Taxonomía: la de %s materiales es igual a la de v_materiales (%s distintas)',
                     CASE WHEN n = e_mco AND n2 = 0 THEN ok ELSE mal END, n, n2);

    -- ============================================================== Cliente de MCO + MLC
    r := r || text '--- Cliente de MCO + MLC con la vista';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_dos, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) FILTER (WHERE mercado = 'MCO'), count(*) FILTER (WHERE mercado = 'MLC'),
           count(*) FILTER (WHERE mercado NOT IN ('MCO', 'MLC')) INTO n, n2, e_ev_mco FROM public.v_materiales_cliente;
    r := r || format('%s  Ve %s de MCO y %s de MLC (esperado %s y %s), %s de otros',
                     CASE WHEN n = e_mco AND n2 = e_mlc AND e_ev_mco = 0 THEN ok ELSE mal END, n, n2, e_mco, e_mlc, e_ev_mco);
    RESET ROLE;

    -- ============================================================== Los demás roles y anon
    r := r || text '--- Otros roles';
    FOR t, a_sin IN SELECT * FROM (VALUES ('ADMIN', a_adm), ('ZB', a_zb), ('AGENCIA', a_ag), ('PROVEEDOR', a_prov)) v LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sin, 'role', 'authenticated')::text, true);
        SET LOCAL ROLE authenticated;
        SELECT count(*) INTO n FROM public.v_materiales_cliente;
        r := r || format('%s  %s: %s filas por v_materiales_cliente (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, t, n);
        RESET ROLE;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
    SET LOCAL ROLE anon;
    BEGIN
        SELECT count(*) INTO n FROM public.v_materiales_cliente;
        r := r || (mal || '  anon lee v_materiales_cliente');
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || (ok || '  anon no tiene permiso sobre v_materiales_cliente');
    END;
    RESET ROLE;

    -- ============================================================== Solo Cliente admite vistas
    r := r || text '--- Reglas de usuarios.vistas';
    BEGIN
        UPDATE public.usuarios SET vistas = '{materiales}' WHERE correo = 'prueba.zb@oasis.invalid';
        r := r || (mal || '  Un Equipo ZB quedó con vistas');
    EXCEPTION WHEN check_violation THEN
        r := r || (ok || '  CHECK: un Equipo ZB no admite vistas adicionales');
    END;
    BEGIN
        UPDATE public.usuarios SET vistas = '{inversion}' WHERE correo = 'prueba.cli.sin@oasis.invalid';
        r := r || (mal || '  Un Cliente quedó con una vista que no existe');
    EXCEPTION WHEN check_violation THEN
        r := r || (ok || '  CHECK: un Cliente no admite una vista que no existe');
    END;

    -- Un ADMIN habilita y quita la vista con fn_admin_editar_usuario.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_sin, 'Prueba cliente sin vista', 'CLIENTE', NULL, ARRAY[v_mco], ARRAY['materiales']);
    r := r || format('%s  ADMIN habilita «materiales»: vistas %s, cambio de acceso %s',
                     CASE WHEN j -> 'vistas' = '["materiales"]' AND (j ->> 'acceso_cambio')::boolean THEN ok ELSE mal END,
                     j ->> 'vistas', j ->> 'acceso_cambio');
    j := public.fn_admin_editar_usuario(u_sin, 'Otro nombre', 'CLIENTE', NULL, ARRAY[v_mco]);
    r := r || format('%s  Editar sin mandar vistas las conserva: %s, cambio de acceso %s',
                     CASE WHEN j -> 'vistas' = '["materiales"]' AND NOT (j ->> 'acceso_cambio')::boolean THEN ok ELSE mal END,
                     j ->> 'vistas', j ->> 'acceso_cambio');
    BEGIN
        PERFORM public.fn_admin_editar_usuario(u_sin, 'Otro nombre', 'ZB', NULL, ARRAY[v_mco], ARRAY['materiales']);
        r := r || (mal || '  Pasar a Equipo ZB con la vista pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  Pasar a Equipo ZB pidiendo la vista: rechazado (%s)', ok, SQLSTATE);
    END;
    BEGIN
        PERFORM public.fn_admin_crear_usuario('prueba.zb2@oasis.invalid', 'X', 'ZB', NULL, ARRAY[v_mco], ARRAY['materiales']);
        r := r || (mal || '  Crear un Equipo ZB con vistas pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  Crear un Equipo ZB con vistas: rechazado (%s)', ok, SQLSTATE);
    END;
    r := r || format('%s  Crear un Cliente con la vista: vistas %s',
                     CASE WHEN (public.fn_admin_crear_usuario('prueba.cli.nuevo@oasis.invalid', 'Nuevo', 'CLIENTE', NULL,
                                    ARRAY[v_mco], ARRAY['materiales'])).vistas = '{materiales}' THEN ok ELSE mal END, '{materiales}');
    RESET ROLE;

    -- El que no tenía la vista ahora ve MCO.
    PERFORM set_config('request.jwt.claims', json_build_object('sub',
        (SELECT auth_user_id FROM public.usuarios WHERE id = u_sin), 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.v_materiales_cliente;
    r := r || format('%s  Con la vista recién habilitada ve %s materiales (esperado %s)', CASE WHEN n = e_mco THEN ok ELSE mal END, n, e_mco);
    RESET ROLE;

    -- Otro rol: la vista se vacía sola. Y un no-ADMIN no edita.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_admin_editar_usuario(u_sin, 'Otro nombre', 'ZB', NULL, ARRAY[v_mco]);
    r := r || format('%s  Cliente → Equipo ZB: vistas %s (esperado [])', CASE WHEN j -> 'vistas' = '[]' THEN ok ELSE mal END, j ->> 'vistas');
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mco, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        PERFORM public.fn_admin_editar_usuario(u_sin, 'X', 'CLIENTE', NULL, ARRAY[v_mco], ARRAY['materiales']);
        r := r || (mal || '  Un Cliente ejecutó fn_admin_editar_usuario');
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || (ok || '  Un Cliente no ejecuta fn_admin_editar_usuario (42501)');
    END;
    RESET ROLE;

    -- Auditoría (solo la lee ADMIN; aquí, como postgres).
    SELECT string_agg(valor_anterior || ' → ' || valor_nuevo, ' ; ' ORDER BY id), bool_and(usuario_id = u_adm)
    INTO t, b FROM public.auditoria WHERE tabla = 'usuarios' AND fila_id = u_sin AND campo = 'vistas';
    r := r || format('%s  Auditoría del campo vistas, con el ADMIN: %s',
                     CASE WHEN b AND t = '[] → ["materiales"] ; ["materiales"] → []' THEN ok ELSE mal END, t);

    RAISE EXCEPTION E'PRUEBAS TERMINADAS — % FALLAS — todo revertido\n%',
        (SELECT count(*) FROM unnest(r) l WHERE l LIKE 'FALLA%'), array_to_string(r, E'\n');
END;
$pruebas$;
