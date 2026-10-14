// Pantalla Usuarios: solo ADMIN. Lista quién tiene acceso y da de alta,
// desactiva, reactiva o genera contraseñas temporales.
// Todo cambio pasa por la Edge Function gestionar-usuarios: ella tiene la llave
// secreta para Auth (crear y bloquear logins); esta página nunca la ve.
// Leer es directo: un ADMIN lee usuarios y usuario_mercados por RLS.

// Roles que se ofrecen, en este orden. PLANNING sigue en el enum por
// compatibilidad, pero ya no se da de alta.
const ROLES = [
  { valor: 'ZB',        etiqueta: 'Equipo ZB', ayuda: 'captura en sus mercados' },
  { valor: 'AGENCIA',   etiqueta: 'Agencia',   ayuda: 'portal: enlaces de sus mercados' },
  { valor: 'PROVEEDOR', etiqueta: 'Proveedor', ayuda: 'portal: reporte y evidencias' },
  { valor: 'LECTURA',   etiqueta: 'Lectura',   ayuda: 'consulta sin captura' },
  { valor: 'ADMIN',     etiqueta: 'Admin',     ayuda: 'todo, en todos los mercados' },
];
const ETIQUETA_ROL = { ...Object.fromEntries(ROLES.map(r => [r.valor, r.etiqueta])), PLANNING: 'Planning (antiguo)' };

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
      panel: null,
      copiada: false,
    }),

    computed: {
      mercadosPorId() { return new Map(this.mercados.map(m => [m.id, m])); },
      proveedoresPorId() { return new Map(this.proveedores.map(p => [p.id, p])); },
      opcionesMercado() { return this.mercados.map(m => ({ valor: m.id, etiqueta: `${m.codigo} · ${m.nombre}` })); },
      proveedoresDelMercado() {
        const p = this.panel;
        return p ? this.proveedores.filter(x => x.mercado_id === p.mercadoProveedor && x.activo) : [];
      },

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

      // ---- panel de alta
      erroresPanel() {
        const p = this.panel;
        if (!p || p.clave) return {};
        const e = {};
        const correo = p.correo.trim().toLowerCase();
        if (!RE_CORREO.test(correo)) e.correo = 'Formato de correo no válido';
        else if (this.usuarios.some(u => u.correo.toLowerCase() === correo)) e.correo = 'Ya hay un usuario con ese correo';
        if (!p.nombre.trim()) e.nombre = 'Obligatorio';
        if (!p.rol) e.rol = 'Elige el rol';
        else if (p.rol === 'PROVEEDOR') { if (!p.proveedor_id) e.proveedor_id = 'Obligatorio para un proveedor'; }
        else if (p.rol !== 'ADMIN' && !p.mercados.length) e.mercados = 'Elige al menos un mercado';
        return e;
      },
      hayErrores() { return Object.keys(this.erroresPanel).length > 0; },
    },

    watch: {
      'panel.mercadoProveedor'() { if (this.panel && !this.panel.clave) this.panel.proveedor_id = null; },
    },

    methods: {
      etiquetaRol(r) { return ETIQUETA_ROL[r] || r; },
      codigoMercado(id) { const m = this.mercadosPorId.get(id); return m ? m.codigo : '?'; },
      alcance(u) {
        if (u.rol === 'PROVEEDOR') {
          const p = this.proveedoresPorId.get(u.proveedor_id);
          return p ? `${p.nombre} (${this.codigoMercado(p.mercado_id)})` : '';
        }
        const ids = this.mercadosDe.get(u.id) || [];
        if (u.rol === 'ADMIN' && !ids.length) return 'Todos';
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

      reemplazar(datos) {
        const i = this.usuarios.findIndex(x => x.id === datos.id);
        const fila = { ...datos, _ocupado: false, _error: '' };
        if (i >= 0) this.usuarios.splice(i, 1, fila);
        else this.usuarios.push(fila);
      },

      // ---------------------------------------------------------------- Panel

      abrirNuevo() {
        this.panel = {
          clave: null, correo: '', nombre: '', rol: null,
          mercadoProveedor: (this.mercados.find(m => m.codigo === 'MCO') || this.mercados[0] || {}).id,
          proveedor_id: null, mercados: [],
          tocados: {}, intento: false, guardando: false, error: '',
        };
        nextTick(() => {
          const el = document.querySelector(`${PANEL_ACTIVO} #p-correo`);
          if (el) el.focus();
        });
      },
      tocar(campo) { if (this.panel) this.panel.tocados[campo] = true; },
      errPanel(campo) {
        const p = this.panel;
        if (!p || !(p.intento || p.tocados[campo])) return '';
        return this.erroresPanel[campo] || '';
      },

      async crear() {
        const p = this.panel;
        if (!p || p.guardando) return;
        p.intento = true;
        p.error = '';
        if (this.hayErrores) return;
        p.guardando = true;
        try {
          const esProv = p.rol === 'PROVEEDOR';
          const r = await llamar({
            accion: 'crear',
            correo: p.correo.trim().toLowerCase(),
            nombre: p.nombre.trim(),
            rol: p.rol,
            proveedor_id: esProv ? p.proveedor_id : null,
            mercados: esProv ? [] : p.mercados,
          });
          this.reemplazar(r.usuario);
          if (!esProv && p.mercados.length) this.mercadosDe.set(r.usuario.id, [...p.mercados]);
          this.mostrarClave(r.usuario, r.clave, 'Usuario creado');
        } catch (e) {
          p.error = 'No se creó: ' + e.message;
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

      // ---------------------------------------------------------------- Carga

      async cargar() {
        try {
          const [usuarios, um, mercados, proveedores] = await Promise.all([
            traerTodo(() => sb.from('usuarios')
              .select('id, correo, nombre, rol, proveedor_id, activo, auth_user_id, debe_cambiar_clave').order('correo')),
            traerTodo(() => sb.from('usuario_mercados').select('usuario_id, mercado_id').order('usuario_id')),
            traerTodo(() => sb.from('mercados').select('id, codigo, nombre').order('id')),
            traerTodo(() => sb.from('proveedores').select('id, mercado_id, nombre, activo').order('nombre')),
          ]);
          this.usuarios = usuarios.map(u => ({ ...u, _ocupado: false, _error: '' }));
          const m = new Map();
          for (const x of um) {
            if (!m.has(x.usuario_id)) m.set(x.usuario_id, []);
            m.get(x.usuario_id).push(x.mercado_id);
          }
          this.mercadosDe = m;
          this.mercados = mercados;
          this.proveedores = proveedores;
        } catch (e) {
          console.error(e);
          this.errorCarga = 'No se pudieron cargar los usuarios: ' + (e.message || e);
        } finally {
          this.cargando = false;
        }
      },
    },

    mounted() {
      this.cargar();
      document.addEventListener('keydown', (ev) => {
        if (ev.key !== 'Escape') return;
        if (this.panel && !document.querySelector('.multi.abierto')) this.cerrarPanel();
        else this.confirmar = null;
      });
    },
  }).mount('#app');
}

iniciar();
