# OASIS v2.0

Sistema de seguimiento de pauta OOH (publicidad exterior) de Mercado Libre, operado por el equipo ZetaB. Reemplaza un sistema construido en Google Sheets. Responde siempre en español.

## Vocabulario — usarlo con precisión

- **Compra** — un paquete de OOH comprado a un proveedor: una valla, un paradero, un circuito de pantallas. Tiene ID propio (001, 002…), formato, ubicación, fechas de compra y **valor_total**. Equivale a una fila de la hoja `Flow`. Una compra es una línea de costo: el mismo paradero con arriendo y producción son dos compras distintas.
- **Material** — lo que corre sobre una compra para una sub campaña, con sus propias fechas. Una compra puede tener varios materiales (001-A, 001-B…). Equivale a una fila de la hoja `Tracking`.

No usar "ejecución" para referirse al material. La única excepción es la columna `id_ejecucion` de las vistas de inversión, que conserva ese nombre por compatibilidad con la hoja `Inversion_Daily` que consume BI.

El objetivo del sistema es saber cuánta plata corresponde a cada material, día por día, repartiendo el valor de la compra.

## Dónde vive cada cosa

| Qué | Dónde |
|---|---|
| Base de datos | Supabase, proyecto `tjlteqhqctdtlbppigdi` (Postgres), conectado por MCP en modo lectura |
| Esquema original | `oasis_v2_esquema.sql` (vocabulario viejo; ver `migracion_vocabulario.sql`) |
| Carga desde Sheets | `cargar_oasis.py` — lee el Sheets de cada mercado en vivo y hace upsert; los IDs de los Sheets están en `mercados.json`. Ver «Cómo cargar datos» |
| Inversión precalculada | `sql/inversion_precalculada.sql` (tabla `inversion_diaria`, `fn_recalcular_inversion*`, triggers, `fn_inversion_filtrada`, `fn_inversion_resumen`); pruebas en `sql/inversion_pruebas.sql`. Ver «Inversión precalculada» en Modelo de datos |
| Varios mercados | `sql/mercados_enum.sql` (COLOCACION; va primero y aparte) y `sql/mercados.sql` (moneda, campaña por compra, `campanas_alias`, columnas que admiten vacío, vistas, alertas nuevas, `fn_asignar_taxonomia`); pruebas en `sql/mercados_pruebas.sql` (se revierten solas). Ver «Varios mercados» |
| Contraseña olvidada de un ADMIN | `cambiar_clave.py` — la cambia directo en Auth por la conexión de `.env` (ver «Alta de usuarios») |
| Credenciales Google | `credenciales_google.json` — cuenta de servicio, nunca al repositorio |
| Credenciales Postgres | `.env` — nunca al repositorio |
| Autenticación y RLS | `rls_fase2.sql` — funciones de identidad, políticas, trigger de vínculo |
| Sistema de diseño | `DISENO.md` — tokens, tipografía, componentes y pantallas de la interfaz |
| Interfaz interna | `app/` — sitio estático; login con correo y contraseña. El código de 6 dígitos por correo se ve como «próximamente» hasta tener correo propio (ver Login). Cuatro pantallas: Compras, Materiales, Inversión, Alertas, más Usuarios (solo ADMIN) y `clave.html` (cambio obligatorio de la contraseña temporal). Con rol LECTURA, Compras y Materiales se muestran como texto, sin edición |
| Gestión de usuarios | `sql/usuarios.sql` (funciones `fn_admin_*`, `debe_cambiar_clave`), Edge Function `supabase/functions/gestionar-usuarios/`, pantalla `app/usuarios.html`, prueba `supabase/probar_usuarios.py`. Ver «Alta de usuarios» |
| Portal externo | `app/portal.html` (+ `js/portal.js`, `css/portal.css`) — PROVEEDOR y AGENCIA. El mismo login los manda ahí según el rol. Ver «Acceso externo» |
| Acceso externo y auditoría | `sql/fase3_portal.sql` (`fn_mis_compras`, `v_materiales_externos`, políticas, funciones de escritura, `auditoria`); pruebas en `sql/fase3_portal_pruebas.sql` (se revierten solas) |
| Evidencias | `sql/fase3_evidencias.sql` (tabla `evidencias`, bucket `evidencias`, políticas de Storage, `fn_uso_storage`); interfaz en `app/js/evidencias.js` y `app/css/evidencias.css`, la usan el portal y Materiales. Ver «Evidencias» |
| Sitio publicado | https://zeta-be.github.io/OASIS/ — GitHub Pages publica `app/` en cada push a `main` (`.github/workflows/pages.yml`). Vive en la subcarpeta `/OASIS/`: toda ruta dentro de `app/` debe ser relativa, nunca empezar con `/` |
| Plantilla de correo de acceso | `supabase/plantilla_codigo.html` — se pega a mano en Supabase → Authentication → Emails (Magic Link y Confirm signup). Todavía no se puede: Supabase no deja editar plantillas sin SMTP propio |
| Detector de duplicados | `sql/duplicados.sql` (tabla, RLS, `fn_unificar_duplicado`, `fn_rechazar_duplicado`), Edge Function `supabase/functions/detectar-duplicados/` (el prompt está en `prompt.md`), prueba local `supabase/probar_duplicados.ts`. Ver «Detector de duplicados» |
| Código | GitHub `Zeta-Be/OASIS` (https://github.com/Zeta-Be/OASIS) |
| Fuente de captura actual | Un Google Sheets por mercado, con los IDs en `mercados.json` (MCO `13Vh45CymNMntNG-EW3NQnglnfyvq39nT7nvediDTV1g`). Los equipos siguen llenando ahí hasta el corte. Cada Sheets se comparte como Lector con `oasis-lector@mbw-spl-brazil.iam.gserviceaccount.com` |

## Modelo de datos

```
mercados ──< campanas            (glosario oficial de ZetaB, no se edita aquí)
mercados ──< proveedores         (una fila por proveedor-mercado, agrupadas por grupo_id)
mercados ──< compras ──< materiales
usuarios ──< usuario_mercados    (a qué países accede cada usuario interno)
configuracion                    (clave fecha_corte: nula = hoy)
```

Siete mercados: MCO, MLB, MLM, MLA, MLC, MLU, MPE, cada uno con su moneda (`mercados.moneda`: COP, BRL, MXN, ARS, CLP, UYU, PEN). Hay datos de MCO, MLC, MLU, MLA y MLM.

Enums: `tipo_costo` (EXHIBICION, PRODUCCION, IMPUESTOS, COLOCACION), `tipo_compra` (DIRECTO, BONIFICADO, FACTURABLE, PAGO ANTICIPADO), `medio` (OOH, DOOH), `rol` (PLANNING, ZB, AGENCIA, PROVEEDOR, LECTURA, ADMIN). Un valor del Sheets que no está en su enum entra vacío, con el texto original en `compras.fuera_de_catalogo` y la alerta «valor fuera de catálogo».

**Rol LECTURA.** Consulta interna sin captura: jefes, otras áreas, gente nueva en planning. Ve las cuatro pantallas con los datos de **todos** los mercados (igual que ADMIN; `fn_mis_mercados()`), filtra y exporta; no escribe nada. Sus `usuario_mercados` solo deciden con qué mercado abre. No es el rol de BI: BI se conectará a las vistas directamente, sin usuario en la app, y eso se define en la Fase 4.

Vistas: `v_materiales_externos` (la única para PROVEEDOR y AGENCIA; ver «Acceso externo»), `v_materiales` (nivel material, con taxonomía; desde `sql/mercados.sql` también mercado_id, moneda y campana_grupo al final), `v_inversion_diaria`, `v_inversion_semanal`, `v_inversion_total`, `v_alertas` (alerta, referencia y, para enlazar, mercado, compra_id, material_id; al final mercado_id y detalle), `v_cuadre` (cruza por código **y** mercado), `v_sub_campanas` (glosario de cada mercado sin su campaña OOH; para elegir sub campaña en Materiales).

**Inversión precalculada** (`sql/inversion_precalculada.sql`). El reparto ya calculado vive en la tabla `inversion_diaria`: una fila por material y día, con material_id, fecha, compra_id, mercado_id, costo_proyectado y pct_participacion. Guarda solo lo caro de calcular. Lo descriptivo (proveedor, campaña, formato, moneda) y lo que depende de la fecha (estado, costo ejecutado) lo pone `v_inversion_diaria` al leer, así que no queda viejo si se unifica un proveedor, cambia el glosario o pasa un día.
- **Quién la mantiene:** `fn_recalcular_inversion(compra)` reescribe solo las filas de esa compra. La llaman triggers en `materiales` (alta, baja, cambio de fechas o de compra) y en `compras` (cambio de valor o de mercado); una compra borrada se lleva sus filas en cascada. `cargar_oasis.py` pone `oasis.sin_recalculo = 'on'` mientras escribe y al final llama a `fn_recalcular_inversion_mercado`, una vez por mercado. **Si algo escribe materiales o compras con esa marca encendida y no recalcula, la inversión queda vieja.** Para rehacer todo: `SELECT fn_recalcular_inversion_mercado(id) FROM mercados;`.
- **Acceso:** RLS en la tabla: internos de sus mercados (ADMIN y LECTURA ven todos); externos, 0 filas. BI se conecta como postgres y no se ve afectado.
- **La pantalla pide agregados, no filas:** `fn_inversion_resumen(mercado, filtros)` devuelve en un jsonb los KPIs, los periodos (por mes o por semana), las barras por sub campaña y por proveedor, y las opciones de los filtros. `fn_inversion_filtrada(mercado, filtros)` devuelve las filas filtradas: la Diaria la pagina de a 500 y el CSV la baja en lotes de 1.000. Total y Semanal se traen completas para el mercado por `fn_inversion_total()` y `fn_inversion_semanal()`, que siguen existiendo: devuelven la vista tal cual con los nested loops apagados. Si se agrega otra lectura de inversión desde la app, va por estas funciones.
- **Tiempos** (19-10-2026, base real, cinco mercados, ADMIN por la API): resumen 0,3–0,7 s; Total 0,7–1,1 s; Semanal 1,0–1,2 s; una página de la Diaria 0,2–0,6 s; un lote de CSV 0,5 s. BI, la diaria completa de los cinco mercados (57.776 filas): 0,15 s. Meta: ninguna consulta de la pantalla por encima de 2 s.
- **«Costo en el mes»:** en la pestaña Total, con filtro de mes, la tabla agrega esta columna junto a «Costo proyectado» (el material entero). Es lo que suma cada material dentro de los meses filtrados, y sale de `fn_inversion_resumen` (`por_material`), con los mismos filtros que los KPIs. El total de la tabla va bajo esa columna y cuadra con los KPIs; los totales del material entero quedan en blanco.
- **Pruebas:** `sql/inversion_pruebas.sql` recalcula todo desde cero y lo compara contra el SQL de la vista de antes (mismo costo por material y día, misma suma por compra), revisa los triggers, el contrato con BI y el acceso. Se revierte solo.

**Campaña de la compra.** Es de cada compra: la columna CAMPAÑA del Flow, que debe ser una taxonomía (`MLC_ML_OTH-PF_ALL_ALTO-IMPACTO_X`). Se guarda en tres campos: `compras.campana_texto` (tal cual), `campana_taxonomia` (válida, del Flow o de `campanas_alias`) y `campana_id` (la campaña del glosario, si existe). Las reglas están en la base: `fn_taxonomia_de_texto` y `fn_campana_de_taxonomia`; las usan la carga y la corrección en Alertas. Las campañas OTH-PF (PARQUE-FIJO, ALTO-IMPACTO, PLANTA-FIJA, REGIONES, INTERIOR) cuentan como una sola, «PARQUE FIJO», para filtros (`campana_grupo`). `mercados.campana_ooh_id` ya solo es la campaña con la que la pantalla Compras arranca una compra nueva (MCO y MLU PARQUE-FIJO, MLA PARQUE-FIJO, MLC ALTO-IMPACTO, MLM PLANTA-FIJA); editar una compra nunca le cambia la campaña.

**Valor total.** `compras.valor_total_manual`: false = sale de la fórmula (ver reglas de negocio), lo recalcula la interfaz; true = escrito a mano (marcado cuando difiere más de $1 de la fórmula, al migrar y al cargar). `descuento_pct` es fracción 0–1.

**Tramos.** Cuando una campaña cruza dos compras del mismo soporte se parte en un material por compra; los tramos comparten `materiales.grupo_tramo` (uuid, nulo si no está partido). La interfaz crea y parte materiales con `fn_guardar_tramos(material_id, datos, tramos)`: una transacción, con permisos del usuario (RLS aplica), que asigna la siguiente letra libre de cada compra y rechaza tramos fuera del periodo. Mismo soporte = mismo mercado, proveedor, ubicación y tipo de costo. No hay CHECK de periodo en la tabla: el Sheets todavía trae materiales fuera de su compra y la carga no debe fallar.

Cambios de Fase 2 sobre el esquema: `sql/fase2_compras.sql`, `sql/fase2_materiales.sql`, `sql/fase2_alertas.sql`, `sql/fase2_inversion.sql`, `sql/fase2_tiempo.sql`, `sql/fase2_mes_compra.sql`.

## Acceso externo (Fase 3)

Primera vez que entran usuarios de fuera de ZetaBé. La regla: **un externo no ve nada del Flow**. Ni la tabla `compras`, ni una vista de compras, ni fechas de la compra, ni tarifas, descuentos, valor total o inversión. Ve sus materiales como hoy ve el Tracking en Sheets, y eso se cumple en la base, no solo en la pantalla.

| Rol | Ve | Escribe |
|---|---|---|
| PROVEEDOR | Los materiales de las compras de **su proveedor** (`usuarios.proveedor_id`) | Reporte de implementación, solo con `fn_reportar_implementacion`; sus evidencias (fotos, videos, enlaces), ver «Evidencias» |
| AGENCIA | Los materiales de las compras de **sus mercados** (`usuario_mercados`) | Enlace, solo con `fn_actualizar_enlace` |

- **Una sola regla, `fn_mis_compras()`:** SECURITY DEFINER, devuelve solo ids de compra (PROVEEDOR: las de su `proveedor_id`; AGENCIA: las de `fn_mis_mercados()`; internos: ninguna). La usan la política de materiales, la vista y las dos funciones de escritura. Si cambia qué le toca a un externo, se cambia ahí.
- **`v_materiales_externos`:** la única vista para externos y lo único que consulta el portal. Dueño postgres, `security_invoker = false`, `security_barrier = true`, filtrada con `fn_mis_compras()`. Columnas, exactamente: id (llave del material), codigo, sub_campana, referencia, fecha_inicio, fecha_fin, enlace, reporte_implementacion, evidencia_url (las del material; `evidencia_url` ya no la usa el portal) y compra (código), proveedor, formato, ubicacion, ciudad, tipo_costo (las que el Tracking hereda por VLOOKUP). Agregar una columna aquí es decidir mostrársela a proveedores y agencias.
- **compras:** ninguna política para externos; `SELECT * FROM compras` les da cero filas. No hay vista de compras expuesta a `authenticated`.
- **materiales:** política `lectura_externos`, solo SELECT, con `compra_id IN (SELECT fn_mis_compras())`. No puede ser `EXISTS (… FROM compras …)` como en los internos: esa subconsulta pasa por RLS y para un externo siempre daría falso. Sin políticas de INSERT, UPDATE ni DELETE: un PATCH por la API cambia cero filas. Ojo: por esta política un externo que consulte la tabla directo también ve las columnas técnicas del material (`compra_id`, `secuencia`, `sub_campana_id`, `referencia`, `grupo_tramo`); nada del Flow.
- **Escritura:** `fn_reportar_implementacion(material_id, reporte)` y `fn_actualizar_enlace(material_id, enlace)` son SECURITY DEFINER: revisan rol y pertenencia con `fn_mis_compras()`, exigen enlaces `https://` (`fn_es_url`) y tocan solo sus campos. Si el material no es suyo, error 42501. Los internos no las usan: editan en Materiales.
- **Catálogos:** los externos leen de `campanas` solo las sub campañas de sus materiales. `proveedores`, `mercados`, `configuracion`, `usuario_mercados` y `duplicados_propuestos` siguen solo para internos. Cualquier usuario activo lee su propia fila de `usuarios` (el login la necesita para saber a dónde mandarlo).
- **Todo lo demás da cero filas, no 403:** las vistas de inversión, `v_materiales`, `v_alertas`, `v_cuadre` y `v_sub_campanas` cruzan con tablas que el externo no ve. Con un solo rol de Postgres (`authenticated`) para todos, la base no puede negar una vista a unos y dársela a otros; lo que la vacía es RLS. **Pendiente opcional:** un rol de Postgres aparte para externos (por el hook de Supabase Auth que pone `role` en el JWT), sin GRANT sobre compras ni sobre las vistas de inversión. Daría error 403 real y protegería aunque una política quedara mal; es un cambio de arquitectura, no urgente.
- **`fn_mis_mercados()`:** para PROVEEDOR devuelve el mercado de su proveedor; para AGENCIA, sus `usuario_mercados`. Las políticas internas exigen rol interno, así que esto no les abre nada.
- **Auditoría:** tabla `auditoria` (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id, en). Un trigger en `compras` y `materiales` registra cada campo cambiado, de cualquier rol; alta y baja van como una fila con `campo` = `(alta)` o `(baja)` y la fila completa en JSON. No registra `actualizado_en` ni un número que solo cambia de escala (125000000 → 125000000.00). `usuario_id` nulo = cambio sin login de la app (la carga desde Sheets, una conexión directa). Solo ADMIN la lee; nadie escribe en ella por la API.
- **Portal:** los externos entran a `portal.html` (el login y las pantallas internas los redirigen; la redirección es comodidad, la protección es RLS). Una card con sus materiales, filtros por mes y sub campaña, calendario sin costos y CSV con las mismas columnas de la vista (más el número de evidencias). Las evidencias van en un panel por material (ver «Evidencias»).
- **Duplicados:** si se unifica un proveedor, sus compras pasan al proveedor canónico. Un usuario PROVEEDOR que apuntaba al proveedor absorbido deja de ver esas compras: hay que cambiar su `proveedor_id` al canónico.
- **Pruebas:** después de tocar algo de esto, correr `sql/fase3_portal_pruebas.sql` en el SQL Editor. Crea usuarios de prueba (PROVEEDOR de EFECTIMEDIOS, AGENCIA de MCO, PLANNING, LECTURA, ADMIN), simula sus sesiones como la API y termina con un error a propósito que revierte todo; el informe sale en el mensaje del error, una línea OK o FALLA por prueba. Recorre todas las vistas de `public` salvo `v_materiales_externos`, así que una vista nueva queda cubierta sola. Tiene fijo que EFECTIMEDIOS ve 218 materiales (al 19-10-2026) (`ESPERADO_PROVEEDOR`): si el Sheets cambia los suyos, actualizarlo.

**Alta de un proveedor o una agencia:** en la pantalla Usuarios, como cualquier otro (ver «Alta de usuarios»). Al PROVEEDOR se le elige su proveedor (si no existe, primero su fila en `proveedores`, una por proveedor y mercado, con `grupo_id`; ojo con los duplicados: usar el nombre que ya tienen sus compras). No lleva `usuario_mercados`: su mercado sale del proveedor. La AGENCIA lleva sus mercados.

## Evidencias

El proveedor documenta la implementación de cada material con varias evidencias: fotos, videos o enlaces. Reemplazan al campo único `materiales.evidencia_url`, que se migró a filas ENLACE y ya no se usa en el portal. La columna sigue existiendo; borrarla es una decisión aparte.

- **Tabla `evidencias`:** id, material_id, tipo (FOTO, VIDEO, ENLACE), ruta_storage (archivos) o url (enlaces), nombre_archivo, tamano_bytes, subido_por, en. Varias por material. Nadie actualiza: una evidencia se borra y se vuelve a subir.
- **Quién hace qué (RLS):** el PROVEEDOR lee e inserta en materiales de sus compras (`fn_mis_compras()`) y borra solo las que subió. La AGENCIA lee las de sus mercados. Los internos leen las de los materiales que ven (sus mercados; ADMIN todo). ADMIN borra cualquiera. La regla de «quién ve este material» está en `fn_veo_material()` y la comparten la tabla y Storage.
- **Lo que no viene del navegador:** un trigger pone `subido_por`, `en` y el **tamaño real**, leído de los metadatos del objeto en Storage, no el que manda el navegador. También exige que el archivo exista en la carpeta de su material, que lo haya subido el mismo usuario, el tipo MIME correcto y los topes: foto hasta 2 MB, video hasta 50 MB. Los enlaces, solo `https://`.
- **Bucket `evidencias`:** privado. Ruta `{proveedor_id}/{material_id}/{uuid}.{ext}`. El bucket solo acepta image/jpeg, image/png, image/webp, video/mp4, video/quicktime y video/webm, con 50 MB por archivo. Las políticas de `storage.objects` están en `fn_evidencia_permitida()`: el PROVEEDOR sube y lee solo en la carpeta de su `proveedor_id` y en materiales de sus compras. Los internos y la AGENCIA leen lo de los materiales que ven. Nadie actualiza ni sobrescribe. Borra quien subió el archivo, o un ADMIN. Los archivos se ven con **URLs firmadas de 10 minutos**, nunca públicas.
- **Borrar:** el portal borra primero el archivo del bucket y después la fila. Si el archivo no se borra, la fila se queda (mejor una evidencia visible que un huérfano invisible). Ojo: cuando RLS no deja borrar, Storage no da error, devuelve una lista vacía; el portal lo trata como fallo.
- **Huérfanos** (archivos sin fila en `evidencias`): salen de un borrado a medias, de un material borrado (sus filas se van en cascada, los archivos no) o, por unos segundos, de una subida en curso. `fn_evidencias_huerfanas()` los lista (solo internos) y Alertas los avisa a partir de los 10 minutos de antigüedad. Un ADMIN los borra en Supabase → Storage → evidencias.
- **En el navegador:** las fotos se reducen a máximo 1600 px de ancho y se comprimen a WebP (o JPEG) al 85 % antes de subir; si siguen pasando de 2 MB, se baja la calidad. Los videos suben sin procesar. Hay barra de progreso y miniatura (en los videos, el primer cuadro). En el celular, el selector ofrece la cámara.
- **Regla del video por enlace:** un video de más de 50 MB no se sube. El portal dice «Comprime el video o compártelo por enlace». Para videos largos lo normal es un enlace de Drive o YouTube, no un archivo.
- **Cuota del plan gratis de Supabase:** 1 GB de Storage en total y 50 MB por archivo. `fn_uso_storage()` suma el tamaño real de `storage.objects` del bucket, huérfanos incluidos (solo internos; a un externo le devuelve nulo). Desde 700 MB, Alertas muestra «Almacenamiento de evidencias al X % del plan gratis», en rojo desde el 90 %. **Al llegar al tope**, Storage deja de aceptar archivos. Hay dos salidas: pasar al plan Pro (100 GB incluidos; también sube el tope por archivo) o depurar, empezando por los videos, que son los más pesados. Para depurar: primero los huérfanos (Alertas), después `SELECT * FROM evidencias WHERE tipo = 'VIDEO' ORDER BY tamano_bytes DESC`. Un ADMIN borra el archivo en Supabase → Storage y luego la fila.
- **Ancho de banda:** el plan gratis incluye 5 GB de transferencia al mes. Por eso las tablas muestran solo el número de evidencias; las miniaturas se cargan únicamente al abrir el panel de un material.

## Alta de usuarios

Desde la pantalla **Usuarios** (`usuarios.html`, solo ADMIN; el enlace aparece en la barra solo para ellos). Reemplaza el alta manual en tres pasos (fila en `usuarios`, filas en `usuario_mercados`, login en Supabase → Authentication).

- **Nuevo usuario** (panel lateral): correo, nombre y rol, con estas etiquetas: Equipo ZB (ZB), Agencia, Proveedor, Lectura, Admin. Si es Proveedor, se elige el mercado y luego el proveedor (obligatorio). Para los demás roles, uno o varios mercados (obligatorio salvo Admin, que ve todos). PLANNING sigue en el enum por compatibilidad, pero no se ofrece y la base lo rechaza en altas nuevas.
- Al crear, la base guarda la fila y sus mercados, Auth crea el login con una **contraseña temporal de 12 caracteres** (mayúscula, minúscula, número y símbolo; sin 0/O ni 1/l/I) y el usuario queda con `debe_cambiar_clave = true`. La contraseña se muestra **una sola vez**, con botón de copiar y el aviso «Envíala por un canal privado». No se guarda en ningún lado; si se pierde, se genera otra.
- **Por fila:** Desactivar (pierde el acceso en el acto y su login queda bloqueado en Auth; un ADMIN no puede desactivarse a sí mismo), Reactivar y Nueva contraseña (otra temporal, con la misma marca). En usuarios antiguos que no tienen login, el botón dice «Crear login».
- **Cambio obligatorio:** con `debe_cambiar_clave = true`, el login y todas las pantallas mandan a `clave.html` hasta que la persona elija su propia contraseña (mínimo 10 caracteres); al guardarla, `fn_clave_cambiada()` apaga la marca. La redirección es del navegador; quien conoce la temporal podría usar la API, pero también podría cambiarla, así que no se bloquea en la base.
- **Cómo funciona:** `usuarios.html` llama a la Edge Function `gestionar-usuarios`. Esta verifica con el JWT que quien llama sea ADMIN activo (si no, responde 403) y usa dos clientes. Con la **llave secreta** hace solo lo de Auth: crear el login, bloquearlo o desbloquearlo, poner la contraseña. Con el **JWT del ADMIN** llama a las funciones de la base (`fn_admin_crear_usuario`, `fn_admin_cambiar_activo`, `fn_admin_marcar_clave_temporal`, `fn_admin_borrar_usuario_sin_login`), que vuelven a exigir ADMIN y validan: correo con formato válido y que no exista, proveedor obligatorio si el rol es Proveedor, al menos un mercado para los demás. Por eso **la auditoría registra al ADMIN que lo hizo**: alta, mercados, activo, contraseña temporal (en `auditoria`, tabla `usuarios`).
- **Si Auth falla** al crear, la fila se deshace. Si falla al desactivar o reactivar, la base vuelve a como estaba. Si ya existe un login con ese correo sin usuario en OASIS, la función lo dice: hay que borrarlo en Authentication → Users.
- **La llave secreta** va solo en Supabase → Edge Functions → Secrets, con el nombre `OASIS_SECRET_KEY` (una llave `sb_secret_…` de Settings → API Keys). Si no está, la función usa `SUPABASE_SERVICE_ROLE_KEY`, que Supabase pone solo. Nunca va en el repositorio ni en `app/`: `probar_usuarios.py` busca con `git grep` llaves `sb_secret_` y JWT de `service_role` en los archivos y en todo el historial.
- **Desplegar:** `npx supabase functions deploy gestionar-usuarios --project-ref tjlteqhqctdtlbppigdi --use-api`. `verify_jwt` está apagado en `supabase/config.toml`: la sesión se verifica dentro de la función.
- **Si un ADMIN olvida su contraseña** y no hay otro ADMIN que le genere una temporal: `source .env && python3 cambiar_clave.py correo@empresa.com`. Pide la contraseña nueva dos veces sin eco (mínimo 10 caracteres), la escribe en `auth.users` con `crypt(…, gen_salt('bf'))` por la conexión de `.env` y cierra las sesiones viejas de ese login. No marca `debe_cambiar_clave` y no imprime ni guarda la contraseña. Avisa si el login está bloqueado o el usuario inactivo: eso no lo arregla, lo hace un ADMIN en la pantalla. Sirve para cualquier login, pero para los demás lo normal es «Nueva contraseña» en la pantalla, que deja rastro en la auditoría; este script no lo deja.
- **Probar:** `source .env && python3 supabase/probar_usuarios.py`. Crea un ADMIN temporal directo en la base (contraseña aleatoria que no se imprime). Recorre el flujo completo contra la función desplegada: validaciones, crear, entrar con la temporal, 403 a un no-ADMIN, nueva contraseña, desactivar, reactivar y cambio de contraseña. Revisa la auditoría y la llave, y al final borra los usuarios de prueba, sus logins y su auditoría, aunque algo falle.

## Detector de duplicados

La IA propone, el humano confirma; nada se unifica sin clic. Card «Posibles duplicados» arriba en Alertas: «Analizar» llama a la Edge Function `detectar-duplicados` dos veces (PROVEEDOR y SOPORTE) para el mercado activo; cada propuesta se unifica o se marca «No son lo mismo». LECTURA ve la lista sin botones.

- **La función** lee con el JWT de quien llama (RLS aplica), manda al modelo (`claude-sonnet-4-6`; se cambia con el secreto `MODELO_DUPLICADOS`) los elementos numerados y recibe números, no textos. Revisa en código lo que no depende del criterio del modelo: dos o más valores, mismo proveedor, misma ciudad (sin tildes) y no repetir un grupo ya unificado o rechazado con los mismos valores. Cada análisis reemplaza las PENDIENTE de ese mercado y tipo.
- **Unificar soporte** cambia `compras.ubicacion` en las compras exactas de cada valor (mercado, proveedor, ubicación y ciudad). **Unificar proveedor** pasa las compras al proveedor canónico (si el nombre no existe, renombra el del grupo con más compras) y deja los demás con `activo = false`. Primero proveedores, luego soportes: un soporte solo se agrupa dentro de un proveedor.
- **La carga respeta lo unificado.** `cargar_oasis.py` traduce lo que llega del Sheets con las propuestas UNIFICADO (proveedor → canónico; proveedor, ubicación y ciudad → ubicación canónica) y lo avisa en el reporte. Sin eso, la siguiente carga desharía la unificación.
- **Desplegar:** `npx supabase functions deploy detectar-duplicados --project-ref tjlteqhqctdtlbppigdi --use-api` (pide `npx supabase login` la primera vez). Secreto: `npx supabase secrets set ANTHROPIC_API_KEY=… --project-ref tjlteqhqctdtlbppigdi`. `supabase/config.toml` apaga `verify_jwt` (la sesión se verifica en la función) y empaca `prompt.md`.
- **Ajustar el prompt:** editar `prompt.md`, probar con `supabase/probar_duplicados.ts` (mismo código, sin desplegar) y volver a desplegar.

## Reglas de negocio — no cambiar sin consultar

**Reparto de inversión.** El valor de una compra se reparte entre sus materiales según los días de calendario que ocupó cada uno. Cuando varios materiales corren el mismo día —lo normal en pantallas digitales—, el costo de ese día se divide en partes iguales entre los activos. Está en `fn_recalcular_inversion_compras` (que llena la tabla `inversion_diaria`) y se lee por `v_inversion_diaria`. Verificación: sumar el costo de una compra por fecha da siempre `valor_total / días calendario`, constante.

**Nunca repartir por días-material.** Ese fue el modelo original y estaba mal: con materiales simultáneos cuenta el mismo día varias veces.

**Un material nunca excede su compra.** Las compras son mensuales y las campañas no respetan el calendario. Si una campaña cruza dos compras del mismo soporte, se parte en dos materiales, uno por compra: 001-A del 15 al 30 de junio bajo la compra de junio, 002-A del 1 al 15 de julio bajo la de julio. En la herramienta es **bloqueo al guardar**, no aviso. El formulario debe ofrecer crear el segundo tramo bajo la compra siguiente, buscándola por soporte y proveedor.

**Fórmula del valor total.** Depende de `compras.tiempo` (columna TIEMPO del Flow) y del tipo de costo. Sin tipo de costo no hay fórmula: la compra es manual. Si `tiempo = 'SEMANA'`, la tarifa es semanal: valor total = tarifa neta × cantidad × nro. semanas (vacío cuenta como 0). **Excepción: si `tipo_costo = 'PRODUCCION'`, el valor total es siempre tarifa neta × cantidad, aunque el tiempo sea SEMANA** (la producción se cobra una vez, no por semana). En cualquier otro caso, valor total = tarifa neta × cantidad. La comparación es exacta; `cargar_oasis.py` normaliza antes TIEMPO por la unidad que nombra (ver «Cómo cargar datos») y cuenta cuántas filas cambió. La aplican igual la interfaz (`formulaValorTotal` en `app/js/compras.js`, también en el panel de nueva compra), `cargar_oasis.py` al marcar `valor_total_manual` y `sql/fase2_tiempo.sql`. Una compra es manual cuando su valor difiere más de $1 de la fórmula; cambiar la fórmula solo cambia la bandera, nunca el valor guardado.

**Costo proyectado vs ejecutado.** Proyectado es todo el periodo. Ejecutado solo los días hasta `configuracion.fecha_corte` (nula = hoy). Ambos se reportan siempre. Solo un ADMIN cambia la fecha de corte, desde el encabezado de Inversión y con confirmación; el cambio afecta también lo que lee BI.

**Mes de ejecución y mes de compra.** El mismo dinero se puede leer por dos meses distintos, y los dos son correctos:
- El Flow y la facturación asignan todo el valor de una compra al mes en que empieza. Una campaña del 15 de junio al 15 de julio comprada en junio es «plata de junio».
- OASIS reparte el valor por día (`v_inversion_diaria`). La misma campaña queda la mitad en junio y la mitad en julio.

Las vistas de inversión traen las dos lecturas: `month` (y `year`, `week`, `date`) es el mes de ejecución; `mes_compra` (primer día del mes de `compras.fecha_inicio`) reproduce la lectura del Flow. Verificación: `SELECT mes_compra, sum(costo_proyectado) FROM v_inversion_diaria GROUP BY 1` coincide, salvo redondeo a centavos, con `sum(valor_total)` de las compras con materiales fechados agrupadas por `date_trunc('month', fecha_inicio)`. La lectura principal es el mes de ejecución; mes de compra es auxiliar, para conciliar (ver Contrato con BI). En Inversión, el selector «Ver por: mes de ejecución / mes de compra» arranca siempre en mes de ejecución y cambia el filtro de mes (exacto en las tres pestañas con mes de compra), los KPIs, el gráfico por mes y la pestaña Semanal (con mes de compra junta las semanas que el cambio de mes partía en dos). Al comparar con el Flow o con una factura, usar mes de compra.

**Las vistas se encadenan.** Semanal y total se agregan desde la diaria, y la diaria lee la tabla precalculada. `v_cuadre` suma la tabla directo. No duplicar la lógica del reparto: vive en un solo lugar, `fn_recalcular_inversion_compras`.

**Código de material.** `compra.codigo + '-' + letra` donde la letra es la secuencia (1=A). La letra no implica orden cronológico.

**Taxonomía de 11 piezas.** Calculada en `v_materiales`. El mercado sale de la compra.

**Validaciones al capturar.** Fecha fin ≥ fecha inicio. Material dentro del periodo de su compra. Campaña y proveedor del mismo mercado que la compra (FK compuesta). Sub campaña del glosario del mismo mercado. Formato entre los que maneja ese proveedor.

## Contrato con BI

`v_inversion_diaria` es lo que consume BI. Sus 18 columnas originales, con sus nombres y su orden, deben mantenerse estables: site, bu, year, month, week, date, proveedor, tipo_costo, formato, valor_total, id (compra), id_ejecucion (material), campana, sub_campana, pct_participacion, costo_proyectado, estado, costo_ejecutado.

Columnas agregadas después, siempre al final para no mover las anteriores: `mes_compra` (19, `sql/fase2_mes_compra.sql`); `moneda` (20), `mercado_id` (21) y `campana_grupo` (22, OTH-PF = «PARQUE FIJO»), de `sql/mercados.sql`. `v_inversion_semanal` y `v_inversion_total` también las tienen al final.

**Nunca sumar mercados.** Cada mercado está en su moneda (`moneda`): un total de BI o de la app es por mercado. En la app, Inversión siempre muestra un mercado (no hay «Todos») y Compras, con «Todos», muestra un total por moneda.

**La columna estándar para reportar por mes es `month`** (mes de ejecución, el reparto por día de OASIS). `mes_compra` es auxiliar: sirve para conciliar con el Flow o con la facturación, que asignan todo al mes de inicio de la compra, y no reemplaza a `month` en ningún reporte.

## Verificación

```sql
SELECT * FROM v_cuadre;    -- debe salir vacío: compras donde la suma no da el valor total
                           -- (hoy, salvo la 371 de MLA: material de 365 días en una compra de enero)
SELECT * FROM v_alertas;   -- pendientes de captura
```

Fase 1 validada: `v_inversion_diaria` reproduce la hoja `Inversion_Daily` con diferencia menor a $2 sobre $3.080 millones.

## Cómo cargar datos

```
source .env
python3 cargar_oasis.py --todos --dry-run          # simula los cinco mercados
python3 cargar_oasis.py --mercado MLC --dry-run    # simula uno
python3 cargar_oasis.py --mercado MLC              # carga uno
python3 cargar_oasis.py --todos                    # carga todos
```

Los IDs de los Sheets están en `mercados.json`. Cada mercado va en su propia transacción: si uno falla, los demás siguen y el resumen lo dice. Antes de tocar la base, el script compara el mercado con la celda PAÍS del Flow (C3) y con la tabla `mercados`; si no coinciden, no carga ese mercado. Localiza los encabezados por nombre, no por posición; si falta uno, se detiene y dice cuál. Es repetible: hace upsert por llave natural. Detecta compras y materiales que ya no están en el Sheets pero no los borra: eso se decide a mano. `--ensayo-sql archivo.sql` aplica una migración dentro de la misma transacción revertida, para ver cómo quedaría la carga con ella antes de aplicarla.

**Todo se carga.** Lo incompleto o inconsistente entra y queda en Alertas de su mercado. Solo no entran: las filas del Flow que solo tienen el ID (plantilla vacía) y los materiales cuya compra no está en el Flow. El reporte dice, por mercado, cuántas compras y materiales leyó y cuántos entraron, qué normalizó en silencio y cada tipo de alerta con su conteo y los primeros 10 casos, leídos de `v_alertas` tal como los verá la pantalla.

**En silencio** (solo se cuentan en el reporte):
- **TIEMPO** por la unidad que nombra: Mes, Meses, MES, Mensual, «2 MESES» → MES; Semana, Semanas, Semanal → SEMANA; Día, Dia, Dias, Diario, «21 días» → DIAS. El número se pierde a propósito: la fórmula solo distingue SEMANA.
- **FORMATO** a mayúsculas y espacios limpios. Lo que difiere en algo más (plural, tildes, una letra: PANTALLA DIGITAL / PANTALLAS DIGITALES) entra tal cual y va a la alerta «formatos parecidos» (`fn_clave_formato` y `levenshtein` de `fuzzystrmatch`).
- **CAMPAÑA** con texto después de la taxonomía («…_INTERIOR_X  5», «… del 01/01/20»): se toma la taxonomía. Sin taxonomía, se busca en `campanas_alias`; si no está, entra el texto tal cual y sale «campaña sin taxonomía».

**Proveedores, dos niveles, con reglas fijas** (el modelo no interviene en la carga):
- **(a)** Si solo cambian mayúsculas, tildes, espacios, puntuación o sufijo societario (S.A., SAS, SRL…), se unifica sola al nombre que ya existe en la base, o al más frecuente en el Sheets si es nuevo. Queda como propuesta UNIFICADO en `duplicados_propuestos` y una fila en `auditoria` por variante. Una propuesta PENDIENTE que la regla ya resolvió se cierra sola.
- **(b)** Si hay palabras de más o de menos (MASSIVA / MASSIVA METRO) o una posible abreviación (JCDX / JCDECAUX, AM ADS / AMERICAN ADS), se cargan como proveedores aparte y van a «proveedores por confirmar», en la card «Posibles duplicados» de Alertas. Nada de (b) se une sin clic.

**Sin tipo de costo** no hay fórmula: la compra vale lo que diga el Sheets (0 si no dice nada) y se marca `valor_total_manual`. **Fechas:** las dos o ninguna; una compra o un material con fechas invertidas entra sin fechas, y el reporte muestra las originales para corregirlas en el Sheets.

**Catálogos ampliados** (`sql/mercados_enum.sql`): tipo de costo COLOCACION (MLA) y tipo de compra FACTURABLE y PAGO ANTICIPADO (MLM). Al 19 de octubre de 2026 eran los únicos valores de los cinco Flows que faltaban. Un valor nuevo de un enum va siempre en un archivo aparte, que se confirma antes de usarlo: Postgres no deja usarlo en la misma transacción que lo agrega.

## Varios mercados

- **Alertas es por mercado:** no hay «Todos». Tipos nuevos: «campaña sin taxonomía», «campaña fuera del glosario», «compra incompleta» (dice qué le falta), «compra sin tipo de costo», «valor fuera de catálogo», «compra sin valor» (sin tarifa ni valor; las BONIFICADO no salen, valen 0 a propósito), «formatos parecidos» y «proveedores por confirmar» (estas últimas se ven en la card de duplicados, no en card propia).
- **Corregir la taxonomía desde Alertas:** en «campaña sin taxonomía» cada texto del Flow tiene un campo para escribir la taxonomía correcta. `fn_asignar_taxonomia` (con permisos del usuario: PLANNING, ZB o ADMIN del mercado) la guarda en `campanas_alias` y corrige las compras del mercado con ese texto; la próxima carga ya no da la alerta. Precargado: MLU «PARQUE FIJO» → `MLU_ML_OTH-PF_ALL_PARQUE-FIJO_X`.
- **Selector de mercado** en Compras, Materiales, Inversión y Alertas para quien tiene varios (ADMIN, LECTURA, un Equipo ZB con varios); con uno solo queda fijo. Inversión y Alertas nunca muestran «Todos». Inversión pide a la base solo el mercado elegido y escribe cada cifra con su moneda.
- **Portal externo** sin cambios: un proveedor o una agencia siguen viendo solo lo suyo.
- **Pruebas:** `sql/mercados_pruebas.sql` (Equipo ZB de MLC sin nada de MCO, LECTURA con todos, cuadre por mercado, compra sin tipo de costo, corrección de taxonomía). Después de tocar algo de esto, correrla junto con `sql/fase3_portal_pruebas.sql`.

## Qué NO hacer

- **Nunca** hacer commit de `.xlsx`, `.csv`, `.env` ni `credenciales_google.json`. El `.gitignore` los excluye; no lo cambies.
- **No crear archivos en `supabase/migrations/`** salvo decisión explícita. La integración de Supabase con GitHub aplica automáticamente en producción lo que haya ahí al fusionar a `main`. Nuestras migraciones van en `sql/` y se aplican a mano, con revisión.
- No modificar el Google Sheets. La carga es Sheets → Supabase, en una sola dirección.
- No cambiar las reglas de reparto ni el contrato con BI sin confirmar con Nicolás.
- Preferir cambios pequeños y verificables. Después de tocar vistas, correr `v_cuadre`.
- No dar de alta usuarios a mano en Supabase: se hace en la pantalla Usuarios (ver «Alta de usuarios»), que crea la fila, los mercados y el login juntos y deja rastro en la auditoría. Si alguien olvida su contraseña, un ADMIN le genera otra temporal ahí mismo (no hay «olvidé mi contraseña» sin correo propio); si el que la olvidó es el ADMIN, `cambiar_clave.py`. Si algo obliga a hacerlo a mano, el orden importa: la fila en `usuarios` va **antes** de crear el login, para que el trigger complete `auth_user_id`.

## Login

Dos métodos en `app/index.html`, los dos siempre visibles; el interruptor es `CODIGO_DISPONIBLE` en `app/js/login.js`.
- **Hoy (`false`):** contraseña es la primera pestaña y la que abre. La pestaña «Código por correo» dice «próximamente» y solo muestra una nota. El piloto entra con contraseña. Quien entra con una contraseña temporal pasa primero por `clave.html` (ver «Alta de usuarios»).
- **Con correo propio (`true`):** se configura SMTP propio en Supabase (Resend), se pega `supabase/plantilla_codigo.html` y se cambia a `true`. El código pasa a ser la primera pestaña y la principal; la contraseña queda como segunda opción.

Se usa código y no enlace porque los escáneres del correo corporativo abren los enlaces antes que el usuario y los dejan vencidos.

## Estado y pendientes

**Hecho:** esquema, vistas de cálculo, carga en vivo desde Sheets, validación contra Sheets, repositorio, corrección de vocabulario, autenticación y RLS para roles internos. Fase 2 completa: las cuatro pantallas de la interfaz interna (Compras, Materiales, Inversión, Alertas) terminadas y probadas.

**RLS:** activo con 18 políticas para roles internos (PLANNING, ZB, LECTURA, ADMIN), definidas en `rls_fase2.sql`, y las de externos de `sql/fase3_portal.sql` (ver «Acceso externo»). Catálogos: lectura para internos, escritura ADMIN. `compras` y `materiales`: según `fn_mis_mercados()`; LECTURA no escribe. `usuarios` y `usuario_mercados`: cada uno lo suyo, ADMIN todo. Las vistas tienen `security_invoker` y `anon` no tiene acceso. `postgres` salta RLS, así que la carga y BI no se ven afectados.

**Fase 2 (completa):** interfaz interna para planning y ZB, construida con Claude Code siguiendo `DISENO.md`. Cuatro pantallas: Compras, Materiales, Inversión y Alertas. Consulta se eliminó: Materiales la absorbe (filtros, solo lectura para LECTURA y exportar a CSV). Inversión (gráficos de resumen y tablas total, semanal y diaria) y Alertas son de solo lectura para todos los roles; la única escritura es la fecha de corte (ADMIN). Los enlaces de Alertas abren Compras o Materiales con `?mercado=…&compra=…` o `&material=…` (y `&partir=1` para fuera de periodo). El último mercado elegido se recuerda en el navegador y la barra muestra el número de alertas de ese mercado.

**Siguiente:**
1. **Despliegue y piloto con usuarios internos.** Publicar `app/` como sitio estático, dar de alta a los usuarios del piloto (pantalla Usuarios) y ajustar con lo que reporten. Los equipos siguen llenando el Sheets hasta que el piloto confirme el corte.
2. **Fase 3: portal externo.** En la rama `feature/portal`: acceso externo, auditoría y `portal.html`. Falta piloto con un proveedor y una agencia.
3. **Fase 4: BI.** Conexión directa de BI a las vistas, sin usuario en la app.

**Datos por limpiar en el Sheets** (trabajo del equipo, no del sistema), según la carga del 5 de octubre de 2026: 1 material sin fechas (053-A), 109 materiales fuera del periodo de su compra (se resuelven con «Partir →» en Materiales), 12 compras sin materiales, proveedores duplicados (`JCDECAUX`/`JCDX`, `PUBLICIDAD BARRANQUILLA`/`PUBLICIDAD BQUILLA`).

**Riesgo del Sheets:** en Flow el ID es `=TEXT(ROW()-10,"000")` y en Tracking el "ID FLOW" se escribe a mano. Ordenar o insertar filas en Flow renumera las compras y deja materiales colgados de otra compra sin ningún aviso. Antes de cargar, comparar con `--dry-run` cuántas compras cambian de ubicación.

**Tarea del día del corte** (cuando el Sheets se jubile y los 109 fuera de periodo estén limpios): agregar un trigger en `materiales` que haga cumplir en la base que el material esté dentro del periodo de su compra, al insertar o actualizar el material y al cambiar las fechas de la compra. Hoy esa regla solo vive en la interfaz y en `fn_guardar_tramos`; no se pone antes porque haría fallar `cargar_oasis.py`.

**Decisiones abiertas:** días de montaje entre campañas, reparto por share of voice, identidad individual de proveedores, cuándo borrar `materiales.evidencia_url`.

## Contexto del usuario

Nicolás trabaja en OOH para Mercado Libre Colombia. No es desarrollador; maneja bien Sheets y está aprendiendo el stack. Prefiere explicaciones paso a paso, respuestas directas, y que se le señalen problemas y tradeoffs con claridad en vez de validarlo todo. Las decisiones de arquitectura están documentadas y no se re-litigan salvo que él lo pida.

## Permisos de Nicolás en GCP (proyecto mbw-spl-brazil)

Editor, Create Service Accounts, Service Account Key Admin, BigQuery User, BigQuery Job User, BigQuery Connection User, BigQuery Metadata Viewer. Puede crear cuentas de servicio, llaves, Cloud SQL, Cloud Run, datasets BigQuery y habilitar APIs. No puede asignar permisos a otros ni ver facturación.
