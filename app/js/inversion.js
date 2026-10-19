// Pantalla de Inversión: las tres vistas de reparto (total, semanal, diaria), de
// solo lectura. Cada pestaña lee su vista tal cual; los filtros son compartidos.
// La única escritura es la fecha de corte, y solo para ADMIN.

// Título y tipo de cada columna de las vistas. El tipo decide formato y alineación.
const COLUMNAS_INV = {
  site:              ['Mercado', 'cod'],
  bu:                ['BU', 'txt'],
  year:              ['Año', 'ent'],
  month:             ['Mes', 'ent'],
  week:              ['Semana', 'ent'],
  date:              ['Fecha', 'fecha'],
  proveedor:         ['Proveedor', 'txt'],
  tipo_costo:        ['Tipo de costo', 'txt'],
  formato:           ['Formato', 'txt'],
  valor_total:       ['Valor total compra', 'pesos'],
  id:                ['Compra', 'cod'],
  id_ejecucion:      ['Material', 'cod'],
  campana:           ['Campaña', 'txt'],
  sub_campana:       ['Sub campaña', 'txt'],
  fecha_inicio:      ['Fecha inicio', 'fecha'],
  fecha_fin:         ['Fecha fin', 'fecha'],
  dias:              ['Días', 'ent'],
  pct_participacion: ['% participación', 'pct'],
  costo_proyectado:  ['Costo proyectado', 'pesos'],
  estado:            ['Estado', 'txt'],
  costo_ejecutado:   ['Costo ejecutado', 'pesos'],
  mes_compra:        ['Mes de compra', 'mes'],
  moneda:            ['Moneda', 'cod'],
};

// Columnas en el orden de cada vista. `orden` es único por fila: la paginación
// de la API necesita un orden estable para no repetir ni saltar filas.
// Se leen por `fn`, que devuelve la vista tal cual con un plan que no se cae
// por RLS (sql/fase2_inversion.sql); leída directo, la vista pasa los 8 s.
const PESTANAS = {
  total: {
    titulo: 'Total', vista: 'v_inversion_total', fn: 'fn_inversion_total',
    columnas: ['site', 'bu', 'proveedor', 'tipo_costo', 'formato', 'valor_total', 'id', 'id_ejecucion',
      'campana', 'sub_campana', 'fecha_inicio', 'fecha_fin', 'dias', 'pct_participacion',
      'costo_proyectado', 'costo_ejecutado', 'mes_compra', 'moneda'],
    orden: ['site', 'id_ejecucion'],
  },
  semanal: {
    titulo: 'Semanal', vista: 'v_inversion_semanal', fn: 'fn_inversion_semanal',
    columnas: ['site', 'bu', 'year', 'month', 'week', 'proveedor', 'tipo_costo', 'formato', 'valor_total',
      'id', 'id_ejecucion', 'campana', 'sub_campana', 'fecha_inicio', 'fecha_fin', 'dias',
      'costo_proyectado', 'costo_ejecutado', 'mes_compra', 'moneda'],
    orden: ['site', 'id_ejecucion', 'year', 'month', 'week'],
  },
  diaria: {
    titulo: 'Diaria', vista: 'v_inversion_diaria', fn: 'fn_inversion_diaria',
    columnas: ['site', 'bu', 'year', 'month', 'week', 'date', 'proveedor', 'tipo_costo', 'formato',
      'valor_total', 'id', 'id_ejecucion', 'campana', 'sub_campana', 'pct_participacion',
      'costo_proyectado', 'estado', 'costo_ejecutado', 'mes_compra', 'moneda'],
    orden: ['site', 'id_ejecucion', 'date'],
  },
};

const POR_PAGINA = 200;
const TOP_GRAFICO = 8;          // barras por gráfico; el resto va a "Otros"

const SIN_SUB_INV = '__sin__';  // opción "Sin sub campaña" del filtro
const pad2 = (n) => String(n).padStart(2, '0');

// Dos lecturas del mismo dinero (CLAUDE.md, «Mes de ejecución y mes de compra»):
//   ejecucion  el mes del día en que corre el material (month): el reparto de OASIS.
//   compra     el mes en que empieza la compra (mes_compra): como el Flow y la facturación.
const VER_POR = { ejecucion: 'Mes de ejecución', compra: 'Mes de compra' };
const mesEjecucion = (r) => `${r.year}-${pad2(r.month)}`;
const mesCompra = (r) => (r.mes_compra || '').slice(0, 7);

// Semanal por mes de compra: la vista parte en dos la semana que cruza de mes
// (agrupa por month). Con mes de compra ese corte no aplica: se juntan.
function semanalPorCompra(filas) {
  const g = new Map();
  for (const r of filas) {
    const k = `${r.site}|${r.id_ejecucion}|${r.year}|${r.week}`;
    const a = g.get(k);
    if (!a) { g.set(k, { ...r }); continue; }
    if (r.fecha_inicio < a.fecha_inicio) a.fecha_inicio = r.fecha_inicio;
    if (r.fecha_fin > a.fecha_fin) a.fecha_fin = r.fecha_fin;
    a.dias = Number(a.dias) + Number(r.dias);
    a.costo_proyectado = Number(a.costo_proyectado) + Number(r.costo_proyectado);
    a.costo_ejecutado = Number(a.costo_ejecutado) + Number(r.costo_ejecutado);
  }
  return Object.freeze([...g.values()]);
}

// Un mercado a la vez, siempre: cada cifra va en su moneda y nunca se suman
// mercados (pesos colombianos y chilenos no se suman). Por eso no hay «Todos»
// y la pantalla pide a la base solo el mercado elegido.

// Como traerTodo, pero pide las páginas en paralelo: la diaria pasa de 10.000 filas.
async function traerTodoParalelo(consulta) {
  const { count, error } = await consulta({ count: 'exact', head: true });
  if (error) throw error;
  const paginas = await Promise.all(
    Array.from({ length: Math.ceil(count / 1000) }, (_, i) =>
      consulta().range(i * 1000, i * 1000 + 999).then(({ data, error: e }) => { if (e) throw e; return data; })));
  return paginas.flat();
}

async function iniciar() {
  const usuario = await requerirAcceso();
  pintarBarra(document.getElementById('barra'), usuario, 'inversion');

  createApp({
    components: { SeleccionMultiple },

    data: () => ({
      PESTANAS,
      COLUMNAS_INV,
      usuario,
      errorCarga: '',
      mercados: [],
      misMercadoIds: [],
      // Por pestaña: filas (congeladas: Vue no las vuelve reactivas), cargando, error.
      datos: {
        total:   { filas: [], cargando: true, error: '' },
        semanal: { filas: [], cargando: true, error: '' },
        diaria:  { filas: [], cargando: true, error: '' },
      },
      pestana: 'total',
      VER_POR,
      // Siempre arranca en mes de ejecución, la lectura principal; no se recuerda la
      // elección. Mes de compra es para conciliar con el Flow o la facturación.
      verPor: 'ejecucion',                      // 'ejecucion' | 'compra'
      pagina: 0,
      filtros: { mercado: '', meses: [], proveedores: [], tiposCosto: [], subCampanas: [], campanas: [] },
      corte: { valor: null, cargado: false },   // configuracion.fecha_corte; null = hoy
      editorCorte: null,                        // { fecha, paso, nuevo, guardando, error }
      verTablasGraficos: false,                 // los gráficos como tabla (mismos datos)
      globo: null,                              // ayuda flotante de los gráficos
    }),

    computed: {
      esAdmin() { return this.usuario.rol === 'ADMIN'; },
      misMercados() { return this.mercados.filter(m => this.misMercadoIds.includes(m.id)); },
      mercadosPorId() { return new Map(this.mercados.map(m => [m.id, m])); },
      codigoFiltro() { const m = this.mercadosPorId.get(this.filtros.mercado); return m ? m.codigo : ''; },
      moneda() { const m = this.mercadosPorId.get(this.filtros.mercado); return m ? m.moneda : ''; },
      formatoMoneda() { return fmtMoneda(this.moneda); },

      eyebrow() {
        const m = this.mercadosPorId.get(this.filtros.mercado);
        return m ? `${m.codigo} · ${m.nombre} · cifras en ${m.moneda}` : '';
      },

      actual() {
        const d = this.datos[this.pestana];
        if (this.pestana === 'semanal' && this.verPor === 'compra') return { ...d, filas: this.semanalCompra };
        return d;
      },
      semanalCompra() { return semanalPorCompra(this.datos.semanal.filas); },
      // Semanal por mes de compra ya no se parte por mes de ejecución: sin columna Mes.
      columnas() {
        const c = PESTANAS[this.pestana].columnas;
        return this.pestana === 'semanal' && this.verPor === 'compra' ? c.filter(x => x !== 'month') : c;
      },
      claveMes() { return this.verPor === 'compra' ? mesCompra : mesEjecucion; },

      // ---- filtros: opciones sacadas de la vista total (tiene todos los materiales fechados)
      filasDelMercado() {
        const k = this.codigoFiltro;
        return k ? this.datos.total.filas.filter(f => f.site === k) : this.datos.total.filas;
      },
      opcionesMes() {
        const s = new Set();
        const k = this.codigoFiltro;
        for (const f of this.datos.semanal.filas) if (!k || f.site === k) s.add(this.claveMes(f));
        s.delete('');
        return [...s].sort().map(m => {
          const [y, mm] = m.split('-');
          return { valor: m, etiqueta: `${MESES[Number(mm) - 1]} ${y}` };
        });
      },
      opcionesProveedor() { return this.unicos('proveedor'); },
      opcionesTipoCosto() { return ENUMS.tipo_costo.map(t => ({ valor: t, etiqueta: t })); },
      opcionesSubCampana() {
        return [{ valor: SIN_SUB_INV, etiqueta: 'Sin sub campaña' }, ...this.unicos('sub_campana')];
      },
      // Campaña de la compra; las de parque fijo (OTH-PF: PARQUE-FIJO, ALTO-IMPACTO,
      // PLANTA-FIJA…) son una sola opción, «PARQUE FIJO».
      opcionesCampana() { return this.unicos('campana_grupo'); },

      filtradas() { return this.filtrar(this.actual.filas, this.pestana === 'total'); },

      // Gráficos: siempre desde la diaria filtrada, que reparte por día y por eso
      // da el mes exacto, esté en la pestaña que esté la tabla.
      graficos() {
        const filas = this.filtrar(this.datos.diaria.filas, false);
        const agrupar = (clave, etiqueta) => {
          const m = new Map();
          for (const r of filas) {
            const k = clave(r);
            let g = m.get(k);
            if (!g) m.set(k, g = { clave: k, etiqueta: etiqueta(k), proy: 0, ejec: 0 });
            g.proy += Number(r.costo_proyectado) || 0;
            g.ejec += Number(r.costo_ejecutado) || 0;
          }
          return [...m.values()];
        };
        const principales = (lista) => {
          lista.sort((a, b) => b.proy - a.proy);
          if (lista.length <= TOP_GRAFICO + 1) return lista;
          const resto = lista.slice(TOP_GRAFICO);
          return [...lista.slice(0, TOP_GRAFICO), {
            clave: '__otros', etiqueta: `Otros (${resto.length})`, otros: true,
            proy: resto.reduce((x, g) => x + g.proy, 0), ejec: resto.reduce((x, g) => x + g.ejec, 0),
          }];
        };
        const meses = agrupar(this.claveMes, k => k).filter(g => g.clave).sort((a, b) => a.clave.localeCompare(b.clave));
        meses.forEach((g, i) => {
          const [y, m] = g.clave.split('-');
          g.mes = MESES[Number(m) - 1];
          g.anio = i === 0 || meses[i - 1].clave.slice(0, 4) !== y ? y : '';
          g.etiqueta = `${g.mes} ${y}`;
        });
        const total = meses.reduce((x, g) => x + g.proy, 0);
        const conEscala = (lista) => {
          const max = Math.max(0, ...lista.map(g => g.proy)) || 1;
          for (const g of lista) {
            g.fraccion = g.proy / max;                                   // alto o largo de la barra
            g.pctEjecDeBarra = g.proy ? (g.ejec / g.proy) * 100 : 0;      // dentro de la barra
            g.pctEjec = (g.ejec / max) * 100;
            g.pctPend = ((g.proy - g.ejec) / max) * 100;
            g.pctTotal = total ? (g.proy / total) * 100 : 0;
          }
          return lista;
        };
        return {
          vacio: !filas.length,
          meses: conEscala(meses),
          subs: conEscala(principales(agrupar(r => r.sub_campana || '', k => k || 'Sin sub campaña'))),
          provs: conEscala(principales(agrupar(r => r.proveedor || '', k => k || 'Sin proveedor'))),
        };
      },

      // Sobre todo lo filtrado, no sobre la página.
      sumas() {
        let proyectado = 0, ejecutado = 0;
        for (const r of this.filtradas) {
          proyectado += Number(r.costo_proyectado) || 0;
          ejecutado += Number(r.costo_ejecutado) || 0;
        }
        return { proyectado, ejecutado, porEjecutar: proyectado - ejecutado };
      },

      paginas() { return Math.max(1, Math.ceil(this.filtradas.length / POR_PAGINA)); },
      pagina_() { return Math.min(this.pagina, this.paginas - 1); },
      enPagina() { return this.filtradas.slice(this.pagina_ * POR_PAGINA, (this.pagina_ + 1) * POR_PAGINA); },
      rango() {
        const n = this.filtradas.length;
        if (!n) return '0 filas';
        const desde = this.pagina_ * POR_PAGINA + 1;
        return `Filas ${fmt.format(desde)}–${fmt.format(Math.min(n, desde + POR_PAGINA - 1))} de ${fmt.format(n)}`;
      },

      // Columnas antes del primer monto sumado: ahí va la palabra "Total".
      colsAntesDeSuma() { return this.columnas.indexOf('costo_proyectado'); },

      corteTexto() { return fechaHumana(this.corte.valor || hoyIso()); },
    },

    watch: {
      'filtros.mercado'(id, antes) {
        guardarMercadoActivo(id ? this.mercadosPorId.get(id).codigo : '');
        if (id && id !== antes) this.cargarVistas();
        this.filtros.campanas = [];
        const validos = new Set(this.opcionesProveedor.map(o => o.valor));
        this.filtros.proveedores = this.filtros.proveedores.filter(v => validos.has(v));
        const subs = new Set(this.opcionesSubCampana.map(o => o.valor));
        this.filtros.subCampanas = this.filtros.subCampanas.filter(v => subs.has(v));
        const meses = new Set(this.opcionesMes.map(o => o.valor));
        this.filtros.meses = this.filtros.meses.filter(v => meses.has(v));
      },
      filtros: { deep: true, handler() { this.pagina = 0; } },
      pestana() { this.pagina = 0; },
      verPor() {
        this.pagina = 0;
        const meses = new Set(this.opcionesMes.map(o => o.valor));
        this.filtros.meses = this.filtros.meses.filter(v => meses.has(v));
      },
    },

    methods: {
      filtrar(filas, esTotal) {
        const f = this.filtros;
        const k = this.codigoFiltro;
        const prov = new Set(f.proveedores);
        const tipos = new Set(f.tiposCosto);
        const subs = new Set(f.subCampanas);
        const camps = new Set(f.campanas);
        const meses = f.meses;
        return filas.filter(r => {
          if (k && r.site !== k) return false;
          if (prov.size && !prov.has(r.proveedor)) return false;
          if (tipos.size && !tipos.has(r.tipo_costo)) return false;
          if (subs.size && !subs.has(r.sub_campana || SIN_SUB_INV)) return false;
          if (camps.size && !camps.has(r.campana_grupo)) return false;
          if (meses.length) {
            // Por mes de compra el filtro es exacto en todas las pestañas: cada fila
            // tiene un solo mes de compra. Por mes de ejecución, Total no tiene mes:
            // entra el material que corre en alguno de esos meses.
            if (this.verPor === 'compra') {
              if (!meses.includes(mesCompra(r))) return false;
            } else if (esTotal) {
              if (!meses.some(m => r.fecha_inicio <= `${m}-31` && r.fecha_fin >= `${m}-01`)) return false;
            } else if (!meses.includes(mesEjecucion(r))) return false;
          }
          return true;
        });
      },

      unicos(campo) {
        const s = new Set();
        for (const f of this.filasDelMercado) if (f[campo]) s.add(f[campo]);
        return [...s].sort((a, b) => a.localeCompare(b, 'es')).map(v => ({ valor: v, etiqueta: v }));
      },

      tipo(col) { return COLUMNAS_INV[col][1]; },
      esNum(col) { return ['ent', 'pesos', 'pct', 'fecha', 'mes', 'cod'].includes(this.tipo(col)); },
      celda(r, col) {
        const v = r[col];
        if (v === null || v === undefined) return '';
        switch (this.tipo(col)) {
          case 'pesos': return this.formatoMoneda.format(Number(v));
          case 'pct':   return (Number(v) * 100).toLocaleString('es-CO', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' %';
          case 'fecha': { const [y, m, d] = v.split('-'); return `${d}/${m}/${y}`; }
          case 'mes':   { const [y, m] = v.split('-'); return `${MESES[Number(m) - 1]} ${y}`; }
          default:      return v;
        }
      },
      pesos(x) { return this.formatoMoneda.format(x); },
      pesosCortos(x) { return montoCorto(x); },
      pct(x) { return x.toLocaleString('es-CO', { maximumFractionDigits: 1 }) + ' %'; },

      // Ayuda flotante de una barra: el valor exacto de lo que la etiqueta abrevia.
      mostrarGlobo(ev, g) {
        const caja = ev.currentTarget.getBoundingClientRect();
        this.globo = {
          x: Math.min(caja.left, window.innerWidth - 280),
          y: caja.bottom + 6,
          titulo: g.etiqueta,
          filas: [
            { clase: 'proy', valor: this.pesos(g.proy), texto: `Proyectado · ${this.pct(g.pctTotal)} del total` },
            { clase: 'ejec', valor: this.pesos(g.ejec), texto: 'Ejecutado' },
            { clase: 'pend', valor: this.pesos(g.proy - g.ejec), texto: 'Por ejecutar' },
          ],
        };
      },
      ocultarGlobo() { this.globo = null; },
      fmtEntero(x) { return fmt.format(x); },
      fechaHumana,

      // Mismo formato que el CSV de Materiales. Montos sin separador de miles y con
      // coma decimal, para que Excel en español los sume; fechas en AAAA-MM-DD.
      exportarCsv() {
        const columnas = this.columnas.map(col => [COLUMNAS_INV[col][0], (r) => {
          const v = r[col];
          return typeof v === 'number' ? String(v).replace('.', ',') : v;
        }]);
        descargarCsv(`inversion_${this.pestana}_${this.codigoFiltro}_${hoyIso()}.csv`, columnas, this.filtradas);
      },

      // ---------------------------------------------------------------- Fecha de corte

      abrirCorte() {
        if (!this.esAdmin) return;
        this.editorCorte = { fecha: this.corte.valor || hoyIso(), paso: 'editar', nuevo: null, guardando: false, error: '' };
        nextTick(() => { const el = document.getElementById('corte-fecha'); if (el) el.focus(); });
      },
      cerrarCorte() { if (!this.editorCorte || !this.editorCorte.guardando) this.editorCorte = null; },
      // Primero se elige, después se confirma: cambia el ejecutado en todas partes.
      proponerCorte(nuevo) {
        const e = this.editorCorte;
        e.error = '';
        if (nuevo !== null && !/^\d{4}-\d{2}-\d{2}$/.test(nuevo || '')) { e.error = 'Elige una fecha'; return; }
        if (nuevo === this.corte.valor) { this.editorCorte = null; return; }
        e.nuevo = nuevo;
        e.paso = 'confirmar';
      },
      async guardarCorte() {
        const e = this.editorCorte;
        e.guardando = true;
        e.error = '';
        const { data, error } = await sb.from('configuracion')
          .update({ valor: e.nuevo }).eq('clave', 'fecha_corte').select('valor');
        if (error || !data.length) {
          console.error('No se guardó la fecha de corte', error);
          e.error = error ? (error.message || String(error)) : 'Sin permiso para cambiar la fecha de corte';
          e.guardando = false;
          return;
        }
        this.corte.valor = data[0].valor || null;
        this.editorCorte = null;
        this.cargarVistas();   // el costo ejecutado depende del corte
      },

      // ---------------------------------------------------------------- Carga

      // Solo el mercado elegido. Si el usuario cambia de mercado a mitad de una
      // carga, la respuesta vieja se descarta (turno).
      async cargarVista(clave) {
        const p = PESTANAS[clave];
        const d = this.datos[clave];
        const mercado = this.filtros.mercado;
        if (!mercado) return;
        const turno = d.turno = (d.turno || 0) + 1;
        d.cargando = true;
        d.error = '';
        try {
          const filas = await traerTodoParalelo((opciones) => {
            if (opciones) return sb.rpc(p.fn, {}, { get: true, ...opciones }).eq('mercado_id', mercado);
            let q = sb.rpc(p.fn, {}, { get: true }).select([...p.columnas, 'campana_grupo'].join(', ')).eq('mercado_id', mercado);
            for (const o of p.orden) q = q.order(o);
            return q;
          });
          if (turno !== d.turno) return;
          d.filas = Object.freeze(filas);
        } catch (e) {
          if (turno !== d.turno) return;
          console.error(e);
          d.error = `No se pudo cargar ${p.vista}: ${e.message || e}`;
        }
        d.cargando = false;
      },
      cargarVistas() { for (const clave of Object.keys(PESTANAS)) this.cargarVista(clave); },

      async cargar() {
        try {
          const [mercados, mis, propios, corte] = await Promise.all([
            traerTodo(() => sb.from('mercados').select('id, codigo, nombre, moneda').order('id')),
            sb.rpc('fn_mis_mercados'),
            traerTodo(() => sb.from('usuario_mercados').select('mercado_id').eq('usuario_id', this.usuario.id).order('mercado_id')),
            sb.from('configuracion').select('valor').eq('clave', 'fecha_corte').maybeSingle(),
          ]);
          if (mis.error) throw mis.error;
          if (corte.error) throw corte.error;
          this.mercados = mercados;
          this.misMercadoIds = (mis.data || []).map(x => (typeof x === 'object' ? Object.values(x)[0] : x)).map(Number);
          this.corte = { valor: (corte.data && corte.data.valor) || null, cargado: true };
          // Nunca «Todos»: sin mercado recordado, el propio o el primero.
          const inicial = mercadoInicial(this.misMercados, propios.map(p => p.mercado_id));
          this.filtros.mercado = inicial || (this.misMercados[0] || {}).id || '';
          if (!this.misMercados.length) {
            this.errorCarga = 'Tu usuario no tiene mercados asignados. Pide a un administrador que te los asigne.';
          }
        } catch (e) {
          console.error(e);
          this.errorCarga = 'No se pudo cargar la pantalla: ' + (e.message || e);
        }
      },
    },

    mounted() {
      this.cargar();
      document.addEventListener('keydown', (ev) => {
        if (ev.key === 'Escape' && this.editorCorte) this.cerrarCorte();
      });
    },
  }).mount('#app');
}

iniciar();
