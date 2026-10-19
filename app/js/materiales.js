// Pantalla de Materiales: una fila por material, equivale a la hoja Tracking del Sheets.
// Lo existente se edita en la tabla; lo nuevo se crea en el panel lateral, que
// también resuelve la partición cuando un material excede su compra (tramos.js).

const COLUMNAS_MATERIAL = [
  'id', 'compra_id', 'secuencia', 'sub_campana_id', 'referencia', 'enlace',
  'reporte_implementacion', 'fecha_inicio', 'fecha_fin', 'grupo_tramo',
].join(', ');

const COLUMNAS_COMPRA_M = [
  'id', 'mercado_id', 'codigo', 'proveedor_id', 'tipo_costo', 'formato',
  'ubicacion', 'ciudad', 'fecha_inicio', 'fecha_fin',
].join(', ');

// Lo que se edita en la fila. Las fechas se guardan juntas (la base exige el par).
const EDITABLES = ['sub_campana_id', 'referencia', 'enlace', 'reporte_implementacion', 'fecha_inicio', 'fecha_fin'];
const FECHAS = ['fecha_inicio', 'fecha_fin'];

const SIN_SUB = 0;  // opción "Sin sub campaña" del filtro
const DIAS_SEMANA = ['D', 'L', 'M', 'M', 'J', 'V', 'S'];

// ------------------------------------------------------------------ Filas

let contadorMateriales = 0;

const textoONulo = (s) => { const t = (s || '').trim(); return t === '' ? null : t; };

// Lo editable tal como va a la base: texto vacío = null.
function editables(r) {
  return {
    sub_campana_id:         r.sub_campana_id || null,
    referencia:             textoONulo(r.referencia),
    enlace:                 textoONulo(r.enlace),
    reporte_implementacion: textoONulo(r.reporte_implementacion),
    fecha_inicio:           r.fecha_inicio || null,
    fecha_fin:              r.fecha_fin || null,
  };
}

function desdeBaseMaterial(m, taxonomia) {
  const r = {
    _k: ++contadorMateriales,
    id: m.id,
    compra_id: m.compra_id,
    secuencia: m.secuencia,
    sub_campana_id: m.sub_campana_id,
    referencia: m.referencia || '',
    enlace: m.enlace || '',
    reporte_implementacion: m.reporte_implementacion || '',
    fecha_inicio: m.fecha_inicio,
    fecha_fin: m.fecha_fin,
    grupo_tramo: m.grupo_tramo,
    taxonomia: taxonomia || '',
    _guardando: false,
    _repetir: false,
    _estado: null,
  };
  r._orig = editables(r);   // último estado guardado
  return r;
}

function mensajeErrorMaterial(error) {
  if (!error) return 'Error desconocido';
  if (error.code === '42501') return 'Sin permiso para guardar en este mercado';
  if (error.code === '23505') return 'Otra persona creó un material en esa compra al mismo tiempo; intenta de nuevo';
  if (error.code === '23503') return error.message || 'La sub campaña no es de este mercado';
  if (error.code === '23514') return error.message || 'La base rechazó las fechas';
  return error.message || String(error);
}

// ------------------------------------------------------------------ App

async function iniciar() {
  const usuario = await requerirAcceso();
  pintarBarra(document.getElementById('barra'), usuario, 'materiales');

  createApp({
    components: { SeleccionMultiple, PanelEvidencias },

    data: () => ({
      ENUMS,
      catalogoCosto: [],       // tipos_costo, con sus mercados
      usuario,
      cargando: true,
      errorCarga: '',
      avisoPedido: '',
      mercados: [],
      misMercadoIds: [],
      proveedores: [],
      subCampanas: [],
      compras: [],
      filas: [],
      filtros: { mercado: '', meses: [], proveedores: [], subCampanas: [], tiposCosto: [], buscar: '' },
      vista: 'tabla',          // 'tabla' | 'calendario'
      calMes: '',              // AAAA-MM del calendario
      costos: {},              // AAAA-MM -> { cargando, material: Map, compra: Map, error }
      genCostos: 0,            // sube al invalidar: descarta cargas que terminan tarde
      globo: null,             // ayuda flotante: { x, y, lineas, img }
      resaltada: null,         // fila que pidió Alertas (_k)
      borrador: null,          // material nuevo, o partición, en el panel lateral
      evidencias: [],          // de la tabla evidencias (las sube el proveedor)
      panelEv: null,           // { id, codigo, ubicacion } con el panel de evidencias abierto
    }),

    computed: {
      soloLectura() { return this.usuario.rol === 'LECTURA'; },

      misMercados() { return this.mercados.filter(m => this.misMercadoIds.includes(m.id)); },
      mercadosPorId() { return new Map(this.mercados.map(m => [m.id, m])); },
      proveedoresPorId() { return new Map(this.proveedores.map(p => [p.id, p])); },
      comprasPorId() { return new Map(this.compras.map(c => [c.id, c])); },
      subPorId() { return new Map(this.subCampanas.map(s => [s.id, s])); },
      evidenciasPorMaterial() {
        const m = new Map();
        for (const e of this.evidencias) {
          if (!m.has(e.material_id)) m.set(e.material_id, []);
          m.get(e.material_id).push(e);
        }
        return m;
      },

      eyebrow() {
        const m = this.mercadosPorId.get(this.filtros.mercado);
        return m ? `${m.codigo} · ${m.nombre}` : 'Todos mis mercados';
      },

      // ---- filtros
      meses() {
        const s = new Set();
        for (const r of this.filas) {
          if (!r.fecha_inicio || !r.fecha_fin || r.fecha_fin < r.fecha_inicio) continue;
          let [y, m] = r.fecha_inicio.slice(0, 7).split('-').map(Number);
          const fin = r.fecha_fin.slice(0, 7);
          for (let i = 0; i < 60; i++) {
            const k = `${y}-${String(m).padStart(2, '0')}`;
            s.add(k);
            if (k >= fin) break;
            m++; if (m > 12) { m = 1; y++; }
          }
        }
        return [...s].sort();
      },
      opcionesMes() { return this.meses.map(m => ({ valor: m, etiqueta: this.nombreMes(m) })); },
      opcionesTipoCosto() {
        const m = this.mercadosPorId.get(this.filtros.mercado);
        return tiposCostoPara(this.catalogoCosto, m && m.codigo).map(t => ({ valor: t, etiqueta: t }));
      },
      opcionesProveedor() {
        const lista = this.filtros.mercado
          ? this.proveedores.filter(p => p.mercado_id === this.filtros.mercado)
          : this.proveedores.filter(p => this.misMercadoIds.includes(p.mercado_id));
        return lista.map(p => ({
          valor: p.id,
          etiqueta: this.filtros.mercado ? p.nombre : `${p.nombre} (${this.codigoMercado(p.mercado_id)})`,
        }));
      },
      opcionesSubCampana() {
        const lista = this.filtros.mercado
          ? this.subCampanas.filter(s => s.mercado_id === this.filtros.mercado)
          : this.subCampanas.filter(s => this.misMercadoIds.includes(s.mercado_id));
        return [
          { valor: SIN_SUB, etiqueta: 'Sin sub campaña' },
          ...lista.map(s => ({ valor: s.id, etiqueta: this.filtros.mercado ? s.nombre_unico : `${s.nombre_unico} (${s.mercado})` })),
        ];
      },

      visibles() {
        const f = this.filtros;
        const prov = new Set(f.proveedores);
        const subs = new Set(f.subCampanas);
        const tipos = new Set(f.tiposCosto);
        const q = normTexto(f.buscar);
        return this.filas.filter(r => {
          const c = this.comprasPorId.get(r.compra_id);
          if (!c) return false;
          if (f.mercado && c.mercado_id !== f.mercado) return false;
          if (prov.size && !prov.has(c.proveedor_id)) return false;
          if (tipos.size && !tipos.has(c.tipo_costo)) return false;
          if (subs.size && !subs.has(r.sub_campana_id || SIN_SUB)) return false;
          if (f.meses.length) {
            if (!r.fecha_inicio || !r.fecha_fin) return false;
            if (!f.meses.some(m => r.fecha_inicio <= `${m}-31` && r.fecha_fin >= `${m}-01`)) return false;
          }
          if (q && !c.codigo.includes(q) && !normTexto(c.ubicacion).includes(q)
              && !this.codigoMaterial(r).includes(q)) return false;
          return true;
        });
      },

      kpis() {
        let sinFechas = 0, sinSub = 0, fuera = 0;
        for (const r of this.visibles) {
          if (!r._orig.fecha_inicio) sinFechas++;
          if (!r._orig.sub_campana_id) sinSub++;
          if (this.errores.get(r._k)._fuera) fuera++;
        }
        return { total: this.visibles.length, sinFechas, sinSub, fuera };
      },

      errores() {
        const m = new Map();
        for (const r of this.filas) m.set(r._k, this.validarFila(r));
        return m;
      },

      // Materiales de cada grupo de tramos, para señalarlos en la tabla.
      tramosPorGrupo() {
        const g = new Map();
        for (const r of this.filas) {
          if (!r.grupo_tramo) continue;
          if (!g.has(r.grupo_tramo)) g.set(r.grupo_tramo, []);
          g.get(r.grupo_tramo).push(r);
        }
        return g;
      },

      estadoGlobal() {
        if (this.cargando) return { clase: '', texto: '' };
        const guardando = this.filas.filter(r => r._guardando).length;
        const pendientes = this.filas.filter(r => r._estado && ['err', 'prop'].includes(r._estado.clase) && !r._guardando).length;
        if (guardando) return { clase: 'prop', texto: 'Guardando…' };
        if (pendientes) return { clase: 'err', texto: `${pendientes} ${pendientes === 1 ? 'fila sin guardar' : 'filas sin guardar'}` };
        if (this.soloLectura) return { clase: '', texto: 'Solo lectura' };
        return { clase: 'ok', texto: 'Todo guardado' };
      },

      // ---- calendario
      calDias() {
        if (!this.calMes) return [];
        const [y, m] = this.calMes.split('-').map(Number);
        const n = new Date(Date.UTC(y, m, 0)).getUTCDate();
        return Array.from({ length: n }, (_, i) => {
          const iso = `${this.calMes}-${String(i + 1).padStart(2, '0')}`;
          const dow = new Date(`${iso}T00:00:00Z`).getUTCDay();
          return { iso, d: i + 1, dow: DIAS_SEMANA[dow], finde: dow === 0 || dow === 6 };
        });
      },
      // Materiales activos por compra y día del mes, contando todos los de la
      // compra (no solo los visibles): el rayado es una propiedad de la compra.
      activosCompraDia() {
        const cuenta = new Map();
        const dias = this.calDias;
        if (!dias.length) return cuenta;
        const ini = dias[0].iso, fin = dias[dias.length - 1].iso;
        for (const r of this.filas) {
          const o = r._orig;
          if (!o.fecha_inicio || o.fecha_fin < ini || o.fecha_inicio > fin) continue;
          for (const d of dias) {
            if (d.iso < o.fecha_inicio || d.iso > o.fecha_fin) continue;
            const k = `${r.compra_id}|${d.iso}`;
            cuenta.set(k, (cuenta.get(k) || 0) + 1);
          }
        }
        return cuenta;
      },
      // Una fila por material visible que corre en el mes; cada día con su clase.
      calFilas() {
        const dias = this.calDias;
        if (!dias.length) return [];
        const ini = dias[0].iso, fin = dias[dias.length - 1].iso;
        return this.visibles
          .filter(r => r._orig.fecha_inicio && r._orig.fecha_inicio <= fin && r._orig.fecha_fin >= ini)
          .map(r => ({
            r,
            celdas: dias.map(d => {
              const activo = d.iso >= r._orig.fecha_inicio && d.iso <= r._orig.fecha_fin;
              const compartido = activo && (this.activosCompraDia.get(`${r.compra_id}|${d.iso}`) || 0) > 1;
              return [d.finde ? 'finde' : '', activo ? (compartido ? 'compartido' : 'activo') : ''].join(' ');
            }),
          }));
      },
      costosMes() { return this.costos[this.calMes] || null; },

      // ---- panel lateral
      compraBorrador() { return this.borrador ? this.comprasPorId.get(this.borrador.compra_id) || null : null; },
      resultadosCompra() {
        const b = this.borrador;
        if (!b || b.compra_id) return [];
        const q = normTexto(b.busqueda);
        const mercados = new Set(this.filtros.mercado ? [this.filtros.mercado] : this.misMercadoIds);
        const lista = this.compras.filter(c => mercados.has(c.mercado_id)
          && (!q || c.codigo.includes(q) || normTexto(c.ubicacion).includes(q)));
        lista.sort((a, b2) => (a.codigo === q ? -1 : b2.codigo === q ? 1 : 0)
          || (b2.fecha_inicio || '').localeCompare(a.fecha_inicio || '') || b2.codigo.localeCompare(a.codigo));
        return lista.slice(0, 40);
      },
      erroresBorrador() {
        const b = this.borrador;
        if (!b) return {};
        const c = this.compraBorrador;
        const e = {};
        if (!c) e.compra_id = 'Elige la compra';
        if (!b.sub_campana_id) e.sub_campana_id = 'Obligatoria';
        else if (c && !this.subValida(c.mercado_id, b.sub_campana_id)) e.sub_campana_id = 'No es del glosario de este mercado';
        Object.assign(e, erroresFechas(b.fecha_inicio, b.fecha_fin, c, true));
        return e;
      },
      // Cómo quedaría guardado: dentro de la compra, partido o bloqueado.
      planBorrador() {
        const b = this.borrador, c = this.compraBorrador;
        if (!b || !c) return null;
        const plan = planTramos(c, b.fecha_inicio, b.fecha_fin, this.compras);
        if (!plan || !plan.tramos) return plan;
        // Letra de cada tramo: el material que se parte conserva la suya.
        for (const t of plan.tramos) {
          t.codigo = b.material_id && t.compra.id === c.id
            ? b.material_codigo
            : `${t.compra.codigo}-${letra(this.siguienteSecuencia(t.compra.id))}`;
        }
        return plan;
      },
      mensajePlan() {
        const p = this.planBorrador, c = this.compraBorrador, b = this.borrador;
        if (!p || !c) return null;
        if (p.tipo === 'particion') return { clase: 'aviso', texto: mensajeParticion(c, p.tramos, b.material_id ? b.material_codigo : null) };
        if (p.tipo === 'sin_compra') return { clase: 'error', texto: mensajeSinCompra(c, this.nombreProveedor(c.proveedor_id), p.hueco), compras: true };
        if (p.tipo === 'sin_cruce') return { clase: 'error', texto: `El material no se cruza con la compra ${c.codigo}. Elige la compra que cubre esas fechas.` };
        return null;
      },
      particionOk() { return !!this.planBorrador && this.planBorrador.tipo === 'particion'; },
      // Se puede guardar si no hay errores, o si el único es "fuera de la compra" y hay partición.
      bloqueoBorrador() {
        const e = { ...this.erroresBorrador };
        const p = this.planBorrador;
        if (e._fuera && p && p.tipo === 'particion') { delete e.fecha_inicio; delete e.fecha_fin; }
        delete e._fuera;
        return Object.keys(e).length > 0;
      },
      textoGuardar() {
        const b = this.borrador, p = this.planBorrador;
        if (!b) return '';
        if (b._guardando) return 'Guardando…';
        if (p && p.tipo === 'particion') {
          const nuevos = p.tramos.length - (b.material_id ? 1 : 0);
          return `Confirmar: ${b.material_id ? 'partir y crear' : 'crear'} ${nuevos} ${nuevos === 1 ? 'material' : 'materiales'}`;
        }
        return b.material_id ? 'Guardar material' : 'Crear material';
      },
      codigoPrevisto() {
        const b = this.borrador, c = this.compraBorrador;
        if (!b || !c) return '';
        if (b.material_id) return b.material_codigo;
        return `${c.codigo}-${letra(this.siguienteSecuencia(c.id))}`;
      },
      miniaturaBorrador() { return this.borrador ? miniatura(this.borrador.enlace) : null; },
    },

    watch: {
      'filtros.mercado'(id) {
        guardarMercadoActivo(id ? this.codigoMercado(id) : '');
        const validos = new Set(this.opcionesProveedor.map(o => o.valor));
        this.filtros.proveedores = this.filtros.proveedores.filter(id => validos.has(id));
        const subs = new Set(this.opcionesSubCampana.map(o => o.valor));
        this.filtros.subCampanas = this.filtros.subCampanas.filter(id => subs.has(id));
      },
      'filtros.meses'(v) { if (v.length) this.calMes = v[0]; },
      calMes(m) { if (this.vista === 'calendario') this.cargarCostos(m); },
    },

    methods: {
      fmtEntero(x) { return fmt.format(x); },
      fmtMonto(x, mercadoId) {
        const m = this.mercadosPorId.get(mercadoId);
        return esNumero(x) ? fmtMoneda(m && m.moneda).format(x) : '—';
      },
      nombreMes(k) { const [y, m] = k.split('-'); return `${MESES[Number(m) - 1]} ${y}`; },
      fechaCorta(iso) { if (!iso) return ''; const [y, m, d] = iso.split('-'); return `${d}/${m}/${y}`; },
      periodoCompra(c) { return c && c.fecha_inicio ? `${this.fechaCorta(c.fecha_inicio)} – ${this.fechaCorta(c.fecha_fin)}` : 'sin periodo'; },
      codigoMercado(id) { const m = this.mercadosPorId.get(id); return m ? m.codigo : '?'; },
      nombreProveedor(id) { const p = this.proveedoresPorId.get(id); return p ? p.nombre : ''; },
      nombreSub(id) { const s = this.subPorId.get(id); return s ? s.nombre_unico : ''; },
      compraDe(r) { return this.comprasPorId.get(r.compra_id) || {}; },
      codigoMaterial(r) {
        const c = this.comprasPorId.get(r.compra_id);
        return c ? `${c.codigo}-${letra(r.secuencia)}` : '';
      },
      miniatura,
      cuentaEvidencias(r) { return (this.evidenciasPorMaterial.get(r.id) || []).length; },
      abrirEvidencias(r) { this.panelEv = { id: r.id, codigo: this.codigoMaterial(r), ubicacion: this.compraDe(r).ubicacion }; },

      subCampanasDe(mercadoId, actual) {
        return this.subCampanas.filter(s => s.mercado_id === mercadoId && (s.activo || s.id === actual));
      },
      subValida(mercadoId, id) {
        const s = this.subPorId.get(id);
        return !!s && s.mercado_id === mercadoId;
      },

      siguienteSecuencia(compraId) {
        let max = 0;
        for (const r of this.filas) if (r.compra_id === compraId && r.secuencia > max) max = r.secuencia;
        return max + 1;
      },

      validarFila(r) {
        const c = this.comprasPorId.get(r.compra_id);
        const e = erroresFechas(r.fecha_inicio, r.fecha_fin, c, false);
        if (r.sub_campana_id && c && !this.subValida(c.mercado_id, r.sub_campana_id)) {
          e.sub_campana_id = 'No es del glosario de este mercado';
        }
        return e;
      },
      msgErr(r, campo) { return this.errores.get(r._k)[campo] || ''; },
      claseErr(r, campo) { return this.msgErr(r, campo) ? 'err' : ''; },
      fuera(r) { return !!this.errores.get(r._k)._fuera; },

      // Señal de tramo: los otros materiales de la misma campaña partida.
      tramosDe(r) {
        if (!r.grupo_tramo) return '';
        const g = (this.tramosPorGrupo.get(r.grupo_tramo) || [])
          .slice().sort((a, b) => (a._orig.fecha_inicio || '').localeCompare(b._orig.fecha_inicio || ''));
        return `Campaña partida en ${g.length} tramos: ${g.map(x => this.codigoMaterial(x)).join(', ')}`;
      },

      // ---------------------------------------------------------------- Edición en tabla

      cambios(r) {
        const actual = editables(r);
        const c = {};
        for (const k of EDITABLES) if (actual[k] !== r._orig[k]) c[k] = actual[k];
        // Las fechas van siempre juntas.
        if (FECHAS.some(k => k in c)) for (const k of FECHAS) c[k] = actual[k];
        return c;
      },

      alSalirDeCelda(ev) {
        if (this.soloLectura) return;
        const tr = ev.target.closest('tr[data-k]');
        if (!tr) return;
        // De fecha inicio a fecha fin de la misma fila aún no se guarda: se valida el par.
        const destino = ev.relatedTarget;
        if (destino && tr.contains(destino) && ev.target.type === 'date' && destino.type === 'date') return;
        const r = this.filas.find(x => x._k === Number(tr.dataset.k));
        if (r) this.guardar(r);
      },

      async guardar(r) {
        if (this.soloLectura) return;
        const cambios = this.cambios(r);
        if (!Object.keys(cambios).length) {
          if (r._estado && r._estado.clase !== 'ok') r._estado = null;
          return;
        }

        // Bloquea lo que se cambió y está mal. Un error heredado del Sheets (ej.
        // fechas fuera de la compra) no impide corregir la referencia.
        const errs = this.errores.get(r._k);
        const malos = Object.keys(errs).filter(k => k !== '_fuera' && k in cambios);
        if (malos.length) {
          r._estado = errs._fuera && malos.some(k => FECHAS.includes(k))
            ? { clase: 'err', texto: 'fuera de la compra', detalle: errs.fecha_fin || errs.fecha_inicio }
            : { clase: 'err', texto: malos.length === 1 ? '1 error' : `${malos.length} errores`, detalle: malos.map(k => errs[k]).join(' · ') };
          return;
        }
        if (r._guardando) { r._repetir = true; return; }

        r._guardando = true;
        r._estado = { clase: 'prop', texto: 'guardando…' };
        let error = null;
        try {
          const res = await sb.from('materiales')
            .update({ ...cambios, actualizado_en: new Date().toISOString() })
            .eq('id', r.id)
            .select('id');
          error = res.error;
          if (!error && res.data.length === 0) error = { code: '42501' };
        } catch (e) {
          error = e;
        }

        r._guardando = false;
        if (error) {
          r._estado = { clase: 'err', texto: 'error', detalle: mensajeErrorMaterial(error) };
          console.error('No se guardó el material', this.codigoMaterial(r), error);
        } else {
          r._orig = { ...r._orig, ...cambios };
          const estado = { clase: 'ok', texto: 'guardado' };
          r._estado = estado;
          setTimeout(() => { if (r._estado === estado) r._estado = null; }, 2500);
          if ('sub_campana_id' in cambios || 'referencia' in cambios) this.refrescarTaxonomia([r.id]);
          if (FECHAS.some(k => k in cambios)) this.invalidarCostos();
        }
        if (r._repetir) { r._repetir = false; this.guardar(r); }
      },

      deshacer(r) {
        Object.assign(r, {
          sub_campana_id: r._orig.sub_campana_id,
          referencia: r._orig.referencia || '',
          enlace: r._orig.enlace || '',
          reporte_implementacion: r._orig.reporte_implementacion || '',
          fecha_inicio: r._orig.fecha_inicio,
          fecha_fin: r._orig.fecha_fin,
        });
        r._estado = null;
      },
      tieneCambios(r) { return Object.keys(this.cambios(r)).length > 0; },

      async refrescarTaxonomia(ids) {
        const { data, error } = await sb.from('v_materiales').select('material_id, taxonomia').in('material_id', ids);
        if (error) { console.error(error); return; }
        for (const t of data) {
          const r = this.filas.find(x => x.id === t.material_id);
          if (r) r.taxonomia = t.taxonomia;
        }
      },

      // ---------------------------------------------------------------- Exportar

      // Filas filtradas con las columnas de la tabla, tal como están guardadas en
      // la base (una edición sin guardar no sale). La imagen sale de su enlace.
      exportarCsv() {
        const columnas = [
          ['Mercado', (r, c) => this.codigoMercado(c.mercado_id)],
          ['Código', (r) => this.codigoMaterial(r)],
          ['Compra', (r, c) => c.codigo],
          ['Ubicación', (r, c) => c.ubicacion],
          ['Proveedor', (r, c) => this.nombreProveedor(c.proveedor_id)],
          ['Formato', (r, c) => c.formato],
          ['Ciudad', (r, c) => c.ciudad],
          ['Tipo de costo', (r, c) => c.tipo_costo],
          ['Sub campaña', (r) => this.nombreSub(r._orig.sub_campana_id)],
          ['Referencia', (r) => r._orig.referencia],
          ['Enlace', (r) => r._orig.enlace],
          ['Reporte de implementación', (r) => r._orig.reporte_implementacion],
          ['Evidencias', (r) => this.cuentaEvidencias(r)],
          ['Fecha inicio', (r) => r._orig.fecha_inicio],
          ['Fecha fin', (r) => r._orig.fecha_fin],
          ['Taxonomía', (r) => r.taxonomia],
        ];
        const m = this.mercadosPorId.get(this.filtros.mercado);
        descargarCsv(`materiales_${m ? m.codigo : 'todos'}_${hoyIso()}.csv`,
          columnas.map(([t, f]) => [t, (r) => f(r, this.compraDe(r))]), this.visibles);
      },

      // ---------------------------------------------------------------- Panel lateral

      async abrirPanel() {
        if (this.soloLectura || this.cargando) return;
        this.borrador = {
          modo: 'nuevo',
          material_id: null, material_codigo: '', fila_k: null,
          compra_id: null, busqueda: '', resaltado: 0,
          sub_campana_id: null, referencia: '', enlace: '', reporte_implementacion: '',
          fecha_inicio: null, fecha_fin: null,
          _tocados: {}, _intento: false, _guardando: false, _error: '',
        };
        await nextTick();
        const el = document.querySelector(`${PANEL_ACTIVO} #p-compra`);
        if (el) el.focus();
      },

      // "Partir →": el material con las fechas que se salen de su compra.
      async abrirPartir(r) {
        if (this.soloLectura) return;
        this.borrador = {
          modo: 'partir',
          material_id: r.id, material_codigo: this.codigoMaterial(r), fila_k: r._k,
          compra_id: r.compra_id, busqueda: '', resaltado: 0,
          sub_campana_id: r.sub_campana_id, referencia: r.referencia, enlace: r.enlace,
          reporte_implementacion: r.reporte_implementacion,
          fecha_inicio: r.fecha_inicio, fecha_fin: r.fecha_fin,
          _tocados: { fecha_inicio: true, fecha_fin: true }, _intento: false, _guardando: false, _error: '',
        };
        await nextTick();
        const el = document.querySelector(`${PANEL_ACTIVO} #p-fin`);
        if (el) el.focus();
      },

      cerrarPanel() {
        if (this.borrador && this.borrador._guardando) return;
        this.borrador = null;
      },

      tocar(campo) { if (this.borrador) this.borrador._tocados[campo] = true; },
      errPanel(campo) {
        const b = this.borrador;
        if (!b || !(b._intento || b._tocados[campo])) return '';
        return this.erroresBorrador[campo] || '';
      },

      elegirCompra(c) {
        const b = this.borrador;
        b.compra_id = c.id;
        b.busqueda = '';
        // La sub campaña tiene que ser del mercado de la compra.
        if (b.sub_campana_id && !this.subValida(c.mercado_id, b.sub_campana_id)) b.sub_campana_id = null;
        nextTick(() => {
          const el = document.querySelector(`${PANEL_ACTIVO} #p-sub`);
          if (el) el.focus();
        });
      },
      cambiarCompra() {
        this.borrador.compra_id = null;
        nextTick(() => {
          const el = document.querySelector(`${PANEL_ACTIVO} #p-compra`);
          if (el) el.focus();
        });
      },
      teclaBusqueda(ev) {
        const b = this.borrador, n = this.resultadosCompra.length;
        if (ev.key === 'ArrowDown') { b.resaltado = Math.min(b.resaltado + 1, n - 1); ev.preventDefault(); }
        else if (ev.key === 'ArrowUp') { b.resaltado = Math.max(b.resaltado - 1, 0); ev.preventDefault(); }
        else if (ev.key === 'Enter') {
          ev.preventDefault();
          if (this.resultadosCompra[b.resaltado]) this.elegirCompra(this.resultadosCompra[b.resaltado]);
        }
      },

      async guardarBorrador() {
        const b = this.borrador;
        if (!b || b._guardando) return;
        b._intento = true;
        b._error = '';
        if (this.bloqueoBorrador) {
          await nextTick();
          const primero = document.querySelector(
            ['.campo.err input', '.campo.err select'].map(x => `${PANEL_ACTIVO} ${x}`).join(', '));
          if (primero) primero.focus();
          return;
        }

        const c = this.compraBorrador;
        const plan = this.planBorrador;
        const tramos = plan && plan.tramos ? plan.tramos : [{ compra: c, fi: b.fecha_inicio, ff: b.fecha_fin }];

        b._guardando = true;
        try {
          const { data, error } = await sb.rpc('fn_guardar_tramos', {
            p_material_id: b.material_id,
            p_datos: {
              sub_campana_id: b.sub_campana_id,
              referencia: textoONulo(b.referencia),
              enlace: textoONulo(b.enlace),
              reporte_implementacion: textoONulo(b.reporte_implementacion),
            },
            p_tramos: tramos.map(t => ({ compra_id: t.compra.id, fecha_inicio: t.fi, fecha_fin: t.ff })),
          });
          if (error) throw error;

          const ids = data.map(m => m.id);
          const tax = await sb.from('v_materiales').select('material_id, taxonomia').in('material_id', ids);
          const taxPorId = new Map((tax.data || []).map(t => [t.material_id, t.taxonomia]));

          const nuevas = [];
          for (const m of data) {
            const r = desdeBaseMaterial(m, taxPorId.get(m.id));
            const i = this.filas.findIndex(x => x.id === m.id);
            if (i >= 0) { r._k = this.filas[i]._k; this.filas.splice(i, 1, r); }
            else this.filas.push(r);
            r._estado = { clase: 'ok', texto: i >= 0 ? 'partido' : 'creado' };
            nuevas.push(r._k);
          }
          this.ordenarFilas();
          this.invalidarCostos();
          this.borrador = null;

          await nextTick();
          const tr = document.querySelector(`#app tr[data-k="${nuevas[0]}"]`);
          if (tr) tr.scrollIntoView({ block: 'nearest' });
          setTimeout(() => {
            for (const r of this.filas) if (nuevas.includes(r._k) && r._estado && r._estado.clase === 'ok') r._estado = null;
          }, 4000);
        } catch (e) {
          console.error('No se guardó el material', e);
          b._error = 'No se pudo guardar: ' + mensajeErrorMaterial(e);
          b._guardando = false;
        }
      },

      // ---------------------------------------------------------------- Calendario

      verCalendario() {
        if (this.vista === 'calendario') { this.vista = 'tabla'; this.globo = null; return; }
        if (!this.calMes || !this.filtros.meses.length) {
          const hoy = new Date().toISOString().slice(0, 7);
          this.calMes = this.filtros.meses[0]
            || (this.meses.includes(hoy) ? hoy : this.meses[this.meses.length - 1] || hoy);
        }
        this.vista = 'calendario';
        this.cargarCostos(this.calMes);
      },
      moverMes(n) {
        let [y, m] = this.calMes.split('-').map(Number);
        m += n;
        if (m < 1) { m = 12; y--; }
        if (m > 12) { m = 1; y++; }
        this.calMes = `${y}-${String(m).padStart(2, '0')}`;
      },

      // El costo del día cambia cuando cambian las fechas de un material.
      invalidarCostos() {
        this.genCostos++;
        this.costos = {};
        if (this.vista === 'calendario') this.cargarCostos(this.calMes);
      },

      // Costo del día de cada material y de cada compra, desde v_inversion_diaria
      // (por fn_inversion_diaria: leída directo, con RLS pasa el límite de 8 s).
      async cargarCostos(mes) {
        if (!mes || this.costos[mes]) return;
        const gen = this.genCostos;
        const entrada = { cargando: true, material: new Map(), compra: new Map(), error: '' };
        this.costos = { ...this.costos, [mes]: entrada };
        const [y, m] = mes.split('-').map(Number);
        const fin = `${mes}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, '0')}`;
        try {
          const filas = await traerTodo(() => sb.rpc('fn_inversion_diaria', {}, { get: true })
            .select('site, id, id_ejecucion, date, costo_proyectado')
            .gte('date', `${mes}-01`).lte('date', fin)
            .order('site').order('id_ejecucion').order('date'));
          for (const f of filas) {
            const costo = Number(f.costo_proyectado);
            entrada.material.set(`${f.site}|${f.id_ejecucion}|${f.date}`, costo);
            const kc = `${f.site}|${f.id}|${f.date}`;
            entrada.compra.set(kc, (entrada.compra.get(kc) || 0) + costo);
          }
        } catch (e) {
          console.error(e);
          entrada.error = 'No se pudieron cargar los costos';
        }
        entrada.cargando = false;
        if (gen !== this.genCostos) return;
        this.costos = { ...this.costos, [mes]: { ...entrada } };
      },

      // ---------------------------------------------------------------- Ayuda flotante

      mostrarGlobo(ev) {
        const el = ev.target.closest('[data-dia], [data-img]');
        if (!el) { this.globo = null; return; }
        const caja = el.getBoundingClientRect();
        const pos = { x: Math.min(caja.left, window.innerWidth - 300), y: caja.bottom + 6 };
        if (el.dataset.img) { this.globo = { ...pos, img: el.dataset.img, lineas: [] }; return; }

        const r = this.filas.find(x => x._k === Number(el.closest('tr[data-k]').dataset.k));
        if (!r) return;
        const c = this.compraDe(r);
        const dia = el.dataset.dia;
        const mk = this.codigoMercado(c.mercado_id);
        const cod = this.codigoMaterial(r);
        const activo = dia >= r._orig.fecha_inicio && dia <= r._orig.fecha_fin;
        const n = this.activosCompraDia.get(`${r.compra_id}|${dia}`) || 0;
        const lineas = [
          `${cod} · ${fechaLarga(dia)}`,
          activo ? 'Material activo' : 'Material no activo este día',
          `${n} ${n === 1 ? 'material activo' : 'materiales activos'} en la compra ${c.codigo}`,
        ];
        const k = this.costosMes;
        if (!k || k.cargando) lineas.push('Cargando costo…');
        else if (k.error) lineas.push(k.error);
        else {
          const dc = k.compra.get(`${mk}|${c.codigo}|${dia}`);
          const dm = k.material.get(`${mk}|${cod}|${dia}`);
          lineas.push(`Costo del día · compra: ${this.fmtMonto(dc, c.mercado_id)}`);
          if (activo) lineas.push(`Costo del día · este material: ${this.fmtMonto(dm, c.mercado_id)}`);
        }
        this.globo = { ...pos, lineas };
      },
      ocultarGlobo() { this.globo = null; },

      // ---------------------------------------------------------------- Carga

      // Desde Alertas: la fila resaltada y en pantalla; si se sale de su compra,
      // con el panel de partición abierto (LECTURA solo la ve).
      async irAFilaPedida() {
        const p = filaPedida();
        if (!p.material) return;
        const r = this.filas.find(x => x.id === p.material);
        if (!r) { this.avisoPedido = 'Ese material ya no está o no es de tus mercados.'; return; }
        this.resaltada = r._k;
        await nextTick();
        const tr = document.querySelector(`#app tr[data-k="${r._k}"]`);
        if (tr) tr.scrollIntoView({ block: 'center' });
        if (p.partir && !this.soloLectura && this.fuera(r)) this.abrirPartir(r);
      },

      ordenarFilas() {
        const cmp = (a, b) => {
          const ca = this.compraDe(a), cb = this.compraDe(b);
          return (ca.mercado_id - cb.mercado_id) || (ca.codigo || '').localeCompare(cb.codigo || '') || (a.secuencia - b.secuencia);
        };
        this.filas.sort(cmp);
      },

      async cargar() {
        try {
          const [mercados, mis, propios, proveedores, subs, compras, materiales, taxonomias, evidencias, catalogos] = await Promise.all([
            traerTodo(() => sb.from('mercados').select('id, codigo, nombre, moneda').order('id')),
            sb.rpc('fn_mis_mercados'),
            traerTodo(() => sb.from('usuario_mercados').select('mercado_id').eq('usuario_id', this.usuario.id).order('mercado_id')),
            traerTodo(() => sb.from('proveedores').select('id, mercado_id, nombre').order('nombre')),
            traerTodo(() => sb.from('v_sub_campanas').select('id, mercado_id, mercado, nombre_unico, activo').order('nombre_unico')),
            traerTodo(() => sb.from('compras').select(COLUMNAS_COMPRA_M).order('id')),
            traerTodo(() => sb.from('materiales').select(COLUMNAS_MATERIAL).order('id')),
            traerTodo(() => sb.from('v_materiales').select('material_id, taxonomia').order('material_id')),
            cargarEvidencias(),
            cargarCatalogos(),
          ]);
          this.catalogoCosto = catalogos.tiposCosto;
          if (mis.error) throw mis.error;

          this.mercados = mercados;
          this.misMercadoIds = (mis.data || []).map(x => (typeof x === 'object' ? Object.values(x)[0] : x)).map(Number);
          this.proveedores = proveedores;
          this.subCampanas = subs;
          this.compras = compras;
          this.evidencias = evidencias;
          const tax = new Map(taxonomias.map(t => [t.material_id, t.taxonomia]));
          this.filas = materiales.map(m => desdeBaseMaterial(m, tax.get(m.id)));
          this.ordenarFilas();

          this.filtros.mercado = mercadoInicial(this.misMercados, propios.map(p => p.mercado_id));
          if (!this.misMercados.length) {
            this.errorCarga = 'Tu usuario no tiene mercados asignados. Pide a un administrador que te los asigne.';
          }
        } catch (e) {
          console.error(e);
          this.errorCarga = 'No se pudieron cargar los materiales: ' + (e.message || e);
        } finally {
          this.cargando = false;
        }
        this.irAFilaPedida();
      },
    },

    mounted() {
      this.cargar();
      document.addEventListener('keydown', (ev) => {
        if (ev.key === 'Escape' && this.borrador && !document.querySelector('.multi.abierto')) this.cerrarPanel();
      });
      window.addEventListener('beforeunload', (ev) => {
        const pendientes = this.filas.some(r => r._guardando || (r._estado && ['err', 'prop'].includes(r._estado.clase)));
        if (pendientes || this.borrador) { ev.preventDefault(); ev.returnValue = ''; }
      });
    },
  }).mount('#app');
}

iniciar();
