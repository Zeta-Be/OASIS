-- =============================================================================
-- OASIS v2.0 — Pruebas de sql/campanas_familia.sql
-- =============================================================================
-- Correr en el SQL Editor (o con la conexión de .env). Agrega al glosario de
-- MLU campañas de prueba (ZQDUR, ZQPRE, ZQPPS-04-2026, ZQPPS-05-26), crea
-- compras con distintas taxonomías y termina con un error a propósito que
-- revierte todo; el informe sale en el mensaje del error, una línea OK o FALLA
-- por prueba.
--
-- Revisa:
--   * fn_campana_familia y fn_campana_anio con los casos del glosario real;
--   * exacta → con campaña del glosario y sin alerta;
--   * por familia → sin alerta, regla FAMILIA, sin campaña del glosario
--     (no se asigna una fase) y campana_grupo con el nombre corto;
--   * año de 2 y 4 dígitos, en los dos sentidos → sin alerta;
--   * otro número de PPS no es la misma campaña → con alerta;
--   * una campaña inventada → con alerta;
--   * equivalencias manuales: solo ADMIN escribe, se validan, quedan en
--     auditoría con el ADMIN y valen solo para su mercado y BU;
--   * columnas de v_inversion_diaria sin cambios (contrato con BI);
--   * v_alertas en menos de 2 s para un ADMIN.
-- =============================================================================

DO $pruebas$
DECLARE
    r        text[] := '{}';
    ok       text := 'OK   ';
    mal      text := 'FALLA';
    a_adm    uuid := gen_random_uuid();
    a_lec    uuid := gen_random_uuid();
    u_adm    bigint;
    v_mlu    smallint;
    c_exacta bigint;
    c_fam    bigint;
    c_anio   bigint;
    c_anio2  bigint;
    c_otro   bigint;
    c_inv    bigint;
    c_eq     bigint;
    c_eq_mp  bigint;
    n        integer;
    t        text;
    g        text;
    e_id     bigint;
    t0       timestamptz;
    ms       numeric;
    x        record;

    -- ¿La compra tiene la alerta «campaña fuera del glosario»?
    -- (subconsulta repetida en línea: plpgsql no tiene funciones locales)
BEGIN
    SELECT id INTO v_mlu FROM public.mercados WHERE codigo = 'MLU';

    -- ============================================================== Normalizaciones
    r := r || text '--- Familia y año';
    FOR x IN SELECT * FROM (VALUES
        ('MDDDUR', 'MDD'), ('CMPRE', 'CM'), ('CMDUR', 'CM'), ('CM-02', 'CM'), ('CMDUR-2', 'CM'), ('CMPRE-2', 'CM'),
        ('HSDUR', 'HS'), ('HSEXT', 'HS'), ('HS-01', 'HS'), ('HS-2', 'HS'), ('CYBFESTPRE', 'CYBFEST'), ('CYBFESTEXT', 'CYBFEST'),
        ('PPS-04-2026', 'PPS-04-26'), ('PPS-04-26', 'PPS-04-26'), ('BFDD', 'BFDD'), ('HSSHAKE', 'HSSHAKE'), ('PRE', 'PRE'),
        ('cm', 'CM')) v(entra, sale)
    LOOP
        t := public.fn_campana_familia(x.entra);
        IF t IS DISTINCT FROM x.sale THEN
            r := r || format('%s  familia de %s: %s (se esperaba %s)', mal, x.entra, t, x.sale);
        END IF;
    END LOOP;
    r := r || format('%s  familia: 18 casos del glosario real (CM-02, CMDUR-2, MDDDUR, PPS-04-2026, HSSHAKE…)',
                     CASE WHEN EXISTS (SELECT 1 FROM unnest(r) y WHERE y LIKE 'FALLA  familia%') THEN mal ELSE ok END);
    r := r || format('%s  año: PPS-04-2026 y PPS-04-26 iguales; PPS-04-26 y PPS-05-26 distintos',
                     CASE WHEN public.fn_campana_anio('PPS-04-2026') = public.fn_campana_anio('pps-04-26')
                               AND public.fn_campana_anio('PPS-04-26') <> public.fn_campana_anio('PPS-05-26') THEN ok ELSE mal END);

    -- ============================================================== Glosario y compras de prueba
    INSERT INTO public.campanas (mercado_id, nombre_unico, nombre_calendario) VALUES
        (v_mlu, 'ZQDUR', 'PRUEBA ZQ'), (v_mlu, 'ZQPRE', 'PRUEBA ZQ'),
        (v_mlu, 'ZQPPS-04-2026', 'PRUEBA PPS 4'), (v_mlu, 'ZQPPS-05-26', 'PRUEBA PPS 5');

    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-EXACTA', 0, true, 'MLU_ML_FE-T1_ALL_ZQDUR_X') RETURNING id INTO c_exacta;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-FAMILIA', 0, true, 'MLU_ML_FE-T1_ALL_ZQ_X') RETURNING id INTO c_fam;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-ANIO-2', 0, true, 'MLU_ML_FE-PPS_ALL_ZQPPS-04-26_X') RETURNING id INTO c_anio;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-ANIO-4', 0, true, 'MLU_ML_FE-PPS_ALL_ZQPPS-05-2026_X') RETURNING id INTO c_anio2;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-OTRO-PPS', 0, true, 'MLU_ML_FE-PPS_ALL_ZQPPS-06-26_X') RETURNING id INTO c_otro;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-INVENTADA', 0, true, 'MLU_ML_FE-T1_ALL_ZQINVENTADA_X') RETURNING id INTO c_inv;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia) VALUES
        (v_mlu, 'PRUEBA-EQUIV', 0, true, 'MLU_ML_FE-T1_ALL_ZQLUNES_X') RETURNING id INTO c_eq;
    INSERT INTO public.compras (mercado_id, codigo, valor_total, valor_total_manual, campana_taxonomia, cliente) VALUES
        (v_mlu, 'MP-PRUEBA-EQUIV', 0, true, 'MLU_MP_FE-T1_ALL_ZQLUNES_X', 'MP') RETURNING id INTO c_eq_mp;
    INSERT INTO public.materiales (compra_id, secuencia) VALUES (c_fam, 1);

    -- ============================================================== Reglas
    r := r || text '--- Reconocimiento';
    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_exacta AND alerta = 'campaña fuera del glosario';
    SELECT campana_id::text INTO t FROM public.compras WHERE id = c_exacta;
    r := r || format('%s  exacta (ZQDUR): campaña del glosario %s y sin alerta (%s)',
                     CASE WHEN t IS NOT NULL AND n = 0 THEN ok ELSE mal END, coalesce(t, 'vacía'), n);

    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_fam AND alerta = 'campaña fuera del glosario';
    SELECT regla || ' ' || familia || ' ' || array_to_string(glosario, '/') INTO t
    FROM public.v_campanas_sin_glosario WHERE taxonomia = 'MLU_ML_FE-T1_ALL_ZQ_X';
    SELECT campana_grupo INTO g FROM public.v_materiales WHERE compra_id = c_fam LIMIT 1;
    r := r || format('%s  por familia (ZQ ↔ ZQDUR/ZQPRE): sin alerta (%s), marcada «%s»',
                     CASE WHEN n = 0 AND t = 'FAMILIA ZQ ZQDUR/ZQPRE' THEN ok ELSE mal END, n, t);
    r := r || format('%s  por familia no elige fase: sin campaña del glosario y campana_grupo = %s',
                     CASE WHEN (SELECT campana_id FROM public.compras WHERE id = c_fam) IS NULL AND g = 'ZQ' THEN ok ELSE mal END, g);

    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id IN (c_anio, c_anio2) AND alerta = 'campaña fuera del glosario';
    SELECT string_agg(regla || ' ' || array_to_string(glosario, '/'), ' | ' ORDER BY taxonomia) INTO t
    FROM public.v_campanas_sin_glosario WHERE taxonomia IN ('MLU_ML_FE-PPS_ALL_ZQPPS-04-26_X', 'MLU_ML_FE-PPS_ALL_ZQPPS-05-2026_X');
    r := r || format('%s  año: compra -26 con glosario -2026 y compra -2026 con glosario -26, sin alerta (%s): %s',
                     CASE WHEN n = 0 AND t = 'AÑO ZQPPS-04-2026 | AÑO ZQPPS-05-26' THEN ok ELSE mal END, n, t);

    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_otro AND alerta = 'campaña fuera del glosario';
    r := r || format('%s  otro número (ZQPPS-06-26) no es la misma campaña: con alerta (%s)', CASE WHEN n = 1 THEN ok ELSE mal END, n);
    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_inv AND alerta = 'campaña fuera del glosario';
    r := r || format('%s  campaña inventada (ZQINVENTADA): con alerta (%s)', CASE WHEN n = 1 THEN ok ELSE mal END, n);
    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_eq AND alerta = 'campaña fuera del glosario';
    r := r || format('%s  sin equivalencia, ZQLUNES tiene alerta (%s)', CASE WHEN n = 1 THEN ok ELSE mal END, n);

    -- ============================================================== Equivalencias manuales
    r := r || text '--- Equivalencias manuales';
    INSERT INTO public.usuarios (correo, nombre, rol, activo) VALUES
        ('prueba.eq.admin@oasis.invalid', 'Prueba admin', 'ADMIN', true),
        ('prueba.eq.lectura@oasis.invalid', 'Prueba lectura', 'LECTURA', true);
    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_adm, 'prueba.eq.admin@oasis.invalid', 'authenticated', 'authenticated'),
        (a_lec, 'prueba.eq.lectura@oasis.invalid', 'authenticated', 'authenticated');
    SELECT id INTO u_adm FROM public.usuarios WHERE auth_user_id = a_adm;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_lec, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        INSERT INTO public.campanas_equivalencias (mercado_id, bu, texto, familia) VALUES (v_mlu, 'ML', 'ZQLUNES', 'ZQ');
        r := r || text 'FALLA  LECTURA escribió una equivalencia';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     LECTURA no escribe equivalencias (42501)';
    END;
    SELECT count(*) INTO n FROM public.v_campanas_sin_glosario WHERE mercado_id = v_mlu AND taxonomia LIKE '%\_ZQ%';
    r := r || format('%s  LECTURA lee v_campanas_sin_glosario (%s campañas de prueba)', CASE WHEN n = 7 THEN ok ELSE mal END, n);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_adm, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    BEGIN
        INSERT INTO public.campanas_equivalencias (mercado_id, bu, texto, familia) VALUES (v_mlu, 'ML', 'ZQLUNES', 'NOEXISTE');
        r := r || text 'FALLA  equivalencia a una familia que no está en el glosario: la aceptó';
    EXCEPTION WHEN check_violation THEN
        r := r || format('OK     familia que no está en el glosario: %s', SQLERRM);
    END;
    BEGIN
        INSERT INTO public.campanas_equivalencias (mercado_id, bu, texto, familia) VALUES (v_mlu, 'ML', 'ZQPRE', 'ZQ');
        r := r || text 'FALLA  equivalencia de algo que ya se reconoce solo: la aceptó';
    EXCEPTION WHEN check_violation THEN
        r := r || format('OK     texto que ya se reconoce solo: %s', SQLERRM);
    END;
    INSERT INTO public.campanas_equivalencias (mercado_id, bu, texto, familia) VALUES (v_mlu, 'ML', ' zqlunes ', 'zqdur')
    RETURNING id, texto || ' → ' || familia INTO e_id, t;
    r := r || format('%s  ADMIN la crea, normalizada: %s', CASE WHEN t = 'ZQLUNES → ZQ' THEN ok ELSE mal END, t);
    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_eq AND alerta = 'campaña fuera del glosario';
    SELECT regla INTO t FROM public.v_campanas_sin_glosario WHERE taxonomia = 'MLU_ML_FE-T1_ALL_ZQLUNES_X';
    r := r || format('%s  con la equivalencia, ZQLUNES (ML) sin alerta (%s), regla %s', CASE WHEN n = 0 AND t = 'EQUIVALENCIA' THEN ok ELSE mal END, n, t);
    SELECT count(*) INTO n FROM public.v_alertas WHERE compra_id = c_eq_mp AND alerta = 'campaña fuera del glosario';
    r := r || format('%s  la equivalencia es de ML: la misma campaña en MP sigue con alerta (%s)', CASE WHEN n = 1 THEN ok ELSE mal END, n);

    t0 := clock_timestamp();
    SELECT count(*) INTO n FROM public.v_alertas;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    r := r || format('%s  v_alertas completa para un ADMIN: %s filas en %s ms', CASE WHEN ms < 2000 THEN ok ELSE mal END, n, round(ms));
    t0 := clock_timestamp();
    SELECT count(*) INTO n FROM public.v_campanas_sin_glosario;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    r := r || format('%s  v_campanas_sin_glosario: %s campañas en %s ms', CASE WHEN ms < 2000 THEN ok ELSE mal END, n, round(ms));
    DELETE FROM public.campanas_equivalencias WHERE id = e_id;
    RESET ROLE;

    SELECT string_agg(campo || ' ' || coalesce(usuario_id::text, '∅'), ' | ' ORDER BY id) INTO t
    FROM public.auditoria WHERE tabla = 'campanas_equivalencias' AND fila_id = e_id;
    r := r || format('%s  auditoría con el ADMIN: %s', CASE WHEN t = format('(alta) %s | (baja) %s', u_adm, u_adm) THEN ok ELSE mal END, t);

    -- ============================================================== Contrato con BI
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO t
    FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_inversion_diaria';
    r := r || format('%s  v_inversion_diaria con sus 22 columnas en orden', CASE WHEN t =
        'site,bu,year,month,week,date,proveedor,tipo_costo,formato,valor_total,id,id_ejecucion,campana,sub_campana,'
        'pct_participacion,costo_proyectado,estado,costo_ejecutado,mes_compra,moneda,mercado_id,campana_grupo' THEN ok ELSE mal END);

    -- ============================================================== Informe
    RAISE EXCEPTION E'PRUEBAS DE CAMPAÑAS POR FAMILIA — %\n%',
        CASE WHEN EXISTS (SELECT 1 FROM unnest(r) y WHERE y LIKE 'FALLA%') THEN 'HAY FALLAS' ELSE 'TODAS OK' END,
        array_to_string(r, E'\n');
END;
$pruebas$;
