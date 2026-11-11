-- =============================================================================
-- OASIS v2.0 — Pruebas de sql/usuarios_permisos.sql
-- =============================================================================
-- Correr en el SQL Editor (o con la conexión de .env). Crea usuarios y un
-- mercado de prueba, simula sus sesiones como la API y termina con un error a
-- propósito que revierte todo; el informe sale en el mensaje del error: una
-- línea OK o FALLA por prueba.
--
-- Revisa:
--   * catálogo de vistas: Cliente admite materiales, compras e inversión; los
--     demás roles, ninguna (trigger, mismo error que el CHECK de antes);
--   * Cliente sin vistas adicionales: 0 filas en las cuatro vistas _cliente y en
--     las tablas base; el dashboard le sigue funcionando;
--   * Cliente solo con Materiales: Compras e Inversión en 0;
--   * Cliente con Compras: ve las compras de sus mercados con el mismo valor
--     total, sin columnas de tarifa bruta, descuento ni tarifa neta (pedirlas da
--     error, como por la API);
--   * Cliente con Inversión: las mismas cifras que ve un ADMIN por las funciones
--     internas (total, periodos, sub campañas, proveedores, opciones, Total y
--     Semanal), solo de sus mercados, en menos de 2 s;
--   * los demás roles y anon no leen nada por las vistas nuevas;
--   * «Todos los países»: un mercado de prueba que se activa aparece solo para
--     quien tiene la marca (y ADMIN), no para un Cliente con los mercados uno
--     por uno; ADMIN y LECTURA llevan la marca siempre;
--   * Proveedor JCDECAUX en MCO + MLC: sus materiales de los dos países, ninguno
--     de MLM ni de otro proveedor; evidencias solo en sus carpetas;
--   * fn_admin_crear_usuario y fn_admin_editar_usuario: marca, proveedores en
--     varios países (mismo nombre, uno por país), vistas desmarcadas por
--     defecto, cierre de sesiones y auditoría con antes y después.
-- =============================================================================

DO $pruebas$
DECLARE
    r        text[] := '{}';
    ok       text := 'OK   ';
    mal      text := 'FALLA';
    a_sin    uuid := gen_random_uuid();   -- Cliente MCO + MLC sin vistas
    a_mat    uuid := gen_random_uuid();   -- Cliente MCO solo Materiales
    a_comp   uuid := gen_random_uuid();   -- Cliente MCO con Compras
    a_inv    uuid := gen_random_uuid();   -- Cliente MCO + MLC con Inversión
    a_todos  uuid := gen_random_uuid();   -- Cliente con «Todos los países»
    a_siete  uuid := gen_random_uuid();   -- Cliente con los mercados uno por uno
    a_prov   uuid := gen_random_uuid();   -- Proveedor JCDECAUX MCO + MLC
    a_adm    uuid := gen_random_uuid();
    a_lec    uuid := gen_random_uuid();
    a_zb     uuid := gen_random_uuid();
    a_ag     uuid := gen_random_uuid();
    u_prov   bigint;
    u_adm    bigint;
    u_inv    bigint;
    u_nuevo  bigint;
    v_mco    smallint;
    v_mlc    smallint;
    v_mlm    smallint;
    v_nuevo  smallint;
    j_mco    integer;   -- JCDECAUX en cada país
    j_mlc    integer;
    j_mlm    integer;
    v_efect  integer;
    e_n      integer;
    e_s      numeric;
    m_j_mlc  bigint;    -- un material de JCDECAUX en MLC, otro en MLM, otro de EFECTIMEDIOS
    m_j_mlm  bigint;
    m_efect  bigint;
    n        integer;
    n2       integer;
    s        numeric;
    t        text;
    b        boolean;
    j        jsonb;
    j2       jsonb;
    t0       timestamptz;
    ms       numeric;
    filtros  jsonb;
    u        record;
    ids_mlc  bigint[];
BEGIN
    -- -------------------------------------------------------------- Preparación
    SELECT id INTO v_mco FROM public.mercados WHERE codigo = 'MCO';
    SELECT id INTO v_mlc FROM public.mercados WHERE codigo = 'MLC';
    SELECT id INTO v_mlm FROM public.mercados WHERE codigo = 'MLM';
    SELECT id INTO j_mco FROM public.proveedores WHERE nombre = 'JCDECAUX' AND mercado_id = v_mco;
    SELECT id INTO j_mlc FROM public.proveedores WHERE nombre = 'JCDECAUX' AND mercado_id = v_mlc;
    SELECT id INTO j_mlm FROM public.proveedores WHERE nombre = 'JCDECAUX' AND mercado_id = v_mlm;
    SELECT id INTO v_efect FROM public.proveedores WHERE nombre = 'EFECTIMEDIOS' AND mercado_id = v_mco;
    SELECT min(mt.id) INTO m_j_mlc FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.proveedor_id = j_mlc;
    SELECT min(mt.id) INTO m_j_mlm FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.proveedor_id = j_mlm;
    SELECT min(mt.id) INTO m_efect FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.proveedor_id = v_efect;

    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo, vistas, todos_los_mercados) VALUES
        ('prueba.cli.sin@oasis.invalid',   'Prueba cliente sin vistas',   'CLIENTE',   NULL,  true, '{}',            false),
        ('prueba.cli.mat@oasis.invalid',   'Prueba cliente materiales',   'CLIENTE',   NULL,  true, '{materiales}',  false),
        ('prueba.cli.comp@oasis.invalid',  'Prueba cliente compras',      'CLIENTE',   NULL,  true, '{compras}',     false),
        ('prueba.cli.inv@oasis.invalid',   'Prueba cliente inversión',    'CLIENTE',   NULL,  true, '{inversion}',   false),
        ('prueba.cli.todos@oasis.invalid', 'Prueba cliente todos',        'CLIENTE',   NULL,  true, '{}',            true),
        ('prueba.cli.siete@oasis.invalid', 'Prueba cliente uno por uno',  'CLIENTE',   NULL,  true, '{}',            false),
        ('prueba.proveedor@oasis.invalid', 'Prueba proveedor JCDECAUX',   'PROVEEDOR', j_mco, true, '{}',            false),
        ('prueba.admin@oasis.invalid',     'Prueba admin',                'ADMIN',     NULL,  true, '{}',            false),
        ('prueba.lectura@oasis.invalid',   'Prueba lectura',              'LECTURA',   NULL,  true, '{}',            false),
        ('prueba.zb@oasis.invalid',        'Prueba ZB',                   'ZB',        NULL,  true, '{}',            false),
        ('prueba.agencia@oasis.invalid',   'Prueba agencia',              'AGENCIA',   NULL,  true, '{}',            false);
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
    SELECT u2.id, x.m FROM public.usuarios u2
    JOIN (VALUES ('prueba.cli.sin@oasis.invalid', v_mco), ('prueba.cli.sin@oasis.invalid', v_mlc),
                 ('prueba.cli.mat@oasis.invalid', v_mco), ('prueba.cli.comp@oasis.invalid', v_mco),
                 ('prueba.cli.inv@oasis.invalid', v_mco), ('prueba.cli.inv@oasis.invalid', v_mlc),
                 ('prueba.zb@oasis.invalid', v_mco), ('prueba.agencia@oasis.invalid', v_mco)) x(correo, m)
      ON x.correo = u2.correo;
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
    SELECT u2.id, m.id FROM public.usuarios u2 CROSS JOIN public.mercados m WHERE u2.correo = 'prueba.cli.siete@oasis.invalid';
    SELECT id INTO u_prov FROM public.usuarios WHERE correo = 'prueba.proveedor@oasis.invalid';
    SELECT id INTO u_adm  FROM public.usuarios WHERE correo = 'prueba.admin@oasis.invalid';
    SELECT id INTO u_inv  FROM public.usuarios WHERE correo = 'prueba.cli.inv@oasis.invalid';
    INSERT INTO public.usuario_proveedores (usuario_id, proveedor_id) VALUES (u_prov, j_mlc);

    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_sin,   'prueba.cli.sin@oasis.invalid',   'authenticated', 'authenticated'),
        (a_mat,   'prueba.cli.mat@oasis.invalid',   'authenticated', 'authenticated'),
        (a_comp,  'prueba.cli.comp@oasis.invalid',  'authenticated', 'authenticated'),
        (a_inv,   'prueba.cli.inv@oasis.invalid',   'authenticated', 'authenticated'),
        (a_todos, 'prueba.cli.todos@oasis.invalid', 'authenticated', 'authenticated'),
        (a_siete, 'prueba.cli.siete@oasis.invalid', 'authenticated', 'authenticated'),
        (a_prov,  'prueba.proveedor@oasis.invalid', 'authenticated', 'authenticated'),
        (a_adm,   'prueba.admin@oasis.invalid',     'authenticated', 'authenticated'),
        (a_lec,   'prueba.lectura@oasis.invalid',   'authenticated', 'authenticated'),
        (a_zb,    'prueba.zb@oasis.invalid',        'authenticated', 'authenticated'),
        (a_ag,    'prueba.agencia@oasis.invalid',   'authenticated', 'authenticated');

    r := r || format('%s  Hay datos: JCDECAUX en MCO (%s), MLC (%s) y MLM (%s); materiales de prueba %s, %s, %s',
                     CASE WHEN j_mco IS NOT NULL AND j_mlc IS NOT NULL AND j_mlm IS NOT NULL
                               AND m_j_mlc IS NOT NULL AND m_j_mlm IS NOT NULL AND m_efect IS NOT NULL THEN ok ELSE mal END,
                     j_mco, j_mlc, j_mlm, m_j_mlc, m_j_mlm, m_efect);

    -- ============================================================== Catálogo y reglas
    r := r || text '--- Catálogo de vistas';
    r := r || format('%s  Cliente admite: %s (esperado {materiales,compras,inversion})',
                     CASE WHEN public.fn_vistas_de_rol('CLIENTE') = ARRAY['materiales', 'compras', 'inversion'] THEN ok ELSE mal END,
                     public.fn_vistas_de_rol('CLIENTE'));
    SELECT bool_and(cardinality(public.fn_vistas_de_rol(x)) = 0) INTO b
    FROM unnest(ARRAY['ZB', 'AGENCIA', 'PROVEEDOR', 'LECTURA', 'ADMIN', 'PLANNING']::public.rol_enum[]) x;
    r := r || format('%s  ZB, Agencia, Proveedor, Lectura, Admin y Planning: ninguna', CASE WHEN b THEN ok ELSE mal END);
    BEGIN
        UPDATE public.usuarios SET vistas = '{compras}' WHERE correo = 'prueba.zb@oasis.invalid';
        r := r || (mal || '  Un Equipo ZB quedó con la vista Compras');
    EXCEPTION WHEN check_violation THEN
        r := r || (ok || '  Un Equipo ZB no admite vistas (check_violation)');
    END;
    BEGIN
        UPDATE public.usuarios SET vistas = '{alertas}' WHERE correo = 'prueba.cli.sin@oasis.invalid';
        r := r || (mal || '  Un Cliente quedó con una vista que no existe');
    EXCEPTION WHEN check_violation THEN
        r := r || (ok || '  Un Cliente no admite una vista que no existe (alertas)');
    END;
    BEGIN
        UPDATE public.usuarios SET vistas = '{dashboard}' WHERE correo = 'prueba.cli.sin@oasis.invalid';
        r := r || (mal || '  Se guardó la vista fija dashboard');
    EXCEPTION WHEN check_violation THEN
        r := r || (ok || '  El dashboard es fijo: no se guarda como vista');
    END;
    SELECT bool_and(todos_los_mercados) INTO b FROM public.usuarios WHERE rol IN ('ADMIN', 'LECTURA');
    r := r || format('%s  Todo ADMIN y LECTURA (también los insertados sin marca) lleva «Todos»', CASE WHEN b THEN ok ELSE mal END);
    UPDATE public.usuarios SET todos_los_mercados = true WHERE id = u_prov;
    SELECT todos_los_mercados INTO b FROM public.usuarios WHERE id = u_prov;
    r := r || format('%s  Un Proveedor nunca lleva «Todos»', CASE WHEN NOT b THEN ok ELSE mal END);

    -- ============================================================== Columnas
    r := r || text '--- Columnas de v_compras_cliente';
    SELECT string_agg(column_name::text, ', ' ORDER BY ordinal_position) INTO t
    FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_compras_cliente';
    r := r || format('%s  Columnas: %s',
                     CASE WHEN t = 'id, mercado_id, mercado, mercado_nombre, moneda, codigo, campana, campana_taxonomia, proveedor, '
                                   'tipo_compra, medio, tipo_costo, formato, ubicacion, ciudad, cantidad, valor_total, fecha_inicio, fecha_fin'
                          THEN ok ELSE mal END, t);
    SELECT string_agg(column_name::text, ', ') INTO t FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name IN ('v_compras_cliente', 'v_inversion_cliente', 'v_inversion_semanal_cliente',
                                                     'v_inversion_total_cliente', 'v_mercados_cliente')
      AND column_name ~ '(tarifa|descuento|neta|bruta|semanas|tiempo|manual)';
    r := r || format('%s  Ninguna vista del Cliente trae tarifa, descuento, tiempo, semanas ni la marca manual%s',
                     CASE WHEN t IS NULL THEN ok ELSE mal END, coalesce(': ' || t, ''));
    SELECT string_agg(c.relname || ' ' || coalesce(c.reloptions::text, '—'), '; ') INTO t
    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace
      AND c.relname IN ('v_compras_cliente', 'v_inversion_cliente', 'v_inversion_semanal_cliente', 'v_inversion_total_cliente', 'v_mercados_cliente')
      AND NOT (coalesce(c.reloptions::text, '') LIKE '%security_barrier=true%' AND coalesce(c.reloptions::text, '') LIKE '%security_invoker=false%'
               AND pg_get_userbyid(c.relowner) = 'postgres');
    r := r || format('%s  Las cinco vistas nuevas: security_barrier, security_invoker = false, dueño postgres%s',
                     CASE WHEN t IS NULL THEN ok ELSE mal END, coalesce(' — no: ' || t, ''));

    -- ============================================================== Cliente sin vistas
    r := r || text '--- Cliente MCO + MLC sin vistas adicionales (el caso de hoy)';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sin, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT (SELECT count(*) FROM public.v_materiales_cliente) + (SELECT count(*) FROM public.v_compras_cliente)
         + (SELECT count(*) FROM public.v_inversion_cliente) + (SELECT count(*) FROM public.v_inversion_semanal_cliente)
         + (SELECT count(*) FROM public.v_inversion_total_cliente) INTO n;
    r := r || format('%s  Materiales, Compras, Inversión (diaria, semanal y total) _cliente: %s filas (esperado 0)',
                     CASE WHEN n = 0 THEN ok ELSE mal END, n);
    SELECT (SELECT count(*) FROM public.compras) + (SELECT count(*) FROM public.materiales) + (SELECT count(*) FROM public.inversion_diaria)
         + (SELECT count(*) FROM public.v_inversion_diaria) + (SELECT count(*) FROM public.v_materiales) + (SELECT count(*) FROM public.mercados)
         + (SELECT count(*) FROM public.vistas_catalogo) + (SELECT count(*) FROM public.usuario_proveedores) INTO n;
    r := r || format('%s  Tablas base, vistas internas y catálogos: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    j := public.fn_inversion_resumen_cliente(v_mco, '{}');
    SELECT count(*) INTO n2 FROM public.fn_inversion_filtrada_cliente(v_mco, '{}');
    r := r || format('%s  fn_inversion_resumen_cliente: %s filas; fn_inversion_filtrada_cliente: %s (esperado 0)',
                     CASE WHEN (j ->> 'filas')::int = 0 AND n2 = 0 THEN ok ELSE mal END, j ->> 'filas', n2);
    SELECT count(*) INTO n FROM public.v_mercados_cliente;
    r := r || format('%s  v_mercados_cliente: %s filas (esperado 0: sin vistas no lee ninguna)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    j := public.fn_dashboard_portada(extract(year FROM current_date)::int);
    r := r || format('%s  El dashboard sigue: portada con %s mercados (esperado 2)',
                     CASE WHEN jsonb_array_length(j -> 'mercados') = 2 THEN ok ELSE mal END, jsonb_array_length(j -> 'mercados'));
    RESET ROLE;

    -- ============================================================== Cliente solo Materiales
    r := r || text '--- Cliente MCO solo con Materiales';
    SELECT count(*) INTO e_n FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.mercado_id = v_mco;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_mat, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.v_materiales_cliente;
    SELECT (SELECT count(*) FROM public.v_compras_cliente) + (SELECT count(*) FROM public.v_inversion_cliente)
         + (SELECT count(*) FROM public.v_inversion_semanal_cliente) + (SELECT count(*) FROM public.v_inversion_total_cliente) INTO n2;
    r := r || format('%s  Materiales: %s (esperado %s); Compras e Inversión: %s filas (esperado 0)',
                     CASE WHEN n = e_n AND n2 = 0 THEN ok ELSE mal END, n, e_n, n2);
    RESET ROLE;

    -- ============================================================== Cliente con Compras
    r := r || text '--- Cliente MCO con Compras';
    SELECT count(*), sum(valor_total) INTO e_n, e_s FROM public.compras WHERE mercado_id = v_mco;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_comp, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*), sum(valor_total), count(*) FILTER (WHERE mercado <> 'MCO') INTO n, s, n2 FROM public.v_compras_cliente;
    r := r || format('%s  Ve %s compras de MCO (esperado %s), valor total %s (esperado %s), %s de otro mercado',
                     CASE WHEN n = e_n AND s = e_s AND n2 = 0 THEN ok ELSE mal END, n, e_n, s, e_s, n2);
    FOREACH t IN ARRAY ARRAY['tarifa_bruta', 'descuento_pct', 'tarifa_neta'] LOOP
        BEGIN
            EXECUTE format('SELECT %I FROM public.v_compras_cliente LIMIT 1', t);
            r := r || format('%s  Pedir %s a v_compras_cliente funcionó', mal, t);
        EXCEPTION WHEN undefined_column THEN
            r := r || format('%s  Pedir %s a v_compras_cliente: no existe (como por la API)', ok, t);
        END;
    END LOOP;
    SELECT (SELECT count(*) FROM public.compras) + (SELECT count(*) FROM public.v_materiales_cliente)
         + (SELECT count(*) FROM public.v_inversion_cliente) + (SELECT count(*) FROM public.v_inversion_total_cliente) INTO n;
    r := r || format('%s  compras (tabla), Materiales e Inversión: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    UPDATE public.compras SET valor_total = 1 WHERE mercado_id = v_mco;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  UPDATE a compras: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    BEGIN
        UPDATE public.v_compras_cliente SET valor_total = 1;
        r := r || (mal || '  UPDATE a v_compras_cliente pasó');
    EXCEPTION WHEN OTHERS THEN
        r := r || format('%s  UPDATE a v_compras_cliente: rechazado (%s)', ok, SQLSTATE);
    END;
    RESET ROLE;

    -- ============================================================== Cliente con Inversión: mismas cifras que un ADMIN
    r := r || text '--- Cliente MCO + MLC con Inversión';
    filtros := jsonb_build_object('meses', (SELECT jsonb_agg(DISTINCT to_char(fecha, 'YYYY-MM')) FROM
                                            (SELECT fecha FROM public.inversion_diaria WHERE mercado_id = v_mco ORDER BY fecha LIMIT 1) x));
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_inversion_resumen(v_mco, '{}');
    j2 := public.fn_inversion_resumen(v_mco, filtros || '{"ver_por": "compra"}');
    CREATE TEMP TABLE inv_admin ON COMMIT DROP AS
        SELECT 'total' AS k, count(*) AS filas, sum(costo_proyectado) AS proy, sum(costo_ejecutado) AS ejec FROM public.fn_inversion_total() WHERE mercado_id IN (v_mco, v_mlc)
        UNION ALL
        SELECT 'semanal', count(*), sum(costo_proyectado), sum(costo_ejecutado) FROM public.fn_inversion_semanal() WHERE mercado_id IN (v_mco, v_mlc)
        UNION ALL
        SELECT 'diaria', count(*), sum(costo_proyectado), sum(costo_ejecutado) FROM public.fn_inversion_filtrada(v_mlc, filtros);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_inv, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    t0 := clock_timestamp();
    j2 := jsonb_build_object('admin', j2, 'cliente', public.fn_inversion_resumen_cliente(v_mco, filtros || '{"ver_por": "compra"}'));
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    j := jsonb_build_object('admin', j, 'cliente', public.fn_inversion_resumen_cliente(v_mco, '{}'));
    FOREACH t IN ARRAY ARRAY['total', 'periodos', 'filas', 'opciones'] LOOP
        r := r || format('%s  Resumen MCO, %s: igual al de un ADMIN (sin filtros y con mes de compra)',
                         CASE WHEN j -> 'admin' -> t = j -> 'cliente' -> t AND j2 -> 'admin' -> t = j2 -> 'cliente' -> t THEN ok ELSE mal END, t);
    END LOOP;
    FOREACH t IN ARRAY ARRAY['sub_campanas', 'proveedores', 'por_material'] LOOP
        b := coalesce(j -> 'admin' -> t, 'null') @> coalesce(j -> 'cliente' -> t, 'null') AND coalesce(j -> 'admin' -> t, 'null') <@ coalesce(j -> 'cliente' -> t, 'null')
         AND coalesce(j2 -> 'admin' -> t, 'null') @> coalesce(j2 -> 'cliente' -> t, 'null') AND coalesce(j2 -> 'admin' -> t, 'null') <@ coalesce(j2 -> 'cliente' -> t, 'null');
        r := r || format('%s  Resumen MCO, %s: el mismo conjunto que el de un ADMIN', CASE WHEN b THEN ok ELSE mal END, t);
    END LOOP;
    r := r || format('%s  Resumen filtrado del Cliente en %s ms (meta < 2000)', CASE WHEN ms < 2000 THEN ok ELSE mal END, round(ms));
    -- Lo que pide la pantalla para un mercado (el más grande de los suyos, MLC).
    t0 := clock_timestamp();
    PERFORM public.fn_inversion_resumen_cliente(v_mlc, '{}');
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    t0 := clock_timestamp();
    SELECT count(*) INTO n FROM public.v_inversion_total_cliente WHERE mercado_id = v_mlc;
    n2 := round(extract(epoch FROM clock_timestamp() - t0) * 1000);
    t0 := clock_timestamp();
    SELECT count(*) INTO e_n FROM public.v_inversion_semanal_cliente WHERE mercado_id = v_mlc;
    s := round(extract(epoch FROM clock_timestamp() - t0) * 1000);
    t0 := clock_timestamp();
    PERFORM * FROM public.fn_inversion_filtrada_cliente(v_mlc, '{}') ORDER BY site, id_ejecucion, date LIMIT 500;
    e_s := round(extract(epoch FROM clock_timestamp() - t0) * 1000);
    r := r || format('%s  Tiempos en MLC: resumen %s ms, Total %s ms (%s filas), Semanal %s ms (%s filas), página de la Diaria %s ms (meta < 2000 cada una)',
                     CASE WHEN greatest(ms, n2, s, e_s) < 2000 THEN ok ELSE mal END, round(ms), n2, n, s, e_n, e_s);
    SELECT count(*), sum(costo_proyectado), sum(costo_ejecutado) INTO n, s, e_s FROM public.v_inversion_total_cliente;
    SELECT CASE WHEN n = i.filas AND s = i.proy AND e_s = i.ejec THEN ok ELSE mal END INTO t FROM inv_admin i WHERE i.k = 'total';
    r := r || format('%s  Total: %s filas de MCO + MLC, mismo proyectado y ejecutado que un ADMIN', t, n);
    SELECT count(*), sum(costo_proyectado), sum(costo_ejecutado) INTO n, s, e_s FROM public.v_inversion_semanal_cliente;
    SELECT CASE WHEN n = i.filas AND s = i.proy AND e_s = i.ejec THEN ok ELSE mal END INTO t FROM inv_admin i WHERE i.k = 'semanal';
    r := r || format('%s  Semanal: %s filas, mismas cifras que un ADMIN', t, n);
    SELECT count(*), sum(costo_proyectado), sum(costo_ejecutado) INTO n, s, e_s FROM public.fn_inversion_filtrada_cliente(v_mlc, filtros);
    SELECT CASE WHEN n = i.filas AND s IS NOT DISTINCT FROM i.proy AND e_s IS NOT DISTINCT FROM i.ejec THEN ok ELSE mal END INTO t FROM inv_admin i WHERE i.k = 'diaria';
    r := r || format('%s  Diaria filtrada de MLC: %s filas, mismas cifras que un ADMIN', t, n);
    SELECT count(*) INTO n FROM public.v_inversion_cliente WHERE mercado_id = v_mlm;
    SELECT count(*) INTO n2 FROM public.fn_inversion_filtrada_cliente(v_mlm, '{}');
    r := r || format('%s  MLM (no es suyo): %s filas en la vista, %s por la función (esperado 0)', CASE WHEN n + n2 = 0 THEN ok ELSE mal END, n, n2);
    SELECT (SELECT count(*) FROM public.v_compras_cliente) + (SELECT count(*) FROM public.v_materiales_cliente)
         + (SELECT count(*) FROM public.inversion_diaria) + (SELECT count(*) FROM public.v_inversion_diaria) INTO n;
    r := r || format('%s  Compras, Materiales y las tablas de inversión: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    SELECT string_agg(codigo || ' ' || moneda || ' ' || corte, ', ' ORDER BY codigo), bool_and(corte IS NOT NULL)
      INTO t, b FROM public.v_mercados_cliente;
    r := r || format('%s  Sus mercados, con su moneda y la fecha de corte (todas las columnas): %s',
                     CASE WHEN t LIKE 'MCO COP %, MLC CLP %' AND b THEN ok ELSE mal END, t);
    RESET ROLE;

    -- ============================================================== Otros roles y anon
    r := r || text '--- Otros roles por las vistas nuevas';
    FOR t, a_sin IN SELECT * FROM (VALUES ('ADMIN', a_adm), ('LECTURA', a_lec), ('ZB', a_zb), ('AGENCIA', a_ag), ('PROVEEDOR', a_prov)) v LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sin, 'role', 'authenticated')::text, true);
        SET LOCAL ROLE authenticated;
        SELECT (SELECT count(*) FROM public.v_compras_cliente) + (SELECT count(*) FROM public.v_inversion_cliente)
             + (SELECT count(*) FROM public.v_inversion_semanal_cliente) + (SELECT count(*) FROM public.v_inversion_total_cliente)
             + (SELECT count(*) FROM public.v_mercados_cliente) INTO n;
        r := r || format('%s  %s: %s filas (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, t, n);
        RESET ROLE;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
    SET LOCAL ROLE anon;
    BEGIN
        SELECT count(*) INTO n FROM public.v_compras_cliente;
        r := r || (mal || '  anon lee v_compras_cliente');
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || (ok || '  anon no tiene permiso sobre v_compras_cliente');
    END;
    BEGIN
        PERFORM public.fn_inversion_resumen_cliente(v_mco, '{}');
        r := r || (mal || '  anon ejecuta fn_inversion_resumen_cliente');
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || (ok || '  anon no ejecuta fn_inversion_resumen_cliente');
    END;
    RESET ROLE;

    -- ============================================================== «Todos los países»
    r := r || text '--- «Todos los países»: un mercado nuevo que se activa';
    INSERT INTO public.mercados (codigo, nombre, activo, moneda) VALUES ('MZZ', 'País de prueba', false, 'USD')
    RETURNING id INTO v_nuevo;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_todos, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO n FROM public.fn_mis_mercados() x WHERE x = v_nuevo;
    UPDATE public.mercados SET activo = true WHERE id = v_nuevo;   -- «se activa»
    SELECT count(*) INTO n2 FROM public.fn_mis_mercados() x WHERE x = v_nuevo;
    r := r || format('%s  Cliente con «Todos»: inactivo no lo ve (%s), al activarlo sí (%s), sin que nadie lo edite',
                     CASE WHEN n = 0 AND n2 = 1 THEN ok ELSE mal END, n, n2);
    SELECT count(*) INTO n FROM public.fn_mis_mercados();
    r := r || format('%s  Y ve todos los activos: %s (esperado %s)',
                     CASE WHEN n = (SELECT count(*) FROM public.mercados WHERE activo) THEN ok ELSE mal END, n,
                     (SELECT count(*) FROM public.mercados WHERE activo));
    SET LOCAL ROLE authenticated;
    j := public.fn_dashboard_portada(extract(year FROM current_date)::int);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    j2 := public.fn_dashboard_portada(extract(year FROM current_date)::int);
    r := r || format('%s  Su dashboard: %s mercados, los mismos que la portada de un ADMIN (%s)',
                     CASE WHEN j -> 'mercados' = j2 -> 'mercados' THEN ok ELSE mal END,
                     jsonb_array_length(j -> 'mercados'), jsonb_array_length(j2 -> 'mercados'));
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_siete, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO n FROM public.fn_mis_mercados() x WHERE x = v_nuevo;
    SELECT count(*) INTO n2 FROM public.fn_mis_mercados();
    r := r || format('%s  Cliente con los 7 mercados uno por uno: no ve el nuevo (%s), sigue con %s',
                     CASE WHEN n = 0 AND n2 = 7 THEN ok ELSE mal END, n, n2);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO n FROM public.fn_mis_mercados() x WHERE x = v_nuevo;
    r := r || format('%s  ADMIN lo ve: %s', CASE WHEN n = 1 THEN ok ELSE mal END, n);

    -- ============================================================== Proveedor en dos países
    r := r || text '--- Proveedor JCDECAUX en MCO + MLC';
    SELECT count(*) INTO e_n FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.proveedor_id IN (j_mco, j_mlc);
    SELECT array_agg(mt.id) INTO ids_mlc FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE c.proveedor_id = j_mlc;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_prov, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || format('%s  fn_mis_mercados: %s (esperado MCO y MLC)',
                     CASE WHEN (SELECT array_agg(x ORDER BY x) FROM public.fn_mis_mercados() x) = ARRAY[v_mco, v_mlc]::smallint[] THEN ok ELSE mal END,
                     (SELECT array_agg(x ORDER BY x) FROM public.fn_mis_mercados() x));
    SELECT count(*), count(*) FILTER (WHERE proveedor <> 'JCDECAUX'),
           count(*) FILTER (WHERE id = ANY (ids_mlc))
      INTO n, n2, e_s FROM public.v_materiales_externos;
    r := r || format('%s  v_materiales_externos: %s materiales (esperado %s), %s de MLC, %s de otro proveedor',
                     CASE WHEN n = e_n AND n2 = 0 AND e_s = cardinality(ids_mlc) AND e_s > 0 THEN ok ELSE mal END, n, e_n, e_s, n2);
    SELECT count(*) INTO n FROM public.v_materiales_externos WHERE id IN (m_j_mlm, m_efect);
    r := r || format('%s  Un material de JCDECAUX en MLM y uno de EFECTIMEDIOS: %s visibles (esperado 0)', CASE WHEN n = 0 THEN ok ELSE mal END, n);
    r := r || format('%s  Evidencias: sube en la carpeta de MLC (%s); no en MLM (%s) ni en material de otro (%s)',
                     CASE WHEN public.fn_evidencia_permitida(j_mlc || '/' || m_j_mlc || '/x.jpg', 'subir')
                           AND public.fn_evidencia_permitida(j_mco || '/' || m_j_mlc || '/x.jpg', 'subir')
                           AND NOT public.fn_evidencia_permitida(j_mlm || '/' || m_j_mlm || '/x.jpg', 'subir')
                           AND NOT public.fn_evidencia_permitida(j_mco || '/' || m_efect || '/x.jpg', 'subir') THEN ok ELSE mal END,
                     public.fn_evidencia_permitida(j_mlc || '/' || m_j_mlc || '/x.jpg', 'subir'),
                     public.fn_evidencia_permitida(j_mlm || '/' || m_j_mlm || '/x.jpg', 'subir'),
                     public.fn_evidencia_permitida(j_mco || '/' || m_efect || '/x.jpg', 'subir'));
    RESET ROLE;
    -- El principal siempre en la lista; al dejar de ser Proveedor, la lista se vacía.
    SELECT array_agg(proveedor_id ORDER BY proveedor_id) = ARRAY[j_mco, j_mlc] INTO b FROM public.usuario_proveedores WHERE usuario_id = u_prov;
    r := r || format('%s  usuario_proveedores: el principal (por el trigger) y MLC', CASE WHEN b THEN ok ELSE mal END);

    -- ============================================================== Alta y edición por un ADMIN
    r := r || text '--- fn_admin_crear_usuario y fn_admin_editar_usuario';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT * INTO u FROM public.fn_admin_crear_usuario('prueba.alta.prov@oasis.invalid', 'Alta proveedor', 'PROVEEDOR', NULL, NULL,
                                                       NULL, false, ARRAY[j_mlc, j_mco, j_mlm]);
    u_nuevo := u.id;
    r := r || format('%s  Crear Proveedor JCDECAUX en MCO, MLC y MLM: %s proveedores, principal %s',
                     CASE WHEN (SELECT count(*) FROM public.usuario_proveedores WHERE usuario_id = u_nuevo) = 3 AND u.proveedor_id = least(j_mco, j_mlc, j_mlm)
                          THEN ok ELSE mal END,
                     (SELECT count(*) FROM public.usuario_proveedores WHERE usuario_id = u_nuevo), u.proveedor_id);
    SELECT valor_nuevo INTO t FROM public.auditoria WHERE tabla = 'usuarios' AND fila_id = u_nuevo AND campo = 'proveedores' AND usuario_id = u_adm;
    r := r || format('%s  Auditoría con el ADMIN: proveedores «%s»', CASE WHEN t = 'JCDECAUX (MCO), JCDECAUX (MLC), JCDECAUX (MLM)' THEN ok ELSE mal END, t);
    BEGIN
        PERFORM public.fn_admin_crear_usuario('prueba.alta.mezcla@oasis.invalid', 'X', 'PROVEEDOR', NULL, NULL, NULL, false, ARRAY[j_mco, v_efect]);
        r := r || (mal || '  Crear con JCDECAUX y EFECTIMEDIOS pasó');
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('%s  Rechaza mezclar proveedores: %s', ok, SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_admin_crear_usuario('prueba.alta.vacio@oasis.invalid', 'X', 'PROVEEDOR', NULL, NULL, NULL, false, '{}');
        r := r || (mal || '  Crear Proveedor sin proveedores pasó');
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('%s  Rechaza Proveedor sin proveedores: %s', ok, SQLERRM);
    END;
    j := public.fn_admin_editar_usuario(u_nuevo, 'Alta proveedor', 'PROVEEDOR', j_mlc, NULL, NULL, NULL, ARRAY[j_mlc]);
    r := r || format('%s  Editar: deja solo MLC (principal %s), cambio de acceso %s',
                     CASE WHEN (j -> 'proveedores') = to_jsonb(ARRAY[j_mlc]) AND (j -> 'usuario' ->> 'proveedor_id')::int = j_mlc
                               AND (j ->> 'acceso_cambio')::boolean THEN ok ELSE mal END,
                     j -> 'usuario' ->> 'proveedor_id', j ->> 'acceso_cambio');
    SELECT valor_anterior || ' → ' || valor_nuevo INTO t FROM public.auditoria
    WHERE tabla = 'usuarios' AND fila_id = u_nuevo AND campo = 'proveedores' AND valor_anterior IS NOT NULL;
    r := r || format('%s  Auditoría de proveedores con antes y después: %s', CASE WHEN t LIKE 'JCDECAUX (MCO), %→ JCDECAUX (MLC)' THEN ok ELSE mal END, t);

    SELECT * INTO u FROM public.fn_admin_crear_usuario('prueba.alta.todos@oasis.invalid', 'Alta todos', 'ZB', NULL, NULL, NULL, true);
    SELECT count(*) INTO n FROM public.usuario_mercados WHERE usuario_id = u.id;
    r := r || format('%s  Crear Equipo ZB con «Todos»: marca %s, %s mercados guardados', CASE WHEN u.todos_los_mercados AND n = 0 THEN ok ELSE mal END,
                     u.todos_los_mercados, n);
    SELECT * INTO u FROM public.fn_admin_crear_usuario('prueba.alta.cli@oasis.invalid', 'Alta cliente', 'CLIENTE', NULL, ARRAY[v_mco]);
    r := r || format('%s  Crear Cliente sin mandar vistas: vistas %s (desmarcadas), sin «Todos»',
                     CASE WHEN u.vistas = '{}' AND NOT u.todos_los_mercados THEN ok ELSE mal END, u.vistas);
    u_nuevo := u.id;
    BEGIN
        PERFORM public.fn_admin_crear_usuario('prueba.alta.nada@oasis.invalid', 'X', 'CLIENTE', NULL, '{}');
        r := r || (mal || '  Crear Cliente sin países ni «Todos» pasó');
    EXCEPTION WHEN SQLSTATE '22023' THEN
        r := r || format('%s  Rechaza Cliente sin países: %s', ok, SQLERRM);
    END;
    SELECT * INTO u FROM public.fn_admin_crear_usuario('prueba.alta.lec@oasis.invalid', 'Alta lectura', 'LECTURA', NULL, NULL);
    r := r || format('%s  Crear Lectura: «Todos» sin pedirlo (%s)', CASE WHEN u.todos_los_mercados THEN ok ELSE mal END, u.todos_los_mercados);

    j := public.fn_admin_editar_usuario(u_nuevo, 'Alta cliente', 'CLIENTE', NULL, NULL, ARRAY['inversion', 'materiales'], true);
    r := r || format('%s  Editar Cliente: Materiales + Inversión y «Todos» → vistas %s, marca %s, cambio de acceso %s',
                     CASE WHEN j -> 'vistas' = '["inversion", "materiales"]' AND (j ->> 'todos_los_mercados')::boolean
                               AND (j ->> 'acceso_cambio')::boolean AND j -> 'mercados' = '[]' THEN ok ELSE mal END,
                     j -> 'vistas', j ->> 'todos_los_mercados', j ->> 'acceso_cambio');
    j := public.fn_admin_editar_usuario(u_nuevo, 'Alta cliente', 'CLIENTE', NULL, ARRAY[v_mlc]);
    r := r || format('%s  Editar sin mandar vistas ni marca: las conserva (vistas %s, marca %s, sin cambio de acceso)',
                     CASE WHEN j -> 'vistas' = '["inversion", "materiales"]' AND (j ->> 'todos_los_mercados')::boolean
                               AND NOT (j ->> 'acceso_cambio')::boolean THEN ok ELSE mal END,
                     j -> 'vistas', j ->> 'todos_los_mercados');
    j := public.fn_admin_editar_usuario(u_nuevo, 'Alta cliente', 'CLIENTE', NULL, ARRAY[v_mlc], ARRAY['compras'], false);
    r := r || format('%s  Editar: quita «Todos» (queda MLC) y deja solo Compras: cambio de acceso %s',
                     CASE WHEN j -> 'vistas' = '["compras"]' AND NOT (j ->> 'todos_los_mercados')::boolean
                               AND j -> 'mercados' = to_jsonb(ARRAY[v_mlc]) AND (j ->> 'acceso_cambio')::boolean THEN ok ELSE mal END,
                     j ->> 'acceso_cambio');
    RESET ROLE;
    SELECT string_agg(campo || ': ' || coalesce(valor_anterior, '∅') || ' → ' || coalesce(valor_nuevo, '∅'), ' | ' ORDER BY id) INTO t
    FROM public.auditoria WHERE tabla = 'usuarios' AND fila_id = u_nuevo AND usuario_id = u_adm AND campo IN ('vistas', 'todos_los_mercados');
    r := r || format('%s  Auditoría con el ADMIN, antes y después: %s',
                     CASE WHEN t = 'vistas: [] → ["inversion", "materiales"] | todos_los_mercados: false → true | '
                                   'vistas: ["inversion", "materiales"] → ["compras"] | todos_los_mercados: true → false'
                          THEN ok ELSE mal END, t);

    -- ============================================================== Informe
    RAISE EXCEPTION E'PRUEBAS DE PERMISOS DE USUARIOS — %\n%',
        CASE WHEN EXISTS (SELECT 1 FROM unnest(r) x WHERE x LIKE 'FALLA%') THEN 'HAY FALLAS' ELSE 'TODAS OK' END,
        array_to_string(r, E'\n');
END;
$pruebas$;
