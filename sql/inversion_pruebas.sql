-- =============================================================================
-- OASIS v2.0 — Pruebas de la inversión precalculada
-- =============================================================================
-- Se corre después de sql/inversion_precalculada.sql. NO deja nada en la base:
-- un solo bloque que termina con un error a propósito; el informe sale en el
-- mensaje, una línea OK o FALLA por prueba.
--
--   1. Recalcula los cinco mercados desde cero y compara contra la fórmula
--      vieja (el SQL de la vista de antes, aquí abajo tal cual): mismo costo
--      por material y día, misma suma por compra, mismas filas.
--   2. v_cuadre: vacío salvo la 371 de MLA (material de 365 días en una compra
--      de enero; el redondeo de centavos suma −1,10 ARS).
--   3. Los triggers: cambiar fechas, valor, agregar o borrar un material
--      recalcula la compra y la suma sigue dando el valor total.
--   4. Contrato con BI: mismas 22 columnas en el mismo orden.
--   5. Acceso: un externo ve 0 filas; un Equipo ZB, solo su mercado.
-- =============================================================================

DO $pruebas$
DECLARE
    r       text[] := '{}';
    n       bigint;
    n2      bigint;
    x       numeric;
    t       text;
    v_mat   bigint;
    v_comp  bigint;
    v_valor numeric;
    a_prov  uuid := gen_random_uuid();
    a_zb    uuid := gen_random_uuid();
    v_mlc   smallint := (SELECT id FROM mercados WHERE codigo = 'MLC');
    COLUMNAS_BI constant text := 'site,bu,year,month,week,date,proveedor,tipo_costo,formato,valor_total,id,id_ejecucion,'
        || 'campana,sub_campana,pct_participacion,costo_proyectado,estado,costo_ejecutado,mes_compra,moneda,mercado_id,campana_grupo';
BEGIN
    -- ============================================================== 1. desde cero
    r := r || text '--- Recalcular los cinco mercados desde cero';
    DELETE FROM inversion_diaria;
    SELECT sum(public.fn_recalcular_inversion_mercado(id)) INTO n FROM mercados;
    r := r || format('OK     %s filas recalculadas', n);

    -- La fórmula vieja, el SQL de v_inversion_diaria antes de precalcular.
    CREATE TEMP TABLE vieja ON COMMIT DROP AS
    WITH dias AS (
        SELECT mt.id AS material_id, mt.compra_id, (d.d)::date AS fecha
        FROM materiales mt
        CROSS JOIN LATERAL generate_series(mt.fecha_inicio::timestamptz, mt.fecha_fin::timestamptz, '1 day'::interval) d(d)
        WHERE mt.fecha_inicio IS NOT NULL
    ), pesos AS (
        SELECT d.material_id, d.compra_id, d.fecha,
               1.0 / (count(*) OVER (PARTITION BY d.compra_id, d.fecha))::numeric AS peso
        FROM dias d
    ), normalizado AS (
        SELECT p.*, sum(p.peso) OVER (PARTITION BY p.compra_id) AS peso_compra FROM pesos p
    )
    SELECT n.material_id, n.compra_id, n.fecha,
           round((v.valor_total * n.peso) / n.peso_compra, 2) AS costo_proyectado,
           ((v.valor_total * n.peso) / n.peso_compra) / NULLIF(v.valor_total, 0::numeric) AS pct_participacion
    FROM normalizado n JOIN v_materiales v ON v.material_id = n.material_id;

    SELECT count(*) INTO n FROM vieja;
    SELECT count(*) INTO n2 FROM inversion_diaria;
    r := r || format('%s  mismas filas: vieja %s, tabla %s', CASE WHEN n = n2 THEN 'OK   ' ELSE 'FALLA' END, n, n2);

    SELECT count(*) INTO n FROM vieja v
    FULL JOIN inversion_diaria t ON t.material_id = v.material_id AND t.fecha = v.fecha
    WHERE t.material_id IS NULL OR v.material_id IS NULL
       OR t.costo_proyectado <> v.costo_proyectado
       OR t.pct_participacion IS DISTINCT FROM v.pct_participacion;
    r := r || format('%s  mismo costo y %% por material y día: %s diferencias', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    SELECT count(*) INTO n FROM (
        SELECT compra_id, sum(costo_proyectado) s FROM vieja GROUP BY 1
    ) v FULL JOIN (
        SELECT compra_id, sum(costo_proyectado) s FROM inversion_diaria GROUP BY 1
    ) t USING (compra_id)
    WHERE v.s IS DISTINCT FROM t.s;
    r := r || format('%s  misma suma por compra: %s compras distintas', CASE WHEN n = 0 THEN 'OK   ' ELSE 'FALLA' END, n);

    FOR t IN
        SELECT format('%s  %s: %s filas, %s %s', 'OK   ', m.codigo, count(*), round(sum(i.costo_proyectado), 2), m.moneda)
        FROM inversion_diaria i JOIN mercados m ON m.id = i.mercado_id GROUP BY m.codigo, m.moneda ORDER BY m.codigo
    LOOP
        r := r || t;
    END LOOP;

    -- ============================================================== 2. cuadre
    r := r || text '--- v_cuadre';
    SELECT string_agg(m.codigo || ' ' || q.codigo || ' (' || q.diferencia || ')', ', ') , count(*) INTO t, n
    FROM v_cuadre q JOIN compras c ON c.codigo = q.codigo AND c.valor_total = q.valor_total JOIN mercados m ON m.id = c.mercado_id;
    r := r || format('%s  v_cuadre: %s', CASE WHEN n = 0 OR (n = 1 AND t LIKE 'MLA 371 %') THEN 'OK   ' ELSE 'FALLA' END, coalesce(t, 'vacío'));

    -- ============================================================== 3. triggers
    r := r || text '--- Los triggers recalculan la compra';
    -- Una compra con al menos dos materiales fechados.
    SELECT mt.compra_id INTO v_comp FROM materiales mt WHERE mt.fecha_inicio IS NOT NULL
    GROUP BY 1 HAVING count(*) >= 2 ORDER BY 1 LIMIT 1;
    SELECT id INTO v_mat FROM materiales WHERE compra_id = v_comp AND fecha_inicio IS NOT NULL ORDER BY id LIMIT 1;
    SELECT valor_total INTO v_valor FROM compras WHERE id = v_comp;

    UPDATE materiales SET fecha_fin = fecha_inicio WHERE id = v_mat;
    SELECT count(*), sum(costo_proyectado) INTO n, x FROM inversion_diaria WHERE material_id = v_mat;
    SELECT sum(costo_proyectado) INTO v_valor FROM inversion_diaria WHERE compra_id = v_comp;
    r := r || format('%s  acortar un material a un día: %s fila; la compra sigue sumando su valor (%s)',
        CASE WHEN n = 1 AND abs(v_valor - (SELECT valor_total FROM compras WHERE id = v_comp)) <= 1 THEN 'OK   ' ELSE 'FALLA' END, n, v_valor);

    UPDATE compras SET valor_total = valor_total + 1000 WHERE id = v_comp;
    SELECT sum(costo_proyectado) INTO x FROM inversion_diaria WHERE compra_id = v_comp;
    r := r || format('%s  subir el valor 1.000: la tabla suma %s (valor %s)',
        CASE WHEN abs(x - (SELECT valor_total FROM compras WHERE id = v_comp)) <= 1 THEN 'OK   ' ELSE 'FALLA' END, x, (SELECT valor_total FROM compras WHERE id = v_comp));

    DELETE FROM materiales WHERE id = v_mat;
    SELECT count(*) INTO n FROM inversion_diaria WHERE material_id = v_mat;
    SELECT sum(costo_proyectado) INTO x FROM inversion_diaria WHERE compra_id = v_comp;
    r := r || format('%s  borrar el material: sus filas se van (%s) y los demás se llevan todo el valor (%s)',
        CASE WHEN n = 0 AND abs(x - (SELECT valor_total FROM compras WHERE id = v_comp)) <= 1 THEN 'OK   ' ELSE 'FALLA' END, n, x);

    INSERT INTO materiales (compra_id, secuencia, fecha_inicio, fecha_fin)
    SELECT v_comp, 99, fecha_inicio, fecha_fin FROM compras WHERE id = v_comp RETURNING id INTO v_mat;
    SELECT count(*) INTO n FROM inversion_diaria WHERE material_id = v_mat;
    SELECT sum(costo_proyectado) INTO x FROM inversion_diaria WHERE compra_id = v_comp;
    r := r || format('%s  agregar un material de todo el periodo: %s días y la compra sigue en %s',
        CASE WHEN n > 0 AND abs(x - (SELECT valor_total FROM compras WHERE id = v_comp)) <= 1 THEN 'OK   ' ELSE 'FALLA' END, n, x);

    -- Como la carga: con la marca, el trigger no recalcula.
    PERFORM set_config('oasis.sin_recalculo', 'on', true);
    UPDATE materiales SET fecha_fin = fecha_inicio WHERE id = v_mat;
    SELECT count(*) INTO n FROM inversion_diaria WHERE material_id = v_mat;
    r := r || format('%s  con oasis.sin_recalculo el trigger no recalcula (%s filas siguen)', CASE WHEN n > 1 THEN 'OK   ' ELSE 'FALLA' END, n);
    PERFORM set_config('oasis.sin_recalculo', 'off', true);

    -- ============================================================== 4. contrato con BI
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position) INTO t
    FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_inversion_diaria';
    r := r || format('%s  v_inversion_diaria: mismas 22 columnas en el mismo orden%s',
        CASE WHEN t = COLUMNAS_BI THEN 'OK   ' ELSE 'FALLA' END, CASE WHEN t = COLUMNAS_BI THEN '' ELSE ': ' || t END);

    -- ============================================================== «Costo en el mes»
    -- Pestaña Total con filtro de mes: la suma de la columna es el KPI.
    FOR t IN SELECT codigo FROM mercados WHERE codigo IN ('MCO', 'MLM') ORDER BY codigo LOOP
        SELECT (j -> 'total' ->> 'proyectado')::numeric,
               (SELECT coalesce(sum(value::numeric), 0) FROM jsonb_each_text(j -> 'por_material'))
        INTO x, v_valor
        FROM (SELECT fn_inversion_resumen((SELECT id FROM mercados WHERE codigo = t), '{"meses":["2026-03"]}') j) q;
        r := r || format('%s  %s marzo 2026: «Costo en el mes» suma %s = KPI %s',
            CASE WHEN x = v_valor AND x > 0 THEN 'OK   ' ELSE 'FALLA' END, t, v_valor, x);
    END LOOP;

    -- ============================================================== 5. acceso
    r := r || text '--- Acceso';
    INSERT INTO usuarios (correo, nombre, rol, proveedor_id)
    SELECT 'prueba.prov.inv@oasis.invalid', 'Prueba', 'PROVEEDOR', p.id FROM proveedores p JOIN mercados m ON m.id = p.mercado_id
    WHERE p.nombre = 'EFECTIMEDIOS' AND m.codigo = 'MCO';
    INSERT INTO usuarios (correo, nombre, rol) VALUES ('prueba.zb.inv@oasis.invalid', 'Prueba', 'ZB');
    INSERT INTO usuario_mercados (usuario_id, mercado_id) SELECT id, v_mlc FROM usuarios WHERE correo = 'prueba.zb.inv@oasis.invalid';
    INSERT INTO auth.users (id, email, aud, role) VALUES
        (a_prov, 'prueba.prov.inv@oasis.invalid', 'authenticated', 'authenticated'),
        (a_zb,   'prueba.zb.inv@oasis.invalid',   'authenticated', 'authenticated');

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_prov, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT (SELECT count(*) FROM inversion_diaria) + (SELECT count(*) FROM v_inversion_diaria) + (SELECT count(*) FROM v_cuadre) INTO n;
    SELECT (fn_inversion_resumen(1::smallint) -> 'total' ->> 'proyectado')::numeric INTO x;
    r := r || format('%s  PROVEEDOR: tabla, vista y v_cuadre con %s filas; resumen de MCO %s',
        CASE WHEN n = 0 AND x = 0 THEN 'OK   ' ELSE 'FALLA' END, n, x);
    RESET ROLE;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', a_zb, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) FILTER (WHERE mercado_id <> v_mlc), count(*) INTO n, n2 FROM inversion_diaria;
    SELECT (fn_inversion_resumen(1::smallint) -> 'total' ->> 'proyectado')::numeric INTO x;
    r := r || format('%s  Equipo ZB de MLC: %s filas de otro mercado, %s de MLC; resumen de MCO %s',
        CASE WHEN n = 0 AND n2 > 0 AND x = 0 THEN 'OK   ' ELSE 'FALLA' END, n, n2, x);
    RESET ROLE;

    SELECT count(*) INTO n FROM unnest(r) l WHERE l LIKE 'FALLA%';
    RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = format(E'PRUEBAS DE INVERSIÓN — %s — todo revertido\n', CASE WHEN n = 0 THEN 'TODAS OK' ELSE n || ' FALLAS' END)
                  || array_to_string(r, E'\n');
END
$pruebas$;
