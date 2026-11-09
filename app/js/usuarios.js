// Pantalla Usuarios: solo ADMIN. Lista quién tiene acceso y da de alta, edita,
// desactiva, reactiva o genera contraseñas temporales. Abajo, las tasas de cambio.
// Todo cambio de usuarios pasa por la Edge Function gestionar-usuarios: ella tiene
// la llave secreta para Auth (crear y bloquear logins); esta página nunca la ve.
// Leer es directo: un ADMIN lee usuarios y usuario_mercados por RLS.

// Roles que se ofrecen, en este orden. PLANNING sigue en el enum por
// compatibilidad, pero ya no se da de alta.
const ROLES = [
  { valor: 'ZB',        etiqueta: 'Equipo ZB', ayuda: 'captura en sus mercados' },
  { valor: 'AGENCIA',   etiqueta: 'Agencia',   ayuda: 'portal: enlaces de sus mercados' },
  { valor: 'PROVEEDOR', etiqueta: 'Proveedor', ayuda: 'portal: reporte y evidencias' },
  { valor: 'LECTURA',   etiqueta: 'Lectura',   ayuda: 'consulta sin captura, todos los mercados' },
  { valor: 'CLIENTE',   etiqueta: 'Cliente',   ayuda: 'solo el dashboard de sus mercados' },
  { valor: 'ADMIN',     etiqueta: 'Admin',     ayuda: 'todo, en todos los mercados' },
];
const ETIQUETA_ROL = { ...Object.fromEntries(ROLES.map(r => [r.valor, r.etiqueta])), PLANNING: 'Planning (antiguo)' };

// Igual que en la base (sql/usuarios_edicion.sql): Admin y Lectura ven todos los
// mercados y no se les eligen; Proveedor lleva su proveedor; los demás, al
// menos un mercado.
const VEN_TODOS = ['ADMIN', 'LECTURA'];
const usaMercados = (rol) => !!rol && rol !== 'PROVEEDOR' && !VEN_TODOS.includes(rol);

// Diferencia con la tasa vigente a partir de la cual se pide confirmar.
const TOPE_DIFERENCIA = 0.2;

// Lee una tasa escrita con coma o punto decimal. Devuelve { valor, ambiguo } o null.
//   '3.695,04' y '3,695.04': hay los dos signos; el último es el decimal.
//   '3695,04', '40,58', '17.93': un solo signo seguido de 1, 2 o 4+ cifras: decimal.
//   '1.234.567' o '1,234,567': el signo repetido es de miles.
//   '3.695' o '1,585' (un solo signo seguido de exactamente 3 cifras) es ambiguo:
//   puede ser 3695 o 3,695. Se elige la lectura más cercana a la tasa vigente del
//   mercado (referencia); sin referencia, miles, como se escribe en LATAM. La
//   pantalla muestra siempre cómo lo leyó antes de guardar.
function interpretarTasa(texto, referencia) {
  const t = String(texto || '').replace(/\s/g, '');
  if (!/^[0-9.,]+$/.test(t) || !/[0-9]/.test(t)) return null;
  const puntos = (t.match(/\./g) || []).length;
  const comas = (t.match(/,/g) || []).length;
  let limpio;
  let ambiguo = false;
  if (puntos && comas) {
    const dec = t.lastIndexOf('.') > t.lastIndexOf(',') ? '.' : ',';
    const miles = dec === '.' ? ',' : '.';
    if (t.split(dec).length > 2) return null;          // el decimal aparece una sola vez
    limpio = t.split(miles).join('').replace(dec, '.');
  } else if (puntos + comas === 0) {
    limpio = t;
  } else {
    const sep = puntos ? '.' : ',';
    const partes = t.split(sep);
    if (partes.length > 2) {
      limpio = partes.join('');                        // separador de miles repetido
    } else if (partes[1].length === 3 && /^[1-9]\d{0,2}$/.test(partes[0])) {
      ambiguo = true;
      const miles = Number(partes.join(''));
      const decimal = Number(partes[0] + '.' + partes[1]);
      if (referencia > 0) {
        const lejos = (v) => Math.abs(Math.log(v / referencia));
        limpio = String(lejos(decimal) < lejos(miles) ? decimal : miles);
      } else {
        limpio = String(miles);
      }
    } else {
      limpio = partes.join('.');
    }
  }
  const n = Number(limpio);
  return Number.isFinite(n) && n > 0 ? { valor: n, ambiguo } : null;
}
const hoyISO = () => new Date().toLocaleDateString('en-CA');   // aaaa-mm-dd local

// Igual que fn_admin_crear_usuario en la base.
const RE_CORREO = /^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/;

// Mensaje de un error de la Edge Function (viene en el cuerpo JSON).
async function mensajeFuncion(error) {
  if (!error) return 'Error desconocido';
  try {
    const cuerpo = await error.context.json();
    if (cuerpo && cuerpo.error) return cuerpo.error;
  } catch { /* no era respuesta de la función */ }
  return error.message || String(error);
}

async function llamar(cuerpo) {
  const { data, error } = await sb.functions.invoke('gestionar-usuarios', { body: cuerpo });
  if (error) throw new Error(await mensajeFuncion(error));
  return data;
}

async function iniciar() {
  const yo = await requerirAcceso();
  if (yo.rol !== 'ADMIN') return irA('compras.html');
  pintarBarra(document.getElementById('barra'), yo, 'usuarios');

  createApp({
    components: { SeleccionMultiple },

    data: () => ({
      ROLES,
      yo,
      cargando: true,
      errorCarga: '',
      usuarios: [],
      mercadosDe: new Map(),   // usuario_id -> [mercado_id]
      mercados: [],
      proveedores: [],
      filtros: { buscar: '', rol: '', estado: '' },
      confirmar: null,         // { id, accion, pregunta }
      panel: null,             // { modo: 'nuevo' | 'editar', ... } o { clave, ... }
      copiada: false,
      // Tasas de cambio (sql/dashboard.sql): moneda local por 1 USD, para la vista LATAM del dashboard.
      tasas: [],
      tasaNueva: { mercado_id: null, valor: '', vigente_desde: hoyISO(), confirmar: false },
      tasaError: '',
      tasaGuardando: false,
      tasaBorrar: null,        // id de la tasa que se está confirmando
      tasaEditar: null,        // { id, mercado_id, valor, vigente_desde, confirmar, error, guardando }
    }),

    computed: {
      mercadosPorId() { return new Map(this.mercados.map(m => [m.id, m])); },
      proveedoresPorId() { return new Map(this.proveedores.map(p => [p.id, p])); },
      opcionesMercado() { return this.mercados.map(m => ({ valor: m.id, etiqueta: `${m.codigo} · ${m.nombre}` })); },
      proveedoresDelMercado() {
        const p = this.panel;
        if (!p) return [];
        // Al editar, el proveedor actual aparece aunque se haya desactivado (unificación).
        return this.proveedores.filter(x => x.mercado_id === p.mercadoProveedor
                                            && (x.activo || x.id === (p.original || {}).proveedor_id));
      },
      adminsActivos() { return this.usuarios.filter(u => u.rol === 'ADMIN' && u.activo).length; },

      visibles() {
        const q = this.filtros.buscar.trim().toLowerCase();
        return this.usuarios.filter(u => {
          if (this.filtros.rol && u.rol !== this.filtros.rol) return false;
          if (this.filtros.estado === 'activos' && !u.activo) return false;
          if (this.filtros.estado === 'inactivos' && u.activo) return false;
          if (q && !u.correo.toLowerCase().includes(q) && !u.nombre.toLowerCase().includes(q)) return false;
          return true;
        });
      },

      // ---- panel de alta y edición
      rolesPanel() {
        const p = this.panel;
        // Un usuario antiguo con PLANNING se puede editar sin cambiarle el rol.
        return p && p.original && p.original.rol === 'PLANNING'
          ? [...ROLES, { valor: 'PLANNING', etiqueta: 'Planning (antiguo)', ayuda: 'ya no se asigna' }]
          : ROLES;
      },
      esYo() { return !!(this.panel && this.panel.modo === 'editar' && this.panel.id === this.yo.id); },
      erroresPanel() {
        const p = this.panel;
        if (!p || p.clave) return {};
        const e = {};
        if (p.modo === 'nuevo') {
          const correo = p.correo.trim().toLowerCase();
          if (!RE_CORREO.test(correo)) e.correo = 'Formato de correo no válido';
          else if (this.usuarios.some(u => u.correo.toLowerCase() === correo)) e.correo = 'Ya hay un usuario con ese correo';
        }
        if (!p.nombre.trim()) e.nombre = 'Obligatorio';
        const o = p.original;
        if (!p.rol) e.rol = 'Elige el rol';
        else if (o && p.rol !== o.rol && this.esYo) e.rol = 'No puedes cambiar tu propio rol: pídeselo a otro Admin';
        else if (o && o.rol === 'ADMIN' && o.activo && p.rol !== 'ADMIN' && this.adminsActivos <= 1) {
          e.rol = 'Es el último Admin activo: OASIS no puede quedar sin uno';
        }
        if (p.rol === 'PROVEEDOR') { if (!p.proveedor_id) e.proveedor_id = 'Obligatorio para un proveedor'; }
        else if (usaMercados(p.rol) && !p.mercados.length) e.mercados = 'Elige al menos un mercado';
        return e;
      },
      hayErrores() { return Object.keys(this.erroresPanel).length > 0; },
      // Al editar: ¿cambia lo que puede ver? (mismo criterio que la base). Lista legible.
      cambiosAcceso() {
        const p = this.panel;
        if (!p || p.modo !== 'editar') return [];
        const o = p.original;
        const c = [];
        if (p.rol !== o.rol) c.push(`rol: ${this.etiquetaRol(o.rol)} → ${this.etiquetaRol(p.rol)}`);
        if (p.rol === 'PROVEEDOR' && p.proveedor_id !== o.proveedor_id) {
          const n = (id) => (this.proveedoresPorId.get(id) || {}).nombre || '—';
          c.push(`proveedor: ${n(o.proveedor_id)} → ${n(p.proveedor_id)}`);
        }
        if (usaMercados(p.rol)) {
          const antes = [...o.mercados].sort((a, b) => a - b).join(',');
          const ahora = [...p.mercados].sort((a, b) => a - b).join(',');
          if (antes !== ahora) {
            const cods = (ids) => ids.map(id => this.codigoMercado(id)).join(', ') || 'ninguno';
            c.push(`mercados: ${cods(o.mercados)} → ${cods(p.mercados)}`);
          }
        }
        return c;
      },
      hayCambios() {
        const p = this.panel;
        return !!p && p.modo === 'editar' && (this.cambiosAcceso.length > 0 || p.nombre.trim() !== p.original.nombre);
      },

      // ---- tasas: la vigente de cada mercado es la de fecha más reciente que no sea futura
      vigentePorMercado() {
        const hoy = hoyISO();
        const vigente = new Map();
        for (const t of this.tasas) {
          if (t.vigente_desde > hoy) continue;
          const v = vigente.get(t.mercado_id);
          if (!v || t.vigente_desde > v.vigente_desde) vigente.set(t.mercado_id, t);
        }
        return vigente;
      },
      tasasVista() {
        const hoy = hoyISO();
        const vigente = this.vigentePorMercado;
        const nombres = new Map(this.usuarios.map(u => [u.id, u.nombre]));
        return [...this.tasas]
          .sort((a, b) => this.codigoMercado(a.mercado_id).localeCompare(this.codigoMercado(b.mercado_id))
                          || b.vigente_desde.localeCompare(a.vigente_desde))
          .map(t => ({
            ...t,
            estado: t.vigente_desde > hoy ? 'futura' : vigente.get(t.mercado_id) === t ? 'vigente' : 'anterior',
            autor: t.actualizado_por ? (nombres.get(t.actualizado_por) || `#${t.actualizado_por}`) : 'carga inicial',
            noBorrar: this.motivoNoBorrar(t),
          }));
      },
      // Mercados con datos: los que ya cargó cargar_oasis.py (ultima_carga) o que ya
      // tienen tasa. Hoy MCO, MLA, MLC, MLM y MLU; uno nuevo aparece con su primera carga.
      mercadosTasa() {
        const conTasa = new Set(this.tasas.map(t => t.mercado_id));
        return this.mercados.filter(m => m.ultima_carga || conTasa.has(m.id));
      },
      // Cómo se leyó lo escrito en «Agregar tasa», y cuánto se aleja de la vigente.
      lecturaNueva() { return this.lecturaTasa(this.tasaNueva.mercado_id, this.tasaNueva.valor); },
      lecturaEditar() {
        const e = this.tasaEditar;
        return e ? this.lecturaTasa(e.mercado_id, e.valor) : null;
      },
    },

    methods: {
      etiquetaRol(r) { return ETIQUETA_ROL[r] || r; },
      codigoMercado(id) { const m = this.mercadosPorId.get(id); return m ? m.codigo : '?'; },
      alcance(u) {
        if (u.rol === 'PROVEEDOR') {
          const p = this.proveedoresPorId.get(u.proveedor_id);
          return p ? `${p.nombre} (${this.codigoMercado(p.mercado_id)})` : '';
        }
        if (VEN_TODOS.includes(u.rol)) return 'Todos';
        const ids = this.mercadosDe.get(u.id) || [];
        return ids.map(id => this.codigoMercado(id)).join(', ') || 'sin mercados';
      },

      // ---------------------------------------------------------------- Acciones por fila

      pedir(u, accion) {
        const preguntas = {
          desactivar: `¿Desactivar a ${u.nombre}? Pierde el acceso en el acto.`,
          reactivar: `¿Reactivar a ${u.nombre}?`,
          nueva_clave: u.auth_user_id
            ? `¿Nueva contraseña temporal para ${u.nombre}? La actual deja de servir.`
            : `¿Crear el login de ${u.nombre} con una contraseña temporal?`,
        };
        u._error = '';
        u._aviso = '';
        this.confirmar = { id: u.id, accion, pregunta: preguntas[accion] };
      },

      async ejecutar(u, accion) {
        u._ocupado = true;
        u._error = '';
        try {
          const r = await llamar({ accion, usuario_id: u.id });
          this.reemplazar(r.usuario);
          this.confirmar = null;
          if (r.clave) {
            this.mostrarClave(r.usuario, r.clave,
              accion === 'nueva_clave' && u.auth_user_id ? 'Nueva contraseña' : 'Login creado');
          }
        } catch (e) {
          u._error = e.message;
        } finally {
          u._ocupado = false;
        }
      },

      reemplazar(datos, aviso = '') {
        const i = this.usuarios.findIndex(x => x.id === datos.id);
        const fila = { ...datos, _ocupado: false, _error: '', _aviso: aviso };
        if (i >= 0) this.usuarios.splice(i, 1, fila);
        else this.usuarios.push(fila);
      },

      // ---------------------------------------------------------------- Panel

      abrirNuevo() {
        this.panel = {
          modo: 'nuevo', clave: null, correo: '', nombre: '', rol: null,
          mercadoProveedor: (this.mercados.find(m => m.codigo === 'MCO') || this.mercados[0] || {}).id,
          proveedor_id: null, mercados: [], original: null,
          tocados: {}, intento: false, guardando: false, error: '',
        };
        nextTick(() => {
          const el = document.querySelector(`${PANEL_ACTIVO} #p-correo`);
          if (el) el.focus();
        });
      },

      // El mismo panel, con los datos cargados. El correo no se edita.
      abrirEditar(u) {
        this.confirmar = null;
        const mercados = usaMercados(u.rol) ? [...(this.mercadosDe.get(u.id) || [])] : [];
        const prov = this.proveedoresPorId.get(u.proveedor_id);
        this.panel = {
          modo: 'editar', clave: null, id: u.id, correo: u.correo, nombre: u.nombre, rol: u.rol,
          mercadoProveedor: prov ? prov.mercado_id
            : (this.mercados.find(m => m.codigo === 'MCO') || this.mercados[0] || {}).id,
          proveedor_id: u.proveedor_id, mercados,
          original: { rol: u.rol, nombre: u.nombre, activo: u.activo, proveedor_id: u.proveedor_id, mercados: [...mercados] },
          tocados: {}, intento: false, guardando: false, error: '',
        };
        nextTick(() => {
          const el = document.querySelector(`${PANEL_ACTIVO} #p-nombre`);
          if (el) el.focus();
        });
      },
      tocar(campo) { if (this.panel) this.panel.tocados[campo] = true; },
      errPanel(campo) {
        const p = this.panel;
        if (!p || !(p.intento || p.tocados[campo])) return '';
        return this.erroresPanel[campo] || '';
      },
      // Otro mercado de proveedor: el proveedor elegido ya no vale.
      cambiarMercadoProveedor() { if (this.panel) this.panel.proveedor_id = null; },

      guardar() { return this.panel && this.panel.modo === 'editar' ? this.editar() : this.crear(); },

      async crear() {
        const p = this.panel;
        if (!p || p.guardando) return;
        p.intento = true;
        p.error = '';
        if (this.hayErrores) return;
        p.guardando = true;
        try {
          const esProv = p.rol === 'PROVEEDOR';
          const mercados = usaMercados(p.rol) ? p.mercados : [];
          const r = await llamar({
            accion: 'crear',
            correo: p.correo.trim().toLowerCase(),
            nombre: p.nombre.trim(),
            rol: p.rol,
            proveedor_id: esProv ? p.proveedor_id : null,
            mercados,
          });
          this.reemplazar(r.usuario);
          this.mercadosDe.set(r.usuario.id, [...mercados]);
          this.mostrarClave(r.usuario, r.clave, 'Usuario creado');
        } catch (e) {
          p.error = 'No se creó: ' + e.message;
          p.guardando = false;
        }
      },

      async editar() {
        const p = this.panel;
        if (!p || p.guardando) return;
        p.intento = true;
        p.error = '';
        if (this.hayErrores) return;
        if (!this.hayCambios) { this.cerrarPanel(); return; }
        p.guardando = true;
        try {
          const r = await llamar({
            accion: 'editar',
            usuario_id: p.id,
            nombre: p.nombre.trim(),
            rol: p.rol,
            proveedor_id: p.rol === 'PROVEEDOR' ? p.proveedor_id : null,
            mercados: usaMercados(p.rol) ? p.mercados : [],
          });
          const n = r.sesiones_cerradas || 0;
          const aviso = 'Guardado' + (r.acceso_cambio
            ? (n ? ` · se cerraron ${n} ${n === 1 ? 'sesión' : 'sesiones'}` : ' · no tenía sesiones abiertas')
            : '');
          this.mercadosDe.set(p.id, [...(r.mercados || [])]);
          this.reemplazar(r.usuario, aviso);
          this.panel = null;
        } catch (e) {
          p.error = 'No se guardó: ' + e.message;
          p.guardando = false;
        }
      },

      // La contraseña vive solo en este panel; al cerrarlo se olvida.
      mostrarClave(usuario, clave, titulo) {
        this.copiada = false;
        this.panel = { clave, titulo, correo: usuario.correo, nombre: usuario.nombre };
      },
      async copiar() {
        try {
          await navigator.clipboard.writeText(this.panel.clave);
          this.copiada = true;
        } catch {
          this.panel.error = 'El navegador no dejó copiar; selecciónala y cópiala a mano.';
        }
      },
      cerrarPanel() {
        if (this.panel && this.panel.guardando) return;
        this.panel = null;
        this.copiada = false;
      },

      // ---------------------------------------------------------------- Tasas de cambio

      formatoTasa(v) { return Number(v).toLocaleString('es-CO', { minimumFractionDigits: 2, maximumFractionDigits: 4 }); },
      fechaCorta(iso) { return iso ? iso.slice(0, 10).split('-').reverse().join('/') : ''; },
      monedaDe(mercadoId) { return (this.mercadosPorId.get(mercadoId) || {}).moneda || ''; },
      vigenteDe(mercadoId) { return this.vigentePorMercado.get(mercadoId) || null; },

      // { valor, texto, ambiguo, diferencia (fracción o null), grande } o null si no se entiende.
      lecturaTasa(mercadoId, texto) {
        if (!String(texto || '').trim()) return null;
        const vig = mercadoId ? this.vigenteDe(mercadoId) : null;
        const ref = vig ? Number(vig.valor_por_usd) : null;
        const l = interpretarTasa(texto, ref);
        if (!l) return { error: 'No es un número mayor que 0' };
        const diferencia = ref ? l.valor / ref - 1 : null;
        return {
          valor: l.valor,
          ambiguo: l.ambiguo,
          texto: `${this.formatoTasa(l.valor)} ${this.monedaDe(mercadoId) || 'moneda local'} por 1 USD`,
          diferencia,
          grande: diferencia !== null && Math.abs(diferencia) > TOPE_DIFERENCIA,
        };
      },
      textoDiferencia(d) {
        const pct = Math.round(Math.abs(d) * 100);
        return `${pct} % ${d > 0 ? 'más' : 'menos'} que la vigente`;
      },

      // No se borra la única tasa de un mercado, ni la que rige hoy si no queda otra
      // que rija (la base lo vuelve a revisar: fn_tasas_cambio_minimo).
      motivoNoBorrar(t) {
        const hoy = hoyISO();
        const delMercado = this.tasas.filter(x => x.mercado_id === t.mercado_id && x.id !== t.id);
        if (!delMercado.length) return 'Es la única tasa de este mercado: corrígela con Editar';
        if (t.vigente_desde <= hoy && !delMercado.some(x => x.vigente_desde <= hoy)) {
          return 'Es la única que rige hoy: el mercado quedaría sin tasa';
        }
        return '';
      },

      async cargarTasas() {
        const { data, error } = await sb.from('tasas_cambio')
          .select('id, mercado_id, moneda, valor_por_usd, vigente_desde, actualizado_por, actualizado_en')
          .order('vigente_desde', { ascending: false });
        if (error) throw error;
        this.tasas = data;
      },

      // Cambiar una tasa es agregar otra con su fecha de vigencia: así queda la historia.
      async agregarTasa() {
        const n = this.tasaNueva;
        this.tasaError = '';
        if (!n.mercado_id) { this.tasaError = 'Elige el mercado'; return; }
        const l = this.lecturaNueva;
        if (!l || l.error) { this.tasaError = 'La tasa tiene que ser un número mayor que 0'; return; }
        if (!n.vigente_desde) { this.tasaError = 'Elige desde cuándo rige'; return; }
        if (l.grande && !n.confirmar) { n.confirmar = true; return; }   // primero confirmar
        const m = this.mercadosPorId.get(n.mercado_id);
        this.tasaGuardando = true;
        try {
          const { error } = await sb.from('tasas_cambio')
            .insert({ mercado_id: n.mercado_id, moneda: m.moneda, valor_por_usd: l.valor, vigente_desde: n.vigente_desde });
          if (error) {
            n.confirmar = false;
            this.tasaError = error.code === '23505'
              ? `Ya hay una tasa de ${m.codigo} que rige desde esa fecha: corrígela con Editar`
              : 'No se guardó: ' + error.message;
            return;
          }
          this.tasaNueva = { mercado_id: n.mercado_id, valor: '', vigente_desde: hoyISO(), confirmar: false };
          await this.cargarTasas();
        } finally {
          this.tasaGuardando = false;
        }
      },

      // Editar corrige una tasa mal escrita (valor o fecha). Queda en auditoría.
      abrirEditarTasa(t) {
        this.tasaBorrar = null;
        this.tasaError = '';
        this.tasaEditar = {
          id: t.id, mercado_id: t.mercado_id,
          valor: this.formatoTasa(t.valor_por_usd), vigente_desde: t.vigente_desde,
          confirmar: false, error: '', guardando: false,
        };
      },
      async guardarTasa() {
        const e = this.tasaEditar;
        if (!e || e.guardando) return;
        e.error = '';
        const l = this.lecturaEditar;
        if (!l || l.error) { e.error = 'La tasa tiene que ser un número mayor que 0'; return; }
        if (!e.vigente_desde) { e.error = 'Elige desde cuándo rige'; return; }
        if (l.grande && !e.confirmar) { e.confirmar = true; return; }
        e.guardando = true;
        try {
          const { data, error } = await sb.from('tasas_cambio')
            .update({ valor_por_usd: l.valor, vigente_desde: e.vigente_desde })
            .eq('id', e.id).select('id');
          if (error || !data || !data.length) {
            e.confirmar = false;
            e.error = !error ? 'No se guardó (sin permiso)'
              : error.code === '23505' ? 'Ya hay otra tasa de este mercado que rige desde esa fecha'
              : 'No se guardó: ' + error.message;
            return;
          }
          this.tasaEditar = null;
          await this.cargarTasas();
        } finally {
          if (this.tasaEditar) this.tasaEditar.guardando = false;
        }
      },

      async borrarTasa(t) {
        this.tasaError = '';
        const { data, error } = await sb.from('tasas_cambio').delete().eq('id', t.id).select('id');
        this.tasaBorrar = null;
        if (error) { this.tasaError = 'No se borró: ' + error.message; return; }
        if (!data || !data.length) { this.tasaError = 'No se borró (sin permiso)'; return; }
        await this.cargarTasas();
      },

      // ---------------------------------------------------------------- Carga

      async cargar() {
        try {
          const [usuarios, um, mercados, proveedores] = await Promise.all([
            traerTodo(() => sb.from('usuarios')
              .select('id, correo, nombre, rol, proveedor_id, activo, auth_user_id, debe_cambiar_clave').order('correo')),
            traerTodo(() => sb.from('usuario_mercados').select('usuario_id, mercado_id').order('usuario_id')),
            traerTodo(() => sb.from('mercados').select('id, codigo, nombre, moneda, ultima_carga').order('id')),
            traerTodo(() => sb.from('proveedores').select('id, mercado_id, nombre, activo').order('nombre')),
          ]);
          this.usuarios = usuarios.map(u => ({ ...u, _ocupado: false, _error: '', _aviso: '' }));
          const m = new Map();
          for (const x of um) {
            if (!m.has(x.usuario_id)) m.set(x.usuario_id, []);
            m.get(x.usuario_id).push(x.mercado_id);
          }
          this.mercadosDe = m;
          this.mercados = mercados;
          this.proveedores = proveedores;
          await this.cargarTasas();
        } catch (e) {
          console.error(e);
          this.errorCarga = 'No se pudieron cargar los usuarios: ' + (e.message || e);
        } finally {
          this.cargando = false;
        }
      },
    },

    watch: {
      // Si cambia lo escrito, la confirmación de «diferencia grande» se vuelve a pedir.
      'tasaNueva.valor'() { this.tasaNueva.confirmar = false; },
      'tasaNueva.mercado_id'() { this.tasaNueva.confirmar = false; },
      'tasaEditar.valor'() { if (this.tasaEditar) this.tasaEditar.confirmar = false; },
    },

    mounted() {
      this.cargar();
      document.addEventListener('keydown', (ev) => {
        if (ev.key !== 'Escape') return;
        if (this.panel && !document.querySelector('.multi.abierto')) this.cerrarPanel();
        else { this.confirmar = null; this.tasaEditar = null; this.tasaBorrar = null; }
      });
    },
  }).mount('#app');
}

iniciar();
