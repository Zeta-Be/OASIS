-- =============================================================================
-- OASIS v2.0 — Fase 3: evidencias de implementación (fotos, videos y enlaces)
-- =============================================================================
-- El proveedor sube varias evidencias por material: fotos y videos a Supabase
-- Storage (bucket privado «evidencias») o enlaces https. Reemplaza al campo
-- único materiales.evidencia_url, que se migra aquí y se deja de usar en el
-- portal (la columna no se borra todavía).
--
--   * Tabla evidencias, con RLS:
--       PROVEEDOR  lee e inserta en materiales de sus compras (fn_mis_compras),
--                  borra solo las que subió.
--       AGENCIA    lee las de sus mercados (fn_mis_compras).
--       Internos   leen las de los materiales que ven (sus mercados; ADMIN todo).
--       ADMIN      borra cualquiera.
--     Nadie actualiza: una evidencia se borra y se vuelve a subir.
--   * Un trigger completa lo que no debe venir del navegador: quién la subió,
--     cuándo y el tamaño real del archivo, que lee de Storage. Ahí también se
--     validan el tipo de archivo y los topes (foto 2 MB, video 50 MB).
--   * Bucket evidencias: privado, 50 MB por archivo, solo imágenes y videos.
--     Ruta {proveedor_id}/{material_id}/{uuid}.{ext}. Se sirve con URLs firmadas.
--   * fn_uso_storage(): bytes que ocupa el bucket (con huérfanos), para la
--     alerta de cuota del plan gratis. fn_evidencias_huerfanas(): archivos sin
--     fila en evidencias.
--
-- Depende de sql/fase3_portal.sql (fn_mis_compras, fn_es_url, fn_auditar).
-- No toca vistas de inversión ni el contrato con BI. Repetible. Una transacción.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Permisos de lectura de un material
-- -----------------------------------------------------------------------------
-- La misma regla para la tabla y para Storage: ¿el usuario ve este material?
-- Internos: si la compra es de sus mercados. Externos: si es de sus compras.

CREATE OR REPLACE FUNCTION public.fn_veo_material(p_material_id bigint)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.materiales mt
        JOIN public.compras c ON c.id = mt.compra_id
        WHERE mt.id = p_material_id
          AND CASE
                WHEN public.fn_rol_actual() IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN')
                    THEN c.mercado_id IN (SELECT public.fn_mis_mercados())
                WHEN public.fn_rol_actual() IN ('PROVEEDOR', 'AGENCIA')
                    THEN c.id IN (SELECT public.fn_mis_compras())
                ELSE false
              END
    )
$$;

REVOKE ALL ON FUNCTION public.fn_veo_material(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_veo_material(bigint) TO authenticated;


-- -----------------------------------------------------------------------------
-- 2. Tabla evidencias
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.evidencias (
    id             bigserial   PRIMARY KEY,
    material_id    bigint      NOT NULL REFERENCES public.materiales(id) ON DELETE CASCADE,
    tipo           text        NOT NULL CHECK (tipo IN ('FOTO', 'VIDEO', 'ENLACE')),
    ruta_storage   text,
    url            text,
    nombre_archivo text,
    tamano_bytes   bigint      CHECK (tamano_bytes >= 0),
    subido_por     bigint      REFERENCES public.usuarios(id) ON DELETE SET NULL,
    en             timestamptz NOT NULL DEFAULT now(),
    -- Archivo: ruta y tamaño, sin url. Enlace: url, sin ruta ni tamaño.
    CONSTRAINT evidencias_forma CHECK (
        (tipo IN ('FOTO', 'VIDEO') AND ruta_storage IS NOT NULL AND url IS NULL AND tamano_bytes IS NOT NULL)
        OR (tipo = 'ENLACE' AND url IS NOT NULL AND ruta_storage IS NULL AND tamano_bytes IS NULL)
    ),
    CONSTRAINT evidencias_ruta_unica UNIQUE (ruta_storage)
);

CREATE INDEX IF NOT EXISTS evidencias_material_idx ON public.evidencias (material_id);

ALTER TABLE public.evidencias ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.evidencias FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.evidencias TO authenticated;
GRANT USAGE ON SEQUENCE public.evidencias_id_seq TO authenticated;

-- 2.1 Lectura: quien ve el material ve sus evidencias.
DROP POLICY IF EXISTS lectura ON public.evidencias;
CREATE POLICY lectura ON public.evidencias
    FOR SELECT TO authenticated
    USING (public.fn_veo_material(material_id));

-- 2.2 Alta: solo PROVEEDOR, en materiales de sus compras.
DROP POLICY IF EXISTS alta_proveedor ON public.evidencias;
CREATE POLICY alta_proveedor ON public.evidencias
    FOR INSERT TO authenticated
    WITH CHECK (
        (SELECT public.fn_rol_actual()) = 'PROVEEDOR'
        AND material_id IN (
            SELECT mt.id FROM public.materiales mt
            WHERE mt.compra_id IN (SELECT public.fn_mis_compras())
        )
    );

-- 2.3 Baja: el PROVEEDOR las suyas; ADMIN cualquiera.
DROP POLICY IF EXISTS baja ON public.evidencias;
CREATE POLICY baja ON public.evidencias
    FOR DELETE TO authenticated
    USING (
        (SELECT public.fn_rol_actual()) = 'ADMIN'
        OR (
            (SELECT public.fn_rol_actual()) = 'PROVEEDOR'
            AND subido_por = (SELECT id FROM public.fn_usuario_actual())
            AND public.fn_veo_material(material_id)
        )
    );

-- 2.4 Lo que no viene del navegador ----------------------------------------
-- subido_por y en, siempre del servidor. Para archivos: el objeto tiene que
-- existir en el bucket bajo la carpeta del material, y de ahí salen el tamaño
-- real y el tipo MIME. Corre como postgres: lee storage.objects sin RLS.
-- Sin usuario de la app (carga o migración con postgres) respeta lo que viene.

CREATE OR REPLACE FUNCTION public.fn_evidencia_completar()
RETURNS trigger
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario bigint := (SELECT id FROM public.fn_usuario_actual());
    v_obj     storage.objects;
    v_mime    text;
    v_tamano  bigint;
BEGIN
    IF v_usuario IS NOT NULL THEN
        NEW.subido_por := v_usuario;
        NEW.en := now();
    END IF;

    IF NEW.tipo = 'ENLACE' THEN
        NEW.tamano_bytes := NULL;
        IF NEW.url IS NULL OR NOT public.fn_es_url(btrim(NEW.url)) THEN
            RAISE EXCEPTION 'La evidencia tiene que ser un enlace que empiece por https://' USING ERRCODE = '22023';
        END IF;
        NEW.url := btrim(NEW.url);
        RETURN NEW;
    END IF;

    -- FOTO o VIDEO: el archivo ya subido, en la carpeta de su material.
    IF split_part(NEW.ruta_storage, '/', 2) IS DISTINCT FROM NEW.material_id::text THEN
        RAISE EXCEPTION 'La ruta del archivo no es la de este material' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_obj FROM storage.objects
    WHERE bucket_id = 'evidencias' AND name = NEW.ruta_storage;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El archivo no está en el bucket de evidencias' USING ERRCODE = '22023';
    END IF;
    IF v_usuario IS NOT NULL AND v_obj.owner_id IS DISTINCT FROM (SELECT auth.uid())::text THEN
        RAISE EXCEPTION 'Ese archivo lo subió otra persona' USING ERRCODE = '42501';
    END IF;

    v_mime   := v_obj.metadata ->> 'mimetype';
    v_tamano := (v_obj.metadata ->> 'size')::bigint;
    IF v_tamano IS NULL THEN
        RAISE EXCEPTION 'Storage todavía no tiene el tamaño del archivo; intenta de nuevo' USING ERRCODE = '22023';
    END IF;

    IF NEW.tipo = 'FOTO' AND (v_mime NOT IN ('image/jpeg', 'image/png', 'image/webp') OR v_tamano > 2 * 1024 * 1024) THEN
        RAISE EXCEPTION 'Una foto tiene que ser JPEG, PNG o WebP de hasta 2 MB' USING ERRCODE = '22023';
    END IF;
    IF NEW.tipo = 'VIDEO' AND (v_mime NOT IN ('video/mp4', 'video/quicktime', 'video/webm') OR v_tamano > 50 * 1024 * 1024) THEN
        RAISE EXCEPTION 'Comprime el video o compártelo por enlace (máximo 50 MB, MP4, MOV o WebM)' USING ERRCODE = '22023';
    END IF;

    NEW.tamano_bytes := v_tamano;
    NEW.url := NULL;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_evidencia_completar() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS completar ON public.evidencias;
CREATE TRIGGER completar
    BEFORE INSERT ON public.evidencias
    FOR EACH ROW EXECUTE FUNCTION public.fn_evidencia_completar();

-- 2.5 Auditoría: el mismo trigger que compras y materiales.
DROP TRIGGER IF EXISTS auditar ON public.evidencias;
CREATE TRIGGER auditar
    AFTER INSERT OR UPDATE OR DELETE ON public.evidencias
    FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


-- -----------------------------------------------------------------------------
-- 3. Migrar materiales.evidencia_url
-- -----------------------------------------------------------------------------
-- Una fila ENLACE por cada valor. Solo los https: el trigger rechaza los demás
-- y no deben tumbar la migración (se quedan en la columna, que no se borra).
-- Repetible: no duplica lo ya migrado.

INSERT INTO public.evidencias (material_id, tipo, url)
SELECT mt.id, 'ENLACE', btrim(mt.evidencia_url)
FROM public.materiales mt
WHERE nullif(btrim(mt.evidencia_url), '') IS NOT NULL
  AND public.fn_es_url(btrim(mt.evidencia_url))
  AND NOT EXISTS (
      SELECT 1 FROM public.evidencias e
      WHERE e.material_id = mt.id AND e.tipo = 'ENLACE' AND e.url = btrim(mt.evidencia_url)
  );


-- -----------------------------------------------------------------------------
-- 4. El reporte de implementación ya no lleva evidencia
-- -----------------------------------------------------------------------------
-- La versión anterior escribía también evidencia_url; con evidencias aparte,
-- el portal ya no la toca. Se reemplaza por una con solo el reporte.

DROP FUNCTION IF EXISTS public.fn_reportar_implementacion(bigint, text, text);

CREATE OR REPLACE FUNCTION public.fn_reportar_implementacion(
    p_material_id bigint,
    p_reporte     text
)
RETURNS public.materiales
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rol     public.rol_enum := public.fn_rol_actual();
    v_reporte text := nullif(btrim(p_reporte), '');
    v_m       public.materiales;
BEGIN
    IF v_rol IS DISTINCT FROM 'PROVEEDOR' THEN
        RAISE EXCEPTION 'Solo un proveedor puede reportar la implementación' USING ERRCODE = '42501';
    END IF;

    PERFORM 1 FROM public.materiales
    WHERE id = p_material_id
      AND compra_id IN (SELECT public.fn_mis_compras())
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El material % no existe o no es de tu proveedor', p_material_id USING ERRCODE = '42501';
    END IF;

    IF length(v_reporte) > 2000 THEN
        RAISE EXCEPTION 'El reporte pasa de 2.000 caracteres' USING ERRCODE = '22023';
    END IF;

    UPDATE public.materiales SET
        reporte_implementacion = v_reporte,
        actualizado_en         = now()
    WHERE id = p_material_id
    RETURNING * INTO v_m;

    RETURN v_m;
END;
$$;

REVOKE ALL ON FUNCTION public.fn_reportar_implementacion(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_reportar_implementacion(bigint, text) TO authenticated;


-- -----------------------------------------------------------------------------
-- 5. Bucket evidencias
-- -----------------------------------------------------------------------------
-- Privado. 50 MB por archivo (el tope del plan gratis); el de 2 MB por foto lo
-- aplican el navegador (comprime antes) y el trigger de la tabla.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'evidencias', 'evidencias', false, 52428800,
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/quicktime', 'video/webm']
)
ON CONFLICT (id) DO UPDATE SET
    public             = EXCLUDED.public,
    file_size_limit    = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ¿Puede el usuario actual subir o leer este objeto? La ruta es
-- {proveedor_id}/{material_id}/{archivo}: exactamente dos carpetas, numéricas.
-- p_accion: 'subir' o 'leer'.
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
        -- Solo en la carpeta de su proveedor y en materiales de sus compras.
        RETURN v_partes[1] = v_u.proveedor_id::text
           AND EXISTS (SELECT 1 FROM public.materiales
                       WHERE id = v_material AND compra_id IN (SELECT public.fn_mis_compras()));
    END IF;

    -- Los demás no suben. Leen lo de los materiales que ven.
    RETURN p_accion = 'leer' AND public.fn_veo_material(v_material);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_evidencia_permitida(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_evidencia_permitida(text, text) TO authenticated;

DROP POLICY IF EXISTS evidencias_subir ON storage.objects;
CREATE POLICY evidencias_subir ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'evidencias' AND public.fn_evidencia_permitida(name, 'subir'));

DROP POLICY IF EXISTS evidencias_leer ON storage.objects;
CREATE POLICY evidencias_leer ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'evidencias' AND public.fn_evidencia_permitida(name, 'leer'));

-- Borrar: quien lo subió (si todavía lo puede leer) o ADMIN. Nadie actualiza:
-- no hay política de UPDATE, así que tampoco se puede sobrescribir un archivo.
DROP POLICY IF EXISTS evidencias_borrar ON storage.objects;
CREATE POLICY evidencias_borrar ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'evidencias'
        AND (
            (SELECT public.fn_rol_actual()) = 'ADMIN'
            OR (owner_id = (SELECT auth.uid())::text AND public.fn_evidencia_permitida(name, 'leer'))
        )
    );


-- -----------------------------------------------------------------------------
-- 6. Uso del almacenamiento
-- -----------------------------------------------------------------------------
-- Lo que de verdad ocupa el bucket, leído de storage.objects: cuenta también
-- los archivos huérfanos (sin fila en evidencias). Para la alerta de cuota del
-- plan gratis (1 GB). Solo internos; a un externo le devuelve null.

CREATE OR REPLACE FUNCTION public.fn_uso_storage()
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT CASE
        WHEN public.fn_rol_actual() IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN') THEN (
            SELECT coalesce(sum((o.metadata ->> 'size')::bigint), 0)::bigint
            FROM storage.objects o
            WHERE o.bucket_id = 'evidencias'
        )
    END
$$;

REVOKE ALL ON FUNCTION public.fn_uso_storage() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_uso_storage() TO authenticated;

-- Archivos del bucket sin fila en evidencias: ocupan cuota y nadie los ve.
-- Salen de un borrado a medias, de un material borrado (la fila se va en
-- cascada, el archivo no) o de una subida en curso (el archivo llega antes que
-- la fila; dura segundos). Solo internos; a un externo no le devuelve nada.

CREATE OR REPLACE FUNCTION public.fn_evidencias_huerfanas()
RETURNS TABLE (ruta text, tamano_bytes bigint, subido_en timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT o.name, (o.metadata ->> 'size')::bigint, o.created_at
    FROM storage.objects o
    WHERE o.bucket_id = 'evidencias'
      AND public.fn_rol_actual() IN ('PLANNING', 'ZB', 'LECTURA', 'ADMIN')
      AND NOT EXISTS (SELECT 1 FROM public.evidencias e WHERE e.ruta_storage = o.name)
    ORDER BY o.created_at
$$;

REVOKE ALL ON FUNCTION public.fn_evidencias_huerfanas() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fn_evidencias_huerfanas() TO authenticated;

COMMIT;
