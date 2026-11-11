-- =============================================================================
-- OASIS v2.0 — Usuarios: vistas por pantalla, «Todos los países» y proveedor en
-- varios países
-- =============================================================================
-- Tres cambios en quién ve qué. Ninguno cambia el acceso de un usuario que ya
-- existe: ningún Cliente gana vistas y nadie pierde mercados (lo comprueba
-- sql/usuarios_permisos_pruebas.sql, usuario por usuario).
--
-- 1. VISTAS POR PANTALLA (rol Cliente)
--    * vistas_catalogo: las pantallas que se le pueden habilitar a cada rol,
--      con su etiqueta y ayuda. La pantalla Usuarios arma la lista de casillas
--      desde aquí: sumar una vista es un INSERT (más su vista en la base y su
--      página), sin tocar usuarios.js. 'dashboard' es fija (siempre = true):
--      se muestra marcada y no se guarda en usuarios.vistas.
--    * Hoy, Cliente: Materiales (ya existía), Compras e Inversión. Todas de
--      solo lectura, en cualquier combinación, desmarcadas por defecto.
--    * fn_vistas_de_rol lee el catálogo. El CHECK usuarios_vistas pasa a ser
--      un trigger (un CHECK no puede leer una tabla): mismo error, 23514.
--    * Cada pantalla del Cliente lee SOLO de su vista _cliente (dueño postgres,
--      security_invoker = false, security_barrier = true), filtrada con
--      fn_tengo_vista('…') y fn_mis_mercados(). Nunca de las tablas base: el
--      Cliente sigue sin ninguna política sobre compras, materiales ni
--      inversion_diaria.
--        v_compras_cliente   proveedor, formato, ubicación, ciudad, medio,
--                            campaña, fechas, cantidad, tipo de costo, tipo de
--                            compra y valor total. SIN tarifa bruta, descuento
--                            ni tarifa neta (ni tiempo, semanas o la marca de
--                            valor manual). Agregar una columna aquí es decidir
--                            mostrársela al cliente.
--        v_inversion_cliente, v_inversion_semanal_cliente,
--        v_inversion_total_cliente   las mismas filas que v_inversion_diaria,
--                            _semanal y _total (proyectado y ejecutado, en su
--                            moneda). Por dentro, funciones SECURITY DEFINER de
--                            un mercado (ver la sección 5: las vistas internas
--                            son security_invoker). La pantalla pide la Diaria y
--                            el resumen por fn_inversion_filtrada_cliente y
--                            fn_inversion_resumen_cliente, copias de las
--                            internas. Si cambian las internas, cambiar estas:
--                            la batería compara las dos.
--        v_mercados_cliente  código, nombre, moneda y fecha de corte de sus
--                            mercados (el Cliente no lee la tabla mercados).
--
-- 2. «TODOS LOS PAÍSES»
--    * usuarios.todos_los_mercados: la marca. Con ella el usuario ve todos los
--      mercados activos, también uno que se active mañana, sin que nadie lo
--      edite. No se guardan sus usuario_mercados.
--    * ADMIN y LECTURA ya veían todos por su rol (y lo siguen viendo así): quedan
--      con la marca, que el trigger les pone siempre. PROVEEDOR nunca la lleva
--      (su alcance sale de sus proveedores).
--    * Los Clientes que hoy tienen los siete mercados uno por uno NO pasan a la
--      marca: seguirían viendo lo mismo hoy, pero verían solos un país nuevo, y
--      eso es ampliar su acceso. Se cambia a mano en Usuarios si se quiere.
--
-- 3. PROVEEDOR EN VARIOS PAÍSES
--    * usuario_proveedores: las filas de proveedores (una por proveedor y
--      mercado) que ve el usuario. El mismo proveedor en varios países es el
--      mismo nombre (JCDECAUX en MCO, MLC, MLM y MLU): la base exige que todos
--      los elegidos tengan el mismo nombre y que haya uno por país.
--    * usuarios.proveedor_id se queda: es el principal (la carpeta de sus
--      evidencias en Storage y lo que leen las páginas). Un trigger lo mantiene
--      dentro de usuario_proveedores, así que lo de antes sigue igual.
--    * fn_mis_compras, fn_mis_mercados y fn_evidencia_permitida leen
--      usuario_proveedores.
--
-- fn_admin_crear_usuario y fn_admin_editar_usuario reciben p_todos y
-- p_proveedores al final, con DEFAULT: la Edge Function desplegada antes de este
-- cambio sigue funcionando igual. Cambiar la marca o los proveedores cuenta como
-- cambio de acceso (cierra sesiones, queda en auditoría con antes y después).
--
-- Depende de sql/usuarios.sql, usuarios_edicion.sql, cliente_vistas.sql,
-- fase3_portal.sql, fase3_evidencias.sql, inversion_precalculada.sql y
-- dashboard.sql. Repetible. Una transacción. No toca v_inversion_diaria ni el
-- contrato con BI. Pruebas: sql/usuarios_permisos_pruebas.sql (se revierte sola).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Catálogo de vistas y reglas de usuarios.vistas
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.vistas_catalogo (
    vista    text PRIMARY KEY,
    etiqueta text NOT NULL,
    ayuda    text,
    roles    public.rol_enum[] NOT NULL,
    orden    smallint NOT NULL DEFAULT 0,
    siempre  boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE public.vistas_catalogo IS
    'Pantallas que se pueden habilitar por usuario (usuarios.vistas), por rol. siempre = la tiene todo usuario del rol (no se guarda). La pantalla Usuarios arma sus casillas desde aquí.';

INSERT INTO public.vistas_catalogo (vista, etiqueta, ayuda, roles, orden, siempre) VALUES
    ('dashboard',  'Dashboard',  'siempre',                                      '{CLIENTE}', 0, true),
    ('materiales', 'Materiales', 'el Tracking, solo lectura',                     '{CLIENTE}', 1, false),
    ('compras',    'Compras',    'solo lectura, sin tarifa bruta, descuento ni tarifa neta', '{CLIENTE}', 2, false),
    ('inversion',  'Inversión',  'proyectado y ejecutado por día, semana y mes, solo lectura', '{CLIENTE}', 3, false)
ON CONFLICT (vista) DO UPDATE
    SET etiqueta = EXCLUDED.etiqueta, ayuda = EXCLUDED.ayuda, roles = EXCLUDED.roles,
        orden = EXCLUDED.orden, siempre = EXCLUDED.siempre;

ALTER TABLE public.vistas_catalogo ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_admin ON public.vistas_catalogo;
CREATE POLICY lectura_admin ON public.vistas_catalogo FOR SELECT TO authenticated
    USING ((SELECT public.fn_rol_actual()) = 'ADMIN');
REVOKE ALL ON public.vistas_catalogo FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.vistas_catalogo TO authenticated;

-- Las vistas que se le pueden habilitar a un rol (sin las fijas).
CREATE OR REPLACE FUNCTION public.fn_vistas_de_rol(p_rol public.rol_enum)
RETURNS text[]
LANGUAGE sql STABLE
SET search_path = public
AS $$
    SELECT coalesce(array_agg(vista ORDER BY orden), '{}')
    FROM public.vistas_catalogo
    WHERE p_rol = ANY (roles) AND NOT siempre
$$;

-- El CHECK no puede leer el catálogo: lo reemplaza este trigger, con el mismo error.
ALTER TABLE public.usuarios DROP CONSTRAINT IF EXISTS usuarios_vistas;


-- -----------------------------------------------------------------------------
-- 2. «Todos los países»: usuarios.todos_los_mercados
-- -----------------------------------------------------------------------------

ALTER TABLE public.usuarios
    ADD COLUMN IF NOT EXISTS todos_los_mercados boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.usuarios.todos_los_mercados IS
    'Ve todos los mercados activos, también los que se activen después. ADMIN y LECTURA siempre; PROVEEDOR nunca.';

-- Antes del trigger: ADMIN y LECTURA ya ven todo por su rol; la marca lo dice.
UPDATE public.usuarios SET todos_los_mercados = true
WHERE rol IN ('ADMIN', 'LECTURA') AND NOT todos_los_mercados;

-- Reglas por fila: vistas que el rol admite (ordenadas, sin repetir) y la marca
-- según el rol. Para ZB, CLIENTE y AGENCIA la marca la decide quien edita.
CREATE OR REPLACE FUNCTION public.fn_usuarios_reglas_acceso()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    NEW.vistas := ARRAY(SELECT DISTINCT unnest(coalesce(NEW.vistas, '{}')) ORDER BY 1);
    IF NOT NEW.vistas <@ public.fn_vistas_de_rol(NEW.rol) THEN
        RAISE EXCEPTION 'El rol % no admite las vistas %', NEW.rol, array_to_string(NEW.vistas, ', ')
            USING ERRCODE = '23514';
    END IF;
    IF NEW.rol IN ('ADMIN', 'LECTURA') THEN
        NEW.todos_los_mercados := true;
    ELSIF NEW.rol = 'PROVEEDOR' THEN
        NEW.todos_los_mercados := false;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reglas_acceso ON public.usuarios;
CREATE TRIGGER reglas_acceso
    BEFORE INSERT OR UPDATE OF rol, vistas, todos_los_mercados ON public.usuarios
    FOR EACH ROW EXECUTE FUNCTION public.fn_usuarios_reglas_acceso();


-- -----------------------------------------------------------------------------
-- 3. Proveedor en varios países: usuario_proveedores
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.usuario_proveedores (
    usuario_id   bigint  NOT NULL REFERENCES public.usuarios(id) ON DELETE CASCADE,
    proveedor_id integer NOT NULL REFERENCES public.proveedores(id),
    PRIMARY KEY (usuario_id, proveedor_id)
);
CREATE INDEX IF NOT EXISTS usuario_proveedores_proveedor ON public.usuario_proveedores (proveedor_id);

COMMENT ON TABLE public.usuario_proveedores IS
    'Proveedores (uno por mercado, mismo nombre) que ve un usuario PROVEEDOR. Incluye siempre usuarios.proveedor_id.';

ALTER TABLE public.usuario_proveedores ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lectura_admin ON public.usuario_proveedores;
CREATE POLICY lectura_admin ON public.usuario_proveedores FOR SELECT TO authenticated
    USING ((SELECT public.fn_rol_actual()) = 'ADMIN');
REVOKE ALL ON public.usuario_proveedores FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.usuario_proveedores TO authenticated;

-- Lo que ya había: el proveedor de cada usuario PROVEEDOR.
INSERT INTO public.usuario_proveedores (usuario_id, proveedor_id)
SELECT id, proveedor_id FROM public.usuarios
WHERE rol = 'PROVEEDOR' AND proveedor_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- El principal (usuarios.proveedor_id) siempre está en la lista; quien deja de
-- ser PROVEEDOR se queda sin lista. Así, quien cambie proveedor_id directo (por
-- ejemplo, tras unificar un proveedor) no deja la lista desfasada.
CREATE OR REPLACE FUNCTION public.fn_usuarios_proveedor_principal()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.rol <> 'PROVEEDOR' OR NEW.proveedor_id IS NULL THEN
        DELETE FROM public.usuario_proveedores WHERE usuario_id = NEW.id;
        RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.proveedor_id IS DISTINCT FROM NEW.proveedor_id AND OLD.proveedor_id IS NOT NULL THEN
        DELETE FROM public.usuario_proveedores WHERE usuario_id = NEW.id AND proveedor_id = OLD.proveedor_id;
    END IF;
    INSERT INTO public.usuario_proveedores (usuario_id, proveedor_id)
    VALUES (NEW.id, NEW.proveedor_id) ON CONFLICT DO NOTHING;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS proveedor_principal ON public.usuarios;
CREATE TRIGGER proveedor_principal
    AFTER INSERT OR UPDATE OF rol, proveedor_id ON public.usuarios
    FOR EACH ROW EXECUTE FUNCTION public.fn_usuarios_proveedor_principal();

-- «JCDECAUX (MCO), JCDECAUX (MLC)»: para la auditoría.
CREATE OR REPLACE FUNCTION public.fn_texto_proveedores(p_ids integer[])
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT nullif(string_agg(p.nombre || ' (' || m.codigo || ')', ', ' ORDER BY m.codigo, p.id), '')
    FROM public.proveedores p JOIN public.mercados m ON m.id = p.mercado_id
    WHERE p.id = ANY (coalesce(p_ids, '{}'))
$$;
REVOKE ALL ON FUNCTION public.fn_texto_proveedores(integer[]) FROM PUBLIC, anon, authenticated;


-- -----------------------------------------------------------------------------
-- 4. Las reglas de alcance: fn_mis_mercados, fn_mis_compras, evidencias
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_mis_mercados()
RETURNS SETOF smallint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    -- ADMIN y LECTURA: todos, por su rol (como siempre).
    SELECT m.id
    FROM public.mercados m
    WHERE public.fn_rol_actual() IN ('ADMIN', 'LECTURA')
    UNION
    -- «Todos los países»: los mercados activos, también los nuevos.
    SELECT m.id
    FROM public.mercados m
    JOIN public.fn_usuario_actual() u ON u.todos_los_mercados AND u.rol <> 'PROVEEDOR'
    WHERE m.activo
    UNION
    SELECT um.mercado_id
    FROM public.usuario_mercados um
    JOIN public.fn_usuario_actual() u ON u.id = um.usuario_id
    WHERE u.rol <> 'PROVEEDOR'
    UNION
    -- PROVEEDOR: los mercados de sus proveedores.
    SELECT p.mercado_id
    FROM public.usuario_proveedores up
    JOIN public.proveedores p ON p.id = up.proveedor_id
    JOIN public.fn_usuario_actual() u ON u.id = up.usuario_id
    WHERE u.rol = 'PROVEEDOR'
$$;

CREATE OR REPLACE FUNCTION public.fn_mis_compras()
RETURNS SETOF bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT c.id
    FROM public.compras c
    JOIN public.fn_usuario_actual() u ON u.rol = 'PROVEEDOR'
    WHERE c.proveedor_id IN (SELECT up.proveedor_id FROM public.usuario_proveedores up WHERE up.usuario_id = u.id)
    UNION ALL
    SELECT c.id
    FROM public.compras c
    JOIN public.fn_usuario_actual() u ON u.rol = 'AGENCIA'
    WHERE c.mercado_id IN (SELECT public.fn_mis_mercados())
$$;

-- Igual que antes; el PROVEEDOR sube en la carpeta de cualquiera de sus
-- proveedores (la página usa el principal) y solo en materiales de sus compras.
CREATE OR REPLACE FUNCTION public.fn_evidencia_permitida(p_nombre text, p_accion text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_partes   text[] := string_to_array(p_nombre, '/');
    v_u        public.usuarios;
    v_material bigint;
BEGIN
    IF array_length(v_partes, 1) <> 3
       OR v_partes[1] !~ '^\d{1,9}$' OR v_partes[2] !~ '^\d{1,18}$' OR v_partes[3] = '' THEN
        RETURN false;
    END IF;
    v_material := v_partes[2]::bigint;

    SELECT * INTO v_u FROM public.fn_usuario_actual();
    IF v_u.id IS NULL THEN
        RETURN false;
    END IF;

    IF v_u.rol = 'PROVEEDOR' THEN
        RETURN v_partes[1]::integer IN (SELECT proveedor_id FROM public.usuario_proveedores WHERE usuario_id = v_u.id)
           AND EXISTS (SELECT 1 FROM public.materiales
                       WHERE id = v_material AND compra_id IN (SELECT public.fn_mis_compras()));
    END IF;

    -- Los demás no suben. Leen lo de los materiales que ven.
    RETURN p_accion = 'leer' AND public.fn_veo_material(v_material);
END;
$$;


-- -----------------------------------------------------------------------------
-- 5. Lo que lee el Cliente: sus mercados, Compras e Inversión
-- -----------------------------------------------------------------------------

-- Sus mercados (el Cliente no lee la tabla): para los selectores y la moneda de
-- Compras e Inversión. Solo con alguna vista adicional: un Cliente que solo
-- tiene el dashboard no lee ninguna vista (como hasta hoy).
-- Las de inversión dependen de esta: primero ellas (se recrean abajo).
DROP VIEW IF EXISTS public.v_inversion_cliente CASCADE;
DROP VIEW IF EXISTS public.v_inversion_semanal_cliente CASCADE;
DROP VIEW IF EXISTS public.v_inversion_total_cliente CASCADE;
DROP VIEW IF EXISTS public.v_mercados_cliente;
CREATE VIEW public.v_mercados_cliente
WITH (security_invoker = false, security_barrier = true) AS
SELECT m.id, m.codigo, m.nombre, m.moneda,
       -- La misma fecha de corte que usa v_inversion_diaria para el costo ejecutado.
       coalesce(nullif((SELECT valor FROM public.configuracion WHERE clave = 'fecha_corte'), '')::date,
                current_date) AS corte
FROM public.mercados m
WHERE (SELECT EXISTS (SELECT 1 FROM public.fn_usuario_actual() u
                      WHERE u.rol = 'CLIENTE' AND cardinality(u.vistas) > 0))
  AND m.id IN (SELECT public.fn_mis_mercados());

-- Compras: sin tarifa bruta, descuento ni tarifa neta.
DROP VIEW IF EXISTS public.v_compras_cliente;
CREATE VIEW public.v_compras_cliente
WITH (security_invoker = false, security_barrier = true) AS
SELECT c.id,
       c.mercado_id,
       m.codigo  AS mercado,
       m.nombre  AS mercado_nombre,
       m.moneda,
       c.codigo,
       coalesce(ca.nombre_unico, c.campana_taxonomia, c.campana_texto) AS campana,
       c.campana_taxonomia,
       p.nombre  AS proveedor,
       c.tipo_compra,
       c.medio,
       c.tipo_costo,
       c.formato,
       c.ubicacion,
       c.ciudad,
       c.cantidad,
       c.valor_total,
       c.fecha_inicio,
       c.fecha_fin
FROM public.compras c
JOIN public.mercados m ON m.id = c.mercado_id
LEFT JOIN public.proveedores p ON p.id = c.proveedor_id
LEFT JOIN public.campanas ca ON ca.id = c.campana_id
WHERE (SELECT public.fn_tengo_vista('compras'))
  AND c.mercado_id IN (SELECT public.fn_mis_mercados());

-- Inversión. v_inversion_diaria, _semanal y _total son security_invoker (y
-- leen v_materiales, también invoker): Postgres las revisa siempre con los
-- permisos de quien consulta, aunque las lea una vista de dueño postgres, y RLS
-- le daría 0 filas al Cliente. Por eso las leen tres funciones SECURITY DEFINER
-- de UN mercado, que solo devuelven filas si el usuario tiene la vista
-- «inversion» y ese mercado es suyo. Las vistas _cliente recorren sus mercados
-- (v_mercados_cliente) y exponen m.id como mercado_id: un filtro por mercado
-- llega hasta la función y se lee solo ese mercado.
DROP VIEW IF EXISTS public.v_inversion_cliente CASCADE;
DROP VIEW IF EXISTS public.v_inversion_semanal_cliente CASCADE;
DROP VIEW IF EXISTS public.v_inversion_total_cliente CASCADE;

CREATE OR REPLACE FUNCTION public.fn_inversion_diaria_de_cliente(p_mercado smallint)
RETURNS SETOF public.v_inversion_diaria
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT d.* FROM public.v_inversion_diaria d
    WHERE d.mercado_id = p_mercado
      AND public.fn_tengo_vista('inversion')
      AND p_mercado IN (SELECT public.fn_mis_mercados())
$$;

CREATE OR REPLACE FUNCTION public.fn_inversion_semanal_de_cliente(p_mercado smallint)
RETURNS SETOF public.v_inversion_semanal
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
SET enable_nestloop TO 'off'
AS $$
    SELECT s.* FROM public.v_inversion_semanal s
    WHERE s.mercado_id = p_mercado
      AND public.fn_tengo_vista('inversion')
      AND p_mercado IN (SELECT public.fn_mis_mercados())
$$;

CREATE OR REPLACE FUNCTION public.fn_inversion_total_de_cliente(p_mercado smallint)
RETURNS SETOF public.v_inversion_total
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
SET enable_nestloop TO 'off'
AS $$
    SELECT t.* FROM public.v_inversion_total t
    WHERE t.mercado_id = p_mercado
      AND public.fn_tengo_vista('inversion')
      AND p_mercado IN (SELECT public.fn_mis_mercados())
$$;

REVOKE ALL ON FUNCTION public.fn_inversion_diaria_de_cliente(smallint), public.fn_inversion_semanal_de_cliente(smallint),
                       public.fn_inversion_total_de_cliente(smallint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_inversion_diaria_de_cliente(smallint), public.fn_inversion_semanal_de_cliente(smallint),
                          public.fn_inversion_total_de_cliente(smallint) TO authenticated;

CREATE VIEW public.v_inversion_cliente
WITH (security_invoker = false, security_barrier = true) AS
SELECT d.site, d.bu, d.year, d.month, d.week, d.date, d.proveedor, d.tipo_costo, d.formato, d.valor_total,
       d.id, d.id_ejecucion, d.campana, d.sub_campana, d.pct_participacion, d.costo_proyectado, d.estado,
       d.costo_ejecutado, d.mes_compra, d.moneda, m.id AS mercado_id, d.campana_grupo
FROM public.v_mercados_cliente m
CROSS JOIN LATERAL public.fn_inversion_diaria_de_cliente(m.id) d;

CREATE VIEW public.v_inversion_semanal_cliente
WITH (security_invoker = false, security_barrier = true) AS
SELECT s.site, s.bu, s.year, s.month, s.week, s.proveedor, s.tipo_costo, s.formato, s.valor_total,
       s.id, s.id_ejecucion, s.campana, s.sub_campana, s.fecha_inicio, s.fecha_fin, s.dias,
       s.costo_proyectado, s.costo_ejecutado, s.mes_compra, s.moneda, m.id AS mercado_id, s.campana_grupo
FROM public.v_mercados_cliente m
CROSS JOIN LATERAL public.fn_inversion_semanal_de_cliente(m.id) s;

CREATE VIEW public.v_inversion_total_cliente
WITH (security_invoker = false, security_barrier = true) AS
SELECT t.site, t.bu, t.proveedor, t.tipo_costo, t.formato, t.valor_total, t.id, t.id_ejecucion,
       t.campana, t.sub_campana, t.fecha_inicio, t.fecha_fin, t.dias, t.pct_participacion,
       t.costo_proyectado, t.costo_ejecutado, t.mes_compra, t.moneda, m.id AS mercado_id, t.campana_grupo
FROM public.v_mercados_cliente m
CROSS JOIN LATERAL public.fn_inversion_total_de_cliente(m.id) t;

REVOKE ALL ON public.v_mercados_cliente, public.v_compras_cliente, public.v_inversion_cliente,
              public.v_inversion_semanal_cliente, public.v_inversion_total_cliente
    FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_mercados_cliente, public.v_compras_cliente, public.v_inversion_cliente,
                public.v_inversion_semanal_cliente, public.v_inversion_total_cliente
    TO authenticated;

COMMENT ON VIEW public.v_compras_cliente IS
    'Lo único que un Cliente lee de las compras: solo con la vista «compras» y solo sus mercados. Sin tarifa bruta, descuento ni tarifa neta.';
COMMENT ON VIEW public.v_inversion_cliente IS
    'v_inversion_diaria para el Cliente con la vista «inversion», solo sus mercados. Filtrar por mercado_id: lee solo ese mercado.';

-- Copias de fn_inversion_filtrada y fn_inversion_resumen
-- (sql/inversion_precalculada.sql) sobre las vistas del Cliente. Misma lógica:
-- la batería compara resultados con las internas.
CREATE OR REPLACE FUNCTION public.fn_inversion_filtrada_cliente(p_mercado smallint, p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS SETOF public.v_inversion_cliente
LANGUAGE sql STABLE
SET search_path = public
AS $$
    SELECT d.*
    FROM v_inversion_cliente d
    WHERE d.mercado_id = p_mercado
      AND (NOT (p_filtros ? 'meses') OR jsonb_array_length(p_filtros -> 'meses') = 0
           OR to_char(CASE WHEN p_filtros ->> 'ver_por' = 'compra' THEN d.mes_compra ELSE d.date END, 'YYYY-MM')
              IN (SELECT jsonb_array_elements_text(p_filtros -> 'meses')))
      AND (NOT (p_filtros ? 'proveedores') OR jsonb_array_length(p_filtros -> 'proveedores') = 0
           OR d.proveedor IN (SELECT jsonb_array_elements_text(p_filtros -> 'proveedores')))
      AND (NOT (p_filtros ? 'tipos_costo') OR jsonb_array_length(p_filtros -> 'tipos_costo') = 0
           OR d.tipo_costo::text IN (SELECT jsonb_array_elements_text(p_filtros -> 'tipos_costo')))
      AND (NOT (p_filtros ? 'campanas') OR jsonb_array_length(p_filtros -> 'campanas') = 0
           OR d.campana_grupo IN (SELECT jsonb_array_elements_text(p_filtros -> 'campanas')))
      AND (NOT (p_filtros ? 'sub_campanas') OR jsonb_array_length(p_filtros -> 'sub_campanas') = 0
           OR coalesce(d.sub_campana, '__sin__') IN (SELECT jsonb_array_elements_text(p_filtros -> 'sub_campanas')))
$$;

CREATE OR REPLACE FUNCTION public.fn_inversion_resumen_cliente(p_mercado smallint, p_filtros jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = public
AS $$
    WITH f AS (
        SELECT *,
            CASE WHEN p_filtros ->> 'agrupar' = 'semana'
                 THEN to_char(date, 'IYYY-"S"IW')
                 ELSE to_char(CASE WHEN p_filtros ->> 'ver_por' = 'compra' THEN mes_compra ELSE date END, 'YYYY-MM')
            END AS periodo
        FROM public.fn_inversion_filtrada_cliente(p_mercado, p_filtros)
    ),
    base AS (
        SELECT proveedor, sub_campana, campana_grupo,
               to_char(CASE WHEN p_filtros ->> 'ver_por' = 'compra' THEN mes_compra ELSE date END, 'YYYY-MM') AS mes
        FROM public.v_inversion_cliente WHERE mercado_id = p_mercado
    )
    SELECT jsonb_build_object(
        'total', (SELECT jsonb_build_object('proyectado', coalesce(sum(costo_proyectado), 0),
                                            'ejecutado',  coalesce(sum(costo_ejecutado), 0)) FROM f),
        'periodos', coalesce((SELECT jsonb_agg(x ORDER BY x ->> 'clave') FROM (
            SELECT jsonb_build_object('clave', periodo, 'proyectado', sum(costo_proyectado), 'ejecutado', sum(costo_ejecutado)) x
            FROM f GROUP BY periodo) s), '[]'),
        'sub_campanas', coalesce((SELECT jsonb_agg(x) FROM (
            SELECT jsonb_build_object('clave', coalesce(sub_campana, ''), 'proyectado', sum(costo_proyectado), 'ejecutado', sum(costo_ejecutado)) x
            FROM f GROUP BY sub_campana) s), '[]'),
        'proveedores', coalesce((SELECT jsonb_agg(x) FROM (
            SELECT jsonb_build_object('clave', coalesce(proveedor, ''), 'proyectado', sum(costo_proyectado), 'ejecutado', sum(costo_ejecutado)) x
            FROM f GROUP BY proveedor) s), '[]'),
        'filas', (SELECT count(*) FROM f),
        'por_material', CASE WHEN jsonb_array_length(coalesce(p_filtros -> 'meses', '[]')) > 0 THEN
            coalesce((SELECT jsonb_object_agg(id_ejecucion, s) FROM (
                SELECT id_ejecucion, sum(costo_proyectado) s FROM f GROUP BY id_ejecucion) x), '{}') END,
        'opciones', (SELECT jsonb_build_object(
            'meses',        coalesce(jsonb_agg(DISTINCT mes) FILTER (WHERE mes IS NOT NULL), '[]'),
            'proveedores',  coalesce(jsonb_agg(DISTINCT proveedor) FILTER (WHERE proveedor IS NOT NULL), '[]'),
            'sub_campanas', coalesce(jsonb_agg(DISTINCT sub_campana) FILTER (WHERE sub_campana IS NOT NULL), '[]'),
            'campanas',     coalesce(jsonb_agg(DISTINCT campana_grupo) FILTER (WHERE campana_grupo IS NOT NULL), '[]'))
          FROM base)
    )
$$;

REVOKE ALL ON FUNCTION public.fn_inversion_filtrada_cliente(smallint, jsonb), public.fn_inversion_resumen_cliente(smallint, jsonb)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_inversion_filtrada_cliente(smallint, jsonb), public.fn_inversion_resumen_cliente(smallint, jsonb)
    TO authenticated;


-- -----------------------------------------------------------------------------
-- 6. Alta y edición: p_todos y p_proveedores
-- -----------------------------------------------------------------------------
-- Una sola firma de cada una (con la vieja al lado, la llamada rpc sería ambigua).

DROP FUNCTION IF EXISTS public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[], text[]);
DROP FUNCTION IF EXISTS public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[], text[]);

-- Valida los proveedores de un usuario PROVEEDOR: al menos uno, existentes,
-- activos (o ya suyos), el mismo nombre y uno por país. Devuelve la lista
-- ordenada; el principal es p_principal si está en ella, si no el primero.
CREATE OR REPLACE FUNCTION public.fn_validar_proveedores_usuario(
    p_proveedores integer[], p_principal integer, p_ya_suyos integer[] DEFAULT '{}'
)
RETURNS integer[]
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ids integer[] := ARRAY(SELECT DISTINCT x FROM unnest(
                          coalesce(p_proveedores, CASE WHEN p_principal IS NULL THEN '{}' ELSE ARRAY[p_principal] END)) x
                          WHERE x IS NOT NULL ORDER BY 1);
BEGIN
    IF cardinality(v_ids) = 0 THEN
        RAISE EXCEPTION 'Un proveedor necesita su proveedor (activo)' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(*) FROM public.proveedores p
        WHERE p.id = ANY (v_ids) AND (p.activo OR p.id = ANY (coalesce(p_ya_suyos, '{}')))) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'Un proveedor elegido no existe o está inactivo' USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(DISTINCT upper(btrim(nombre))) FROM public.proveedores WHERE id = ANY (v_ids)) > 1 THEN
        RAISE EXCEPTION 'Los proveedores elegidos tienen que ser el mismo proveedor en distintos países'
            USING ERRCODE = '22023';
    END IF;
    IF (SELECT count(DISTINCT mercado_id) FROM public.proveedores WHERE id = ANY (v_ids)) <> cardinality(v_ids) THEN
        RAISE EXCEPTION 'Elige el proveedor una sola vez por país' USING ERRCODE = '22023';
    END IF;
    RETURN v_ids;
END;
$$;
REVOKE ALL ON FUNCTION public.fn_validar_proveedores_usuario(integer[], integer, integer[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_admin_crear_usuario(
    p_correo       text,
    p_nombre       text,
    p_rol          public.rol_enum,
    p_proveedor_id integer,
    p_mercados     smallint[],
    p_vistas       text[]    DEFAULT NULL,
    p_todos        boolean   DEFAULT false,
    p_proveedores  integer[] DEFAULT NULL
)
RETURNS public.usuarios
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin    bigint := public.fn_exigir_admin();
    v_correo   text := lower(btrim(p_correo));
    v_nombre   text := btrim(p_nombre);
    v_mercados smallint[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_mercados, '{}')) ORDER BY 1);
    v_vistas   text[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_vistas, '{}')) ORDER BY 1);
    v_todos    boolean := coalesce(p_todos, false);
    v_provs    integer[] := '{}';
    v_principal integer;
    v_u        public.usuarios;
BEGIN
    IF v_correo IS NULL OR v_correo !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' THEN
        RAISE EXCEPTION 'El correo no tiene un formato válido' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM public.usuarios WHERE lower(correo) = v_correo) THEN
        RAISE EXCEPTION 'Ya existe un usuario con el correo %', v_correo USING ERRCODE = '23505';
    END IF;
    IF v_nombre IS NULL OR v_nombre = '' THEN
        RAISE EXCEPTION 'Falta el nombre' USING ERRCODE = '22023';
    END IF;
    IF p_rol IS NULL OR p_rol = 'PLANNING' THEN
        RAISE EXCEPTION 'Elige un rol: Equipo ZB, Agencia, Proveedor, Lectura, Cliente o Admin' USING ERRCODE = '22023';
    END IF;

    IF p_rol = 'PROVEEDOR' THEN
        v_provs := public.fn_validar_proveedores_usuario(p_proveedores, p_proveedor_id);
        v_principal := CASE WHEN p_proveedor_id = ANY (v_provs) THEN p_proveedor_id ELSE v_provs[1] END;
        v_mercados := '{}';
        v_todos := false;
    ELSE
        IF p_proveedor_id IS NOT NULL OR cardinality(coalesce(p_proveedores, '{}')) > 0 THEN
            RAISE EXCEPTION 'Solo el rol Proveedor lleva proveedor' USING ERRCODE = '22023';
        END IF;
        IF p_rol IN ('ADMIN', 'LECTURA') THEN
            v_todos := true;
        END IF;
        IF v_todos THEN
            v_mercados := '{}';
        ELSIF cardinality(v_mercados) = 0 THEN
            RAISE EXCEPTION 'Elige al menos un país o «Todos los países»' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM unnest(v_mercados) m WHERE m NOT IN (SELECT id FROM public.mercados)) THEN
            RAISE EXCEPTION 'Hay un mercado que no existe' USING ERRCODE = '22023';
        END IF;
    END IF;

    IF NOT v_vistas <@ public.fn_vistas_de_rol(p_rol) THEN
        RAISE EXCEPTION 'Ese rol no admite las vistas adicionales pedidas (%)', array_to_string(v_vistas, ', ')
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.usuarios (correo, nombre, rol, proveedor_id, activo, debe_cambiar_clave, vistas, todos_los_mercados)
    VALUES (v_correo, v_nombre, p_rol, v_principal, true, true, v_vistas, v_todos)
    RETURNING * INTO v_u;

    IF cardinality(v_mercados) > 0 THEN
        INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
        SELECT v_u.id, unnest(v_mercados);
        PERFORM public.fn_auditar_usuario(v_u.id, 'mercados', NULL, public.fn_codigos_mercados(v_mercados), v_admin);
    END IF;

    IF cardinality(v_provs) > 0 THEN
        -- El principal ya entró por el trigger proveedor_principal.
        INSERT INTO public.usuario_proveedores (usuario_id, proveedor_id)
        SELECT v_u.id, unnest(v_provs) ON CONFLICT DO NOTHING;
        PERFORM public.fn_auditar_usuario(v_u.id, 'proveedores', NULL, public.fn_texto_proveedores(v_provs), v_admin);
    END IF;

    RETURN v_u;
END;
$$;

-- p_vistas NULL = no tocar las vistas (si el rol no cambia). Con otro rol, o si
-- el rol nuevo no las admite, quedan vacías. p_todos NULL = como estaba.
-- p_proveedores NULL = solo p_proveedor_id (como antes de este cambio).
CREATE OR REPLACE FUNCTION public.fn_admin_editar_usuario(
    p_usuario_id   bigint,
    p_nombre       text,
    p_rol          public.rol_enum,
    p_proveedor_id integer,
    p_mercados     smallint[],
    p_vistas       text[]    DEFAULT NULL,
    p_todos        boolean   DEFAULT NULL,
    p_proveedores  integer[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_admin       bigint := public.fn_exigir_admin();
    v_nombre      text := btrim(p_nombre);
    v_mercados    smallint[] := ARRAY(SELECT DISTINCT unnest(coalesce(p_mercados, '{}')) ORDER BY 1);
    v_vistas      text[];
    v_todos       boolean;
    v_provs       integer[] := '{}';
    v_provs_antes integer[];
    v_principal   integer;
    v_antes       public.usuarios;
    v_u           public.usuarios;
    v_merc_antes  smallint[];
    v_acceso      boolean;
    v_sesiones    integer := 0;
BEGIN
    SELECT * INTO v_antes FROM public.usuarios WHERE id = p_usuario_id FOR UPDATE;
    IF v_antes.id IS NULL THEN
        RAISE EXCEPTION 'El usuario % no existe', p_usuario_id USING ERRCODE = '22023';
    END IF;
    IF v_nombre IS NULL OR v_nombre = '' THEN
        RAISE EXCEPTION 'Falta el nombre' USING ERRCODE = '22023';
    END IF;
    IF p_rol IS NULL THEN
        RAISE EXCEPTION 'Elige el rol' USING ERRCODE = '22023';
    END IF;
    IF p_rol = 'PLANNING' AND v_antes.rol <> 'PLANNING' THEN
        RAISE EXCEPTION 'El rol Planning ya no se asigna: usa Equipo ZB' USING ERRCODE = '22023';
    END IF;
    IF p_usuario_id = v_admin AND p_rol <> v_antes.rol THEN
        RAISE EXCEPTION 'No puedes cambiar tu propio rol: pídeselo a otro ADMIN' USING ERRCODE = '22023';
    END IF;
    IF v_antes.rol = 'ADMIN' AND v_antes.activo AND p_rol <> 'ADMIN'
       AND NOT EXISTS (SELECT 1 FROM public.usuarios WHERE rol = 'ADMIN' AND activo AND id <> v_antes.id) THEN
        RAISE EXCEPTION 'OASIS no puede quedar sin un ADMIN activo: % es el último', v_antes.correo
            USING ERRCODE = '22023';
    END IF;

    v_provs_antes := ARRAY(SELECT proveedor_id FROM public.usuario_proveedores
                           WHERE usuario_id = p_usuario_id ORDER BY 1);

    IF p_rol = 'PROVEEDOR' THEN
        v_provs := public.fn_validar_proveedores_usuario(p_proveedores, p_proveedor_id, v_provs_antes);
        v_principal := CASE WHEN p_proveedor_id = ANY (v_provs) THEN p_proveedor_id ELSE v_provs[1] END;
        v_mercados := '{}';
        v_todos := false;
    ELSE
        IF p_proveedor_id IS NOT NULL OR cardinality(coalesce(p_proveedores, '{}')) > 0 THEN
            RAISE EXCEPTION 'Solo el rol Proveedor lleva proveedor' USING ERRCODE = '22023';
        END IF;
        v_todos := CASE WHEN p_rol IN ('ADMIN', 'LECTURA') THEN true
                        WHEN p_todos IS NOT NULL THEN p_todos
                        WHEN p_rol = v_antes.rol THEN v_antes.todos_los_mercados
                        ELSE false END;
        IF v_todos THEN
            v_mercados := '{}';
        ELSIF cardinality(v_mercados) = 0 THEN
            RAISE EXCEPTION 'Elige al menos un país o «Todos los países»' USING ERRCODE = '22023';
        END IF;
        IF EXISTS (SELECT 1 FROM unnest(v_mercados) m WHERE m NOT IN (SELECT id FROM public.mercados)) THEN
            RAISE EXCEPTION 'Hay un mercado que no existe' USING ERRCODE = '22023';
        END IF;
    END IF;

    -- Vistas adicionales: las pedidas; sin pedir, las que tenía si el rol sigue igual.
    IF p_vistas IS NOT NULL THEN
        v_vistas := ARRAY(SELECT DISTINCT unnest(p_vistas) ORDER BY 1);
        IF NOT v_vistas <@ public.fn_vistas_de_rol(p_rol) THEN
            RAISE EXCEPTION 'Ese rol no admite las vistas adicionales pedidas (%)', array_to_string(v_vistas, ', ')
                USING ERRCODE = '22023';
        END IF;
    ELSIF p_rol = v_antes.rol THEN
        v_vistas := v_antes.vistas;
    ELSE
        v_vistas := '{}';
    END IF;

    v_merc_antes := ARRAY(SELECT mercado_id FROM public.usuario_mercados
                          WHERE usuario_id = p_usuario_id ORDER BY 1);

    -- Nombre, rol, proveedor, vistas y marca: el trigger auditar registra cada campo que cambie.
    UPDATE public.usuarios
    SET nombre = v_nombre,
        rol = p_rol,
        proveedor_id = v_principal,
        vistas = v_vistas,
        todos_los_mercados = v_todos
    WHERE id = p_usuario_id
    RETURNING * INTO v_u;

    -- Mercados: solo la diferencia; en auditoría, antes y después.
    IF v_mercados IS DISTINCT FROM v_merc_antes THEN
        DELETE FROM public.usuario_mercados
        WHERE usuario_id = p_usuario_id AND mercado_id <> ALL (v_mercados);
        INSERT INTO public.usuario_mercados (usuario_id, mercado_id)
        SELECT p_usuario_id, m FROM unnest(v_mercados) m
        ON CONFLICT DO NOTHING;
        PERFORM public.fn_auditar_usuario(p_usuario_id, 'mercados',
            public.fn_codigos_mercados(v_merc_antes), public.fn_codigos_mercados(v_mercados), v_admin);
    END IF;

    -- Proveedores: la lista exacta (el trigger ya dejó el principal).
    DELETE FROM public.usuario_proveedores
    WHERE usuario_id = p_usuario_id AND proveedor_id <> ALL (v_provs);
    INSERT INTO public.usuario_proveedores (usuario_id, proveedor_id)
    SELECT p_usuario_id, x FROM unnest(v_provs) x
    ON CONFLICT DO NOTHING;
    IF v_provs IS DISTINCT FROM v_provs_antes THEN
        PERFORM public.fn_auditar_usuario(p_usuario_id, 'proveedores',
            public.fn_texto_proveedores(v_provs_antes), public.fn_texto_proveedores(v_provs), v_admin);
    END IF;

    -- ¿Cambió lo que puede ver? Para ADMIN y LECTURA los mercados no cuentan.
    v_acceso := v_u.rol IS DISTINCT FROM v_antes.rol
             OR v_u.proveedor_id IS DISTINCT FROM v_antes.proveedor_id
             OR v_provs IS DISTINCT FROM v_provs_antes
             OR v_u.vistas IS DISTINCT FROM v_antes.vistas
             OR v_u.todos_los_mercados IS DISTINCT FROM v_antes.todos_los_mercados
             OR (v_u.rol NOT IN ('ADMIN', 'LECTURA') AND v_mercados IS DISTINCT FROM v_merc_antes);

    IF v_acceso AND v_u.auth_user_id IS NOT NULL THEN
        v_sesiones := public.fn_cerrar_sesiones(v_u.auth_user_id);
        PERFORM public.fn_auditar_usuario(p_usuario_id, '(sesiones cerradas)', NULL, v_sesiones::text, v_admin);
    END IF;

    RETURN jsonb_build_object(
        'usuario', to_jsonb(v_u),
        'mercados', to_jsonb(v_mercados),
        'proveedores', to_jsonb(v_provs),
        'vistas', to_jsonb(v_u.vistas),
        'todos_los_mercados', v_u.todos_los_mercados,
        'acceso_cambio', v_acceso,
        'sesiones_cerradas', v_sesiones);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[], text[], boolean, integer[])   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[], text[], boolean, integer[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_admin_crear_usuario(text, text, public.rol_enum, integer, smallint[], text[], boolean, integer[])   TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_admin_editar_usuario(bigint, text, public.rol_enum, integer, smallint[], text[], boolean, integer[]) TO authenticated;

COMMIT;
