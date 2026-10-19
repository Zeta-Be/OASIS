// Pantalla de Compras: una fila por compra, equivale a la hoja Flow del Sheets.
// Lo existente se edita en la tabla; lo nuevo se crea en el panel lateral.

const COLUMNAS_COMPRA = [
  'id', 'mercado_id', 'codigo', 'cliente', 'campana_id', 'proveedor_id',
  'tipo_compra', 'medio', 'tipo_costo', 'formato', 'ubicacion', 'ciudad', 'tiempo',
  'tarifa_bruta', 'descuento_pct', 'tarifa_neta', 'cantidad', 'nro_semanas',
  'valor_total', 'valor_total_manual', 'fecha_inicio', 'fecha_fin',
  'campana_texto', 'campana_taxonomia',
].join(', ');

// Lee lo que la gente escribe: "1.234.567", "1234567,5", "10,71", "10.71".
function leerNumero(texto, decimales) {
  const t = String(texto).replace(/\s|\$/g, '');
  if (t === '') return null;
  let normal;
  if (t.includes(',')) normal = t.replace(/\./g, '').replace(',', '.');
  else if ((t.match(/\./g) || []).length > 1 || decimales === 0) normal = t.replace(/\./g, '');
  else normal = t;
  return /^-?\d*\.?\d+$|^-?\d+\.$/.test(normal) ? Number(normal) : NaN;
}

// Valores de "tiempo" que siempre se ofrecen, además de los que ya hay en la base.
const TIEMPOS_BASE = ['MES', 'SEMANA', 'DIAS'];

// Valor total automático. Con tiempo SEMANA la tarifa es por semana: se multiplica
// por nro. semanas (vacío cuenta como 0, igual que en el Sheets y en cargar_oasis.py).
// Excepción: la producción se cobra una vez, nunca por semana. En cualquier otro
// caso, tarifa neta × cantidad.
const porSemana = (r) => r.tiempo === 'SEMANA' && r.tipo_costo !== 'PRODUCCION';
function formulaValorTotal(r) {
  if (!esNumero(r.tarifa_neta) || !esNumero(r.cantidad)) return null;
  const semanas = porSemana(r) ? (esNumero(r.nro_semanas) ? r.nro_semanas : 0) : 1;
  return redondear(r.tarifa_neta * r.cantidad * semanas, 2);
}

// Formatos en mayúscula y con un solo espacio: "valla  led " -> "VALLA LED".
const normFormato = (s) => (s || '').replace(/\s+/g, ' ').trim().toUpperCase();
const compacto = (s) => normFormato(s).replace(/[^A-Z0-9]/g, '');

function distancia(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
  }
  return d[a.length][b.length];
}

// ------------------------------------------------------------------ Celda numérica
// Muestra el número con separadores cuando no tiene foco, y el valor crudo al editar.
const CeldaNum = {
  props: { modelValue: null, decimales: { type: Number, default: 2 }, disabled: Boolean, id: String },
  emits: ['update:modelValue', 'editado'],
  data: () => ({ enfocada: false, texto: '' }),
  computed: {
    mostrado() {
      if (this.enfocada) return this.texto;
      const v = this.modelValue;
      if (v === null || v === undefined) return '';
      if (Number.isNaN(v)) return this.texto;
      return fmt.format(v);
    },
  },
  methods: {
    alEnfocar() {
      this.enfocada = true;
      const v = this.modelValue;
      this.texto = esNumero(v) ? String(v).replace('.', ',') : (Number.isNaN(v) ? this.texto : '');
    },
    alEscribir(ev) {
      this.texto = ev.target.value;
      this.$emit('update:modelValue', leerNumero(this.texto, this.decimales));
      this.$emit('editado');
    },
  },
  template: `<input class="n" inputmode="decimal" :id="id" :value="mostrado" :disabled="disabled"
                    @focus="alEnfocar" @blur="enfocada = false" @input="alEscribir">`,
};

// ------------------------------------------------------------------ Combo
// Desplegable con opciones existentes que también acepta texto nuevo.
// La lista va en posición fija para que no la recorte el scroll de la tabla.
const Combo = {
  props: { modelValue: String, opciones: Array, disabled: Boolean, id: String },
  emits: ['update:modelValue'],
  data: () => ({ abierto: false, filtro: '', activo: -1, pos: {} }),
  computed: {
    lista() {
      const f = normFormato(this.filtro);
      return f ? this.opciones.filter(o => o.includes(f)) : this.opciones;
    },
  },
  methods: {
    ubicar() {
      const r = this.$refs.input.getBoundingClientRect();
      const abajo = window.innerHeight - r.bottom > 220;
      this.pos = {
        left: `${r.left}px`,
        minWidth: `${Math.max(r.width, 180)}px`,
        ...(abajo ? { top: `${r.bottom}px` } : { bottom: `${window.innerHeight - r.top}px` }),
      };
    },
    // Al desplazar (incluido el que hace el navegador al enfocar una celda) la lista
    // acompaña al campo; solo se cierra si el campo sale de la vista.
    alDesplazar() {
      if (!this.abierto) return;
      const r = this.$refs.input.getBoundingClientRect();
      if (r.bottom < 0 || r.top > window.innerHeight) this.cerrar();
      else this.ubicar();
    },
    abrir() {
      this.ubicar();
      this.filtro = '';
      this.activo = -1;
      this.abierto = true;
    },
    cerrar() { this.abierto = false; },
    alEscribir(ev) {
      this.$emit('update:modelValue', ev.target.value);
      if (!this.abierto) this.abrir();
      this.filtro = ev.target.value;
      this.activo = -1;
    },
    elegir(o) {
      this.$emit('update:modelValue', o);
      this.abierto = false;
    },
    tecla(ev) {
      if (!this.abierto) {
        if (ev.key === 'ArrowDown') { this.abrir(); ev.preventDefault(); }
        return;
      }
      if (ev.key === 'ArrowDown') { this.activo = Math.min(this.activo + 1, this.lista.length - 1); ev.preventDefault(); }
      else if (ev.key === 'ArrowUp') { this.activo = Math.max(this.activo - 1, 0); ev.preventDefault(); }
      else if (ev.key === 'Enter' && this.activo >= 0) { this.elegir(this.lista[this.activo]); ev.preventDefault(); }
      else if (ev.key === 'Escape') { this.cerrar(); ev.stopPropagation(); }
    },
  },
  mounted() { window.addEventListener('scroll', this.alDesplazar, true); },
  unmounted() { window.removeEventListener('scroll', this.alDesplazar, true); },
  template: `
    <div class="combo">
      <input ref="input" :id="id" :value="modelValue" :disabled="disabled" autocomplete="off"
             @focus="abrir" @blur="cerrar" @input="alEscribir" @keydown="tecla">
      <ul v-if="abierto && lista.length" class="combo-lista" :style="pos">
        <li v-for="(o, i) in lista" :key="o" :class="{ activo: i === activo, elegido: o === modelValue }"
            @mousedown.prevent="elegir(o)">{{ o }}</li>
      </ul>
    </div>`,
};

// ------------------------------------------------------------------ Campaña
// La campaña de una compra: un desplegable con búsqueda entre las del mercado
// (las taxonomías de sus compras y su glosario) y, al final, «Agregar campaña
// nueva…» para escribir una taxonomía completa. La base la valida y la vincula
// al glosario (sql/compras_campana.sql); aquí se valida el formato para avisar
// antes de guardar.

// Igual que fn_taxonomia_de_texto: {MERCADO}_ML_…_X, al menos cinco piezas.
// Para buscar: sin tildes y en mayúsculas (Compras no carga tramos.js).
const plano = (s) => (s || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase().trim();

const reTaxonomia = (mercado) => new RegExp(`^${mercado}_ML_[A-Z0-9-]+(_[A-Z0-9-]+){3,}$`);

// Nombre corto de una taxonomía: lo que va entre la cuarta pieza y el sufijo
// (MLA_ML_OTH-PF_ALL_INTERIOR_X → INTERIOR; …_SUMMER-26_OOH → SUMMER-26).
function nombreCorto(taxonomia) {
  const p = (taxonomia || '').split('_');
  return p.length >= 6 ? p.slice(4, -1).join('_') : (p[p.length - 2] || taxonomia || '');
}

const SelectorCampana = {
  props: {
    modelValue: Object,        // { campana_id, campana_taxonomia }
    opciones: Array,           // [{ clave, campana_id, taxonomia, nombre }]
    mercado: String,           // código, para validar la taxonomía nueva
    compacto: Boolean,         // en la celda de la tabla
    id: String,
  },
  emits: ['update:modelValue', 'nueva'],
  data: () => ({ abierto: false, busqueda: '', agregando: false, nueva: '', error: '', pos: {} }),
  computed: {
    actual() {
      const v = this.modelValue || {};
      const o = (v.campana_taxonomia && this.opciones.find(x => x.taxonomia === v.campana_taxonomia))
        || (!v.campana_taxonomia && v.campana_id && this.opciones.find(x => x.campana_id === v.campana_id && !x.taxonomia))
        || (v.campana_id && this.opciones.find(x => x.campana_id === v.campana_id));
      if (o) return o;
      return { nombre: v.campana_taxonomia ? nombreCorto(v.campana_taxonomia) : '', taxonomia: v.campana_taxonomia || '' };
    },
    filtradas() {
      const q = plano(this.busqueda);
      if (!q) return this.opciones;
      return this.opciones.filter(o => plano(o.nombre).includes(q) || plano(o.taxonomia).includes(q));
    },
  },
  methods: {
    ubicar() {
      const r = this.$el.getBoundingClientRect();
      const abajo = window.innerHeight - r.bottom > 320;
      const ancho = Math.max(r.width, 300);
      this.pos = {
        left: `${Math.max(8, Math.min(r.left, window.innerWidth - ancho - 8))}px`,
        width: `${ancho}px`,
        ...(abajo ? { top: `${r.bottom}px` } : { bottom: `${window.innerHeight - r.top}px` }),
      };
    },
    abrir() {
      if (this.abierto) { this.cerrar(); return; }
      this.ubicar();
      this.busqueda = '';
      this.agregando = false;
      this.error = '';
      this.abierto = true;
      nextTick(() => { if (this.$refs.buscar) this.$refs.buscar.focus(); });
    },
    cerrar() { this.abierto = false; },
    elegir(o) {
      this.$emit('update:modelValue', { campana_id: o.campana_id || null, campana_taxonomia: o.taxonomia || null });
      this.cerrar();
    },
    empezarNueva() {
      this.agregando = true;
      this.nueva = this.busqueda.trim().toUpperCase().startsWith(`${this.mercado}_`) ? this.busqueda.trim().toUpperCase() : `${this.mercado}_ML_`;
      nextTick(() => { if (this.$refs.nueva) this.$refs.nueva.focus(); });
    },
    usarNueva() {
      const tax = this.nueva.trim().toUpperCase();
      if (!reTaxonomia(this.mercado).test(tax)) {
        this.error = `Formato: ${this.mercado}_ML_TIPO_ALL_NOMBRE_X, en mayúsculas y sin espacios`;
        return;
      }
      this.$emit('nueva', tax);   // queda disponible para las siguientes compras del mercado
      this.$emit('update:modelValue', { campana_id: null, campana_taxonomia: tax });
      this.cerrar();
    },
    fuera(ev) { if (this.abierto && !this.$el.contains(ev.target) && !(this.$refs.lista && this.$refs.lista.contains(ev.target))) this.cerrar(); },
    tecla(ev) { if (ev.key === 'Escape' && this.abierto) { this.cerrar(); ev.stopPropagation(); } },
    alDesplazar(ev) {
      if (!this.abierto || (this.$refs.lista && this.$refs.lista.contains(ev.target))) return;
      const r = this.$el.getBoundingClientRect();
      if (r.bottom < 0 || r.top > window.innerHeight) this.cerrar(); else this.ubicar();
    },
  },
  mounted() {
    document.addEventListener('pointerdown', this.fuera);
    window.addEventListener('scroll', this.alDesplazar, true);
  },
  unmounted() {
    document.removeEventListener('pointerdown', this.fuera);
    window.removeEventListener('scroll', this.alDesplazar, true);
  },
  template: `
    <div class="selector-campana" :class="{ abierto, compacto }" @keydown="tecla">
      <button type="button" class="sc-boton" :id="id" @click="abrir" :aria-expanded="abierto"
              :title="actual.taxonomia || actual.nombre">
        <span class="sc-nombre">{{ actual.nombre || 'Elige la campaña' }}</span>
        <span v-if="!compacto && actual.taxonomia" class="sc-tax mono">{{ actual.taxonomia }}</span>
      </button>
      <div v-if="abierto" ref="lista" class="sc-lista" :style="pos">
        <input ref="buscar" v-model="busqueda" class="sc-buscar" placeholder="Buscar campaña o taxonomía…" autocomplete="off">
        <ul>
          <li v-for="o in filtradas" :key="o.clave" :class="{ elegido: o === actual }" @mousedown.prevent="elegir(o)">
            <span class="sc-nombre">{{ o.nombre }}</span>
            <span class="sc-tax mono">{{ o.taxonomia || 'del glosario' }}</span>
          </li>
          <li v-if="!filtradas.length" class="sin">Ninguna coincide.</li>
        </ul>
        <div class="sc-pie">
          <button v-if="!agregando" type="button" class="enlace" @mousedown.prevent="empezarNueva">Agregar campaña nueva…</button>
          <form v-else class="sc-nueva" @submit.prevent="usarNueva">
            <input ref="nueva" v-model="nueva" class="mono" :class="{ err: error }" autocomplete="off"
                   :placeholder="mercado + '_ML_OTH-PF_ALL_NOMBRE_X'" @input="error = ''">
            <button type="submit" class="btn p">Usar</button>
          </form>
          <div v-if="error" class="campo-error">{{ error }}</div>
        </div>
      </div>
    </div>`,
};

// ------------------------------------------------------------------ Filas

let contadorFilas = 0;

// Lo que se manda a la base. El descuento en pantalla va de 0 a 100; en la base,
// como fracción (0,15 = 15 %). La campaña es de cada compra (columna CAMPAÑA
// del Flow): editar una compra no la toca. Una compra nueva arranca con la
// campaña de parque fijo del mercado (borradorNuevo).
function aPayload(r) {
  return {
    mercado_id:         r.mercado_id,
    codigo:             r.codigo,
    cliente:            r.cliente,
    campana_id:         r.campana_id,
    campana_taxonomia:  r.campana_taxonomia || null,
    proveedor_id:       r.proveedor_id,
    tipo_compra:        r.tipo_compra,
    medio:              r.medio,
    tipo_costo:         r.tipo_costo,
    formato:            normFormato(r.formato),
    ubicacion:          r.ubicacion,
    ciudad:             r.ciudad,
    tiempo:             r.tiempo || null,
    tarifa_bruta:       r.tarifa_bruta,
    descuento_pct:      redondear(r.descuento / 100, 4),
    tarifa_neta:        r.tarifa_neta,
    cantidad:           r.cantidad,
    nro_semanas:        r.nro_semanas,
    valor_total:        r.valor_total,
    valor_total_manual: r.valor_total_manual,
    fecha_inicio:       r.fecha_inicio,
    fecha_fin:          r.fecha_fin,
  };
}

function desdeBase(c) {
  const num = (x) => (x === null || x === undefined ? null : Number(x));
  return {
    _k: ++contadorFilas,
    id: c.id,
    mercado_id: c.mercado_id,
    codigo: c.codigo,
    cliente: c.cliente,
    campana_id: c.campana_id,
    campana_texto: c.campana_texto,
    campana_taxonomia: c.campana_taxonomia,
    proveedor_id: c.proveedor_id,
    tipo_compra: c.tipo_compra,
    medio: c.medio,
    tipo_costo: c.tipo_costo,
    formato: c.formato,
    ubicacion: c.ubicacion,
    ciudad: c.ciudad,
    tiempo: c.tiempo,
    tarifa_bruta: num(c.tarifa_bruta),
    descuento: redondear(num(c.descuento_pct) * 100, 2),
    tarifa_neta: num(c.tarifa_neta),
    cantidad: num(c.cantidad),
    nro_semanas: num(c.nro_semanas),
    valor_total: num(c.valor_total),
    valor_total_manual: !!c.valor_total_manual,
    fecha_inicio: c.fecha_inicio,
    fecha_fin: c.fecha_fin,
    _snap: null,              // último payload guardado (se llena al montar)
    _formatoGuardado: normFormato(c.formato),
    _formatoNuevoOk: '',      // formato nuevo que el usuario ya confirmó
    _guardando: false,
    _repetir: false,
    _estado: null,
  };
}

function borradorNuevo(mercadoId, campanaOoh) {
  return {
    mercado_id: mercadoId,
    cliente: '', campana_id: campanaOoh, proveedor_id: null,
    tipo_compra: null, medio: null, tipo_costo: null,
    formato: '', ubicacion: '', ciudad: '', tiempo: 'MES',
    tarifa_bruta: null, descuento: 0, tarifa_neta: 0,
    cantidad: 1, nro_semanas: null, valor_total: 0, valor_total_manual: false,
    fecha_inicio: null, fecha_fin: null,
    _formatoNuevoOk: '',
    _tocados: {},             // campos por los que ya pasó el usuario
    _intento: false,          // intentó guardar: se muestran todos los errores
    _guardando: false,
    _error: '',
  };
}

function validar(r, ctx) {
  const e = {};
  const obligatorio = 'Obligatorio';

  for (const c of ['cliente', 'formato', 'ubicacion', 'ciudad', 'tipo_compra', 'medio', 'tipo_costo']) {
    if (!r[c]) e[c] = obligatorio;
  }
  // La base lo rechaza igual (fn_validar_tipo_costo); aquí se marca en la celda.
  if (r.tipo_costo && ctx.tipoCostoPermitido && !ctx.tipoCostoPermitido(r)) {
    e.tipo_costo = 'Este tipo de costo no se usa en este mercado';
  }

  // Solo una compra nueva necesita campaña para guardarse. Una cargada del
  // Sheets sin campaña reconocida se corrige desde Alertas y no bloquea la fila.
  if (!r.id && !r.campana_id && !r.campana_taxonomia) e.campana_id = 'Elige la campaña';

  if (!r.proveedor_id) e.proveedor_id = obligatorio;
  else {
    const p = ctx.proveedoresPorId.get(r.proveedor_id);
    if (!p) e.proveedor_id = 'Proveedor desconocido';
    else if (p.mercado_id !== r.mercado_id) e.proveedor_id = 'El proveedor es de otro mercado';
  }

  if (r.tarifa_bruta === null) e.tarifa_bruta = obligatorio;
  else if (!esNumero(r.tarifa_bruta)) e.tarifa_bruta = 'No es un número';
  else if (r.tarifa_bruta < 0) e.tarifa_bruta = 'No puede ser negativa';

  if (r.descuento === null) e.descuento = 'Obligatorio (0 si no hay descuento)';
  else if (!esNumero(r.descuento)) e.descuento = 'No es un número';
  else if (r.descuento < 0 || r.descuento > 100) e.descuento = 'Debe estar entre 0 y 100';

  if (r.cantidad === null) e.cantidad = obligatorio;
  else if (!esNumero(r.cantidad) || !Number.isInteger(r.cantidad)) e.cantidad = 'Debe ser un número entero';
  else if (r.cantidad < 1) e.cantidad = 'Debe ser al menos 1';

  if (r.nro_semanas !== null) {
    if (!esNumero(r.nro_semanas)) e.nro_semanas = 'No es un número';
    else if (r.nro_semanas < 0) e.nro_semanas = 'No puede ser negativo';
  } else if (porSemana(r) && !r.valor_total_manual) {
    e.nro_semanas = 'Obligatorio con tiempo SEMANA: el valor total lo multiplica';
  }

  if (r.valor_total_manual) {
    if (r.valor_total === null) e.valor_total = obligatorio;
    else if (!esNumero(r.valor_total)) e.valor_total = 'No es un número';
    else if (r.valor_total < 0) e.valor_total = 'No puede ser negativo';
  }

  if (!r.fecha_inicio) e.fecha_inicio = obligatorio;
  if (!r.fecha_fin) e.fecha_fin = obligatorio;
  if (r.fecha_inicio && r.fecha_fin && r.fecha_fin < r.fecha_inicio) {
    e.fecha_fin = 'La fecha fin es anterior a la fecha inicio';
  }

  return e;
}

// Tarifa neta heredada del Sheets que no sale de la fórmula (redondeo del descuento).
// Se muestra, no se corrige sola.
function obsNeta(r) {
  if (!esNumero(r.tarifa_bruta) || !esNumero(r.descuento) || !esNumero(r.tarifa_neta)) return '';
  const f = redondear(r.tarifa_bruta * (1 - r.descuento / 100), 2);
  return Math.abs(f - r.tarifa_neta) > 1
    ? `Guardada: ${fmt.format(r.tarifa_neta)}. Fórmula (bruta × (1 − desc.)): ${fmt.format(f)}. Se recalcula si editas tarifa bruta o descuento.`
    : '';
}

function mensajeError(error) {
  if (!error) return 'Error desconocido';
  if (error.code === '42501') return 'Sin permiso para guardar en este mercado';
  if (error.code === '23505') return 'Ese código ya existe en el mercado';
  if (error.code === '23503') return 'Campaña o proveedor no corresponden al mercado';
  if (error.code === '23514') return 'La base rechazó un valor (fechas, descuento o valor total)';
  return error.message || String(error);
}

// ------------------------------------------------------------------ App

async function iniciar() {
  const usuario = await requerirAcceso();
  pintarBarra(document.getElementById('barra'), usuario, 'compras');

  createApp({
    components: { CeldaNum, SeleccionMultiple, Combo, SelectorCampana },

    data: () => ({
      ENUMS,
      catalogos: { tiposCompra: [], tiposCosto: [] },
      campanasNuevas: {},      // mercado_id -> taxonomías escritas en esta sesión
      usuario,
      cargando: true,
      errorCarga: '',
      avisoPedido: '',
      mercados: [],
      misMercadoIds: [],
      campanas: [],
      proveedores: [],
      filas: [],
      filtros: { mercado: '', meses: [], proveedores: [], tiposCosto: [] },
      resaltada: null,         // fila que pidió Alertas (_k)
      borrador: null,         // compra nueva en el panel lateral
    }),

    computed: {
      soloLectura() { return this.usuario.rol === 'LECTURA'; },

      misMercados() { return this.mercados.filter(m => this.misMercadoIds.includes(m.id)); },
      mercadosPorId() { return new Map(this.mercados.map(m => [m.id, m])); },
      campanasPorId() { return new Map(this.campanas.map(c => [c.id, c])); },
      proveedoresPorId() { return new Map(this.proveedores.map(p => [p.id, p])); },

      ctx() {
        return {
          proveedoresPorId: this.proveedoresPorId,
          campanaOoh: (mercadoId) => this.campanaOoh(mercadoId),
          tipoCostoPermitido: (r) => tiposCostoPara(this.catalogos.tiposCosto, this.codigoMercado(r.mercado_id)).includes(r.tipo_costo),
        };
      },

      eyebrow() {
        const m = this.mercadosPorId.get(this.filtros.mercado);
        return m ? `${m.codigo} · ${m.nombre}` : 'Todos mis mercados';
      },

      opcionesMes() { return this.meses.map(m => ({ valor: m, etiqueta: this.nombreMes(m) })); },
      opcionesTipoCosto() {
        return tiposCostoPara(this.catalogos.tiposCosto, this.codigoFiltroMercado).map(t => ({ valor: t, etiqueta: t }));
      },
      // Opciones de campaña por mercado; se arman una vez (la tabla tiene miles de filas).
      campanasPorMercado() {
        const salida = new Map();
        for (const m of this.mercados) salida.set(m.id, this.armarOpcionesCampana(m.id));
        return salida;
      },
      codigoFiltroMercado() { const m = this.mercadosPorId.get(this.filtros.mercado); return m ? m.codigo : ''; },
      opcionesProveedor() {
        const lista = this.filtros.mercado
          ? this.proveedores.filter(p => p.mercado_id === this.filtros.mercado)
          : this.proveedores.filter(p => this.misMercadoIds.includes(p.mercado_id));
        return lista.map(p => ({
          valor: p.id,
          etiqueta: this.filtros.mercado ? p.nombre : `${p.nombre} (${this.codigoMercado(p.mercado_id)})`,
        }));
      },

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

      visibles() {
        const f = this.filtros;
        const prov = new Set(f.proveedores);
        const tipos = new Set(f.tiposCosto);
        return this.filas.filter(r => {
          if (f.mercado && r.mercado_id !== f.mercado) return false;
          if (prov.size && !prov.has(r.proveedor_id)) return false;
          if (tipos.size && !tipos.has(r.tipo_costo)) return false;
          if (f.meses.length) {
            if (!r.fecha_inicio || !r.fecha_fin) return false;
            const cruza = f.meses.some(m => r.fecha_inicio <= `${m}-31` && r.fecha_fin >= `${m}-01`);
            if (!cruza) return false;
          }
          return true;
        });
      },

      // Una suma por moneda: con «Todos», pesos colombianos y chilenos no se suman.
      sumasPorMoneda() {
        const m = new Map();
        for (const r of this.visibles) {
          const moneda = (this.mercadosPorId.get(r.mercado_id) || {}).moneda || '';
          m.set(moneda, (m.get(moneda) || 0) + (esNumero(r.valor_total) ? r.valor_total : 0));
        }
        return [...m.entries()].sort().map(([moneda, suma]) => ({ moneda, suma }));
      },

      // Formatos ya guardados en cada mercado (lo que hay en la base, no lo que se está escribiendo).
      formatosPorMercado() {
        const g = new Map();
        for (const r of this.filas) {
          if (!r._formatoGuardado) continue;
          if (!g.has(r.mercado_id)) g.set(r.mercado_id, new Set());
          g.get(r.mercado_id).add(r._formatoGuardado);
        }
        return g;
      },

      sugerencias() {
        const unicos = (c) => [...new Set(this.filas.map(r => r[c]).filter(Boolean))].sort();
        return { cliente: unicos('cliente'), ciudad: unicos('ciudad') };
      },
      // Desplegable de tiempo: MES, SEMANA, DIAS y lo que ya exista en la base.
      opcionesTiempo() {
        const extra = [...new Set(this.filas.map(r => r.tiempo).filter(Boolean))]
          .filter(t => !TIEMPOS_BASE.includes(t)).sort();
        return [...TIEMPOS_BASE, ...extra];
      },

      errores() {
        const m = new Map();
        for (const r of this.filas) m.set(r._k, validar(r, this.ctx));
        return m;
      },

      netasObservadas() { return this.visibles.filter(r => obsNeta(r)).length; },

      puedeCrear() { return !this.soloLectura && !this.cargando && !!this.filtros.mercado && !!this.campanaOoh(this.filtros.mercado); },
      motivoNoCrear() {
        if (this.soloLectura) return 'Tu rol es de solo lectura';
        if (!this.filtros.mercado) return 'Elige un mercado para crear la compra';
        if (!this.campanaOoh(this.filtros.mercado)) return 'Este mercado no tiene campaña OOH configurada';
        return '';
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

      // ---- panel lateral
      erroresBorrador() { return this.borrador ? validar(this.borrador, this.ctx) : {}; },
      codigoPrevisto() { return this.borrador ? this.siguienteCodigoLocal(this.borrador.mercado_id) : ''; },
    },

    watch: {
      'filtros.mercado'(id) {
        guardarMercadoActivo(id ? this.codigoMercado(id) : '');
        const validos = new Set(this.opcionesProveedor.map(o => o.valor));
        this.filtros.proveedores = this.filtros.proveedores.filter(id => validos.has(id));
      },
    },

    methods: {
      fmtNumero(x) { return esNumero(x) ? fmt.format(x) : ''; },
      fmtEntero(x) { return fmt.format(x); },
      fmtFecha(iso) { if (!iso) return ''; const [y, m, d] = iso.split('-'); return `${d}/${m}/${y}`; },
      nombreProveedor(id) { const p = this.proveedoresPorId.get(id); return p ? p.nombre : ''; },
      nombreMes(k) { const [y, m] = k.split('-'); return `${MESES[Number(m) - 1]} ${y}`; },
      codigoMercado(id) { const m = this.mercadosPorId.get(id); return m ? m.codigo : '?'; },
      // ---- campaña
      opcionesCampana(mercadoId) { return this.campanasPorMercado.get(mercadoId) || []; },
      // La taxonomía más usada para una campaña del glosario en el mercado.
      taxonomiaDe(campanaId, mercadoId) {
        const n = new Map();
        for (const r of this.filas) {
          if (r.mercado_id === mercadoId && r.campana_id === campanaId && r.campana_taxonomia) {
            n.set(r.campana_taxonomia, (n.get(r.campana_taxonomia) || 0) + 1);
          }
        }
        return [...n.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || null;
      },
      agregarCampana(mercadoId, tax) {
        const lista = this.campanasNuevas[mercadoId] || [];
        if (!lista.includes(tax)) this.campanasNuevas = { ...this.campanasNuevas, [mercadoId]: [...lista, tax] };
      },
      valorCampana(r) { return { campana_id: r.campana_id, campana_taxonomia: r.campana_taxonomia }; },
      // En la tabla: cambia la campaña y guarda como cualquier otra celda.
      cambiarCampana(r, v) {
        r.campana_id = v.campana_id;
        r.campana_taxonomia = v.campana_taxonomia;
        if (r.id) this.guardar(r);
      },

      // Las campañas de un mercado: las taxonomías que ya tienen sus compras, las
      // escritas en esta sesión y el glosario del mercado (lo que no esté ya como
      // taxonomía). Por nombre; la de parque fijo se preselecciona aparte.
      armarOpcionesCampana(mercadoId) {
        const glosario = new Map(this.campanas.filter(c => c.mercado_id === mercadoId).map(c => [c.id, c.nombre_unico]));
        const porTax = new Map();
        const conTax = new Set();
        const agregar = (tax, campanaId) => {
          if (porTax.has(tax)) return;
          porTax.set(tax, { clave: `T|${tax}`, campana_id: campanaId || null, taxonomia: tax,
            nombre: (campanaId && glosario.get(campanaId)) || nombreCorto(tax) });
          if (campanaId) conTax.add(campanaId);
        };
        for (const r of this.filas) if (r.mercado_id === mercadoId && r.campana_taxonomia) agregar(r.campana_taxonomia, r.campana_id);
        for (const tax of this.campanasNuevas[mercadoId] || []) agregar(tax, null);
        const solas = [...glosario.entries()].filter(([id]) => !conTax.has(id))
          .map(([id, nombre]) => ({ clave: `C|${id}`, campana_id: id, taxonomia: null, nombre }));
        return [...porTax.values(), ...solas].sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
      },
      // Solo los tipos de costo del mercado de la compra (COLOCACION, solo MLA).
      tiposCostoDe(r) { return tiposCostoPara(this.catalogos.tiposCosto, this.codigoMercado(r.mercado_id), r.tipo_costo); },
      campanaOoh(mercadoId) { const m = this.mercadosPorId.get(mercadoId); return m ? m.campana_ooh_id : null; },
      nombreCampana(r) {
        const c = this.campanasPorId.get(r.campana_id);
        return c ? c.nombre_unico : (r.campana_taxonomia || r.campana_texto || '');
      },
      obsNeta,

      proveedoresDe(r) {
        return this.proveedores.filter(p => p.mercado_id === r.mercado_id && (p.activo || p.id === r.proveedor_id));
      },
      formatosDe(mercadoId) { return [...(this.formatosPorMercado.get(mercadoId) || [])].sort(); },

      msgErr(r, campo) { return this.errores.get(r._k)[campo] || ''; },
      claseErr(r, campo) { return this.msgErr(r, campo) ? 'err' : ''; },

      // Formato que no existe en el mercado y que aún no se confirmó como nuevo.
      avisoFormato(r) {
        const f = normFormato(r.formato);
        if (!f || f === r._formatoNuevoOk) return null;
        const existentes = this.formatosPorMercado.get(r.mercado_id) || new Set();
        if (existentes.has(f)) return null;
        let parecido = null, mejor = Infinity;
        for (const e of existentes) {
          const d = distancia(compacto(f), compacto(e));
          if (d < mejor) { mejor = d; parecido = e; }
        }
        if (mejor > Math.max(2, Math.floor(compacto(f).length / 4))) parecido = null;
        return { formato: f, parecido };
      },
      usarFormato(r, valor) {
        r.formato = valor;
        if (r.id) this.guardar(r);
      },
      confirmarFormatoNuevo(r) {
        r._formatoNuevoOk = normFormato(r.formato);
        if (r.id) this.guardar(r);
      },

      // Recalcula lo derivado de lo que se acaba de editar. La tarifa neta solo
      // cambia si se edita bruta o descuento; el valor total, solo si es automático
      // (lo mueven tarifa, cantidad, tiempo, nro. semanas y tipo de costo).
      recalcular(r, desde) {
        if (desde === 'neta' && esNumero(r.tarifa_bruta) && esNumero(r.descuento)) {
          r.tarifa_neta = redondear(r.tarifa_bruta * (1 - r.descuento / 100), 2);
        }
        const f = formulaValorTotal(r);
        if (!r.valor_total_manual && f !== null) r.valor_total = f;
      },
      formula(r) { return formulaValorTotal(r); },
      textoFormula(r) { return porSemana(r) ? 'tarifa neta × cantidad × nro. semanas' : 'tarifa neta × cantidad'; },
      pistaFormula(r) {
        const f = this.formula(r);
        return `Valor escrito a mano. Fórmula (${this.textoFormula(r)}): ${f === null ? '—' : fmt.format(f)}`;
      },

      // Doble clic: el valor total pasa a manual y se edita.
      async aManual(r, selector) {
        if (this.soloLectura || r.valor_total_manual) return;
        r.valor_total_manual = true;
        await nextTick();
        const input = document.querySelector(selector.startsWith('#p-') ? `${PANEL_ACTIVO} ${selector}` : selector);
        if (input) { input.focus(); input.select(); }
      },
      // ↺: vuelve a automático, recalcula y (en la tabla) guarda.
      aAuto(r) {
        r.valor_total_manual = false;
        this.recalcular(r, 'total');
        if (r.id) this.guardar(r);
      },

      alSalirDeCelda(ev) {
        if (this.soloLectura) return;
        const tr = ev.target.closest('tr[data-k]');
        if (!tr) return;
        const r = this.filas.find(x => x._k === Number(tr.dataset.k));
        if (r) this.guardar(r);
      },

      async guardar(r) {
        if (this.soloLectura) return;

        const errs = this.errores.get(r._k);
        const n = Object.keys(errs).length;
        if (n) {
          r._estado = { clase: 'err', texto: n === 1 ? '1 error' : `${n} errores`, detalle: Object.values(errs).join(' · ') };
          return;
        }
        if (this.avisoFormato(r)) {
          r._estado = { clase: 'prop', texto: 'formato nuevo', detalle: 'Confirma el formato para guardar' };
          return;
        }

        const payload = aPayload(r);
        const snap = JSON.stringify(payload);
        if (snap === r._snap) {
          if (r._estado && r._estado.clase !== 'ok') r._estado = null;
          return;
        }
        if (r._guardando) { r._repetir = true; return; }

        r._guardando = true;
        r._estado = { clase: 'prop', texto: 'guardando…' };
        let error = null;

        try {
          const { mercado_id, codigo, ...cambios } = payload;
          const res = await sb.from('compras')
            .update({ ...cambios, actualizado_en: new Date().toISOString() })
            .eq('id', r.id)
            .select('id, campana_id, campana_taxonomia');
          error = res.error;
          if (!error && res.data.length === 0) error = { code: '42501' };
          // La base vincula la taxonomía con su campaña del glosario: se toma lo suyo.
          if (!error) Object.assign(r, { campana_id: res.data[0].campana_id, campana_taxonomia: res.data[0].campana_taxonomia });
        } catch (e) {
          error = e;
        }

        r._guardando = false;
        if (error) {
          r._estado = { clase: 'err', texto: 'error', detalle: mensajeError(error) };
          console.error('No se guardó la compra', r.codigo, error);
        } else {
          r._snap = JSON.stringify(aPayload(r));
          r.formato = payload.formato;
          r._formatoGuardado = payload.formato;
          const estado = { clase: 'ok', texto: 'guardado' };
          r._estado = estado;
          setTimeout(() => { if (r._estado === estado) r._estado = null; }, 2500);
        }

        if (r._repetir) { r._repetir = false; this.guardar(r); }
      },

      siguienteCodigoLocal(mercadoId) {
        let max = 0;
        for (const r of this.filas) {
          if (r.mercado_id !== mercadoId) continue;
          const n = parseInt(r.codigo, 10);
          if (Number.isFinite(n) && n > max) max = n;
        }
        return String(max + 1).padStart(3, '0');
      },

      // El código se pide a la base al guardar: otra persona pudo crear compras mientras tanto.
      async siguienteCodigoEnBase(mercadoId) {
        const filas = await traerTodo(() => sb.from('compras').select('codigo').eq('mercado_id', mercadoId).order('id'));
        let max = 0;
        for (const f of filas) { const n = parseInt(f.codigo, 10); if (Number.isFinite(n) && n > max) max = n; }
        return String(max + 1).padStart(3, '0');
      },

      // ---------------------------------------------------------------- Panel lateral

      async abrirPanel() {
        if (!this.puedeCrear) return;
        this.borrador = borradorNuevo(this.filtros.mercado, this.campanaOoh(this.filtros.mercado));
        // Parque fijo preseleccionada, con la taxonomía que ya usan sus compras.
        this.borrador.campana_taxonomia = this.taxonomiaDe(this.borrador.campana_id, this.filtros.mercado);
        await nextTick();
        const primero = document.querySelector(`${PANEL_ACTIVO} #p-cliente`);
        if (primero) primero.focus();
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

      async guardarBorrador() {
        const b = this.borrador;
        if (!b || b._guardando) return;
        b._intento = true;
        b._error = '';

        const campos = Object.keys(this.erroresBorrador);
        if (campos.length || this.avisoFormato(b)) {
          await nextTick();
          const primero = document.querySelector(
            ['.campo.err input', '.campo.err select', '.aviso-formato button'].map(x => `${PANEL_ACTIVO} ${x}`).join(', '));
          if (primero) primero.focus();
          return;
        }

        b._guardando = true;
        try {
          const payload = aPayload(b);
          payload.codigo = await this.siguienteCodigoEnBase(b.mercado_id);
          let res = await sb.from('compras').insert(payload).select(COLUMNAS_COMPRA).single();
          if (res.error && res.error.code === '23505') {
            payload.codigo = await this.siguienteCodigoEnBase(b.mercado_id);
            res = await sb.from('compras').insert(payload).select(COLUMNAS_COMPRA).single();
          }
          if (res.error) throw res.error;

          const r = desdeBase(res.data);
          r._snap = JSON.stringify(aPayload(r));
          r._estado = { clase: 'ok', texto: 'creada' };
          this.filas.push(r);
          this.borrador = null;

          await nextTick();
          const tr = document.querySelector(`#app tr[data-k="${r._k}"]`);
          if (tr) tr.scrollIntoView({ block: 'nearest' });
          const fila = this.filas.find(x => x._k === r._k);
          setTimeout(() => { if (fila && fila._estado && fila._estado.texto === 'creada') fila._estado = null; }, 4000);
        } catch (e) {
          console.error('No se creó la compra', e);
          b._error = 'No se pudo guardar: ' + mensajeError(e);
          b._guardando = false;
        }
      },

      // ---------------------------------------------------------------- Carga

      // Desde Alertas: la compra resaltada y en pantalla.
      async irAFilaPedida() {
        const p = filaPedida();
        if (!p.compra) return;
        const r = this.filas.find(x => x.id === p.compra);
        if (!r) { this.avisoPedido = 'Esa compra ya no está o no es de tus mercados.'; return; }
        this.resaltada = r._k;
        await nextTick();
        const tr = document.querySelector(`#app tr[data-k="${r._k}"]`);
        if (tr) tr.scrollIntoView({ block: 'center' });
      },

      async cargar() {
        try {
          const [mercados, mis, propios, campanas, proveedores, compras, catalogos] = await Promise.all([
            traerTodo(() => sb.from('mercados').select('id, codigo, nombre, activo, campana_ooh_id, moneda').order('id')),
            sb.rpc('fn_mis_mercados'),
            traerTodo(() => sb.from('usuario_mercados').select('mercado_id')
              .eq('usuario_id', this.usuario.id).order('mercado_id')),  // un ADMIN ve las de todos
            traerTodo(() => sb.from('campanas').select('id, mercado_id, nombre_unico').order('id')),
            traerTodo(() => sb.from('proveedores').select('id, mercado_id, nombre, activo').order('nombre')),
            traerTodo(() => sb.from('compras').select(COLUMNAS_COMPRA).order('mercado_id').order('codigo')),
            cargarCatalogos(),
          ]);
          this.catalogos = catalogos;
          if (mis.error) throw mis.error;

          this.mercados = mercados;
          this.misMercadoIds = (mis.data || []).map(x => (typeof x === 'object' ? Object.values(x)[0] : x)).map(Number);
          this.campanas = campanas;
          this.proveedores = proveedores;
          this.filas = compras.map(c => {
            const r = desdeBase(c);
            r._snap = JSON.stringify(aPayload(r));
            return r;
          });

          this.filtros.mercado = mercadoInicial(this.misMercados, propios.map(p => p.mercado_id));
          if (!this.misMercados.length) {
            this.errorCarga = 'Tu usuario no tiene mercados asignados. Pide a un administrador que te los asigne.';
          }
        } catch (e) {
          console.error(e);
          this.errorCarga = 'No se pudieron cargar las compras: ' + (e.message || e);
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
