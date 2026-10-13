# Sistema de diseño — OASIS v2.0

Las pantallas de OASIS siguen el sistema visual del Planificador de Campañas ZetaBé y del dashboard Parque Fijo LATAM. Son la misma familia de herramientas y deben verse como tal.

Referencia de origen: el prototipo del Planificador de Campañas ZetaBé (artefacto interno, fuera de este repositorio). Esta especificación lo resume; si algo no está aquí, se decide siguiendo las reglas de uso de abajo, no consultando el prototipo.

## Carácter

Hoja de cálculo editorial. Fondo papel cálido, no blanco puro. Negro y amarillo Mercado Libre como únicos acentos fuertes. Títulos en condensada mayúscula, números en monoespaciada con dígitos tabulares. Nada de sombras suaves, bordes redondeados grandes ni degradados: las esquinas son rectas y los bordes son de 1 px.

Lo que **no** es: no es Material Design, no es shadcn, no es Tailwind por defecto. Si una herramienta genera botones redondeados azules o cards con sombra, está mal.

## Tokens

```css
:root {
  /* Superficies */
  --ground:    #F2F0EA;   /* fondo de página */
  --surface:   #FFFFFF;   /* cards, tablas, inputs */
  --calc:      #F4F1E7;   /* celdas calculadas, solo lectura */

  /* Texto */
  --ink:       #16150F;
  --ink-soft:  #4B4636;
  --muted:     #6E6858;

  /* Líneas */
  --rule:      #E0DCD0;   /* bordes principales */
  --rule-soft: #ECE9E0;   /* separadores de fila */

  /* Acentos */
  --k:         #000000;   /* negro: barra superior, encabezados de tabla, filas de total */
  --y:         #FDC62C;   /* amarillo ML: activo, primario, foco */
  --y-wash:    #FFF5D6;   /* fondo de input con foco, filas observadas */
  --y-deep:    #7A5A00;   /* amarillo oscuro para texto sobre claro */

  /* Estados */
  --err:       #B42318;  --err-wash:  #FDECEA;
  --warn:      #A14A06;  --warn-wash: #FEF1E1;
  --ok:        #2E6B34;  --ok-wash:   #E7F2E8;
}
```

Modo oscuro: el prototipo lo soporta pero OASIS v2.0 arranca solo en claro.

## Tipografía

| Uso | Fuente | Peso | Tamaño |
|---|---|---|---|
| Cuerpo, formularios, tablas | Mulish | 400–700 | 12–13 px en tablas, 14–15 en texto |
| Títulos de pantalla y de card | Sofia Sans Extra Condensed | 800, mayúsculas | 34 px pantalla, 26 px card |
| Números, códigos, fechas, etiquetas pequeñas | JetBrains Mono | 400–500 | 9.5–12 px, `font-variant-numeric: tabular-nums` |

Carga desde Google Fonts:
```
https://fonts.googleapis.com/css2?family=Sofia+Sans+Extra+Condensed:wght@700;800&family=Mulish:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap
```

Los códigos de compra y material (`001`, `001-A`), los montos y las fechas van siempre en JetBrains Mono. El texto descriptivo —ubicación, nombre de campaña— va en Mulish.

## Componentes

### Barra superior
Fondo `--k`, altura mínima 50 px, texto blanco. Contiene: marca, navegación principal, migas de pan, usuario.
- Ítem de navegación: 12.5 px, bold, color `#D8D3C4`; activo en `--y` con subrayado de 2 px del mismo color.
- Migas: 12 px, `#A39D8B`, con el nivel actual en `--y` bold.
- Usuario: dos líneas, nombre y rol, 12 y 11 px.
- Junto a «Alertas», el total de alertas del mercado activo: JetBrains Mono 10 px, `#A39D8B` (`--y` si la pestaña está activa), un poco elevado. Sin alertas, no se muestra.

### Título de pantalla
Sofia Sans Extra Condensed 800, 34 px, mayúsculas, línea de 0.95. Encima puede ir un eyebrow en JetBrains Mono 11 px, espaciado 0.16 em, `--muted`.

### Pestañas
Borde 1 px `--rule`, 12 px bold, texto `--muted`, fondo `--surface`. Activa: fondo `--k`, texto `--y`. Pegadas entre sí (margen −1 px).

### Card
Fondo `--surface`, borde 1 px `--rule`, **borde superior de 4 px en `--k`**. Encabezado con padding 12 × 14, título en condensada 26 px, separador inferior 1 px. Sin radio, sin sombra.

### KPIs
Franja horizontal con borde `--rule`. Cada KPI: etiqueta 9.5 px mayúscula espaciada en `--muted`, valor en JetBrains Mono. Separados por línea vertical `--rule-soft`.

### Tabla
- `th`: fondo `--k`, texto `#F5F3EC`, 10 px, bold, mayúsculas, espaciado 0.06 em. Columnas calculadas con texto en `--y`.
- `td`: 12 px, padding 6 × 10, borde inferior `--rule-soft`, sin ajuste de línea.
- Celda calculada: fondo `--calc`, texto `--ink-soft`.
- Celda numérica: JetBrains Mono, alineada a la derecha.
- Celda con error: fondo `--err-wash`, línea inferior de 2 px en `--err`.
- Fila de subtotal: fondo `#F7F5EF`, bold.
- Fila de total: fondo `--k`, texto claro, bold; los montos destacados en `--y`.
- Primeras columnas pegajosas (sticky) en tablas anchas.
- Fila resaltada (la que se abrió desde Alertas): fondo `--y-wash` y línea izquierda de 4 px en `--k` en la primera celda. Las celdas con error conservan su marca.
- Tablas largas de solo lectura: se paginan de 200 en 200 con un paginador al pie («Filas 1–200 de N», Anterior / Siguiente). KPIs y fila de total siempre suman todo lo filtrado, no la página.

### Inputs dentro de tabla
Sin borde, sin fondo, altura 31 px, padding 0 × 9. Al enfocar, fondo `--y-wash`. Numéricos alineados a la derecha en monoespaciada. El input vive dentro de la celda; la celda es el contenedor visual.

### Inputs fuera de tabla
Borde 1 px `--rule`, altura 32 px, fondo `--surface`. Deshabilitado: fondo `--calc`, borde transparente.

### Etiqueta de campo
11 px, bold, mayúsculas, espaciado 0.06 em, `--muted`, 14 px de margen arriba.

### Botones
12.5 px, bold, padding 9 × 14, borde 1 px `--rule`, fondo `--surface`. Hover: borde `--k`.
- **Primario** (`.p`): fondo `--y`, borde `--k`. Hover: `#FFD24D`.
- Foco visible: contorno 2 px `--k` o `--y`, desplazado 1–2 px.
- Sin iconos salvo que aporten; el texto basta.

### Alertas en línea
Borde izquierdo 4 px, padding 10 × 14, fondo `--surface`, 12.5 px.
- Error: borde `--err`, fondo `--err-wash`.
- Advertencia: borde `--warn`, fondo `--warn-wash`.
- Neutra: borde `--k`.

### Pills de estado
JetBrains Mono 10.5 px, padding 2 × 8, radio completo. Validado en `--ok` sobre `--ok-wash`; propuesto en `--y-deep` sobre `--y-wash`; pendiente en `--err` sobre `--err-wash`.

### Calendario
Celdas de 28 px de ancho, 30 px de alto. Encabezado de día 9.5 px en dos líneas (día de semana, número). Fines de semana con fondo `#F8F6F0` en cuerpo y `#26241E` en encabezado. Cambio de mes con borde izquierdo `#CFCABB`. Día activo marcado con `--y`; día compartido entre varias campañas con rayado diagonal `--y` / `#D6D1C3`.

### Panel lateral
Para crear registros nuevos. Entra desde la derecha sobre la pantalla, con un fondo `--ink` al 28 %. Ancho máximo 560 px, fondo `--surface`, borde izquierdo 1 px `--k` y superior 4 px `--k`, sin sombra. Encabezado con eyebrow y título condensado de 26 px. Los campos siguen el orden de las columnas de la tabla, en dos columnas; los calculados en `--calc`. El error se marca en el campo (fondo `--err-wash`, línea inferior `--err`) con el mensaje debajo en 11.5 px. Pie fijo con "Cancelar" y el botón primario de guardar. Esc cierra.

### Filtro de selección múltiple
Mismo aspecto que un input fuera de tabla. Muestra "Todos" si no hay nada marcado, el nombre si hay uno y "N seleccionados" si hay varios; con selección activa, borde `--k` y texto bold. La lista lleva casillas y un "Limpiar" al pie.

### Gráficos
HTML y CSS, sin librería. Forma de énfasis: lo ejecutado en ámbar `#C98500`, lo que falta por ejecutar en `#DDD8CB`; la barra completa es el proyectado. Validados con el validador de paletas de dataviz (daltonismo ΔE 23.7, visión normal 24.7); el gris queda bajo 3:1 sobre blanco, por eso cada barra lleva su valor y hay vista de tabla.
- Columnas para series en el tiempo (por mes), barras horizontales para categorías (por sub campaña, por proveedor; las 8 mayores y el resto en «Otros (n)»).
- Barras de 24 px como máximo (columnas) y 14 px (horizontales), esquinas rectas, hueco de 2 px blanco entre segmentos, sin eje Y: el valor va sobre la columna o en la punta de la barra, abreviado en millones («$ 632 M»).
- Leyenda única en el encabezado de la card, porque los tres gráficos usan la misma codificación.
- Al pasar el cursor o enfocar con teclado, globo negro con los valores exactos (proyectado con % del total, ejecutado, por ejecutar), valor primero.
- «Ver como tabla» cambia los gráficos por tablas con los mismos datos.
- Mientras recargan (ej. tras cambiar la fecha de corte) quedan al 50 % de opacidad, sin parpadeo.
- El ámbar de los gráficos es un tono propio de los datos: no se usa en botones ni texto.

### Modal de confirmación
Solo para confirmar algo con efecto amplio (ej. la fecha de corte). Centrado, máximo 440 px, mismo fondo `--ink` al 28 % que el panel lateral; caja `--surface` con borde 1 px `--k` y superior 4 px `--k`, sin sombra. Dos pasos: elegir y luego confirmar diciendo qué cambia y para quién. Esc cierra.

### Combo
Input con lista de valores ya usados que acepta texto nuevo (ej. formato). Un valor nuevo se marca en `--warn-wash` y pide confirmación antes de guardar, sugiriendo el existente más parecido.

### Login
Dos columnas: izquierda `--k` con la marca y una frase en `#A39D8B`; derecha el formulario centrado, máximo 520 px.

## Reglas de uso

1. **El amarillo es escaso.** Solo para lo activo, lo primario y el foco. Nunca como fondo de sección ni como decoración.
2. **El negro estructura.** Barra superior, encabezados de tabla, filas de total, borde superior de card. Es lo que hace que una pantalla se lea como parte del sistema.
3. **Las celdas calculadas se ven distintas.** Fondo `--calc`. El usuario tiene que saber de un vistazo qué puede editar y qué no.
4. **Los números siempre en monoespaciada y alineados a la derecha.** Sin excepciones, incluidos códigos y fechas.
5. **Los errores se marcan en la celda**, no solo en un mensaje general. Fondo rojo claro y línea inferior roja.
6. **Lo existente se edita en tabla; lo nuevo se crea en panel lateral.** Las compras y los materiales que ya existen se editan en su fila. Los nuevos se crean en un panel que entra desde la derecha y no existen hasta que se guardan. Los modales siguen siendo solo para confirmaciones.
7. **El rol LECTURA ve texto, no campos.** LECTURA es consulta interna sin captura: jefes, otras áreas, gente nueva en planning. No es el rol de BI (BI se conecta a las vistas sin usuario en la app; Fase 4). En Compras y Materiales los valores se muestran como texto plano, sin inputs; no hay botón de nuevo ni guardado al salir de la celda. Sí puede filtrar, ver el calendario y exportar. Inversión y Alertas las ve completas, igual que los demás roles; solo la fecha de corte no es editable.

## Pantallas de la Fase 2 (interfaz interna)

| Pantalla | Equivale a | Componentes |
|---|---|---|
| Compras | Flow | Card con tabla editable; una fila por compra; alta en panel lateral; filtros de selección múltiple por mes, proveedor, tipo de costo; KPIs de total y cantidad |
| Materiales | Tracking | Card con tabla editable; una fila por material; columnas calculadas de compra en `--calc`; botón que cambia la tabla por el calendario del mes; validación de fechas en celda con enlace «Partir →» al panel; exportar a CSV las filas filtradas. Absorbe la antigua pantalla Consulta (hoja Vista) |
| Inversión | Inversion_total / semanal / diaria | Solo lectura. Filtros encima de todo, compartidos: «Ver por» (mes de ejecución / mes de compra, como pestañas), mercado, mes, proveedor, tipo de costo, sub campaña; la etiqueta del filtro de mes dice cuál de los dos meses filtra. Card «Resumen» con tres gráficos (por mes, por sub campaña, por proveedor) calculados desde la diaria filtrada. Card «Reparto» con tres pestañas en el encabezado de la card, cada una con todas las columnas de su vista; KPIs de proyectado, ejecutado y por ejecutar; fila de total negra; paginación de 200; exportar CSV de la pestaña. «Ejecutado a: 5 oct 2026» en el encabezado: un ADMIN lo cambia o lo vuelve a hoy con confirmación |
| Alertas | v_alertas | Solo lectura. Filtro de mercado; una card por tipo con el conteo en el título, en este orden: fuera de periodo, sin fechas, sin sub campaña, compra sin materiales, sub campaña de otro mercado. Sin casos, sin card. Cada referencia abre Compras o Materiales con la fila resaltada; fuera de periodo abre el panel de partición |

Cada pantalla lleva la barra superior, el título condensado y una card. Las tablas editables siguen el patrón de tabla editable: inputs sin borde dentro de la celda, calculadas en `--calc`, errores en la celda.

## Pantalla de la Fase 3 (portal externo)

| Pantalla | Para | Componentes |
|---|---|---|
| Portal | PROVEEDOR, AGENCIA | Lee solo `v_materiales_externos`: nada del Flow (ni fechas de la compra, ni montos). Barra superior sin navegación interna: marca y migas «Portal / EFECTIMEDIOS» (o «Agencia»). Una card con la tabla de materiales: código, compra (código + ubicación), formato, ciudad, tipo de costo, sub campaña, referencia, enlace, imagen, reporte, evidencia y fechas del material; para AGENCIA también proveedor. Todo en `--calc` salvo lo que el rol edita: reporte y evidencia (PROVEEDOR) o enlace (AGENCIA), con guardado al salir de la fila. Filtros de mes y sub campaña; KPIs de lo que falta por llenar; calendario igual al de Materiales, sin costos; exportar CSV con las mismas columnas |
