-- =============================================================================
-- OASIS v2.0 — Pruebas de Mercado Pago, paso (b): alias por BU
-- =============================================================================
-- Requiere sql/mercado_pago.sql y sql/mercado_pago_alias.sql aplicados. Se corre
-- en el SQL Editor (o con la conexión de .env): crea usuarios y compras de
-- prueba, simula sesiones como la API y termina con un error a propósito que
-- revierte todo; el informe sale en el mensaje del error, OK o FALLA por línea.
-- (Las pruebas del paso (a) —la regla _(ML|MP)_— viven en mercados_pruebas.sql.)
-- =============================================================================

DO $pruebas$
DECLARE
    r      text[] := '{}';
    a_zb   uuid := gen_random_uuid();
    a_lec  uuid := gen_random_uuid();
    v_mlu  smallint;
    c_ml   bigint;
    c_mp   bigint;
    n      integer;
    n2     integer;
    t      text;
BEGIN
    SELECT id INTO v_mlu FROM public.mercados WHERE codigo = 'MLU';

    -- Una sola firma: con dos, la llamada rpc de Alertas sería ambigua.
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'public' AND p.proname = 'fn_asignar_taxonomia';
    r := r || format('%s  fn_asignar_taxonomia tiene una sola firma (%s)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);

    SELECT count(*) INTO n FROM public.campanas_alias
    WHERE mercado_id = v_mlu AND upper(btrim(texto_flow)) = 'PARQUE FIJO' AND bu = 'ML';
    r := r || format('%s  backfill: el alias precargado de MLU («PARQUE FIJO») quedó como ML', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);

    -- -------------------------------------------------------------- Preparación
    INSERT INTO public.usuarios (correo, nombre, rol) VALUES
        ('prueba.zb.mp@oasis.invalid',  'Prueba ZB MP',      'ZB'),
        ('prueba.lec.mp@oasis.invalid', 'Prueba lectura MP', 'LECTURA');
    INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
    SELECT id, v_mlu FROM public.usuarios WHERE correo = 'prueba.zb.mp@oasis.invalid';
    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_zb,  'prueba.zb.mp@oasis.invalid',  'authenticated', 'authenticated'),
        (a_lec, 'prueba.lec.mp@oasis.invalid', 'authenticated', 'authenticated');

    -- El mismo texto del Flow en una compra ML y una MP.
    INSERT INTO public.compras (mercado_id, codigo, cliente, valor_total, valor_total_manual, campana_texto)
    VALUES (v_mlu, 'PRUEBA-BU-ML', 'ML', 100, true, 'TEXTO MP DE PRUEBA') RETURNING id INTO c_ml;
    INSERT INTO public.compras (mercado_id, codigo, cliente, valor_total, valor_total_manual, campana_texto)
    VALUES (v_mlu, 'PRUEBA-BU-MP', 'MP', 100, true, 'TEXTO MP DE PRUEBA') RETURNING id INTO c_mp;

    -- ============================================================== ZB del mercado
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || text '--- ZB de MLU corrige campañas';

    n := public.fn_asignar_taxonomia(v_mlu, 'TEXTO MP DE PRUEBA', 'MLU_MP_OTH-PF_USUARIOS_PARQUE-FIJO_X');
    SELECT campana_taxonomia INTO t FROM public.compras WHERE id = c_mp;
    SELECT count(*) INTO n2 FROM public.compras WHERE id = c_ml AND campana_taxonomia IS NULL;
    r := r || format('%s  taxonomía MP: corrige %s compra (la MP queda %s) y la ML sigue intacta (%s)',
                     CASE WHEN n = 1 AND t = 'MLU_MP_OTH-PF_USUARIOS_PARQUE-FIJO_X' AND n2 = 1 THEN 'OK   ' ELSE 'FALLA' END,
                     n, t, n2);
    SELECT bu INTO t FROM public.campanas_alias WHERE mercado_id = v_mlu AND upper(btrim(texto_flow)) = 'TEXTO MP DE PRUEBA';
    r := r || format('%s  el alias quedó con BU %s, inferida de la taxonomía', CASE WHEN t = 'MP' THEN 'OK   ' ELSE 'FALLA' END, t);

    n := public.fn_asignar_taxonomia(v_mlu, 'TEXTO MP DE PRUEBA', 'MLU_ML_OTH-PF_ALL_PARQUE-FIJO_X');
    SELECT campana_taxonomia INTO t FROM public.compras WHERE id = c_ml;
    SELECT count(*) INTO n2 FROM public.campanas_alias WHERE mercado_id = v_mlu AND upper(btrim(texto_flow)) = 'TEXTO MP DE PRUEBA';
    r := r || format('%s  el mismo texto con taxonomía ML: corrige la compra ML (%s) y conviven %s alias, uno por BU',
                     CASE WHEN n = 1 AND t = 'MLU_ML_OTH-PF_ALL_PARQUE-FIJO_X' AND n2 = 2 THEN 'OK   ' ELSE 'FALLA' END, n, n2);

    PERFORM public.fn_asignar_taxonomia(v_mlu, 'texto mp de prueba', 'MLU_MP_UF-AW_USUARIOS_POINTSMART_X');
    SELECT count(*) INTO n2 FROM public.campanas_alias WHERE mercado_id = v_mlu AND upper(btrim(texto_flow)) = 'TEXTO MP DE PRUEBA';
    SELECT taxonomia INTO t FROM public.campanas_alias
    WHERE mercado_id = v_mlu AND upper(btrim(texto_flow)) = 'TEXTO MP DE PRUEBA' AND bu = 'MP';
    r := r || format('%s  repetir con otra taxonomía MP reemplaza ese alias, no crea otro (%s alias; MP → %s)',
                     CASE WHEN n2 = 2 AND t = 'MLU_MP_UF-AW_USUARIOS_POINTSMART_X' THEN 'OK   ' ELSE 'FALLA' END, n2, t);

    BEGIN
        PERFORM public.fn_asignar_taxonomia(v_mlu, 'OTRO TEXTO', 'MLU_MP_UF-AW_USUARIOS_POINTSMART_X', 'ML');
        r := r || text 'FALLA  BU pedida ML con taxonomía MP: la aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || format('OK     BU pedida ML con taxonomía MP: %s', SQLERRM);
    END;
    BEGIN
        PERFORM public.fn_asignar_taxonomia(v_mlu, 'OTRO TEXTO', 'PARQUE FIJO');
        r := r || text 'FALLA  texto sin formato de taxonomía: lo aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || text 'OK     texto sin formato de taxonomía: rechazado';
    END;
    RESET ROLE;

    -- ============================================================== Sin permiso
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_lec, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        PERFORM public.fn_asignar_taxonomia(v_mlu, 'TEXTO MP DE PRUEBA', 'MLU_MP_UF-AW_USUARIOS_POINTSMART_X');
        r := r || text 'FALLA  LECTURA corrigió una campaña';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     LECTURA no corrige campañas (42501)';
    END;
    RESET ROLE;

    -- ============================================================== La tabla misma
    BEGIN
        INSERT INTO public.campanas_alias (mercado_id, bu, texto_flow, taxonomia)
        VALUES (v_mlu, 'MP', '  texto mp de prueba ', 'MLU_MP_UF-AW_USUARIOS_POINTSMART_X');
        r := r || text 'FALLA  alias repetido (mercado, BU, texto): lo aceptó';
    EXCEPTION WHEN unique_violation THEN
        r := r || text 'OK     alias repetido (mercado, BU, texto): rechazado';
    END;
    BEGIN
        INSERT INTO public.campanas_alias (mercado_id, bu, texto_flow, taxonomia)
        VALUES (v_mlu, 'XX', 'OTRO', 'MLU_ML_OTH-PF_ALL_PARQUE-FIJO_X');
        r := r || text 'FALLA  BU inventada (XX): la aceptó';
    EXCEPTION WHEN check_violation THEN
        r := r || text 'OK     BU inventada (XX): rechazada por el CHECK';
    END;

    RAISE EXCEPTION E'PRUEBAS TERMINADAS — % FALLAS — todo revertido\n%',
        (SELECT count(*) FROM unnest(r) l WHERE l LIKE 'FALLA%'), array_to_string(r, E'\n');
END;
$pruebas$;
