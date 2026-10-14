// Portal externo: lo que ven PROVEEDOR y AGENCIA (Fase 3).
// Nada del Flow. Todo sale de v_materiales_externos, la única vista que lee esta
// pantalla: las columnas del material y las que el Tracking hereda de la compra
// (código, proveedor, formato, ubicación, ciudad, tipo de costo). El calendario
// no carga costos.
// Escritura solo por funciones de la base, cada una con sus campos:
//   PROVEEDOR -> fn_reportar_implementacion (reporte) y sus evidencias
//                (fotos, videos y enlaces, en el panel de evidencias.js)
//   AGENCIA   -> fn_actualizar_enlace (enlace); ve las evidencias sin tocarlas
// materiales.evidencia_url ya no se usa: las evidencias van en su tabla.
// La pantalla solo ofrece esos campos; lo que de verdad lo impide es la base.

const COLUMNAS_PORTAL = [
  'id', 'codigo', 'sub_campana', 'referencia', 'fecha_inicio', 'fecha_fin', 'enlace',
  'reporte_implementacion', 'compra', 'proveedor', 'formato',
  'ubicacion', 'ciudad', 'tipo_costo',
].join(', ');

const EDITABLES_POR_ROL = {
  PROVEEDOR: ['reporte_implementacion'],
  AGENCIA:   ['enlace'],
};

const SIN_SUB_P = '';  // opción "Sin sub campaña" del filtro
const DIAS_SEM = ['D', 'L', 'M', 'M', 'J', 'V', 'S'];


const textoONuloP = (s) => { const t = (s || '').trim(); return t === '' ? null : t; };

let contadorPortal = 0;

function desdeBasePortal(m) {
  const r = {
    ...m,
    _k: ++contadorPortal,
    enlace: m.enlace || '',
    reporte_implementacion: m.reporte_implementacion || '',
    _guardando: false,
    _repetir: false,
    _estado: null,
  };
  r._orig = {
    enlace: textoONuloP(r.enlace),
    reporte_implementacion: textoONuloP(r.reporte_implementacion),
  };
  return r;
}

function mensajeErrorPortal(error) {
  if (!error) return 'Error desconocido';
  if (error.code === '42501') return error.message || 'Este material no es tuyo';
  if (error.code === '22023') return error.message || 'Valor no válido';
  return error.message || String(error);
}

// Barra superior del portal: sin la navegación interna.
function pintarBarraPortal(contenedor, usuario, cuenta) {
  contenedor.innerHTML = `
    <a class="marca" href="portal.html">OASIS<span>.</span></a>
    <div class="migas">Portal <span class="sep">/</span> <strong class="cuenta"></strong></div>
    <div class="usuario">
      <div>
        <div class="nombre"></div>
        <div class="rol"></div>
      </div>
      <button class="salir" type="button">Salir</button>
    </div>`;
  contenedor.querySelector('.cuenta').textContent = cuenta;
  contenedor.querySelector('.nombre').textContent = usuario.nombre;
  contenedor.querySelector('.rol').textContent = usuario.rol;
  contenedor.querySelector('.salir').addEventListener('click', salir);
}

// ------------------------------------------------------------------ App

async function iniciar() {
  const usuario = await requerirAccesoExterno();
  const esProveedor = usuario.rol === 'PROVEEDOR';

  let materiales = [], evidencias = [], errorCarga = '';
  try {
    [materiales, evidencias] = await Promise.all([
      traerTodo(() => sb.from('v_materiales_externos').select(COLUMNAS_PORTAL).order('compra').order('codigo')),
      cargarEvidencias(),
    ]);
    if (!materiales.length) {
      errorCarga = esProveedor
        ? 'Todavía no hay materiales en compras de tu proveedor.'
        : 'Tu usuario no tiene mercados asignados o no hay materiales. Pide a ZetaBé que lo revise.';
    }
  } catch (e) {
    console.error(e);
    errorCarga = 'No se pudieron cargar los materiales: ' + (e.message || e);
  }

  // Nombre de la barra: el proveedor sale de sus propios materiales.
  const cuenta = esProveedor ? (materiales[0] ? materiales[0].proveedor : 'Proveedor') : 'Agencia';
  pintarBarraPortal(document.getElementById('barra'), usuario, cuenta);

  createApp({
    components: { SeleccionMultiple, PanelEvidencias },

    data: () => ({
      usuario,
      cuenta,
      esProveedor,
      editables: EDITABLES_POR_ROL[usuario.rol],
      cargando: false,
      errorCarga,
      filas: materiales.map(desdeBasePortal),
      evidencias,
      panelEv: null,           // material con el panel de evidencias abierto
      filtros: { meses: [], subCampanas: [] },
      vista: 'tabla',
      calMes: '',
      globo: null,
    }),

    computed: {
      evidenciasPorMaterial() {
        const m = new Map();
        for (const e of this.evidencias) {
          if (!m.has(e.material_id)) m.set(e.material_id, []);
          m.get(e.material_id).push(e);
        }
        return m;
      },

      eyebrow() { return this.esProveedor ? `${this.cuenta} · Proveedor` : 'Agencia'; },
      ayuda() {
        return this.esProveedor
          ? 'Escribe el reporte de implementación y pega el enlace a la evidencia (foto o carpeta) de cada material. Se guarda al salir de la fila.'
          : 'Pega en cada material el enlace a su arte. Se guarda al salir de la fila.';
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
      opcionesSubCampana() {
        const nombres = [...new Set(this.filas.map(r => r.sub_campana).filter(Boolean))].sort();
        return [
          { valor: SIN_SUB_P, etiqueta: 'Sin sub campaña' },
          ...nombres.map(n => ({ valor: n, etiqueta: n })),
        ];
      },

      visibles() {
        const f = this.filtros;
        const subs = new Set(f.subCampanas);
        return this.filas.filter(r => {
          if (subs.size && !subs.has(r.sub_campana || SIN_SUB_P)) return false;
          if (f.meses.length) {
            if (!r.fecha_inicio || !r.fecha_fin) return false;
            if (!f.meses.some(m => r.fecha_inicio <= `${m}-31` && r.fecha_fin >= `${m}-01`)) return false;
          }
          return true;
        });
      },

      kpis() {
        let sinReporte = 0, sinEvidencia = 0, sinEnlace = 0;
        for (const r of this.visibles) {
          if (!r._orig.reporte_implementacion) sinReporte++;
          if (!this.cuentaEvidencias(r)) sinEvidencia++;
          if (!r._orig.enlace) sinEnlace++;
        }
        return { total: this.visibles.length, sinReporte, sinEvidencia, sinEnlace };
      },

      errores() {
        const m = new Map();
        for (const r of this.filas) m.set(r._k, this.validarFila(r));
        return m;
      },

      estadoGlobal() {
        if (this.cargando) return { clase: '', texto: '' };
        const guardando = this.filas.filter(r => r._guardando).length;
        const pendientes = this.filas.filter(r => r._estado && ['err', 'prop'].includes(r._estado.clase) && !r._guardando).length;
        if (guardando) return { clase: 'prop', texto: 'Guardando…' };
        if (pendientes) return { clase: 'err', texto: `${pendientes} ${pendientes === 1 ? 'fila sin guardar' : 'filas sin guardar'}` };
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
          return { iso, d: i + 1, dow: DIAS_SEM[dow], finde: dow === 0 || dow === 6 };
        });
      },
      // Materiales activos por compra y día, de los que este usuario ve.
      // Una agencia con varios mercados podría juntar dos compras con el mismo
      // código; hoy solo hay MCO.
      activosCompraDia() {
        const cuenta = new Map();
        const dias = this.calDias;
        if (!dias.length) return cuenta;
        const ini = dias[0].iso, fin = dias[dias.length - 1].iso;
        for (const r of this.filas) {
          if (!r.fecha_inicio || r.fecha_fin < ini || r.fecha_inicio > fin) continue;
          for (const d of dias) {
            if (d.iso < r.fecha_inicio || d.iso > r.fecha_fin) continue;
            const k = `${r.compra}|${d.iso}`;
            cuenta.set(k, (cuenta.get(k) || 0) + 1);
          }
        }
        return cuenta;
      },
      calFilas() {
        const dias = this.calDias;
        if (!dias.length) return [];
        const ini = dias[0].iso, fin = dias[dias.length - 1].iso;
        return this.visibles
          .filter(r => r.fecha_inicio && r.fecha_inicio <= fin && r.fecha_fin >= ini)
          .map(r => ({
            r,
            celdas: dias.map(d => {
              const activo = d.iso >= r.fecha_inicio && d.iso <= r.fecha_fin;
              const compartido = activo && (this.activosCompraDia.get(`${r.compra}|${d.iso}`) || 0) > 1;
              return [d.finde ? 'finde' : '', activo ? (compartido ? 'compartido' : 'activo') : ''].join(' ');
            }),
          }));
      },
    },

    watch: {
      'filtros.meses'(v) { if (v.length) this.calMes = v[0]; },
    },

    methods: {
      esUrl,
      miniatura,
      fmtEntero(x) { return fmt.format(x); },
      nombreMes(k) { if (!k) return ''; const [y, m] = k.split('-'); return `${MESES[Number(m) - 1]} ${y}`; },
      fechaCorta(iso) { if (!iso) return ''; const [y, m, d] = iso.split('-'); return `${d}/${m}/${y}`; },

      validarFila(r) {
        const e = {};
        if (this.esProveedor) {
          if ((r.reporte_implementacion || '').length > 2000) e.reporte_implementacion = 'Máximo 2.000 caracteres';
        } else {
          const url = textoONuloP(r.enlace);
          if (url && !esUrl(url)) e.enlace = 'Tiene que ser un enlace que empiece por https://';
        }
        return e;
      },
      msgErr(r, campo) { return this.errores.get(r._k)[campo] || ''; },
      claseErr(r, campo) { return this.msgErr(r, campo) ? 'err' : ''; },

      // ---------------------------------------------------------------- Edición

      cambios(r) {
        const c = {};
        for (const k of this.editables) {
          const v = textoONuloP(r[k]);
          if (v !== r._orig[k]) c[k] = v;
        }
        return c;
      },
      tieneCambios(r) { return Object.keys(this.cambios(r)).length > 0; },

      alSalirDeCelda(ev) {
        const tr = ev.target.closest('tr[data-k]');
        if (!tr) return;
        // Del reporte a la evidencia de la misma fila aún no se guarda: van juntos.
        if (ev.relatedTarget && tr.contains(ev.relatedTarget)) return;
        const r = this.filas.find(x => x._k === Number(tr.dataset.k));
        if (r) this.guardar(r);
      },

      async guardar(r) {
        const cambios = this.cambios(r);
        if (!Object.keys(cambios).length) {
          if (r._estado && r._estado.clase !== 'ok') r._estado = null;
          return;
        }
        const errs = this.errores.get(r._k);
        if (Object.keys(errs).length) {
          r._estado = { clase: 'err', texto: 'error', detalle: Object.values(errs).join(' · ') };
          return;
        }
        if (r._guardando) { r._repetir = true; return; }

        r._guardando = true;
        let error = null, data = null;
        try {
          r._estado = { clase: 'prop', texto: 'guardando…' };
          if (this.esProveedor) {
            ({ data, error } = await sb.rpc('fn_reportar_implementacion', {
              p_material_id: r.id,
              p_reporte: textoONuloP(r.reporte_implementacion),
            }));
          } else {
            ({ data, error } = await sb.rpc('fn_actualizar_enlace', {
              p_material_id: r.id,
              p_enlace: textoONuloP(r.enlace),
            }));
          }
        } catch (e) {
          error = e;
        }

        r._guardando = false;
        if (error) {
          r._estado = { clase: 'err', texto: 'error', detalle: mensajeErrorPortal(error) };
          console.error('No se guardó el material', r.codigo, error);
        } else {
          for (const k of this.editables) r._orig[k] = textoONuloP(data[k]);
          const estado = { clase: 'ok', texto: 'guardado' };
          r._estado = estado;
          setTimeout(() => { if (r._estado === estado) r._estado = null; }, 2500);
        }
        if (r._repetir) { r._repetir = false; this.guardar(r); }
      },

      deshacer(r) {
        for (const k of this.editables) r[k] = r._orig[k] || '';
        r._estado = null;
      },

      // ---------------------------------------------------------------- Exportar

      // Filas filtradas, tal como están guardadas. Las mismas columnas de la
      // vista: nada del Flow.
      exportarCsv() {
        const columnas = [
          ['Código', (r) => r.codigo],
          ['Compra', (r) => r.compra],
          ['Proveedor', (r) => r.proveedor],
          ['Formato', (r) => r.formato],
          ['Ubicación', (r) => r.ubicacion],
          ['Ciudad', (r) => r.ciudad],
          ['Tipo de costo', (r) => r.tipo_costo],
          ['Sub campaña', (r) => r.sub_campana],
          ['Referencia', (r) => r.referencia],
          ['Enlace', (r) => r._orig.enlace],
          ['Reporte de implementación', (r) => r._orig.reporte_implementacion],
          ['Evidencias', (r) => this.cuentaEvidencias(r)],
          ['Fecha inicio', (r) => r.fecha_inicio],
          ['Fecha fin', (r) => r.fecha_fin],
        ];
        const nombre = normTexto(this.cuenta).toLowerCase().replace(/[^a-z0-9]+/g, '_') || 'portal';
        descargarCsv(`materiales_${nombre}_${hoyIso()}.csv`, columnas, this.visibles);
      },

      // ---------------------------------------------------------------- Calendario

      verCalendario() {
        if (this.vista === 'calendario') { this.vista = 'tabla'; this.globo = null; return; }
        if (!this.calMes || !this.filtros.meses.length) {
          const hoy = hoyIso().slice(0, 7);
          this.calMes = this.filtros.meses[0]
            || (this.meses.includes(hoy) ? hoy : this.meses[this.meses.length - 1] || hoy);
        }
        this.vista = 'calendario';
      },
      moverMes(n) {
        let [y, m] = this.calMes.split('-').map(Number);
        m += n;
        if (m < 1) { m = 12; y--; }
        if (m > 12) { m = 1; y++; }
        this.calMes = `${y}-${String(m).padStart(2, '0')}`;
      },

      mostrarGlobo(ev) {
        const el = ev.target.closest('[data-dia], [data-img]');
        if (!el) { this.globo = null; return; }
        const caja = el.getBoundingClientRect();
        const pos = { x: Math.min(caja.left, window.innerWidth - 300), y: caja.bottom + 6 };
        if (el.dataset.img) { this.globo = { ...pos, img: el.dataset.img, lineas: [] }; return; }

        const r = this.filas.find(x => x._k === Number(el.closest('tr[data-k]').dataset.k));
        if (!r) return;
        const dia = el.dataset.dia;
        const activo = dia >= r.fecha_inicio && dia <= r.fecha_fin;
        const n = this.activosCompraDia.get(`${r.compra}|${dia}`) || 0;
        this.globo = {
          ...pos,
          lineas: [
            `${r.codigo} · ${fechaLarga(dia)}`,
            activo ? 'Material activo' : 'Material no activo este día',
            `${n} ${n === 1 ? 'material activo' : 'materiales activos'} en la compra ${r.compra}`,
          ],
        };
      },
      ocultarGlobo() { this.globo = null; },

      // ---------------------------------------------------------------- Evidencias

      cuentaEvidencias(r) { return (this.evidenciasPorMaterial.get(r.id) || []).length; },
      abrirEvidencias(r) { this.panelEv = r; },
      alAgregarEvidencia(e) { this.evidencias = [...this.evidencias, e]; },
      alBorrarEvidencia(id) { this.evidencias = this.evidencias.filter(e => e.id !== id); },
    },

    mounted() {
      window.addEventListener('beforeunload', (ev) => {
        const pendientes = this.filas.some(r => r._guardando || (r._estado && ['err', 'prop'].includes(r._estado.clase)));
        if (pendientes) { ev.preventDefault(); ev.returnValue = ''; }
      });
    },
  }).mount('#app');
}

iniciar();
