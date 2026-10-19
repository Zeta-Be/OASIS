-- =============================================================================
-- OASIS v2.0 — Pruebas de varios mercados
-- =============================================================================
-- Se corre después de sql/mercados.sql y de cargar los mercados. NO deja nada
-- en la base: un solo bloque que termina con un error a propósito; el informe
-- sale en el mensaje del error, una línea OK o FALLA por prueba.
--
--   1. Un Equipo ZB de MLC no ve nada de MCO (ni compras, ni materiales, ni
--      alertas, ni inversión).
--   2. LECTURA ve todos los mercados, aunque solo tenga uno asignado.
--   3. La inversión de cada mercado cuadra con el valor total de sus compras.
--   4. Una compra con TIPO DE COSTO vacío (y sin campaña ni proveedor) no
--      rompe ninguna vista y reparte su valor completo.
--   5. Corregir la taxonomía desde Alertas: arregla las compras, guarda el
--      alias y queda en auditoría; solo en los mercados propios.
-- =============================================================================

DO $pruebas$
DECLARE
    r        text[] := '{}';
    a_zb     uuid := gen_random_uuid();
    a_lec    uuid := gen_random_uuid();
    u_zb     bigint;
    v_mco    smallint;
    v_mlc    smallint;
    v_compra bigint;
    v_alto   integer;
    n        integer;
    n2       integer;
    x        numeric;
    y        numeric;
    t        text;
    e_mercados_con_compras integer;
    e_compras_mlc integer;
    fila     record;
BEGIN
    SELECT id INTO v_mco FROM mercados WHERE codigo = 'MCO';
    SELECT id INTO v_mlc FROM mercados WHERE codigo = 'MLC';
    SELECT id INTO v_alto FROM campanas WHERE mercado_id = v_mlc AND nombre_unico = 'ALTO-IMPACTO';
    SELECT count(*) INTO e_compras_mlc FROM compras WHERE mercado_id = v_mlc;

    INSERT INTO usuarios (correo, nombre, rol) VALUES
        ('prueba.zb.mlc@oasis.invalid', 'Prueba ZB MLC', 'ZB'),
        ('prueba.lectura@oasis.invalid', 'Prueba lectura', 'LECTURA');
    INSERT INTO usuario_mercados (usuario_id, mercado_id)
    SELECT id, v_mlc FROM usuarios WHERE correo = 'prueba.zb.mlc@oasis.invalid'
    UNION ALL SELECT id, v_mco FROM usuarios WHERE correo = 'prueba.lectura@oasis.invalid';
    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_zb,  'prueba.zb.mlc@oasis.invalid',  'authenticated', 'authenticated'),
        (a_lec, 'prueba.lectura@oasis.invalid', 'authenticated', 'authenticated');
    SELECT id INTO u_zb FROM usuarios WHERE auth_user_id = a_zb;

    r := r || format('       Base: MLC %s compras', e_compras_mlc);

    -- La compra de prueba (como postgres): sin tipo de costo, campaña ni
    -- proveedor, con un material de 10 días. Su valor tiene que repartirse entero.
    INSERT INTO compras (mercado_id, codigo, valor_total, valor_total_manual, fecha_inicio, fecha_fin, campana_texto)
    VALUES (v_mlc, 'PRUEBA-NULL', 1000, true, DATE '2026-03-01', DATE '2026-03-10', 'TEXTO DE PRUEBA SIN TAXONOMIA')
    RETURNING id INTO v_compra;
    INSERT INTO materiales (compra_id, secuencia, fecha_inicio, fecha_fin)
    VALUES (v_compra, 1, DATE '2026-03-01', DATE '2026-03-10');
    -- Después de la compra de prueba: si MLC no tenía compras, ahora cuenta.
    SELECT count(DISTINCT mercado_id) INTO e_mercados_con_compras FROM compras;

    -- ============================================================== 4. tipo de costo vacío
    r := r || text '--- Compra con TIPO DE COSTO vacío';
    SELECT count(*), sum(costo_proyectado) INTO n, x FROM v_inversion_diaria WHERE id = 'PRUEBA-NULL' AND mercado_id = v_mlc;
    r := r || format('%s  v_inversion_diaria: %s días que suman %s (esperado 10 y 1000)', CASE WHEN n = 10 AND x = 1000 THEN 'OK   ' ELSE 'FALLA' END, n, x);
    SELECT sum(costo_proyectado) INTO x FROM v_inversion_semanal WHERE id = 'PRUEBA-NULL' AND mercado_id = v_mlc;
    SELECT sum(costo_proyectado) INTO y FROM v_inversion_total WHERE id = 'PRUEBA-NULL' AND mercado_id = v_mlc;
    r := r || format('%s  v_inversion_semanal (%s) y v_inversion_total (%s) también', CASE WHEN x = 1000 AND y = 1000 THEN 'OK   ' ELSE 'FALLA' END, x, y);
    SELECT count(*) INTO n FROM v_materiales WHERE compra_codigo = 'PRUEBA-NULL';
    SELECT moneda INTO t FROM v_inversion_diaria WHERE id = 'PRUEBA-NULL' LIMIT 1;
    r := r || format('%s  v_materiales la muestra (%s) y la moneda es %s', CASE WHEN n = 1 AND t = 'CLP' THEN 'OK   ' ELSE 'FALLA' END, n, t);
    SELECT count(*) INTO n FROM v_cuadre WHERE codigo = 'PRUEBA-NULL';
    r := r || format('%s  no aparece en v_cuadre (%s)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT string_agg(alerta, ', ' ORDER BY alerta) INTO t FROM v_alertas WHERE compra_id = v_compra;
    r := r || format('%s  alertas de la compra: %s', CASE WHEN t LIKE '%compra sin tipo de costo%' AND t LIKE '%compra incompleta%' AND t LIKE '%campaña sin taxonomía%' THEN 'OK   ' ELSE 'FALLA' END, t);

    -- ============================================================== 3. cuadre por mercado
    r := r || text '--- La inversión cuadra con el valor total, mercado por mercado';
    -- Única excepción conocida: la 371 de MLA, un material de 365 días en una
    -- compra de enero (−1,10 ARS de redondeo). Se va cuando se parta.
    SELECT count(*), string_agg(m.codigo || ' ' || q.codigo, ', ') INTO n, t
    FROM v_cuadre q JOIN compras c ON c.codigo = q.codigo AND c.valor_total = q.valor_total JOIN mercados m ON m.id = c.mercado_id;
    r := r || format('%s  v_cuadre vacío salvo la 371 de MLA: %s', CASE WHEN n = 0 OR (n = 1 AND t = 'MLA 371') THEN 'OK   ' ELSE 'FALLA' END, coalesce(t, 'vacío'));
    FOR fila IN
        SELECT m.codigo, m.moneda,
               (SELECT coalesce(sum(costo_proyectado), 0) FROM v_inversion_diaria d WHERE d.mercado_id = m.id) AS repartido,
               (SELECT coalesce(sum(c.valor_total), 0) FROM compras c WHERE c.mercado_id = m.id
                  AND EXISTS (SELECT 1 FROM materiales mt WHERE mt.compra_id = c.id AND mt.fecha_inicio IS NOT NULL)) AS valor,
               (SELECT count(*) FROM compras c WHERE c.mercado_id = m.id) AS compras
        FROM mercados m
        WHERE EXISTS (SELECT 1 FROM compras c WHERE c.mercado_id = m.id)
        ORDER BY m.codigo
    LOOP
        -- Redondeo a centavos por día: como mucho un centavo por compra.
        r := r || format('%s  %s: repartido %s = valor total %s %s (diferencia %s)',
            CASE WHEN abs(fila.repartido - fila.valor) <= greatest(fila.compras, 1) * 0.01 THEN 'OK   ' ELSE 'FALLA' END,
            fila.codigo, round(fila.repartido, 2), round(fila.valor, 2), fila.moneda, round(fila.repartido - fila.valor, 2));
    END LOOP;

    -- ============================================================== 1. ZB de MLC
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || text '--- Equipo ZB con solo MLC';
    SELECT array_to_string(array_agg(m ORDER BY m), ',') INTO t FROM fn_mis_mercados() m;
    r := r || format('%s  fn_mis_mercados(): %s (solo MLC)', CASE WHEN t = v_mlc::text THEN 'OK   ' ELSE 'FALLA' END, t);
    SELECT count(*) FILTER (WHERE mercado_id <> v_mlc), count(*) INTO n, n2 FROM compras;
    r := r || format('%s  compras: %s de otro mercado, %s de MLC (esperado %s + la de prueba)',
        CASE WHEN n = 0 AND n2 = e_compras_mlc + 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2, e_compras_mlc);
    SELECT count(*) INTO n FROM materiales mt WHERE mt.compra_id IN (SELECT id FROM compras WHERE mercado_id = v_mco);
    SELECT count(*) INTO n2 FROM v_materiales WHERE mercado_id <> v_mlc;
    r := r || format('%s  materiales de MCO: %s; v_materiales de otro mercado: %s', CASE WHEN n = 0 AND n2 = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(*) INTO n FROM v_alertas WHERE mercado_id <> v_mlc;
    r := r || format('%s  v_alertas de otro mercado: %s', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT (SELECT count(*) FROM fn_inversion_total() WHERE mercado_id <> v_mlc)
         + (SELECT count(*) FROM fn_inversion_diaria() WHERE mercado_id <> v_mlc) INTO n;
    r := r || format('%s  inversión (total y diaria) de otro mercado: %s filas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    SELECT (SELECT count(*) FROM duplicados_propuestos WHERE mercado_id <> v_mlc)
         + (SELECT count(*) FROM campanas_alias WHERE mercado_id <> v_mlc) INTO n;
    r := r || format('%s  duplicados y alias de otro mercado: %s', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    -- ============================================================== 5. taxonomía desde Alertas
    r := r || text '--- Corregir la taxonomía desde Alertas';
    BEGIN
        PERFORM fn_asignar_taxonomia(v_mlc, 'TEXTO DE PRUEBA SIN TAXONOMIA', 'no es taxonomia');
        r := r || text 'FALLA  taxonomía sin formato: la aceptó';
    EXCEPTION WHEN invalid_parameter_value THEN
        r := r || format('OK     taxonomía sin formato: %s', SQLERRM);
    END;
    BEGIN
        PERFORM fn_asignar_taxonomia(v_mco, 'PARQUE FIJO', 'MCO_ML_OTH-PF_ALL_PARQUE-FIJO_X');
        r := r || text 'FALLA  ZB de MLC corrige en MCO: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     ZB de MLC no corrige en MCO';
    END;
    n := fn_asignar_taxonomia(v_mlc, 'texto de prueba sin taxonomia', 'MLC_ML_OTH-PF_ALL_ALTO-IMPACTO_X');
    r := r || format('%s  corrige %s compra (sin distinguir mayúsculas)', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END, n);
    RESET ROLE;
    SELECT campana_id, campana_taxonomia INTO n2, t FROM compras WHERE id = v_compra;
    r := r || format('%s  la compra queda en ALTO-IMPACTO (%s) con su taxonomía', CASE WHEN n2 = v_alto AND t = 'MLC_ML_OTH-PF_ALL_ALTO-IMPACTO_X' THEN 'OK   ' ELSE 'FALLA' END, n2);
    SELECT count(*) INTO n FROM campanas_alias WHERE mercado_id = v_mlc AND upper(texto_flow) = 'TEXTO DE PRUEBA SIN TAXONOMIA' AND creado_por = u_zb;
    r := r || format('%s  alias guardado con el usuario', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);
    SELECT count(*) INTO n FROM auditoria WHERE tabla = 'compras' AND fila_id = v_compra AND campo = 'campana_id' AND usuario_id = u_zb;
    r := r || format('%s  auditoría del cambio de campaña con el usuario', CASE WHEN n = 1 THEN 'OK   ' ELSE 'FALLA' END);
    SELECT count(*) INTO n FROM v_alertas WHERE compra_id = v_compra AND alerta = 'campaña sin taxonomía';
    SELECT campana_grupo INTO t FROM v_inversion_diaria WHERE id = 'PRUEBA-NULL' LIMIT 1;
    r := r || format('%s  la alerta se va y la campaña cuenta como %s', CASE WHEN n = 0 AND t = 'PARQUE FIJO' THEN 'OK   ' ELSE 'FALLA' END, t);

    -- ============================================================== 2. LECTURA ve todo
    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_lec, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    r := r || text '--- LECTURA con un solo mercado asignado (MCO)';
    SELECT count(*) INTO n FROM fn_mis_mercados();
    SELECT count(*) INTO n2 FROM mercados;
    r := r || format('%s  fn_mis_mercados(): %s de %s mercados', CASE WHEN n = n2 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    SELECT count(DISTINCT mercado_id) INTO n FROM compras;
    r := r || format('%s  ve compras de %s mercados (esperado %s)', CASE WHEN n = e_mercados_con_compras THEN 'OK   ' ELSE 'FALLA' END, n, e_mercados_con_compras);
    SELECT count(DISTINCT mercado_id) INTO n FROM fn_inversion_total();
    SELECT count(DISTINCT mercado_id) INTO n2 FROM v_alertas;
    r := r || format('%s  inversión de %s mercados y alertas de %s', CASE WHEN n = e_mercados_con_compras AND n2 >= 1 THEN 'OK   ' ELSE 'FALLA' END, n, n2);
    UPDATE compras SET formato = 'X' WHERE mercado_id = v_mlc;
    GET DIAGNOSTICS n = ROW_COUNT;
    r := r || format('%s  LECTURA no edita compras (%s filas)', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);
    BEGIN
        PERFORM fn_asignar_taxonomia(v_mlc, 'OTRO', 'MLC_ML_OTH-PF_ALL_ALTO-IMPACTO_X');
        r := r || text 'FALLA  LECTURA corrige taxonomía: lo aceptó';
    EXCEPTION WHEN insufficient_privilege THEN
        r := r || text 'OK     LECTURA no corrige taxonomías';
    END;
    RESET ROLE;

    SELECT count(*) INTO n FROM unnest(r) l WHERE l LIKE 'FALLA%';
    RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = format(E'PRUEBAS DE MERCADOS — %s — todo revertido\n',
                         CASE WHEN n = 0 THEN 'TODAS OK' ELSE n || ' FALLAS' END) || array_to_string(r, E'\n');
END
$pruebas$;
