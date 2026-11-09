-- =============================================================================
-- OASIS v2.0 — Pruebas del dashboard (sql/dashboard.sql)
-- =============================================================================
-- Correr en el SQL Editor (o con la conexión de .env). Crea usuarios de prueba,
-- simula sus sesiones como la API y termina con un error a propósito que
-- revierte todo; el informe sale en el mensaje del error: una línea OK o FALLA
-- por prueba.
--
-- Revisa:
--   * por mercado y mes, lo que suma fn_dashboard_mercado = el costo ejecutado
--     de v_inversion_diaria con la misma fecha de corte (al peso); portada y
--     LATAM cuadran con el mercado; USD = local / tasa vigente;
--   * CLIENTE con MCO + MLC: ve solo esos dos; pedir MLA da error; no lee
--     ninguna tabla ni vista (salvo su propia fila de usuarios);
--   * AGENCIA, PROVEEDOR y PLANNING: las tres funciones dan error; un CLIENTE
--     desactivado también;
--   * tasas_cambio: solo ADMIN escribe; la moneda y el autor los pone la base;
--   * tiempos de cada función y tamaño del jsonb de cada mercado.
--
-- La comparación contra el dashboard original no va aquí (el repositorio es
-- público y esos totales son del cliente): la hace comparar_dashboard.py, que
-- lee referencias/dashboard_original.html en el equipo de quien la corre.
-- =============================================================================

DO $pruebas$
DECLARE
    MERCADOS   constant text[] := ARRAY['MCO', 'MLA', 'MLC', 'MLM', 'MLU'];
    LIMITE_SEG constant numeric := 2;
    r        text[] := '{}';
    v_anio   int := extract(year FROM current_date)::int;
    -- logins de prueba
    a_cli    uuid := gen_random_uuid();
    a_cli_in uuid := gen_random_uuid();
    a_zb     uuid := gen_random_uuid();
    a_lec    uuid := gen_random_uuid();
    a_adm    uuid := gen_random_uuid();
    a_ag     uuid := gen_random_uuid();
    a_prov   uuid := gen_random_uuid();
    a_plan   uuid := gen_random_uuid();
    a_sesion uuid;
    v_mco    smallint;
    v_mlc    smallint;
    v_efect  integer;
    -- esperado, calculado como postgres
    e_mes    jsonb;
    e_total  jsonb;
    -- auxiliares
    j        jsonb;
    j2       jsonb;
    n        integer;
    n2       integer;
    t        text;
    x        text;
    num      numeric;
    num2     numeric;
    t0       timestamptz;
    seg      numeric;
    malos    text[];
BEGIN
    -- -------------------------------------------------------------- Preparación
    SELECT id INTO v_mco FROM public.mercados WHERE codigo = 'MCO';
    SELECT id INTO v_mlc FROM public.mercados WHERE codigo = 'MLC';
    SELECT id INTO v_efect FROM public.proveedores WHERE nombre = 'EFECTIMEDIOS' AND mercado_id = v_mco;

    -- Costo ejecutado de v_inversion_diaria por mercado y mes, con el corte del dashboard.
    SELECT jsonb_object_agg(k, v) INTO e_mes FROM (
        SELECT d.site || '-' || d.month AS k, round(sum(d.costo_proyectado), 2) AS v
        FROM public.v_inversion_diaria d
        WHERE d.year = v_anio AND d.date <= public.fn_dashboard_corte(d.mercado_id)
        GROUP BY d.site, d.month) s;
    SELECT jsonb_object_agg(site, v) INTO e_total FROM (
        SELECT d.site, round(sum(d.costo_proyectado), 2) AS v
        FROM public.v_inversion_diaria d
        WHERE d.year = v_anio AND d.date <= public.fn_dashboard_corte(d.mercado_id)
        GROUP BY d.site) s;

    -- Usuarios primero; el trigger de auth.users completa auth_user_id.
    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo) VALUES
        ('prueba.cliente@oasis.invalid',   'Prueba cliente',          'CLIENTE',   NULL,    true),
        ('prueba.cliente.in@oasis.invalid','Prueba cliente inactivo', 'CLIENTE',   NULL,    false),
        ('prueba.zb@oasis.invalid',        'Prueba ZB',               'ZB',        NULL,    true),
        ('prueba.lectura@oasis.invalid',   'Prueba lectura',          'LECTURA',   NULL,    true),
        ('prueba.admin@oasis.invalid',     'Prueba admin',            'ADMIN',     NULL,    true),
        ('prueba.agencia@oasis.invalid',   'Prueba agencia',          'AGENCIA',   NULL,    true),
        ('prueba.proveedor@oasis.invalid', 'Prueba proveedor',        'PROVEEDOR', v_efect, true),
        ('prueba.planning@oasis.invalid',  'Prueba planning',         'PLANNING',  NULL,    true);
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
    SELECT u.id, m.id FROM public.usuarios u
    JOIN public.mercados m ON m.codigo IN ('MCO', 'MLC')
    WHERE u.correo IN ('prueba.cliente@oasis.invalid', 'prueba.cliente.in@oasis.invalid')
    UNION ALL
    SELECT u.id, v_mco FROM public.usuarios u
    WHERE u.correo IN ('prueba.zb@oasis.invalid', 'prueba.lectura@oasis.invalid', 'prueba.agencia@oasis.invalid',
                       'prueba.planning@oasis.invalid');

    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_cli,    'prueba.cliente@oasis.invalid',    'authenticated', 'authenticated'),
        (a_cli_in, 'prueba.cliente.in@oasis.invalid', 'authenticated', 'authenticated'),
        (a_zb,     'prueba.zb@oasis.invalid',         'authenticated', 'authenticated'),
        (a_lec,    'prueba.lectura@oasis.invalid',    'authenticated', 'authenticated'),
        (a_adm,    'prueba.admin@oasis.invalid',      'authenticated', 'authenticated'),
        (a_ag,     'prueba.agencia@oasis.invalid',    'authenticated', 'authenticated'),
        (a_prov,   'prueba.proveedor@oasis.invalid',  'authenticated', 'authenticated'),
        (a_plan,   'prueba.planning@oasis.invalid',   'authenticated', 'authenticated');

    SELECT count(*) INTO n FROM public.usuarios WHERE correo LIKE 'prueba.%@oasis.invalid' AND auth_user_id IS NOT NULL;
    r := r || format('%s  Trigger vincula los %s logins de prueba', CASE WHEN n = 8 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- ============================================================== ADMIN: cuadre
    r := r || format('--- ADMIN: cuadre contra v_inversion_diaria (año %s)', v_anio);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    FOREACH x IN ARRAY MERCADOS LOOP
        t0 := clock_timestamp();
        j := public.fn_dashboard_mercado(x, v_anio);
        seg := extract(epoch FROM clock_timestamp() - t0);

        -- por mes: suma de las filas agrupadas vs la vista
        SELECT array_agg(format('mes %s: %s vs %s', s.mes, s.dash, coalesce((e_mes ->> (x || '-' || s.mes))::numeric, 0)))
        INTO malos
        FROM (SELECT (e ->> 0)::int AS mes, sum((e ->> 7)::numeric) AS dash
              FROM jsonb_array_elements(j -> 'r') e GROUP BY 1) s
        WHERE abs(s.dash - coalesce((e_mes ->> (x || '-' || s.mes))::numeric, 0)) >= 1;
        SELECT count(*) INTO n FROM jsonb_object_keys(e_mes) k WHERE k LIKE x || '-%';
        SELECT count(DISTINCT (e ->> 0)) INTO n2 FROM jsonb_array_elements(j -> 'r') e;

        r := r || format('%s  %s: %s meses cuadran al peso con v_inversion_diaria (t = %s)%s',
                         CASE WHEN malos IS NULL AND n = n2 THEN 'OK   ' ELSE 'FALLA' END, x, n2,
                         to_char((j ->> 't')::numeric, 'FM999G999G999G990D00'),
                         CASE WHEN malos IS NULL THEN '' ELSE ': ' || array_to_string(malos, '; ') END);
        r := r || format('%s  %s: t = pf + ci = total de la vista',
                         CASE WHEN abs((j ->> 't')::numeric - (j ->> 'pf')::numeric - (j ->> 'ci')::numeric) < 0.05
                                   AND abs((j ->> 't')::numeric - coalesce((e_total ->> x)::numeric, 0)) < 1
                              THEN 'OK   ' ELSE 'FALLA' END, x);
        -- medio y ciudad reales (no índice 0 en todas las filas como el original)
        SELECT count(DISTINCT (e ->> 9)), count(DISTINCT (e ->> 10)) INTO n, n2 FROM jsonb_array_elements(j -> 'r') e;
        SELECT string_agg(DISTINCT j -> 's' ->> (e ->> 9)::int, ',') INTO t FROM jsonb_array_elements(j -> 'r') e;
        r := r || format('%s  %s: medio (%s) y ciudad (%s valores) salen de la compra',
                         CASE WHEN t ~ 'OOH' AND n2 > 1 THEN 'OK   ' ELSE 'FALLA' END, x, t, n2);
        r := r || format('%s  %s: %s s · %s filas agrupadas · jsonb %s KB',
                         CASE WHEN seg < LIMITE_SEG THEN 'OK   ' ELSE 'FALLA' END, x, round(seg, 2),
                         jsonb_array_length(j -> 'r'), round(octet_length(j::text) / 1024.0));
    END LOOP;

    t0 := clock_timestamp();
    j := public.fn_dashboard_portada(v_anio);
    seg := extract(epoch FROM clock_timestamp() - t0);
    SELECT array_agg(e ->> 'codigo') INTO malos FROM jsonb_array_elements(j -> 'mercados') e
    WHERE abs((e ->> 't')::numeric - coalesce((e_total ->> (e ->> 'codigo'))::numeric, 0)) >= 1;
    r := r || format('%s  Portada: %s mercados, cada total cuadra con la vista%s',
                     CASE WHEN malos IS NULL AND jsonb_array_length(j -> 'mercados') = 5 THEN 'OK   ' ELSE 'FALLA' END,
                     jsonb_array_length(j -> 'mercados'), coalesce(': no cuadran ' || array_to_string(malos, ','), ''));
    r := r || format('%s  Portada: %s s', CASE WHEN seg < LIMITE_SEG THEN 'OK   ' ELSE 'FALLA' END, round(seg, 2));

    t0 := clock_timestamp();
    j := public.fn_dashboard_latam(v_anio);
    seg := extract(epoch FROM clock_timestamp() - t0);
    SELECT array_agg(s.mercado) INTO malos FROM (
        SELECT e ->> 'mercado' AS mercado, sum((e ->> 'inv')::numeric) AS inv FROM jsonb_array_elements(j -> 'filas') e GROUP BY 1) s
    WHERE abs(s.inv - coalesce((e_total ->> s.mercado)::numeric, 0)) >= 1;
    r := r || format('%s  LATAM: lo local suma lo mismo que cada mercado%s',
                     CASE WHEN malos IS NULL THEN 'OK   ' ELSE 'FALLA' END, coalesce(': no cuadran ' || array_to_string(malos, ','), ''));
    SELECT count(*) INTO n FROM jsonb_array_elements(j -> 'filas') e
    JOIN jsonb_array_elements(j -> 'tasas') tc ON tc ->> 'mercado' = e ->> 'mercado'
    WHERE abs((e ->> 'usd')::numeric - round((e ->> 'inv')::numeric / (tc ->> 'valor_por_usd')::numeric, 2)) > 0.01;
    r := r || format('%s  LATAM: USD = local / tasa vigente en todas las filas (%s tasas)',
                     CASE WHEN n = 0 AND jsonb_array_length(j -> 'tasas') = 5 THEN 'OK   ' ELSE 'FALLA' END, jsonb_array_length(j -> 'tasas'));
    r := r || format('%s  LATAM: %s s · %s filas · %s KB', CASE WHEN seg < LIMITE_SEG THEN 'OK   ' ELSE 'FALLA' END,
                     round(seg, 2), jsonb_array_length(j -> 'filas'), round(octet_length(j::text) / 1024.0));

    -- tasas_cambio: ADMIN escribe; moneda y autor los pone la base
    INSERT INTO public.tasas_cambio (mercado_id, moneda, valor_por_usd, vigente_desde)
    VALUES (v_mco, 'XXX', 4000, current_date + 1);
    SELECT tc.moneda, u.correo INTO t, x FROM public.tasas_cambio tc LEFT JOIN public.usuarios u ON u.id = tc.actualizado_por
    WHERE tc.mercado_id = v_mco AND tc.vigente_desde = current_date + 1;
    r := r || format('%s  tasas_cambio: ADMIN agrega una tasa; la moneda (%s) y el autor (%s) los pone la base',
                     CASE WHEN t = 'COP' AND x = 'prueba.admin@oasis.invalid' THEN 'OK   ' ELSE 'FALLA' END, t, x);
    j := public.fn_dashboard_latam(v_anio);
    SELECT (tc ->> 'valor_por_usd')::numeric INTO num FROM jsonb_array_elements(j -> 'tasas') tc WHERE tc ->> 'mercado' = 'MCO';
    r := r || format('%s  Una tasa con vigencia futura no se usa todavía (MCO sigue en %s)',
                     CASE WHEN num <> 4000 THEN 'OK   ' ELSE 'FALLA' END, num);
    RESET ROLE;

    -- ============================================================== LECTURA y ZB
    r := r || text '--- LECTURA y ZB';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_lec, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_dashboard_portada(v_anio);
    r := r || format('%s  LECTURA ve los %s mercados (como ADMIN)',
                     CASE WHEN jsonb_array_length(j -> 'mercados') = 5 THEN 'OK   ' ELSE 'FALLA' END, jsonb_array_length(j -> 'mercados'));
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    j := public.fn_dashboard_portada(v_anio);
    SELECT string_agg(e ->> 'codigo', ',') INTO t FROM jsonb_array_elements(j -> 'mercados') e;
    r := r || format('%s  ZB de MCO ve solo MCO en la portada (%s)', CASE WHEN t = 'MCO' THEN 'OK   ' ELSE 'FALLA' END, t);
    BEGIN
        INSERT INTO public.tasas_cambio (mercado_id, moneda, valor_por_usd, vigente_desde) VALUES (v_mco, 'COP', 1, current_date + 2);
        r := r || text 'FALLA  ZB escribe en tasas_cambio';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     ZB no escribe en tasas_cambio';
    END;
    RESET ROLE;

    -- ============================================================== CLIENTE
    r := r || text '--- CLIENTE con MCO y MLC';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_cli, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    j := public.fn_dashboard_portada(v_anio);
    SELECT string_agg(e ->> 'codigo', ',' ORDER BY e ->> 'codigo') INTO t FROM jsonb_array_elements(j -> 'mercados') e;
    r := r || format('%s  Portada: ve solo %s', CASE WHEN t = 'MCO,MLC' THEN 'OK   ' ELSE 'FALLA' END, t);

    j := public.fn_dashboard_mercado('MCO', v_anio);
    r := r || format('%s  Mercado MCO: lo ve, con el mismo total que ADMIN',
                     CASE WHEN abs((j ->> 't')::numeric - (e_total ->> 'MCO')::numeric) < 1 THEN 'OK   ' ELSE 'FALLA' END);
    FOREACH x IN ARRAY ARRAY['MLA', 'MLM', 'MLU', 'XXX'] LOOP
        BEGIN
            j := public.fn_dashboard_mercado(x, v_anio);
            r := r || format('FALLA  Mercado %s: lo ve sin tenerlo asignado', x);
        EXCEPTION WHEN insufficient_privilege THEN
            r := r || format('OK     Mercado %s: error 42501', x);
        END;
    END LOOP;

    j := public.fn_dashboard_latam(v_anio);
    SELECT string_agg(DISTINCT e ->> 'mercado', ',') INTO t FROM jsonb_array_elements(j -> 'filas') e;
    SELECT string_agg(tc ->> 'mercado', ',' ORDER BY tc ->> 'mercado') INTO x FROM jsonb_array_elements(j -> 'tasas') tc;
    r := r || format('%s  LATAM: filas solo de %s y tasas solo de %s',
                     CASE WHEN t = 'MCO,MLC' AND x = 'MCO,MLC' THEN 'OK   ' ELSE 'FALLA' END, t, x);

    -- Ninguna tabla ni vista de public, salvo su propia fila de usuarios.
    malos := NULL;
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
             WHERE s.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p') ORDER BY 1 LOOP
        BEGIN
            EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
            IF n > 0 AND NOT (t = 'usuarios' AND n = 1) THEN
                malos := malos || format('%s (%s filas)', t, n);
            END IF;
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;   -- sin permiso: también vale
        END;
    END LOOP;
    SELECT count(*) INTO n FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
    WHERE s.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p');
    r := r || format('%s  No lee ninguna de las %s tablas y vistas de public (solo su fila de usuarios)%s',
                     CASE WHEN malos IS NULL THEN 'OK   ' ELSE 'FALLA' END, n,
                     coalesce(': ve ' || array_to_string(malos, ', '), ''));
    SELECT count(*) INTO n FROM storage.objects;
    r := r || format('%s  Storage: %s archivos visibles', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- Las funciones de inversión de la app tampoco le dan nada.
    SELECT count(*) INTO n FROM public.fn_inversion_total();
    SELECT count(*) INTO n2 FROM public.fn_inversion_filtrada(v_mco, '{}'::jsonb);
    r := r || format('%s  fn_inversion_total y fn_inversion_filtrada: %s y %s filas',
                     CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM public.fn_mis_compras();
    r := r || format('%s  fn_mis_compras: %s compras', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    BEGIN
        UPDATE public.compras SET valor_total = valor_total WHERE mercado_id = v_mco;
        GET DIAGNOSTICS n = ROW_COUNT;
        r := r || format('%s  No escribe en compras (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     No escribe en compras (sin permiso)';
    END;
    RESET ROLE;

    -- ============================================================== Sin acceso
    r := r || text '--- Sin acceso: AGENCIA, PROVEEDOR, PLANNING, CLIENTE desactivado';
    FOREACH a_sesion IN ARRAY ARRAY[a_ag, a_prov, a_plan, a_cli_in] LOOP
        SELECT rol::text || CASE WHEN activo THEN '' ELSE ' desactivado' END INTO x FROM public.usuarios WHERE auth_user_id = a_sesion;
        PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sesion, 'role', 'authenticated')::text, true);
        SET LOCAL ROLE authenticated;
        n := 0;
        BEGIN PERFORM public.fn_dashboard_portada(v_anio);        EXCEPTION WHEN insufficient_privilege THEN n := n + 1; END;
        BEGIN PERFORM public.fn_dashboard_mercado('MCO', v_anio); EXCEPTION WHEN insufficient_privilege THEN n := n + 1; END;
        BEGIN PERFORM public.fn_dashboard_latam(v_anio);          EXCEPTION WHEN insufficient_privilege THEN n := n + 1; END;
        SELECT count(*) INTO n2 FROM public.tasas_cambio;
        r := r || format('%s  %s: %s de 3 funciones dan error · tasas_cambio %s filas',
                         CASE WHEN n = 3 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, x, n, n2);
        RESET ROLE;
    END LOOP;

    -- anon no ejecuta nada del dashboard
    SET LOCAL ROLE anon;
    BEGIN
        PERFORM public.fn_dashboard_portada(v_anio);
        r := r || text 'FALLA  anon ejecuta fn_dashboard_portada';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     anon no ejecuta las funciones del dashboard';
    END;
    RESET ROLE;

    RAISE EXCEPTION E'PRUEBAS TERMINADAS — % FALLAS — todo revertido\n%',
        (SELECT count(*) FROM unnest(r) l WHERE l LIKE 'FALLA%'), array_to_string(r, E'\n');
END;
$pruebas$;
