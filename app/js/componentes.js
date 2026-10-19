// Piezas compartidas por las pantallas con tabla editable (Compras, Materiales).
// Van después de comun.js y antes del script de cada pantalla.

const { createApp, nextTick } = Vue;

// Espejo de los enums de la base (oasis_v2_esquema.sql). Si cambian allá, cambian aquí.
const ENUMS = {
  tipo_compra: ['DIRECTO', 'BONIFICADO', 'FACTURABLE', 'PAGO ANTICIPADO'],
  medio:       ['OOH', 'DOOH'],
  tipo_costo:  ['EXHIBICION', 'PRODUCCION', 'IMPUESTOS', 'COLOCACION'],
};

// El panel que se está cerrando sigue en el DOM durante su animación de salida.
const PANEL_ACTIVO = '.panel-fondo:not(.panel-leave-active)';

const MESES = ['Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun', 'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'];

const fmt = new Intl.NumberFormat('es-CO', { maximumFractionDigits: 2 });
const fmtPesos = new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 });

// Cada cifra con la moneda de su mercado (mercados.moneda). Nunca se suman
// montos de mercados distintos: sus monedas no se pueden sumar.
const _formatosMoneda = new Map();
function fmtMoneda(moneda) {
  const m = moneda || 'COP';
  if (!_formatosMoneda.has(m)) {
    _formatosMoneda.set(m, new Intl.NumberFormat('es-CO', { style: 'currency', currency: m, maximumFractionDigits: 0 }));
  }
  return _formatosMoneda.get(m);
}
// "$ 632 M" (millones) o "$ 85 mil", para etiquetas de gráficos. El símbolo $
// es el mismo en COP, CLP, ARS, MXN y UYU: la moneda la dice el encabezado.
function montoCorto(x) {
  const n = x / 1e6;
  const cifra = Math.abs(n) >= 1
    ? `${n.toLocaleString('es-CO', { maximumFractionDigits: Math.abs(n) < 100 ? 1 : 0 })} M`
    : `${Math.round(x / 1e3).toLocaleString('es-CO')} mil`;
  return `$ ${cifra}`;
}

// "2026-10-05" -> "5 oct 2026"
function fechaHumana(iso) {
  if (!iso) return '';
  const [y, m, d] = iso.split('-');
  return `${Number(d)} ${MESES[Number(m) - 1].toLowerCase()} ${y}`;
}

// Fecha de hoy en la hora local, AAAA-MM-DD.
function hoyIso() {
  const h = new Date();
  return `${h.getFullYear()}-${String(h.getMonth() + 1).padStart(2, '0')}-${String(h.getDate()).padStart(2, '0')}`;
}

// Baja un CSV. `columnas` es [[título, (fila) => valor], …].
// Punto y coma: Excel en español lo abre en columnas; Sheets lo detecta solo.
function descargarCsv(nombre, columnas, filas) {
  const celda = (v) => {
    const t = v === null || v === undefined ? '' : String(v);
    return /[";\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t;
  };
  const lineas = [columnas.map(([t]) => t).join(';')];
  for (const r of filas) lineas.push(columnas.map(([, f]) => celda(f(r))).join(';'));
  // BOM: sin él, Excel muestra mal las tildes.
  const blob = new Blob(['\uFEFF' + lineas.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = nombre;
  a.click();
  URL.revokeObjectURL(a.href);
}

// Fila pedida por URL desde Alertas (?compra=12 o ?material=34). Se lee una vez
// y se limpia la URL, para que recargar no vuelva a abrir el panel.
function filaPedida() {
  const q = new URLSearchParams(window.location.search);
  const pedido = {
    compra: q.has('compra') ? Number(q.get('compra')) : null,
    material: q.has('material') ? Number(q.get('material')) : null,
    partir: q.get('partir') === '1',
  };
  if (q.toString()) history.replaceState(null, '', window.location.pathname);
  return pedido;
}

const redondear = (x, d) => Math.round(x * 10 ** d) / 10 ** d;
const esNumero = (x) => typeof x === 'number' && Number.isFinite(x);

// Trae todas las filas de una consulta, de a 1000 (límite por defecto de la API).
async function traerTodo(consulta) {
  const filas = [];
  for (let desde = 0; ; desde += 1000) {
    const { data, error } = await consulta().range(desde, desde + 999);
    if (error) throw error;
    filas.push(...data);
    if (data.length < 1000) return filas;
  }
}

// ------------------------------------------------------------------ Selección múltiple
// Desplegable con casillas. Vacío = "Todos".
const SeleccionMultiple = {
  props: { modelValue: { type: Array, default: () => [] }, opciones: Array, id: String },
  emits: ['update:modelValue'],
  // `sel` es una copia local: dos clics seguidos no se pisan esperando al padre.
  data() { return { abierto: false, sel: [...this.modelValue] }; },
  watch: { modelValue(v) { this.sel = [...v]; } },
  computed: {
    resumen() {
      const n = this.sel.length;
      if (n === 0) return 'Todos';
      if (n === 1) {
        const o = this.opciones.find(x => x.valor === this.sel[0]);
        return o ? o.etiqueta : '1 seleccionado';
      }
      return `${n} seleccionados`;
    },
  },
  methods: {
    alternar(valor) {
      const s = new Set(this.sel);
      s.has(valor) ? s.delete(valor) : s.add(valor);
      // Conserva el orden de las opciones
      this.sel = this.opciones.map(o => o.valor).filter(v => s.has(v));
      this.$emit('update:modelValue', this.sel);
    },
    fuera(ev) { if (this.abierto && !this.$el.contains(ev.target)) this.abierto = false; },
    tecla(ev) { if (ev.key === 'Escape') this.abierto = false; },
  },
  mounted() {
    document.addEventListener('pointerdown', this.fuera);
    this.$el.addEventListener('keydown', this.tecla);
  },
  unmounted() { document.removeEventListener('pointerdown', this.fuera); },
  template: `
    <div class="multi" :class="{ abierto, activo: modelValue.length }">
      <button type="button" class="multi-boton" :id="id" @click="abierto = !abierto"
              :aria-expanded="abierto">{{ resumen }}</button>
      <div v-if="abierto" class="multi-lista">
        <label v-for="o in opciones" :key="o.valor" class="multi-op">
          <input type="checkbox" :checked="sel.includes(o.valor)" @change="alternar(o.valor)">
          <span>{{ o.etiqueta }}</span>
        </label>
        <div v-if="!opciones.length" class="multi-vacio">Sin opciones</div>
        <button v-if="modelValue.length" type="button" class="multi-limpiar"
                @click="$emit('update:modelValue', [])">Limpiar · ver todos</button>
      </div>
    </div>`,
};
