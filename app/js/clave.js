// Crear o cambiar la contraseña. Se llega aquí por dos caminos:
//   * con una contraseña temporal (usuarios.debe_cambiar_clave = true): todas
//     las pantallas mandan aquí hasta que la persona la cambie;
//   * por el enlace del correo de invitación: el enlace trae la sesión y la
//     persona crea su contraseña (misma marca debe_cambiar_clave).
// Al guardarla, la marca se apaga y sigue a su inicio según el rol.

const $ = (id) => document.getElementById(id);
const MIN_CLAVE = 10;

// Cómo se llegó: lo guarda clave.html antes de que Supabase limpie la dirección.
const LLEGADA = window.OASIS_LLEGADA || { hash: '', search: '' };
const enHash = new URLSearchParams(LLEGADA.hash.replace(/^#/, ''));
const enQuery = new URLSearchParams(LLEGADA.search);
const dato = (k) => enHash.get(k) || enQuery.get(k);
const ERROR_ENLACE = dato('error_code') || dato('error');
const TOKEN_HASH = enQuery.get('token_hash');
const ES_INVITACION = dato('type') === 'invite' || !!TOKEN_HASH;

const ENLACE_VENCIDO = 'El enlace venció; pide una nueva invitación.';
const ENLACE_USADO = 'Este enlace ya se usó o venció. Si ya creaste tu contraseña, entra con ella; si no, pide una nueva invitación.';

function mostrar(tipo, texto) {
  const m = $('mensaje');
  m.className = 'alerta' + (tipo ? ' ' + tipo : '');
  m.textContent = texto;
  m.hidden = false;
}

// Enlace vencido, ya usado o sin acceso: mensaje claro y salida al inicio.
function sinEnlace(texto) {
  $('form-nueva').hidden = true;
  $('paso-continuar').hidden = true;
  mostrar('error', texto);
  $('ir-inicio').hidden = false;
}

function traducir(error) {
  const m = (error && error.message) || '';
  if (/should be different|same.*password/i.test(m)) return 'La nueva contraseña tiene que ser distinta de la temporal.';
  if (/weak|characters|length/i.test(m)) return 'Supabase la rechazó por débil: ' + m;
  if (/reauthenticat/i.test(m)) return 'Supabase pide volver a entrar antes de cambiarla. Sal y entra otra vez con la contraseña temporal.';
  return m || 'Error desconocido';
}

function textosDeInvitacion() {
  document.title = 'OASIS · Crea tu contraseña';
  $('frase').textContent = 'Te damos la bienvenida a OASIS. Crea tu contraseña para entrar.';
  $('quien').textContent = 'Invitación a OASIS';
  $('titulo').textContent = 'Crea tu contraseña';
  $('ayuda').textContent = 'Mínimo 10 caracteres. Es solo tuya: el administrador no la conoce.';
}

async function iniciar() {
  if (ES_INVITACION) textosDeInvitacion();

  // El enlace llegó con error (vencido o ya usado): Supabase lo dice en la dirección.
  if (ERROR_ENLACE) return sinEnlace(ENLACE_VENCIDO);

  // Enlace con token: se canjea por la sesión cuando la persona hace clic, no
  // al abrirlo. Abrirlo varias veces no lo gasta; el clic sí, una sola vez.
  if (TOKEN_HASH) {
    // Segunda vez en el mismo navegador, después de «Continuar» y sin haber
    // creado la contraseña: la sesión ya está, sigue directo al formulario.
    // (La sesión de otra persona en este navegador no cuenta: no está pendiente.)
    const previa = await usuarioActual();
    if (previa.session && previa.usuario && previa.usuario.debe_cambiar_clave) {
      window.history.replaceState(null, '', 'clave.html');
      return pedirClave();
    }
    $('paso-continuar').hidden = false;
    $('btn-continuar').addEventListener('click', async () => {
      $('btn-continuar').disabled = true;
      const { error } = await sb.auth.verifyOtp({ token_hash: TOKEN_HASH, type: enQuery.get('type') || 'invite' });
      if (error) {
        // Ya usado: si en este navegador ya hay sesión con acceso (creó su
        // contraseña y volvió a abrir el correo), entra; si no, mensaje claro.
        const { session, usuario } = await usuarioActual();
        if (session && usuario) return irA(paginaDeInicio(usuario));
        return sinEnlace(ENLACE_USADO);
      }
      window.history.replaceState(null, '', 'clave.html');
      $('paso-continuar').hidden = true;
      pedirClave();
    });
    return;
  }

  pedirClave();
}

async function pedirClave() {
  const { session, usuario } = await usuarioActual();
  if (ES_INVITACION) {
    if (!session) return sinEnlace(ENLACE_VENCIDO);
    if (!usuario) return sinEnlace('Tu correo todavía no tiene acceso a OASIS. Pide al administrador que te dé de alta.');
  }
  if (!session || !usuario) return irA('index.html');
  if (!usuario.debe_cambiar_clave) return irA(paginaDeInicio(usuario));

  $('quien').textContent = usuario.correo;
  $('form-nueva').hidden = false;
  $('nueva').focus();

  $('btn-salir').addEventListener('click', salir);

  $('form-nueva').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const nueva = $('nueva').value;
    if (nueva.length < MIN_CLAVE) { mostrar('error', `Mínimo ${MIN_CLAVE} caracteres.`); return; }
    if (nueva !== $('repetir').value) { mostrar('error', 'Las dos contraseñas no coinciden.'); return; }

    const boton = $('btn-guardar');
    boton.disabled = true;
    boton.textContent = 'Guardando…';
    const { error } = await sb.auth.updateUser({ password: nueva });
    if (error) {
      boton.disabled = false;
      boton.textContent = 'Guardar y entrar';
      mostrar('error', traducir(error));
      return;
    }
    // La contraseña ya quedó en Auth; ahora se apaga la marca.
    const r = await sb.rpc('fn_clave_cambiada');
    if (r.error) {
      boton.textContent = 'Guardar y entrar';
      mostrar('error', 'La contraseña cambió, pero no se pudo registrar. Recarga la página e inténtalo de nuevo: ' + r.error.message);
      boton.disabled = false;
      return;
    }
    // Según el rol, igual que el login: Cliente al dashboard, Agencia y
    // Proveedor al portal, el resto a OASIS.
    irA(paginaDeInicio({ ...usuario, debe_cambiar_clave: false }));
  });
}

iniciar();
