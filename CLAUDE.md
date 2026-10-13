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
| Carga desde Sheets | `cargar_oasis.py` — lee el Sheets en vivo y hace upsert |
| Credenciales Google | `credenciales_google.json` — cuenta de servicio, nunca al repositorio |
| Credenciales Postgres | `.env` — nunca al repositorio |
| Autenticación y RLS | `rls_fase2.sql` — funciones de identidad, políticas, trigger de vínculo |
| Sistema de diseño | `DISENO.md` — tokens, tipografía, componentes y pantallas de la interfaz |
| Interfaz interna | `app/` — sitio estático; login con correo y contraseña. El código de 6 dígitos por correo se ve como «próximamente» hasta tener correo propio (ver Login). Cuatro pantallas: Compras, Materiales, Inversión, Alertas. Con rol LECTURA, Compras y Materiales se muestran como texto, sin edición |
| Portal externo | `app/portal.html` (+ `js/portal.js`, `css/portal.css`) — PROVEEDOR y AGENCIA. El mismo login los manda ahí según el rol. Ver «Acceso externo» |
| Acceso externo y auditoría | `sql/fase3_portal.sql` (`fn_mis_compras`, `v_materiales_externos`, políticas, funciones de escritura, `auditoria`); pruebas en `sql/fase3_portal_pruebas.sql` (se revierten solas) |
| Sitio publicado | https://zeta-be.github.io/OASIS/ — GitHub Pages publica `app/` en cada push a `main` (`.github/workflows/pages.yml`). Vive en la subcarpeta `/OASIS/`: toda ruta dentro de `app/` debe ser relativa, nunca empezar con `/` |
| Plantilla de correo de acceso | `supabase/plantilla_codigo.html` — se pega a mano en Supabase → Authentication → Emails (Magic Link y Confirm signup). Todavía no se puede: Supabase no deja editar plantillas sin SMTP propio |
| Detector de duplicados | `sql/duplicados.sql` (tabla, RLS, `fn_unificar_duplicado`, `fn_rechazar_duplicado`), Edge Function `supabase/functions/detectar-duplicados/` (el prompt está en `prompt.md`), prueba local `supabase/probar_duplicados.ts`. Ver «Detector de duplicados» |
| Código | GitHub `Zeta-Be/OASIS` (https://github.com/Zeta-Be/OASIS) |
| Fuente de captura actual | Google Sheets `13Vh45CymNMntNG-EW3NQnglnfyvq39nT7nvediDTV1g` (los equipos siguen llenando ahí hasta que exista la interfaz) |

## Modelo de datos

```
mercados ──< campanas            (glosario oficial de ZetaB, no se edita aquí)
mercados ──< proveedores         (una fila por proveedor-mercado, agrupadas por grupo_id)
mercados ──< compras ──< materiales
usuarios ──< usuario_mercados    (a qué países accede cada usuario interno)
configuracion                    (clave fecha_corte: nula = hoy)
```

Siete mercados: MCO, MLB, MLM, MLA, MLC, MLU, MPE. Hoy solo hay datos de MCO.

Enums: `tipo_costo` (EXHIBICION, PRODUCCION, IMPUESTOS), `tipo_compra` (DIRECTO, BONIFICADO), `medio` (OOH, DOOH), `rol` (PLANNING, ZB, AGENCIA, PROVEEDOR, LECTURA, ADMIN).

**Rol LECTURA.** Consulta interna sin captura: jefes, otras áreas, gente nueva en planning. Ve las cuatro pantallas con los datos de sus mercados, filtra y exporta; no escribe nada. No es el rol de BI: BI se conectará a las vistas directamente, sin usuario en la app, y eso se define en la Fase 4.

Vistas: `v_materiales_externos` (la única para PROVEEDOR y AGENCIA; ver «Acceso externo»), `v_materiales` (nivel material, con taxonomía), `v_inversion_diaria`, `v_inversion_semanal`, `v_inversion_total`, `v_alertas` (alerta, referencia y, para enlazar, mercado, compra_id, material_id), `v_cuadre`, `v_sub_campanas` (glosario de cada mercado sin su campaña OOH; para elegir sub campaña en Materiales).

**La interfaz lee las vistas de inversión por `fn_inversion_diaria()`, `fn_inversion_semanal()` y `fn_inversion_total()`**, nunca directo. Con RLS el planificador estima mal cuántas compras ve el usuario y la vista pasa de 0,5 s a 14 s; `authenticated` corta a los 8 s. Las funciones devuelven la vista tal cual, con permisos del usuario, y solo apagan los nested loops. BI (sin RLS) no se ve afectado. Si se agrega otra lectura de esas vistas desde la app, va por estas funciones.

**Campaña de la compra.** La fija el mercado: `mercados.campana_ooh_id` (MCO = PARQUE-FIJO). Los demás mercados aún no la tienen y no pueden crear compras. La carga avisa si el Sheets trae otra y usa la del mercado.

**Valor total.** `compras.valor_total_manual`: false = sale de la fórmula (ver reglas de negocio), lo recalcula la interfaz; true = escrito a mano (marcado cuando difiere más de $1 de la fórmula, al migrar y al cargar). `descuento_pct` es fracción 0–1.

**Tramos.** Cuando una campaña cruza dos compras del mismo soporte se parte en un material por compra; los tramos comparten `materiales.grupo_tramo` (uuid, nulo si no está partido). La interfaz crea y parte materiales con `fn_guardar_tramos(material_id, datos, tramos)`: una transacción, con permisos del usuario (RLS aplica), que asigna la siguiente letra libre de cada compra y rechaza tramos fuera del periodo. Mismo soporte = mismo mercado, proveedor, ubicación y tipo de costo. No hay CHECK de periodo en la tabla: el Sheets todavía trae materiales fuera de su compra y la carga no debe fallar.

Cambios de Fase 2 sobre el esquema: `sql/fase2_compras.sql`, `sql/fase2_materiales.sql`, `sql/fase2_alertas.sql`, `sql/fase2_inversion.sql`, `sql/fase2_tiempo.sql`, `sql/fase2_mes_compra.sql`.

## Acceso externo (Fase 3)

Primera vez que entran usuarios de fuera de ZetaBé. La regla: **un externo no ve nada del Flow**. Ni la tabla `compras`, ni una vista de compras, ni fechas de la compra, ni tarifas, descuentos, valor total o inversión. Ve sus materiales como hoy ve el Tracking en Sheets, y eso se cumple en la base, no solo en la pantalla.

| Rol | Ve | Escribe |
|---|---|---|
| PROVEEDOR | Los materiales de las compras de **su proveedor** (`usuarios.proveedor_id`) | Reporte de implementación y evidencia, solo con `fn_reportar_implementacion` |
| AGENCIA | Los materiales de las compras de **sus mercados** (`usuario_mercados`) | Enlace, solo con `fn_actualizar_enlace` |

- **Una sola regla, `fn_mis_compras()`:** SECURITY DEFINER, devuelve solo ids de compra (PROVEEDOR: las de su `proveedor_id`; AGENCIA: las de `fn_mis_mercados()`; internos: ninguna). La usan la política de materiales, la vista y las dos funciones de escritura. Si cambia qué le toca a un externo, se cambia ahí.
- **`v_materiales_externos`:** la única vista para externos y lo único que consulta el portal. Dueño postgres, `security_invoker = false`, `security_barrier = true`, filtrada con `fn_mis_compras()`. Columnas, exactamente: id (llave del material), codigo, sub_campana, referencia, fecha_inicio, fecha_fin, enlace, reporte_implementacion, evidencia_url (las del material) y compra (código), proveedor, formato, ubicacion, ciudad, tipo_costo (las que el Tracking hereda por VLOOKUP). Agregar una columna aquí es decidir mostrársela a proveedores y agencias.
- **compras:** ninguna política para externos; `SELECT * FROM compras` les da cero filas. No hay vista de compras expuesta a `authenticated`.
- **materiales:** política `lectura_externos`, solo SELECT, con `compra_id IN (SELECT fn_mis_compras())`. No puede ser `EXISTS (… FROM compras …)` como en los internos: esa subconsulta pasa por RLS y para un externo siempre daría falso. Sin políticas de INSERT, UPDATE ni DELETE: un PATCH por la API cambia cero filas. Ojo: por esta política un externo que consulte la tabla directo también ve las columnas técnicas del material (`compra_id`, `secuencia`, `sub_campana_id`, `referencia`, `grupo_tramo`); nada del Flow.
- **Escritura:** `fn_reportar_implementacion(material_id, reporte, evidencia_url)` y `fn_actualizar_enlace(material_id, enlace)` son SECURITY DEFINER: revisan rol y pertenencia con `fn_mis_compras()`, exigen enlaces `https://` (`fn_es_url`) y tocan solo sus campos. Si el material no es suyo, error 42501. Los internos no las usan: editan en Materiales.
- **Catálogos:** los externos leen de `campanas` solo las sub campañas de sus materiales. `proveedores`, `mercados`, `configuracion`, `usuario_mercados` y `duplicados_propuestos` siguen solo para internos. Cualquier usuario activo lee su propia fila de `usuarios` (el login la necesita para saber a dónde mandarlo).
- **Todo lo demás da cero filas, no 403:** las vistas de inversión, `v_materiales`, `v_alertas`, `v_cuadre` y `v_sub_campanas` cruzan con tablas que el externo no ve. Con un solo rol de Postgres (`authenticated`) para todos, la base no puede negar una vista a unos y dársela a otros; lo que la vacía es RLS. **Pendiente opcional:** un rol de Postgres aparte para externos (por el hook de Supabase Auth que pone `role` en el JWT), sin GRANT sobre compras ni sobre las vistas de inversión. Daría error 403 real y protegería aunque una política quedara mal; es un cambio de arquitectura, no urgente.
- **`fn_mis_mercados()`:** para PROVEEDOR devuelve el mercado de su proveedor; para AGENCIA, sus `usuario_mercados`. Las políticas internas exigen rol interno, así que esto no les abre nada.
- **Auditoría:** tabla `auditoria` (tabla, fila_id, campo, valor_anterior, valor_nuevo, usuario_id, en). Un trigger en `compras` y `materiales` registra cada campo cambiado, de cualquier rol; alta y baja van como una fila con `campo` = `(alta)` o `(baja)` y la fila completa en JSON. No registra `actualizado_en` ni un número que solo cambia de escala (125000000 → 125000000.00). `usuario_id` nulo = cambio sin login de la app (la carga desde Sheets, una conexión directa). Solo ADMIN la lee; nadie escribe en ella por la API.
- **Portal:** los externos entran a `portal.html` (el login y las pantallas internas los redirigen; la redirección es comodidad, la protección es RLS). Una card con sus materiales, filtros por mes y sub campaña, calendario sin costos y CSV con las mismas columnas de la vista. La evidencia se comprueba antes de guardar: https y que el servidor responda. El navegador no puede saber si un archivo de Drive está compartido; eso no se valida.
- **Duplicados:** si se unifica un proveedor, sus compras pasan al proveedor canónico. Un usuario PROVEEDOR que apuntaba al proveedor absorbido deja de ver esas compras: hay que cambiar su `proveedor_id` al canónico.
- **Pruebas:** después de tocar algo de esto, correr `sql/fase3_portal_pruebas.sql` en el SQL Editor. Crea usuarios de prueba (PROVEEDOR de EFECTIMEDIOS, AGENCIA de MCO, PLANNING, LECTURA, ADMIN), simula sus sesiones como la API y termina con un error a propósito que revierte todo; el informe sale en el mensaje del error, una línea OK o FALLA por prueba. Recorre todas las vistas de `public` salvo `v_materiales_externos`, así que una vista nueva queda cubierta sola. Tiene fijo que EFECTIMEDIOS ve 190 materiales (`ESPERADO_PROVEEDOR`): si el Sheets cambia los suyos, actualizarlo.

**Alta de un proveedor** (en este orden):
1. Su fila en `proveedores` si no existe (una por proveedor y mercado, con `grupo_id`). Ojo con los duplicados: usar el nombre que ya tienen sus compras.
2. Su fila en `usuarios`: correo exacto, nombre, `rol = 'PROVEEDOR'`, `proveedor_id` = el id del paso 1. La base exige `proveedor_id` para PROVEEDOR y lo prohíbe para los demás roles. Va **antes** de crear el login, para que el trigger complete `auth_user_id`.
3. El login: Supabase → Authentication → Users → Add user → Create new user, mismo correo, una contraseña, «Auto Confirm User» marcado. La contraseña se entrega por un canal privado.

Un PROVEEDOR no lleva filas en `usuario_mercados`: su mercado sale del proveedor. Una **AGENCIA** se da de alta igual que un interno: fila en `usuarios` con `rol = 'AGENCIA'`, sus filas en `usuario_mercados` y el login.

## Detector de duplicados

La IA propone, el humano confirma; nada se unifica sin clic. Card «Posibles duplicados» arriba en Alertas: «Analizar» llama a la Edge Function `detectar-duplicados` dos veces (PROVEEDOR y SOPORTE) para el mercado activo; cada propuesta se unifica o se marca «No son lo mismo». LECTURA ve la lista sin botones.

- **La función** lee con el JWT de quien llama (RLS aplica), manda al modelo (`claude-sonnet-4-6`; se cambia con el secreto `MODELO_DUPLICADOS`) los elementos numerados y recibe números, no textos. Revisa en código lo que no depende del criterio del modelo: dos o más valores, mismo proveedor, misma ciudad (sin tildes) y no repetir un grupo ya unificado o rechazado con los mismos valores. Cada análisis reemplaza las PENDIENTE de ese mercado y tipo.
- **Unificar soporte** cambia `compras.ubicacion` en las compras exactas de cada valor (mercado, proveedor, ubicación y ciudad). **Unificar proveedor** pasa las compras al proveedor canónico (si el nombre no existe, renombra el del grupo con más compras) y deja los demás con `activo = false`. Primero proveedores, luego soportes: un soporte solo se agrupa dentro de un proveedor.
- **La carga respeta lo unificado.** `cargar_oasis.py` traduce lo que llega del Sheets con las propuestas UNIFICADO (proveedor → canónico; proveedor, ubicación y ciudad → ubicación canónica) y lo avisa en el reporte. Sin eso, la siguiente carga desharía la unificación.
- **Desplegar:** `npx supabase functions deploy detectar-duplicados --project-ref tjlteqhqctdtlbppigdi --use-api` (pide `npx supabase login` la primera vez). Secreto: `npx supabase secrets set ANTHROPIC_API_KEY=… --project-ref tjlteqhqctdtlbppigdi`. `supabase/config.toml` apaga `verify_jwt` (la sesión se verifica en la función) y empaca `prompt.md`.
- **Ajustar el prompt:** editar `prompt.md`, probar con `supabase/probar_duplicados.ts` (mismo código, sin desplegar) y volver a desplegar.

## Reglas de negocio — no cambiar sin consultar

**Reparto de inversión.** El valor de una compra se reparte entre sus materiales según los días de calendario que ocupó cada uno. Cuando varios materiales corren el mismo día —lo normal en pantallas digitales—, el costo de ese día se divide en partes iguales entre los activos. Está en `v_inversion_diaria`. Verificación: sumar el costo de una compra por fecha da siempre `valor_total / días calendario`, constante.

**Nunca repartir por días-material.** Ese fue el modelo original y estaba mal: con materiales simultáneos cuenta el mismo día varias veces.

**Un material nunca excede su compra.** Las compras son mensuales y las campañas no respetan el calendario. Si una campaña cruza dos compras del mismo soporte, se parte en dos materiales, uno por compra: 001-A del 15 al 30 de junio bajo la compra de junio, 002-A del 1 al 15 de julio bajo la de julio. En la herramienta es **bloqueo al guardar**, no aviso. El formulario debe ofrecer crear el segundo tramo bajo la compra siguiente, buscándola por soporte y proveedor.

**Fórmula del valor total.** Depende de `compras.tiempo` (columna TIEMPO del Flow) y del tipo de costo. Si `tiempo = 'SEMANA'`, la tarifa es semanal: valor total = tarifa neta × cantidad × nro. semanas (vacío cuenta como 0). **Excepción: si `tipo_costo = 'PRODUCCION'`, el valor total es siempre tarifa neta × cantidad, aunque el tiempo sea SEMANA** (la producción se cobra una vez, no por semana). En cualquier otro caso, valor total = tarifa neta × cantidad. La comparación es exacta; `cargar_oasis.py` normaliza antes las variantes del Sheets (SEMANAS → SEMANA; DIA y 1 DIA → DIAS) y avisa cuántas filas cambió. La aplican igual la interfaz (`formulaValorTotal` en `app/js/compras.js`, también en el panel de nueva compra), `cargar_oasis.py` al marcar `valor_total_manual` y `sql/fase2_tiempo.sql`. Una compra es manual cuando su valor difiere más de $1 de la fórmula; cambiar la fórmula solo cambia la bandera, nunca el valor guardado.

**Costo proyectado vs ejecutado.** Proyectado es todo el periodo. Ejecutado solo los días hasta `configuracion.fecha_corte` (nula = hoy). Ambos se reportan siempre. Solo un ADMIN cambia la fecha de corte, desde el encabezado de Inversión y con confirmación; el cambio afecta también lo que lee BI.

**Mes de ejecución y mes de compra.** El mismo dinero se puede leer por dos meses distintos, y los dos son correctos:
- El Flow y la facturación asignan todo el valor de una compra al mes en que empieza. Una campaña del 15 de junio al 15 de julio comprada en junio es «plata de junio».
- OASIS reparte el valor por día (`v_inversion_diaria`). La misma campaña queda la mitad en junio y la mitad en julio.

Las vistas de inversión traen las dos lecturas: `month` (y `year`, `week`, `date`) es el mes de ejecución; `mes_compra` (primer día del mes de `compras.fecha_inicio`) reproduce la lectura del Flow. Verificación: `SELECT mes_compra, sum(costo_proyectado) FROM v_inversion_diaria GROUP BY 1` coincide, salvo redondeo a centavos, con `sum(valor_total)` de las compras con materiales fechados agrupadas por `date_trunc('month', fecha_inicio)`. La lectura principal es el mes de ejecución; mes de compra es auxiliar, para conciliar (ver Contrato con BI). En Inversión, el selector «Ver por: mes de ejecución / mes de compra» arranca siempre en mes de ejecución y cambia el filtro de mes (exacto en las tres pestañas con mes de compra), los KPIs, el gráfico por mes y la pestaña Semanal (con mes de compra junta las semanas que el cambio de mes partía en dos). Al comparar con el Flow o con una factura, usar mes de compra.

**Las vistas se encadenan.** Semanal y total se agregan desde la diaria. No duplicar lógica.

**Código de material.** `compra.codigo + '-' + letra` donde la letra es la secuencia (1=A). La letra no implica orden cronológico.

**Taxonomía de 11 piezas.** Calculada en `v_materiales`. El mercado sale de la compra.

**Validaciones al capturar.** Fecha fin ≥ fecha inicio. Material dentro del periodo de su compra. Campaña y proveedor del mismo mercado que la compra (FK compuesta). Sub campaña del glosario del mismo mercado. Formato entre los que maneja ese proveedor.

## Contrato con BI

`v_inversion_diaria` es lo que consume BI. Sus 18 columnas originales, con sus nombres y su orden, deben mantenerse estables: site, bu, year, month, week, date, proveedor, tipo_costo, formato, valor_total, id (compra), id_ejecucion (material), campana, sub_campana, pct_participacion, costo_proyectado, estado, costo_ejecutado.

Columnas agregadas después, siempre al final para no mover las anteriores: `mes_compra` (19, `sql/fase2_mes_compra.sql`). `v_inversion_semanal` y `v_inversion_total` también la tienen al final.

**La columna estándar para reportar por mes es `month`** (mes de ejecución, el reparto por día de OASIS). `mes_compra` es auxiliar: sirve para conciliar con el Flow o con la facturación, que asignan todo al mes de inicio de la compra, y no reemplaza a `month` en ningún reporte.

## Verificación

```sql
SELECT * FROM v_cuadre;    -- debe salir vacío: compras donde la suma no da el valor total
SELECT * FROM v_alertas;   -- pendientes de captura
```

Fase 1 validada: `v_inversion_diaria` reproduce la hoja `Inversion_Daily` con diferencia menor a $2 sobre $3.080 millones.

## Cómo cargar datos

```
source .env
python3 cargar_oasis.py --sheet 13Vh45CymNMntNG-EW3NQnglnfyvq39nT7nvediDTV1g --dry-run   # simula
python3 cargar_oasis.py --sheet 13Vh45CymNMntNG-EW3NQnglnfyvq39nT7nvediDTV1g             # carga
```

El script localiza encabezados por nombre, no por posición. Si falta uno, se detiene y dice cuál. Es repetible: hace upsert por llave natural. Detecta compras y materiales que ya no están en el Sheets pero no los borra: eso se decide a mano.

## Qué NO hacer

- **Nunca** hacer commit de `.xlsx`, `.csv`, `.env` ni `credenciales_google.json`. El `.gitignore` los excluye; no lo cambies.
- **No crear archivos en `supabase/migrations/`** salvo decisión explícita. La integración de Supabase con GitHub aplica automáticamente en producción lo que haya ahí al fusionar a `main`. Nuestras migraciones van en `sql/` y se aplican a mano, con revisión.
- No modificar el Google Sheets. La carga es Sheets → Supabase, en una sola dirección.
- No cambiar las reglas de reparto ni el contrato con BI sin confirmar con Nicolás.
- Preferir cambios pequeños y verificables. Después de tocar vistas, correr `v_cuadre`.
- No dar de alta a alguien en un solo paso. Son dos: (1) su fila en `usuarios` con el correo exacto, **antes** de su primer login, para que el trigger complete `auth_user_id`; si entra antes, el vínculo hay que hacerlo a mano. (2) Sus filas en `usuario_mercados`. Un PLANNING o ZB sin mercados entra, ve los catálogos, pero no ve ninguna compra ni material. ADMIN no necesita mercados: ve todos. **Mientras el login sea con contraseña, hay un tercer paso:** crear la cuenta en Supabase → Authentication → Users → Add user → Create new user, con el mismo correo, una contraseña y «Auto Confirm User» marcado. El trigger hace el vínculo al crearla, así que el paso (1) va antes. La contraseña se le entrega a la persona por un canal privado; si la olvida, un ADMIN la cambia ahí mismo (no hay «olvidé mi contraseña» sin correo propio).

## Login

Dos métodos en `app/index.html`, los dos siempre visibles; el interruptor es `CODIGO_DISPONIBLE` en `app/js/login.js`.
- **Hoy (`false`):** contraseña es la primera pestaña y la que abre. La pestaña «Código por correo» dice «próximamente» y solo muestra una nota. El piloto entra con contraseña.
- **Con correo propio (`true`):** se configura SMTP propio en Supabase (Resend), se pega `supabase/plantilla_codigo.html` y se cambia a `true`. El código pasa a ser la primera pestaña y la principal; la contraseña queda como segunda opción.

Se usa código y no enlace porque los escáneres del correo corporativo abren los enlaces antes que el usuario y los dejan vencidos.

## Estado y pendientes

**Hecho:** esquema, vistas de cálculo, carga en vivo desde Sheets, validación contra Sheets, repositorio, corrección de vocabulario, autenticación y RLS para roles internos. Fase 2 completa: las cuatro pantallas de la interfaz interna (Compras, Materiales, Inversión, Alertas) terminadas y probadas.

**RLS:** activo con 18 políticas para roles internos (PLANNING, ZB, LECTURA, ADMIN), definidas en `rls_fase2.sql`, y las de externos de `sql/fase3_portal.sql` (ver «Acceso externo»). Catálogos: lectura para internos, escritura ADMIN. `compras` y `materiales`: según `fn_mis_mercados()`; LECTURA no escribe. `usuarios` y `usuario_mercados`: cada uno lo suyo, ADMIN todo. Las vistas tienen `security_invoker` y `anon` no tiene acceso. `postgres` salta RLS, así que la carga y BI no se ven afectados.

**Fase 2 (completa):** interfaz interna para planning y ZB, construida con Claude Code siguiendo `DISENO.md`. Cuatro pantallas: Compras, Materiales, Inversión y Alertas. Consulta se eliminó: Materiales la absorbe (filtros, solo lectura para LECTURA y exportar a CSV). Inversión (gráficos de resumen y tablas total, semanal y diaria) y Alertas son de solo lectura para todos los roles; la única escritura es la fecha de corte (ADMIN). Los enlaces de Alertas abren Compras o Materiales con `?mercado=…&compra=…` o `&material=…` (y `&partir=1` para fuera de periodo). El último mercado elegido se recuerda en el navegador y la barra muestra el número de alertas de ese mercado.

**Siguiente:**
1. **Despliegue y piloto con usuarios internos.** Publicar `app/` como sitio estático, dar de alta a los usuarios del piloto (los dos pasos de abajo) y ajustar con lo que reporten. Los equipos siguen llenando el Sheets hasta que el piloto confirme el corte.
2. **Fase 3: portal externo.** En la rama `feature/portal`: acceso externo, auditoría y `portal.html`. Falta piloto con un proveedor y una agencia.
3. **Fase 4: BI.** Conexión directa de BI a las vistas, sin usuario en la app.

**Datos por limpiar en el Sheets** (trabajo del equipo, no del sistema), según la carga del 5 de octubre de 2026: 1 material sin fechas (053-A), 109 materiales fuera del periodo de su compra (se resuelven con «Partir →» en Materiales), 12 compras sin materiales, proveedores duplicados (`JCDECAUX`/`JCDX`, `PUBLICIDAD BARRANQUILLA`/`PUBLICIDAD BQUILLA`).

**Riesgo del Sheets:** en Flow el ID es `=TEXT(ROW()-10,"000")` y en Tracking el "ID FLOW" se escribe a mano. Ordenar o insertar filas en Flow renumera las compras y deja materiales colgados de otra compra sin ningún aviso. Antes de cargar, comparar con `--dry-run` cuántas compras cambian de ubicación.

**Tarea del día del corte** (cuando el Sheets se jubile y los 109 fuera de periodo estén limpios): agregar un trigger en `materiales` que haga cumplir en la base que el material esté dentro del periodo de su compra, al insertar o actualizar el material y al cambiar las fechas de la compra. Hoy esa regla solo vive en la interfaz y en `fn_guardar_tramos`; no se pone antes porque haría fallar `cargar_oasis.py`.

**Decisiones abiertas:** días de montaje entre campañas, reparto por share of voice, evidencias con copia propia, identidad individual de proveedores.

## Contexto del usuario

Nicolás trabaja en OOH para Mercado Libre Colombia. No es desarrollador; maneja bien Sheets y está aprendiendo el stack. Prefiere explicaciones paso a paso, respuestas directas, y que se le señalen problemas y tradeoffs con claridad en vez de validarlo todo. Las decisiones de arquitectura están documentadas y no se re-litigan salvo que él lo pida.

## Permisos de Nicolás en GCP (proyecto mbw-spl-brazil)

Editor, Create Service Accounts, Service Account Key Admin, BigQuery User, BigQuery Job User, BigQuery Connection User, BigQuery Metadata Viewer. Puede crear cuentas de servicio, llaves, Cloud SQL, Cloud Run, datasets BigQuery y habilitar APIs. No puede asignar permisos a otros ni ver facturación.
