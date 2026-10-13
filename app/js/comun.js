// Cliente de Supabase, sesión y barra superior. Lo comparten todas las páginas.

const sb = window.supabase.createClient(
  window.OASIS_CONFIG.supabaseUrl,
  window.OASIS_CONFIG.supabaseKey
);

const ROLES_INTERNOS = ['PLANNING', 'ZB', 'LECTURA', 'ADMIN'];
const ROLES_EXTERNOS = ['PROVEEDOR', 'AGENCIA'];
const esExterno = (usuario) => ROLES_EXTERNOS.includes(usuario.rol);

// Fila de `usuarios` del login actual, o null.
// RLS solo deja leer la fila propia y solo si el usuario está activo, así que
// "sin fila" e "inactivo" se ven igual desde aquí: los dos quedan sin acceso.
async function usuarioActual() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return { session: null, usuario: null };

  const { data, error } = await sb
    .from('usuarios')
    .select('id, correo, nombre, rol, activo, proveedor_id')
    .eq('auth_user_id', session.user.id)
    .maybeSingle();

  if (error) throw error;
  const conocido = data && [...ROLES_INTERNOS, ...ROLES_EXTERNOS].includes(data.rol);
  const usuario = conocido && data.activo ? data : null;
  return { session, usuario };
}

// Adónde va cada rol al entrar. Es solo comodidad: lo que protege los datos es
// RLS, no esta redirección.
function paginaDeInicio(usuario) {
  return esExterno(usuario) ? 'portal.html' : 'compras.html';
}

function irA(pagina) {
  window.location.replace(pagina);
  return new Promise(() => {}); // detiene la página mientras redirige
}

// Para páginas internas: sin sesión o sin acceso, vuelve al login; un externo
// va al portal.
async function requerirAcceso() {
  const { session, usuario } = await usuarioActual();
  if (!session || !usuario) return irA('index.html');
  if (esExterno(usuario)) return irA('portal.html');
  return usuario;
}

// Para el portal: solo PROVEEDOR y AGENCIA; un interno va a su pantalla.
async function requerirAccesoExterno() {
  const { session, usuario } = await usuarioActual();
  if (!session || !usuario) return irA('index.html');
  if (!esExterno(usuario)) return irA(paginaDeInicio(usuario));
  return usuario;
}

async function salir() {
  await sb.auth.signOut();
  window.location.replace('index.html');
}

const NAVEGACION = [
  { clave: 'compras',    texto: 'Compras',    href: 'compras.html' },
  { clave: 'materiales', texto: 'Materiales', href: 'materiales.html' },
  { clave: 'inversion',  texto: 'Inversión',  href: 'inversion.html' },
  { clave: 'alertas',    texto: 'Alertas',    href: 'alertas.html' },
];

function pintarBarra(contenedor, usuario, activa) {
  const nav = NAVEGACION.map(n => {
    const clase = n.clave === activa ? ' class="activo"' : '';
    const cuenta = n.clave === 'alertas' ? '<span class="cuenta-alertas mono"></span>' : '';
    return `<a href="${n.href}"${clase}>${n.texto}${cuenta}</a>`;
  }).join('');

  contenedor.innerHTML = `
    <a class="marca" href="compras.html">OASIS<span>.</span></a>
    <nav>${nav}</nav>
    <div class="usuario">
      <div>
        <div class="nombre"></div>
        <div class="rol"></div>
      </div>
      <button class="salir" type="button">Salir</button>
    </div>`;
  contenedor.querySelector('.nombre').textContent = usuario.nombre;
  contenedor.querySelector('.rol').textContent = usuario.rol;
  contenedor.querySelector('.salir').addEventListener('click', salir);
  actualizarAlertasBarra(leerMercadoActivo());
}

// ------------------------------------------------------------------ Mercado activo
// El último mercado elegido en cualquier pantalla, por código ('' = todos).
// Es una comodidad de este navegador: si no hay, cada pantalla usa su defecto.

const CLAVE_MERCADO = 'oasis.mercado';

function leerMercadoActivo() {
  try { return localStorage.getItem(CLAVE_MERCADO); } catch { return null; }
}
function guardarMercadoActivo(codigo) {
  try { localStorage.setItem(CLAVE_MERCADO, codigo || ''); } catch { /* sin almacenamiento */ }
  actualizarAlertasBarra(codigo || '');
}

// Mercado con el que abre una pantalla: el de la URL (?mercado=MCO, lo usan los
// enlaces de Alertas), luego el último elegido, luego el propio del usuario.
// Devuelve el id, o '' para "Todos".
function mercadoInicial(misMercados, propiosIds) {
  if (misMercados.length === 1) return misMercados[0].id;
  const url = new URLSearchParams(window.location.search).get('mercado');
  const pedido = url !== null ? url : leerMercadoActivo();
  if (pedido === '') return '';
  const m = misMercados.find(x => x.codigo === pedido);
  if (m) return m.id;
  const propio = propiosIds.find(id => misMercados.some(x => x.id === id));
  return propio || '';
}

// Número junto a "Alertas": el total de v_alertas del mercado activo.
let turnoAlertas = 0;
async function actualizarAlertasBarra(codigo) {
  const el = document.querySelector('.topbar .cuenta-alertas');
  if (!el) return;
  const turno = ++turnoAlertas;   // descarta respuestas que llegan tarde
  let q = sb.from('v_alertas').select('alerta', { count: 'exact', head: true });
  if (codigo) q = q.eq('mercado', codigo);
  const { count, error } = await q;
  if (turno !== turnoAlertas) return;
  if (error) console.error('No se pudo contar las alertas', error);
  el.textContent = !error && count ? count.toLocaleString('es-CO') : '';
  el.title = el.textContent ? `${el.textContent} alertas${codigo ? ' en ' + codigo : ''}` : '';
}
