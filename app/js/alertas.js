// Pantalla de Alertas: lo que falta o está mal en la captura, desde v_alertas.
// Solo lectura, salvo la card de posibles duplicados (PLANNING, ZB, ADMIN).
// Cada referencia abre su fila en Compras o Materiales; la
// versión (con o sin inputs) la decide esa pantalla según el rol.

// Orden de las cards y a dónde lleva cada referencia.
const TIPOS_ALERTA = [
  { alerta: 'material fuera del periodo de su compra', titulo: 'Fuera de periodo', destino: 'partir',
    explica: 'Materiales con fechas fuera del periodo de su compra. Al abrirlos, el panel queda listo para partirlos en un tramo por compra.' },
  { alerta: 'material sin fechas', titulo: 'Sin fechas', destino: 'material',
    explica: 'Materiales sin fecha de inicio ni fin. No entran al reparto de inversión.' },
  { alerta: 'material sin sub campaña', titulo: 'Sin sub campaña', destino: 'material',
    explica: 'Materiales sin sub campaña: su inversión no se puede atribuir.' },
  { alerta: 'compra sin materiales', titulo: 'Compra sin materiales', destino: 'compra',
    explica: 'Compras sin ningún material: su valor no se reparte en ningún día.' },
  { alerta: 'sub campaña de otro mercado', titulo: 'Sub campaña de otro mercado', destino: 'material',
    explica: 'La sub campaña del material no es del glosario del mercado de su compra.' },
  // De la carga de varios mercados (sql/mercados.sql): todo entra y queda aquí.
  { alerta: 'campaña sin taxonomía', titulo: 'Campaña sin taxonomía', destino: 'taxonomia',
    explica: 'La columna CAMPAÑA del Flow no tiene formato de taxonomía. Escribe la taxonomía correcta: corrige estas compras y las próximas cargas la traducen solas.' },
  { alerta: 'campaña fuera del glosario', titulo: 'Campaña fuera del glosario', destino: 'glosario',
    explica: 'Estas campañas tienen el formato correcto, pero no están en el glosario oficial de campañas del país. No afecta la inversión. Lo resuelve quien administra el glosario de ZetaBé: agregando la campaña al glosario, o corrigiendo la campaña de la compra si está mal escrita.' },
  { alerta: 'compra incompleta', titulo: 'Compra incompleta', destino: 'compra',
    explica: 'Le falta un dato que el Flow dejó vacío. Sin fechas, la compra no reparte su valor.' },
  { alerta: 'compra sin tipo de costo', titulo: 'Sin tipo de costo', destino: 'compra',
    explica: 'Sin tipo de costo no hay fórmula: vale lo que diga el Flow (0 si no dice nada).' },
  { alerta: 'valor fuera de catálogo', titulo: 'Valor fuera de catálogo', destino: 'compra',
    explica: 'El Flow trae un valor que OASIS no tiene en su lista. La compra entró con ese campo vacío; elige el valor en Compras.' },
  { alerta: 'compra sin valor', titulo: 'Compra sin valor', destino: 'compra',
    explica: 'Ni tarifa ni valor total. Las bonificadas no salen aquí: valen 0 a propósito.' },
  { alerta: 'formatos parecidos', titulo: 'Formatos parecidos', destino: 'ninguno',
    explica: 'Formatos del mismo mercado que se escriben distinto (plural, tildes, una letra). Si son el mismo, unifícalos en el Flow.' },
];

const FORM_VACIO = Object.freeze({ valor: '', ocupado: false, error: '', ok: '' });

// Cómo reconoció OASIS una campaña que no está tal cual en el glosario
// (v_campanas_sin_glosario, sql/campanas_familia.sql).
const REGLA_TEXTO = { FAMILIA: 'por familia', 'AÑO': 'por año', EQUIVALENCIA: 'por equivalencia manual' };
const plural = (n, uno, varios) => `${n.toLocaleString('es-CO')} ${n === 1 ? uno : varios}`;

// Estas no llevan card propia: la card «Posibles duplicados» ya las muestra con sus botones.
const ALERTAS_EN_OTRA_CARD = ['proveedores por confirmar'];

// Posibles duplicados: confianza → clase de pill (DISENO.md, pills de estado).
const CLASE_CONFIANZA = { ALTA: 'ok', MEDIA: 'prop', BAJA: 'err' };
const ORDEN_CONFIANZA = { ALTA: 0, MEDIA: 1, BAJA: 2 };
const INVISIBLES = /[\u200b-\u200d\ufeff]/;

// Cuota de Storage del plan gratis de Supabase (evidencias). Ver CLAUDE.md.
const CUOTA_STORAGE = 1024 * 1024 * 1024;     // 1 GB
const AVISO_STORAGE = 700 * 1024 * 1024;      // avisar desde 700 MB
const GRACIA_HUERFANO = 10 * 60 * 1000;       // una subida en curso deja el archivo antes que la fila

// Mensaje legible de un error de la Edge Function o de un RPC.
async function mensajeDe(error) {
  if (!error) return 'Error desconocido';
  try {
    const cuerpo = await error.context.json();
    if (cuerpo && cuerpo.error) return cuerpo.error;
  } catch { /* no era respuesta de la función */ }
  return error.message || String(error);
}

async function iniciar() {
  const usuario = await requerirAcceso();
  pintarBarra(document.getElementById('barra'), usuario, 'alertas');

  createApp({
    data: () => ({
      usuario,
      cargando: true,
      errorCarga: '',
      usoStorage: null,         // bytes del bucket evidencias (fn_uso_storage)
      huerfanas: [],            // archivos del bucket sin fila en evidencias
      mercados: [],
      misMercadoIds: [],
      alertas: [],
      ubicaciones: new Map(),   // compra_id -> ubicación
      filtros: { mercado: '' },
      duplicados: [],
      porConfirmar: [],         // alias provisionales (campanas_alias.por_confirmar)
      pcMensaje: '',
      analizando: false,
      dup: { mensaje: '', clase: '' },
      taxonomias: {},           // texto del Flow -> { valor, ocupado, error, ok }
      sinGlosario: [],          // v_campanas_sin_glosario: regla con que OASIS reconoce cada campaña
      equivalencias: [],        // campanas_equivalencias (escribe solo ADMIN)
      glosario: [],             // nombres del glosario, para sugerir la familia
      equiv: {},                // mercado|taxonomía -> { valor, ocupado, error }
      eqMensaje: '',
      CLASE_CONFIANZA,
      REGLA_TEXTO,
    }),

    computed: {
      misMercados() { return this.mercados.filter(m => this.misMercadoIds.includes(m.id)); },
      mercadosPorId() { return new Map(this.mercados.map(m => [m.id, m])); },
      codigoFiltro() { const m = this.mercadosPorId.get(this.filtros.mercado); return m ? m.codigo : ''; },
      eyebrow() {
        const m = this.mercadosPorId.get(this.filtros.mercado);
        return m ? `${m.codigo} · ${m.nombre}` : 'Todos mis mercados';
      },

      // Una card por tipo con al menos un caso. Un tipo que la vista agregue
      // después y no esté en la lista sale al final con su nombre tal cual.
      grupos() {
        const k = this.codigoFiltro;
        const porTipo = new Map();
        for (const a of this.alertas) {
          if (k && a.mercado !== k) continue;
          if (ALERTAS_EN_OTRA_CARD.includes(a.alerta)) continue;
          if (!porTipo.has(a.alerta)) porTipo.set(a.alerta, []);
          porTipo.get(a.alerta).push(a);
        }
        // La card del glosario se queda aunque no haya alertas, si hay
        // campañas reconocidas o equivalencias que mostrar.
        if (!porTipo.has('campaña fuera del glosario') && (this.reconocidas.length || this.equivalenciasVisibles.length)) {
          porTipo.set('campaña fuera del glosario', []);
        }
        const conocidos = TIPOS_ALERTA.map(t => t.alerta);
        const extra = [...porTipo.keys()].filter(t => !conocidos.includes(t))
          .map(t => ({ alerta: t, titulo: t, destino: 'material', explica: '' }));
        return [...TIPOS_ALERTA, ...extra]
          .filter(t => porTipo.has(t.alerta))
          .map(t => ({
            ...t,
            casos: porTipo.get(t.alerta).sort((a, b) =>
              a.mercado.localeCompare(b.mercado) || a.referencia.localeCompare(b.referencia)),
          }));
      },
      puedeEscribir() { return ['PLANNING', 'ZB', 'ADMIN'].includes(this.usuario.rol); },
      // Proveedores primero (se unifican antes que los soportes), luego por confianza.
      porConfirmarVisibles() {
        return this.porConfirmar.filter(a => !this.filtros.mercado || a.mercado_id === this.filtros.mercado);
      },
      duplicadosVisibles() {
        const id = this.filtros.mercado;
        return this.duplicados
          .filter(d => !id || d.mercado_id === id)
          .sort((a, b) => (a.tipo === b.tipo ? 0 : a.tipo === 'PROVEEDOR' ? -1 : 1)
            || ORDEN_CONFIANZA[a.confianza] - ORDEN_CONFIANZA[b.confianza] || a.id - b.id);
      },
      // Es de todo el proyecto, no de un mercado: no depende del filtro.
      alertaStorage() {
        if (this.usoStorage === null || this.usoStorage < AVISO_STORAGE) return null;
        const pct = Math.floor((this.usoStorage / CUOTA_STORAGE) * 100);
        return {
          texto: `Almacenamiento de evidencias al ${pct} % del plan gratis`,
          detalle: `${(this.usoStorage / 1024 / 1024).toLocaleString('es-CO', { maximumFractionDigits: 0 })} MB de 1.024 MB. `
            + 'Al llegar al tope, Storage deja de aceptar archivos: pasar al plan Pro o depurar videos.',
          clase: pct >= 90 ? 'error' : 'aviso',
        };
      },
      alertaHuerfanas() {
        const viejas = this.huerfanas.filter(h => Date.now() - new Date(h.subido_en).getTime() > GRACIA_HUERFANO);
        if (!viejas.length) return null;
        const bytes = viejas.reduce((s, h) => s + Number(h.tamano_bytes || 0), 0);
        const n = viejas.length;
        return {
          texto: `${n} ${n === 1 ? 'archivo' : 'archivos'} en el bucket sin fila en evidencias`,
          detalle: `Ocupan ${(bytes / 1024 / 1024).toLocaleString('es-CO', { maximumFractionDigits: 1 })} MB de la cuota y nadie los ve. `
            + 'Un ADMIN los borra en Supabase → Storage → evidencias.',
          rutas: viejas.slice(0, 5).map(h => h.ruta),
          mas: Math.max(0, n - 5),
        };
      },
      total() { return this.grupos.reduce((s, g) => s + g.casos.length, 0); },
      // Campañas del mercado que OASIS reconoce sin estar tal cual en el glosario.
      reconocidas() {
        return this.sinGlosario
          .filter(x => x.regla && (!this.filtros.mercado || x.mercado_id === this.filtros.mercado))
          .sort((a, b) => b.compras - a.compras || a.taxonomia.localeCompare(b.taxonomia));
      },
      comprasReconocidas() { return this.reconocidas.reduce((s, x) => s + x.compras, 0); },
      equivalenciasVisibles() {
        return this.equivalencias.filter(e => !this.filtros.mercado || e.mercado_id === this.filtros.mercado);
      },
      glosarioDelMercado() {
        return this.glosario.filter(c => c.mercado_id === this.filtros.mercado).map(c => c.nombre_unico).sort();
      },
      esAdmin() { return this.usuario.rol === 'ADMIN'; },
      puedeCorregir() { return ['PLANNING', 'ZB', 'ADMIN'].includes(this.usuario.rol); },
    },

    watch: {
      'filtros.mercado'(id) {
        guardarMercadoActivo(id ? this.mercadosPorId.get(id).codigo : '');
        this.dup = { mensaje: '', clase: '' };
        this.prepararTaxonomias();
      },
      alertas() { this.prepararTaxonomias(); },
    },

    methods: {
      enlace(grupo, a) {
        const q = new URLSearchParams({ mercado: a.mercado });
        // "compra sin materiales" no tiene material: siempre va a Compras.
        if (grupo.destino === 'compra' || !a.material_id) {
          q.set('compra', a.compra_id);
          return `compras.html?${q}`;
        }
        q.set('material', a.material_id);
        if (grupo.destino === 'partir') q.set('partir', '1');
        return `materiales.html?${q}`;
      },
      ubicacion(a) { return this.ubicaciones.get(a.compra_id) || ''; },

      // ---------------------------------------------------------- Taxonomía
      // «Campaña sin taxonomía» y «campaña fuera del glosario» se agrupan por
      // campaña (el detalle de la alerta): una fila por campaña, no por compra.
      gruposTaxonomia(casos) {
        const m = new Map();
        for (const a of casos) {
          const t = a.detalle || '(vacío)';
          if (!m.has(t)) m.set(t, { texto: a.detalle, casos: [] });
          m.get(t).casos.push(a);
        }
        return [...m.values()].sort((x, y) => y.casos.length - x.casos.length);
      },
      // Un formulario por texto del Flow. Se preparan fuera del pintado (crear
      // objetos reactivos mientras Vue pinta lo hace volver a pintar).
      prepararTaxonomias() {
        const k = this.codigoFiltro;
        for (const a of this.alertas) {
          if (a.alerta === 'campaña fuera del glosario' && a.mercado === k && a.detalle) {
            const ke = `${a.mercado_id}|${a.detalle}`;
            if (!this.equiv[ke]) this.equiv[ke] = { valor: '', ocupado: false, error: '' };
            continue;
          }
          if (a.alerta !== 'campaña sin taxonomía' || a.mercado !== k || !a.detalle) continue;
          const clave = `${k}|${a.detalle}`;
          if (!this.taxonomias[clave]) this.taxonomias[clave] = { valor: `${k}_ML_`, ocupado: false, error: '', ok: '' };
        }
      },
      formTax(texto) { return this.taxonomias[`${this.codigoFiltro}|${texto}`] || FORM_VACIO; },
      async guardarTaxonomia(texto) {
        const f = this.formTax(texto);
        f.error = '';
        f.ok = '';
        const tax = f.valor.trim().toUpperCase();
        if (!new RegExp(`^${this.codigoFiltro}_(ML|MP)_[A-Z0-9-]+(_[A-Z0-9-]+){3,}$`).test(tax)) {
          f.error = `Formato: ${this.codigoFiltro}_ML_TIPO_ALL_NOMBRE_X (o _MP_ para Mercado Pago), en mayúsculas y sin espacios`;
          return;
        }
        f.ocupado = true;
        const { data, error } = await sb.rpc('fn_asignar_taxonomia', {
          p_mercado_id: this.filtros.mercado, p_texto: texto, p_taxonomia: tax,
        });
        f.ocupado = false;
        if (error) { f.error = 'No se guardó: ' + await mensajeDe(error); return; }
        f.ok = `${data} ${data === 1 ? 'compra corregida' : 'compras corregidas'}`;
        await this.recargarAlertas();
      },
      // Título de la card: «2 campañas · 52 compras» en las agrupadas por campaña.
      cuentaDe(g) {
        if (g.destino !== 'glosario') return g.casos.length.toLocaleString('es-CO');
        const campanas = new Set(g.casos.map(a => a.detalle)).size;
        return `${plural(campanas, 'campaña', 'campañas')} · ${plural(g.casos.length, 'compra', 'compras')}`;
      },
      plural,

      // ------------------------------------------------- Equivalencias manuales
      // Para lo que las reglas no cubren: el nombre corto de la campaña del Flow
      // equivale a una familia del glosario (CYBERMONDAY → CM). Solo ADMIN; la
      // base normaliza (CMDUR → CM), valida y deja auditoría.
      piezasTax(tax) {
        const p = (tax || '').split('_');
        return { bu: p[1] || 'ML', corto: p.slice(4, -1).join('_') };
      },
      formEq(tax) { return this.equiv[`${this.filtros.mercado}|${tax}`] || FORM_VACIO; },
      async guardarEquivalencia(tax) {
        const f = this.formEq(tax);
        const { bu, corto } = this.piezasTax(tax);
        f.error = '';
        this.eqMensaje = '';
        if (!f.valor.trim()) { f.error = 'Escribe la campaña o familia del glosario (por ejemplo CM o CMDUR)'; return; }
        f.ocupado = true;
        const { data, error } = await sb.from('campanas_equivalencias')
          .insert({ mercado_id: this.filtros.mercado, bu, texto: corto, familia: f.valor.trim() })
          .select('id, mercado_id, bu, texto, familia, creado_en').single();
        f.ocupado = false;
        if (error) { f.error = 'No se guardó: ' + await mensajeDe(error); return; }
        f.valor = '';
        this.eqMensaje = `${data.texto} (${data.bu}) equivale ahora a la familia ${data.familia}.`;
        await this.cargarGlosario();
        await this.recargarAlertas();
      },
      async borrarEquivalencia(e) {
        if (!confirm(`¿Quitar la equivalencia ${e.texto} → ${e.familia}? Sus compras vuelven a la alerta.`)) return;
        const { data, error } = await sb.from('campanas_equivalencias').delete().eq('id', e.id).select('id');
        if (error || !data || !data.length) { this.eqMensaje = 'No se pudo quitar: ' + (error ? await mensajeDe(error) : 'sin permiso'); return; }
        this.eqMensaje = `Se quitó ${e.texto} → ${e.familia}.`;
        await this.cargarGlosario();
        await this.recargarAlertas();
      },
      async cargarGlosario() {
        const [sinGlosario, equivalencias] = await Promise.all([
          traerTodo(() => sb.from('v_campanas_sin_glosario')
            .select('mercado_id, mercado, bu, taxonomia, nombre_corto, regla, familia, glosario, compras').order('taxonomia')),
          traerTodo(() => sb.from('campanas_equivalencias')
            .select('id, mercado_id, bu, texto, familia, creado_en').order('texto')),
        ]);
        this.sinGlosario = sinGlosario;
        this.equivalencias = equivalencias;
      },

      async recargarAlertas() {
        this.alertas = await traerTodo(() => sb.from('v_alertas')
          .select('alerta, referencia, mercado, compra_id, material_id, mercado_id, detalle')
          .order('alerta').order('mercado').order('referencia'));
        actualizarAlertasBarra(this.codigoFiltro);
      },

      // ------------------------------------------------- Taxonomías por confirmar
      // Alias provisionales: la carga los usa para no frenarse; aquí se confirma
      // la taxonomía buena y fn_asignar_taxonomia re-apunta lo ya cargado.
      fechaCorta(iso) { return (iso || '').slice(0, 10).split('-').reverse().join('/'); },
      async cargarPorConfirmar() {
        const filas = await traerTodo(() => sb.from('campanas_alias')
          .select('id, mercado_id, bu, texto_flow, taxonomia, nota, creado_en')
          .eq('por_confirmar', true).order('id'));
        this.porConfirmar = filas.map(a => ({ ...a, _valor: a.taxonomia, _ocupado: false, _error: '' }));
      },
      async confirmarTaxonomia(a) {
        a._error = '';
        const mk = this.codigoMercado(a.mercado_id);
        const tax = a._valor.trim().toUpperCase();
        if (!new RegExp(`^${mk}_${a.bu}_[A-Z0-9-]+(_[A-Z0-9-]+){3,}$`).test(tax)) {
          a._error = `Formato: ${mk}_${a.bu}_TIPO_AUDIENCIA_NOMBRE_X, en mayúsculas y sin espacios`;
          return;
        }
        a._ocupado = true;
        const { data, error } = await sb.rpc('fn_asignar_taxonomia', {
          p_mercado_id: a.mercado_id, p_texto: a.texto_flow, p_taxonomia: tax, p_bu: a.bu,
        });
        a._ocupado = false;
        if (error) { a._error = 'No se guardó: ' + await mensajeDe(error); return; }
        this.porConfirmar = this.porConfirmar.filter(x => x.id !== a.id);
        this.pcMensaje = `${a.texto_flow} (${a.bu}): quedó ${tax}. ${data} ${data === 1 ? 'compra re-apuntada' : 'compras re-apuntadas'}.`;
        await this.recargarAlertas();
      },

      // ---------------------------------------------------------- Duplicados
      codigoMercado(id) { const m = this.mercadosPorId.get(id); return m ? m.codigo : ''; },
      invisible(t) { return INVISIBLES.test(t); },
      totalCompras(d) { return d.valores.reduce((s, v) => s + (v.compras || 0), 0); },
      detalle(d, v) {
        const n = `${v.compras} ${v.compras === 1 ? 'compra' : 'compras'}`;
        if (d.tipo === 'PROVEEDOR') return n;
        return [v.proveedor, v.ciudad, (v.formatos || []).join(', '), n].filter(Boolean).join(' · ');
      },

      async cargarDuplicados() {
        const filas = await traerTodo(() => sb.from('duplicados_propuestos')
          .select('id, mercado_id, tipo, valores, canonico, confianza, razon')
          .eq('estado', 'PENDIENTE').order('id'));
        this.duplicados = filas.map(d => ({ ...d, _canonico: d.canonico, _ocupado: false, _error: '' }));
      },

      // Proveedores y soportes en paralelo: son dos llamadas a la función.
      async analizar() {
        const mercado = this.filtros.mercado;
        const codigo = this.codigoFiltro;
        this.analizando = true;
        this.dup = { mensaje: '', clase: '' };
        try {
          const resultados = await Promise.all(['PROVEEDOR', 'SOPORTE'].map(async tipo => {
            const { data, error } = await sb.functions.invoke('detectar-duplicados', {
              body: { mercado_id: mercado, tipo },
            });
            if (error) throw new Error(`${tipo === 'PROVEEDOR' ? 'Proveedores' : 'Soportes'}: ${await mensajeDe(error)}`);
            return data;
          }));
          await this.cargarDuplicados();
          const [p, s] = resultados.map(r => r.encontrados);
          this.dup = {
            clase: p + s ? 'ok' : '',
            mensaje: p + s
              ? `${codigo}: ${p} ${p === 1 ? 'grupo' : 'grupos'} de proveedores y ${s} de soportes por revisar.`
              : `${codigo}: no se encontraron duplicados nuevos.`,
          };
        } catch (e) {
          console.error(e);
          this.dup = { clase: 'error', mensaje: 'No se pudo analizar. ' + (e.message || e) };
          await this.cargarDuplicados().catch(() => {});
        } finally {
          this.analizando = false;
        }
      },

      async unificar(d) {
        d._ocupado = true;
        d._error = '';
        const { data, error } = await sb.rpc('fn_unificar_duplicado', { p_id: d.id, p_canonico: d._canonico });
        if (error) {
          d._ocupado = false;
          d._error = 'No se pudo unificar: ' + await mensajeDe(error);
          return;
        }
        this.duplicados = this.duplicados.filter(x => x.id !== d.id);
        this.dup = { clase: 'ok', mensaje: `Unificado en «${d._canonico.trim()}»: ${data} ${data === 1 ? 'compra cambió' : 'compras cambiaron'}.` };
        // Las ubicaciones de las alertas pueden haber cambiado.
        const compras = await traerTodo(() => sb.from('compras').select('id, ubicacion').order('id')).catch(() => null);
        if (compras) this.ubicaciones = new Map(compras.map(c => [c.id, c.ubicacion]));
      },

      async rechazar(d) {
        d._ocupado = true;
        d._error = '';
        const { error } = await sb.rpc('fn_rechazar_duplicado', { p_id: d.id });
        if (error) {
          d._ocupado = false;
          d._error = 'No se pudo marcar: ' + await mensajeDe(error);
          return;
        }
        this.duplicados = this.duplicados.filter(x => x.id !== d.id);
      },

      async cargar() {
        try {
          const [mercados, mis, propios, alertas, compras, uso, huerfanas] = await Promise.all([
            traerTodo(() => sb.from('mercados').select('id, codigo, nombre').order('id')),
            sb.rpc('fn_mis_mercados'),
            traerTodo(() => sb.from('usuario_mercados').select('mercado_id').eq('usuario_id', this.usuario.id).order('mercado_id')),
            traerTodo(() => sb.from('v_alertas').select('alerta, referencia, mercado, compra_id, material_id, mercado_id, detalle')
              .order('alerta').order('mercado').order('referencia')),
            traerTodo(() => sb.from('compras').select('id, ubicacion').order('id')),
            sb.rpc('fn_uso_storage'),
            sb.rpc('fn_evidencias_huerfanas'),
          ]);
          if (mis.error) throw mis.error;
          if (uso.error) console.error('No se pudo leer el uso de Storage', uso.error);
          else this.usoStorage = Number(uso.data);
          if (huerfanas.error) console.error('No se pudo revisar el bucket', huerfanas.error);
          else this.huerfanas = huerfanas.data || [];
          this.mercados = mercados;
          this.misMercadoIds = (mis.data || []).map(x => (typeof x === 'object' ? Object.values(x)[0] : x)).map(Number);
          this.alertas = alertas;
          this.ubicaciones = new Map(compras.map(c => [c.id, c.ubicacion]));
          await this.cargarDuplicados();
          await this.cargarPorConfirmar();
          await this.cargarGlosario();
          if (this.esAdmin) {
            this.glosario = await traerTodo(() => sb.from('campanas').select('mercado_id, nombre_unico').order('id'));
          }
          // Alertas es por mercado: sin «Todos». Sin mercado recordado, el propio o el primero.
          const inicial = mercadoInicial(this.misMercados, propios.map(p => p.mercado_id));
          this.filtros.mercado = inicial || (this.misMercados[0] || {}).id || '';
          if (!this.misMercados.length) {
            this.errorCarga = 'Tu usuario no tiene mercados asignados. Pide a un administrador que te los asigne.';
          }
        } catch (e) {
          console.error(e);
          this.errorCarga = 'No se pudieron cargar las alertas: ' + (e.message || e);
        } finally {
          this.cargando = false;
        }
      },
    },

    mounted() { this.cargar(); },
  }).mount('#app');
}

iniciar();
