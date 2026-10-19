-- =============================================================================
-- OASIS v2.0 — Fase 3: pruebas del acceso externo
-- =============================================================================
-- Se corre después de fase3_portal.sql. NO deja nada en la base: es un solo
-- bloque que termina con un error a propósito, y ese error revierte todo
-- (usuarios de prueba, reportes, enlaces y filas de auditoría). El informe sale
-- en el mensaje del error: cada línea es OK o FALLA.
--
-- Cada sesión se simula como la arma la API: rol authenticated y el JWT en
-- request.jwt.claims, que es de donde auth.uid() saca el usuario.
--
-- Requiere sql/fase3_portal.sql y sql/fase3_evidencias.sql aplicados.
--
-- El proveedor de prueba es EFECTIMEDIOS (MCO). El 19-10-2026 tenía 218
-- materiales; si el Sheets agrega o quita materiales suyos, actualizar
-- ESPERADO_PROVEEDOR.
-- =============================================================================

DO $pruebas$
DECLARE
    ESPERADO_PROVEEDOR constant integer := 218;
    COLUMNAS_VISTA constant text := 'id,codigo,sub_campana,referencia,fecha_inicio,fecha_fin,enlace,reporte_implementacion,'
                                 || 'evidencia_url,compra,proveedor,formato,ubicacion,ciudad,tipo_costo';
    TABLAS_CERO constant text[] := ARRAY['compras', 'mercados', 'proveedores', 'proveedor_grupos', 'configuracion',
                                         'usuario_mercados', 'auditoria', 'duplicados_propuestos'];
    r        text[] := '{}';
    -- logins de prueba
    a_prov   uuid := gen_random_uuid();
    a_ag     uuid := gen_random_uuid();
    a_plan   uuid := gen_random_uuid();
    a_lec    uuid := gen_random_uuid();
    a_adm    uuid := gen_random_uuid();
    a_sesion uuid;
    u_prov   bigint;
    u_ag     bigint;
    u_plan   bigint;
    -- lo esperado, calculado como postgres
    v_mco         smallint;
    v_efect       integer;
    e_mat_prov    bigint[];
    e_comp_prov   integer;
    e_mat_mco     bigint[];
    e_comp_mco    integer;
    e_comp_total  integer;
    e_mat         bigint[];
    m_propio      bigint;
    m_ajeno       bigint;
    v_ref         text;
    v_fi          date;
    v_vistas      text[];
    -- auxiliares
    n        integer;
    n2       integer;
    ids      bigint[];
    t        text;
    d        date;
    x        text;
    m        public.materiales;
    -- evidencias
    v_otro_prov   integer;
    ev_propia     bigint;
    ev_ajena      bigint;
    ev_de_otro    bigint;
    ruta_propia   text;
    ruta_ajena    text;
    e             public.evidencias;
    k             bigint;
BEGIN
    -- -------------------------------------------------------------- Preparación
    SELECT id INTO v_mco FROM public.mercados WHERE codigo = 'MCO';
    SELECT id INTO v_efect FROM public.proveedores WHERE nombre = 'EFECTIMEDIOS' AND mercado_id = v_mco;

    SELECT array_agg(mt.id ORDER BY mt.id) INTO e_mat_prov
    FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id
    WHERE c.proveedor_id = v_efect;
    SELECT count(*) INTO e_comp_prov FROM public.compras WHERE proveedor_id = v_efect;

    SELECT array_agg(mt.id ORDER BY mt.id) INTO e_mat_mco
    FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id
    WHERE c.mercado_id = v_mco;
    SELECT count(*) INTO e_comp_mco FROM public.compras WHERE mercado_id = v_mco;
    SELECT count(*) INTO e_comp_total FROM public.compras;

    m_propio := e_mat_prov[1];
    SELECT mt.id INTO m_ajeno
    FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id
    WHERE c.proveedor_id <> v_efect AND c.mercado_id = v_mco
    ORDER BY mt.id LIMIT 1;
    SELECT referencia, fecha_inicio INTO v_ref, v_fi FROM public.materiales WHERE id = m_propio;

    -- Todas las vistas de public menos la de externos: deben darles cero filas.
    SELECT array_agg(viewname::text ORDER BY viewname) INTO v_vistas
    FROM pg_views WHERE schemaname = 'public' AND viewname <> 'v_materiales_externos';

    -- Usuarios primero; el trigger de auth.users completa auth_user_id al crear el login.
    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id) VALUES
        ('prueba.proveedor@oasis.invalid', 'Prueba proveedor', 'PROVEEDOR', v_efect),
        ('prueba.agencia@oasis.invalid',   'Prueba agencia',   'AGENCIA',   NULL),
        ('prueba.planning@oasis.invalid',  'Prueba planning',  'PLANNING',  NULL),
        ('prueba.lectura@oasis.invalid',   'Prueba lectura',   'LECTURA',   NULL),
        ('prueba.admin@oasis.invalid',     'Prueba admin',     'ADMIN',     NULL);
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
    SELECT id, v_mco FROM public.usuarios
    WHERE correo IN ('prueba.agencia@oasis.invalid', 'prueba.planning@oasis.invalid', 'prueba.lectura@oasis.invalid');

    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_prov, 'prueba.proveedor@oasis.invalid', 'authenticated', 'authenticated'),
        (a_ag,   'prueba.agencia@oasis.invalid',   'authenticated', 'authenticated'),
        (a_plan, 'prueba.planning@oasis.invalid',  'authenticated', 'authenticated'),
        (a_lec,  'prueba.lectura@oasis.invalid',   'authenticated', 'authenticated'),
        (a_adm,  'prueba.admin@oasis.invalid',     'authenticated', 'authenticated');

    SELECT id INTO u_prov FROM public.usuarios WHERE auth_user_id = a_prov;
    SELECT id INTO u_ag   FROM public.usuarios WHERE auth_user_id = a_ag;
    SELECT id INTO u_plan FROM public.usuarios WHERE auth_user_id = a_plan;
    r := r || format('%s  Trigger vincula los logins de prueba', CASE WHEN u_prov IS NOT NULL AND u_ag IS NOT NULL AND u_plan IS NOT NULL THEN 'OK   ' ELSE 'FALLA' END);
    r := r || format('       Base: EFECTIMEDIOS %s compras / %s materiales; MCO %s compras / %s materiales; %s vistas a revisar',
                     e_comp_prov, cardinality(e_mat_prov), e_comp_mco, cardinality(e_mat_mco), cardinality(v_vistas));

    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO t
    FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_materiales_externos';
    r := r || format('%s  v_materiales_externos tiene exactamente las columnas acordadas%s',
                     CASE WHEN t = COLUMNAS_VISTA THEN 'OK   ' ELSE 'FALLA' END,
                     CASE WHEN t = COLUMNAS_VISTA THEN '' ELSE ': ' || coalesce(t, '(no existe)') END);

    -- ============================================================== Externos: lectura
    -- La misma batería para los dos roles.
    FOREACH a_sesion IN ARRAY ARRAY[a_prov, a_ag] LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', a_sesion, 'role', 'authenticated')::text, true);
        SET LOCAL ROLE authenticated;

        IF a_sesion = a_prov THEN
            e_mat := e_mat_prov;
            r := r || text '--- PROVEEDOR (EFECTIMEDIOS): lectura';
            SELECT count(*), array_agg(id ORDER BY id) INTO n, ids FROM public.v_materiales_externos;
            r := r || format('%s  v_materiales_externos: ve %s materiales (esperado exactamente %s)',
                             CASE WHEN n = ESPERADO_PROVEEDOR AND ids = e_mat_prov THEN 'OK   ' ELSE 'FALLA' END, n, ESPERADO_PROVEEDOR);
            SELECT count(*) INTO n FROM public.v_materiales_externos WHERE proveedor <> 'EFECTIMEDIOS';
            r := r || format('%s  ninguno de otro proveedor (%s)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
            SELECT count(*) INTO n FROM public.fn_mis_compras();
            r := r || format('%s  fn_mis_compras(): %s compras (las %s de EFECTIMEDIOS)', CASE WHEN n = e_comp_prov THEN 'OK   ' ELSE 'FALLA' END, n, e_comp_prov);
        ELSE
            e_mat := e_mat_mco;
            r := r || text '--- AGENCIA (MCO): lectura';
            SELECT count(*), array_agg(id ORDER BY id) INTO n, ids FROM public.v_materiales_externos;
            r := r || format('%s  v_materiales_externos: ve %s materiales (todos los de MCO: %s)',
                             CASE WHEN ids = e_mat_mco THEN 'OK   ' ELSE 'FALLA' END, n, cardinality(e_mat_mco));
            SELECT count(*) INTO n FROM public.fn_mis_compras();
            r := r || format('%s  fn_mis_compras(): %s compras (las %s de MCO)', CASE WHEN n = e_comp_mco THEN 'OK   ' ELSE 'FALLA' END, n, e_comp_mco);
        END IF;

        SELECT array_agg(id ORDER BY id) INTO ids FROM public.materiales;
        r := r || format('%s  tabla materiales (política): %s filas, las mismas de la vista',
                         CASE WHEN ids = e_mat THEN 'OK   ' ELSE 'FALLA' END, coalesce(cardinality(ids), 0));

        SELECT count(*) INTO n FROM public.compras;
        r := r || format('%s  SELECT * FROM compras: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
        SELECT count(*) INTO n FROM public.v_inversion_diaria;
        r := r || format('%s  SELECT * FROM v_inversion_diaria: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

        t := NULL;
        FOREACH x IN ARRAY v_vistas LOOP
            BEGIN
                EXECUTE format('SELECT count(*) FROM public.%I', x) INTO n;
            EXCEPTION WHEN insufficient_privilege THEN
                n := 0;   -- sin permiso: tampoco ve nada
            END;
            IF n > 0 THEN t := coalesce(t || ', ', '') || x || '=' || n; END IF;
        END LOOP;
        r := r || format('%s  las otras %s vistas de public: todas con 0 filas%s',
                         CASE WHEN t IS NULL THEN 'OK   ' ELSE 'FALLA' END, cardinality(v_vistas), coalesce(' — con filas: ' || t, ''));
        r := r || format('       (%s)', array_to_string(v_vistas, ', '));

        SELECT (SELECT count(*) FROM public.fn_inversion_diaria()) + (SELECT count(*) FROM public.fn_inversion_semanal())
             + (SELECT count(*) FROM public.fn_inversion_total()) INTO n;
        r := r || format('%s  fn_inversion_diaria/semanal/total(): %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

        t := NULL;
        FOREACH x IN ARRAY TABLAS_CERO LOOP
            EXECUTE format('SELECT count(*) FROM public.%I', x) INTO n;
            IF n > 0 THEN t := coalesce(t || ', ', '') || x || '=' || n; END IF;
        END LOOP;
        r := r || format('%s  tablas %s: todas con 0 filas%s', CASE WHEN t IS NULL THEN 'OK   ' ELSE 'FALLA' END,
                         array_to_string(TABLAS_CERO, ', '), coalesce(' — con filas: ' || t, ''));

        SELECT count(*) INTO n FROM public.usuarios;
        r := r || format('%s  usuarios: %s fila (la suya)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
        SELECT count(*) INTO n FROM public.campanas
        WHERE id NOT IN (SELECT sub_campana_id FROM public.materiales WHERE sub_campana_id IS NOT NULL);
        r := r || format('%s  campanas: solo las sub campañas de sus materiales (%s de más)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

        RESET ROLE;
    END LOOP;

    -- ============================================================== PROVEEDOR: escritura
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_prov, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || text '--- PROVEEDOR (EFECTIMEDIOS): escritura';

    BEGIN
        m := public.fn_reportar_implementacion(m_propio, 'Instalado el lunes');
        r := r || format('%s  fn_reportar_implementacion en material suyo (%s)', CASE WHEN m.reporte_implementacion = 'Instalado el lunes' THEN 'OK   ' ELSE 'FALLA' END, m_propio);
    EXCEPTION WHEN others THEN
        r := r || format('FALLA  fn_reportar_implementacion en material suyo: %s', SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_reportar_implementacion(m_ajeno, 'x');
        r := r || text 'FALLA  fn_reportar_implementacion en material de otro proveedor: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || format('OK     fn_reportar_implementacion en material de otro proveedor: %s', SQLERRM);
    END;
    UPDATE public.materiales SET referencia = 'HACKEO' WHERE id = m_propio;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PATCH referencia por la API: %s filas cambiadas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    UPDATE public.materiales SET fecha_inicio = DATE '2000-01-01' WHERE id = m_propio;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PATCH fecha_inicio por la API: %s filas cambiadas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    UPDATE public.materiales SET reporte_implementacion = 'directo' WHERE id = m_propio;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PATCH del reporte sin la función: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    UPDATE public.compras SET valor_total = 1 WHERE proveedor_id = v_efect;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PATCH compras: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    DELETE FROM public.materiales WHERE id = m_propio;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  DELETE material: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    BEGIN
        INSERT INTO public.materiales (compra_id, secuencia) SELECT compra_id, 99 FROM public.materiales WHERE id = m_propio;
        r := r || text 'FALLA  INSERT material: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     INSERT material: rechazado por RLS';
    END;
    BEGIN
        UPDATE public.v_materiales_externos SET enlace = 'https://x.com/y' WHERE id = m_propio;
        r := r || text 'FALLA  UPDATE sobre v_materiales_externos: lo aceptó';
    EXCEPTION WHEN others THEN
        r := r || format('OK     UPDATE sobre v_materiales_externos: %s', SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_actualizar_enlace(m_propio, 'https://ejemplo.com/x');
        r := r || text 'FALLA  fn_actualizar_enlace como proveedor: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     fn_actualizar_enlace como proveedor: rechazado';
    END;
    BEGIN
        PERFORM public.fn_guardar_tramos(m_propio, '{"referencia":"HACKEO"}'::jsonb,
            jsonb_build_array(jsonb_build_object('compra_id', 1, 'fecha_inicio', '2026-01-01', 'fecha_fin', '2026-01-02')));
        r := r || text 'FALLA  fn_guardar_tramos como proveedor: lo aceptó';
    EXCEPTION WHEN others THEN
        r := r || format('OK     fn_guardar_tramos como proveedor: %s', SQLERRM);
    END;
    RESET ROLE;

    SELECT referencia, fecha_inicio INTO t, d FROM public.materiales WHERE id = m_propio;
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'materiales' AND fila_id = m_propio AND usuario_id = u_prov
      AND campo = 'reporte_implementacion';
    r := r || format('%s  auditoria: %s fila del reporte con el usuario del proveedor', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT evidencia_url INTO x FROM public.materiales WHERE id = m_propio;
    r := r || format('%s  el reporte ya no toca evidencia_url', CASE WHEN x IS NULL THEN 'OK   ' ELSE 'FALLA' END);
    SELECT count(*) INTO n FROM public.auditoria WHERE fila_id = m_propio AND campo IN ('referencia', 'fecha_inicio');
    r := r || format('%s  referencia y fecha_inicio intactas, sin auditoría de cambio',
                     CASE WHEN t IS NOT DISTINCT FROM v_ref AND d IS NOT DISTINCT FROM v_fi AND n = 0 THEN 'OK   ' ELSE 'FALLA' END);

    -- ============================================================== AGENCIA: escritura
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_ag, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || text '--- AGENCIA (MCO): escritura';
    BEGIN
        m := public.fn_actualizar_enlace(m_ajeno, 'https://drive.google.com/file/d/enlaceprueba99/view');
        r := r || format('%s  fn_actualizar_enlace en material de MCO', CASE WHEN m.enlace LIKE '%enlaceprueba99%' THEN 'OK   ' ELSE 'FALLA' END);
    EXCEPTION WHEN others THEN
        r := r || format('FALLA  fn_actualizar_enlace en material de MCO: %s', SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_actualizar_enlace(m_ajeno, 'no es un enlace');
        r := r || text 'FALLA  enlace no válido: lo aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || text 'OK     enlace no válido: rechazado';
    END;
    BEGIN
        PERFORM public.fn_reportar_implementacion(m_propio, 'x');
        r := r || text 'FALLA  fn_reportar_implementacion como agencia: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     fn_reportar_implementacion como agencia: rechazado';
    END;
    UPDATE public.materiales SET referencia = 'HACKEO', enlace = 'https://x.com/y' WHERE id = m_propio;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PATCH referencia/enlace directo por la API: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    UPDATE public.compras SET valor_total = 1 WHERE mercado_id = v_mco;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PATCH compras: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;
    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'materiales' AND fila_id = m_ajeno AND usuario_id = u_ag AND campo = 'enlace';
    r := r || format('%s  auditoria: cambio de enlace con el usuario de la agencia', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);


    -- ============================================================== Evidencias y Storage
    r := r || text '--- Evidencias (tabla y bucket)';
    SELECT id::text = 'evidencias' AND NOT public AND file_size_limit = 52428800
           AND allowed_mime_types @> ARRAY['image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm']
           AND cardinality(allowed_mime_types) = 6
      INTO STRICT x
    FROM storage.buckets WHERE id = 'evidencias';
    r := r || format('%s  bucket evidencias: privado, 50 MB por archivo, solo fotos y videos permitidos', CASE WHEN x = 'true' THEN 'OK   ' ELSE 'FALLA' END);

    -- Lo ajeno lo pone postgres: un archivo y un enlace en un material de otro
    -- proveedor, y un enlace en un material de EFECTIMEDIOS subido por otra persona.
    SELECT c.proveedor_id INTO v_otro_prov FROM public.materiales mt JOIN public.compras c ON c.id = mt.compra_id WHERE mt.id = m_ajeno;
    ruta_ajena := v_otro_prov || '/' || m_ajeno || '/ajena.jpg';
    INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
    VALUES ('evidencias', ruta_ajena, a_plan::text, '{"size": 1000, "mimetype": "image/jpeg"}');
    INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_ajeno, 'ENLACE', 'https://ejemplo.com/ajena') RETURNING id INTO ev_ajena;
    INSERT INTO public.evidencias (material_id, tipo, url, subido_por) VALUES (m_propio, 'ENLACE', 'https://ejemplo.com/de-otro', u_plan) RETURNING id INTO ev_de_otro;

    -- PROVEEDOR ---------------------------------------------------------------
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_prov, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;

    ruta_propia := v_efect || '/' || m_propio || '/prueba.jpg';
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
        VALUES ('evidencias', ruta_propia, a_prov::text, '{"size": 150000, "mimetype": "image/jpeg"}');
        r := r || text 'OK     PROVEEDOR sube a su carpeta, en material suyo';
    EXCEPTION WHEN others THEN
        r := r || format('FALLA  PROVEEDOR sube a su carpeta, en material suyo: %s', SQLERRM);
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, ruta_storage, tamano_bytes, nombre_archivo)
        VALUES (m_propio, 'FOTO', ruta_propia, 1, 'prueba.jpg') RETURNING * INTO e;
        ev_propia := e.id;
        r := r || format('%s  registra la FOTO: tamaño real %s bytes (no el 1 que mandó), subido_por suyo',
                         CASE WHEN e.tamano_bytes = 150000 AND e.subido_por = u_prov THEN 'OK   ' ELSE 'FALLA' END, e.tamano_bytes);
    EXCEPTION WHEN others THEN
        r := r || format('FALLA  registra la FOTO: %s', SQLERRM);
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_propio, 'ENLACE', 'https://drive.google.com/file/d/prueba123456/view');
        r := r || text 'OK     registra un ENLACE https en material suyo';
    EXCEPTION WHEN others THEN
        r := r || format('FALLA  registra un ENLACE https en material suyo: %s', SQLERRM);
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_propio, 'ENLACE', 'http://ejemplo.com/foto.jpg');
        r := r || text 'FALLA  ENLACE http:// (sin s): lo aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || format('OK     ENLACE http:// (sin s): %s', SQLERRM);
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_propio, 'ENLACE', 'javascript:alert(1)');
        r := r || text 'FALLA  ENLACE que no es enlace: lo aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || text 'OK     ENLACE que no es enlace: rechazado';
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_ajeno, 'ENLACE', 'https://ejemplo.com/x');
        r := r || text 'FALLA  evidencia en material ajeno: la aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     evidencia en material ajeno: rechazada por RLS';
    END;
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
        VALUES ('evidencias', v_otro_prov || '/' || m_ajeno || '/intruso.jpg', a_prov::text, '{"size": 10, "mimetype": "image/jpeg"}');
        r := r || text 'FALLA  subir a la carpeta de otro proveedor: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     subir a la carpeta de otro proveedor: rechazado';
    END;
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
        VALUES ('evidencias', v_efect || '/' || m_ajeno || '/intruso.jpg', a_prov::text, '{"size": 10, "mimetype": "image/jpeg"}');
        r := r || text 'FALLA  subir a su carpeta pero en material ajeno: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     subir a su carpeta pero en material ajeno: rechazado';
    END;
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
        VALUES ('evidencias', v_efect || '/' || m_propio || '/sub/../x.jpg', a_prov::text, '{"size": 10, "mimetype": "image/jpeg"}');
        r := r || text 'FALLA  ruta con carpetas de más: la aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     ruta con carpetas de más: rechazada';
    END;
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
        VALUES ('evidencias', v_efect || '/' || m_propio || '/grande.jpg', a_prov::text, '{"size": 3145728, "mimetype": "image/jpeg"}');
        INSERT INTO public.evidencias (material_id, tipo, ruta_storage, tamano_bytes)
        VALUES (m_propio, 'FOTO', v_efect || '/' || m_propio || '/grande.jpg', 1);
        r := r || text 'FALLA  FOTO de 3 MB: la aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || format('OK     FOTO de 3 MB: %s', SQLERRM);
    END;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, ruta_storage, tamano_bytes)
        VALUES (m_ajeno, 'FOTO', ruta_ajena, 1);
        r := r || text 'FALLA  registrar como suyo el archivo de otro: lo aceptó';
    EXCEPTION WHEN insufficient_privilege OR invalid_parameter_value THEN
        r := r || format('OK     registrar como suyo el archivo de otro: %s', SQLERRM);
    END;

    SELECT count(*) INTO n FROM public.evidencias WHERE id = ev_ajena;
    SELECT count(*) INTO n2 FROM storage.objects WHERE bucket_id = 'evidencias' AND name = ruta_ajena;
    r := r || format('%s  no lee la evidencia ajena (%s) ni el archivo ajeno (%s)', CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM public.evidencias WHERE material_id = m_propio;
    r := r || format('%s  lee las evidencias de su material: %s (foto, enlace y la de otra persona)', CASE WHEN n = 3 THEN 'OK   ' ELSE 'FALLA' END, n);

    DELETE FROM public.evidencias WHERE id = ev_ajena;
    GET DIAGNOSTICS n = ROW_COUNT;
    DELETE FROM public.evidencias WHERE id = ev_de_otro;
    GET DIAGNOSTICS n2 = ROW_COUNT;
    r := r || format('%s  no borra la evidencia ajena (%s) ni la que subió otra persona en su material (%s)', CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    BEGIN
        UPDATE public.evidencias SET url = 'https://ejemplo.com/cambiada' WHERE id = ev_de_otro;
        r := r || text 'FALLA  UPDATE de evidencias: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     UPDATE de evidencias: sin permiso (nadie actualiza)';
    END;
    UPDATE storage.objects SET metadata = '{"size": 1}' WHERE bucket_id = 'evidencias' AND name = ruta_propia;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  UPDATE de su archivo en el bucket: %s filas (nadie actualiza)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- Borrado directo en storage.objects: la API de Storage activa este permiso.
    PERFORM set_config('storage.allow_delete_query', 'true', true);
    DELETE FROM storage.objects WHERE bucket_id = 'evidencias' AND name = ruta_ajena;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  no borra el archivo ajeno del bucket (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    -- Mismo orden que el portal: archivo primero, fila después.
    DELETE FROM storage.objects WHERE bucket_id = 'evidencias' AND name = ruta_propia;
    GET DIAGNOSTICS n2 = ROW_COUNT;
    DELETE FROM public.evidencias WHERE id = ev_propia;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  borra su archivo (%s) y después su evidencia (%s)', CASE WHEN n = 1 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END, n2, n);
    PERFORM set_config('storage.allow_delete_query', 'false', true);
    SELECT public.fn_uso_storage() IS NULL INTO STRICT x;
    SELECT count(*) INTO n FROM public.fn_evidencias_huerfanas();
    r := r || format('%s  fn_uso_storage() para un externo: nulo; fn_evidencias_huerfanas(): %s filas', CASE WHEN x = 'true' AND n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;

    SELECT count(*) INTO n FROM public.auditoria
    WHERE tabla = 'evidencias' AND usuario_id = u_prov AND campo IN ('(alta)', '(baja)');
    r := r || format('%s  auditoria de evidencias: %s filas (altas y baja del proveedor)', CASE WHEN n = 3 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- AGENCIA -----------------------------------------------------------------
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_ag, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_propio, 'ENLACE', 'https://ejemplo.com/agencia');
        r := r || text 'FALLA  AGENCIA inserta evidencia: la aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     AGENCIA inserta evidencia: rechazada';
    END;
    BEGIN
        INSERT INTO storage.objects (bucket_id, name, owner_id, metadata)
        VALUES ('evidencias', v_efect || '/' || m_propio || '/agencia.jpg', a_ag::text, '{"size": 10, "mimetype": "image/jpeg"}');
        r := r || text 'FALLA  AGENCIA sube al bucket: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     AGENCIA sube al bucket: rechazado';
    END;
    SELECT count(*) INTO n FROM public.evidencias WHERE id IN (ev_ajena, ev_de_otro);
    SELECT count(*) INTO n2 FROM storage.objects WHERE bucket_id = 'evidencias' AND name = ruta_ajena;
    r := r || format('%s  AGENCIA lee evidencias (%s) y archivos (%s) de MCO', CASE WHEN n = 2 AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    DELETE FROM public.evidencias WHERE id = ev_ajena;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  AGENCIA no borra evidencias (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;

    -- Internos ------------------------------------------------------------------
    -- Lo esperado, como postgres: todo lo que ocupa el bucket, con huérfanos.
    SELECT coalesce(sum((metadata ->> 'size')::bigint), 0) INTO n2 FROM storage.objects WHERE bucket_id = 'evidencias';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_plan, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.evidencias WHERE id IN (ev_ajena, ev_de_otro);
    r := r || format('%s  PLANNING lee las evidencias de MCO (%s)', CASE WHEN n = 2 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT public.fn_uso_storage() INTO k;
    r := r || format('%s  fn_uso_storage() = %s bytes: el tamaño real del bucket, con el archivo huérfano (esperado %s)',
                     CASE WHEN k = n2 AND k >= 1000 THEN 'OK   ' ELSE 'FALLA' END, k, n2);
    SELECT count(*) INTO n FROM public.fn_evidencias_huerfanas() WHERE ruta = ruta_ajena;
    r := r || format('%s  fn_evidencias_huerfanas() detecta el archivo sin fila en evidencias', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);
    BEGIN
        INSERT INTO public.evidencias (material_id, tipo, url) VALUES (m_propio, 'ENLACE', 'https://ejemplo.com/planning');
        r := r || text 'FALLA  PLANNING inserta evidencia: la aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     PLANNING inserta evidencia: rechazada (las sube el proveedor)';
    END;
    DELETE FROM public.evidencias WHERE id = ev_ajena;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PLANNING no borra evidencias (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    DELETE FROM public.evidencias WHERE id = ev_ajena;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  ADMIN borra cualquier evidencia (%s fila)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;

    -- ============================================================== Internos
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_plan, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || text '--- Internos';
    SELECT count(*) INTO n FROM public.compras;
    SELECT count(*) INTO n2 FROM public.materiales;
    r := r || format('%s  PLANNING ve %s compras y %s materiales de MCO', CASE WHEN n = e_comp_mco AND n2 = cardinality(e_mat_mco) THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM public.fn_inversion_total();
    r := r || format('%s  PLANNING lee fn_inversion_total(): %s filas', CASE WHEN n > 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT (SELECT count(*) FROM public.v_materiales_externos) + (SELECT count(*) FROM public.fn_mis_compras()) INTO n;
    r := r || format('%s  PLANNING en v_materiales_externos y fn_mis_compras(): %s filas (son solo para externos)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    UPDATE public.materiales SET referencia = coalesce(referencia, '') || ' (prueba)' WHERE id = m_propio;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  PLANNING edita la referencia: %s fila', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT count(*) INTO n FROM public.auditoria;
    r := r || format('%s  PLANNING no lee auditoria: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    BEGIN
        PERFORM public.fn_reportar_implementacion(m_propio, 'x');
        r := r || text 'FALLA  fn_reportar_implementacion como PLANNING: la aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     fn_reportar_implementacion como PLANNING: rechazada (edita en Materiales)';
    END;
    RESET ROLE;
    SELECT count(*) INTO n FROM public.auditoria WHERE fila_id = m_propio AND campo = 'referencia' AND usuario_id = u_plan;
    r := r || format('%s  auditoria registra el cambio de PLANNING', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);

    -- Escala numérica: reescribir un monto igual con otra escala no es un cambio.
    UPDATE public.compras SET valor_total = round(valor_total, 2) + 0.00 WHERE mercado_id = v_mco;
    GET DIAGNOSTICS n2 = ROW_COUNT;
    SELECT count(*) INTO n FROM public.auditoria WHERE tabla = 'compras' AND campo = 'valor_total';
    r := r || format('%s  auditoria ignora el cambio de escala de valor_total en %s compras (%s filas)', CASE WHEN n = 0 AND n2 > 0 THEN 'OK   ' ELSE 'FALLA' END, n2, n);

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_lec, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.compras;
    UPDATE public.materiales SET referencia = 'x' WHERE id = m_propio;
    GET DIAGNOSTICS n2 = ROW_COUNT;
    -- LECTURA ve todos los mercados (sql/mercados.sql), aunque solo tenga MCO asignado.
    r := r || format('%s  LECTURA ve %s compras (todas: %s) y no edita (%s filas)', CASE WHEN n = e_comp_total AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, e_comp_total, n2);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO n FROM public.auditoria;
    r := r || format('%s  ADMIN lee auditoria: %s filas', CASE WHEN n > 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT count(*) INTO n FROM public.compras;
    r := r || format('%s  ADMIN ve %s compras (todas: %s)', CASE WHEN n = e_comp_total THEN 'OK   ' ELSE 'FALLA' END, n, e_comp_total);
    BEGIN
        INSERT INTO public.auditoria (tabla, fila_id, campo) VALUES ('x', 1, 'x');
        r := r || text 'FALLA  ADMIN escribe en auditoria';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     nadie escribe en auditoria por la API (ni ADMIN)';
    END;
    RESET ROLE;

    SET LOCAL ROLE anon;
    BEGIN
        SELECT count(*) INTO n FROM public.v_materiales_externos;
        r := r || format('FALLA  anon lee v_materiales_externos (%s filas)', n);
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     anon no puede leer v_materiales_externos';
    END;
    RESET ROLE;

    SELECT count(*) INTO n FROM unnest(r) l WHERE l LIKE 'FALLA%';
    RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = format(E'PRUEBAS TERMINADAS — %s — todo revertido\n',
                         CASE WHEN n = 0 THEN 'TODAS OK' ELSE n || ' FALLAS' END) || array_to_string(r, E'\n');
END
$pruebas$;
