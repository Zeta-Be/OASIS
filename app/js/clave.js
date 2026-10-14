// Cambio de contraseña obligatorio: el usuario entró con una contraseña
// temporal (usuarios.debe_cambiar_clave = true). Todas las pantallas lo mandan
// aquí hasta que la cambie; al cambiarla, la marca se apaga y sigue a su inicio.

const $ = (id) => document.getElementById(id);
const MIN_CLAVE = 10;

function mostrar(tipo, texto) {
  const m = $('mensaje');
  m.className = 'alerta' + (tipo ? ' ' + tipo : '');
  m.textContent = texto;
  m.hidden = false;
}

function traducir(error) {
  const m = (error && error.message) || '';
  if (/should be different|same.*password/i.test(m)) return 'La nueva contraseña tiene que ser distinta de la temporal.';
  if (/weak|characters|length/i.test(m)) return 'Supabase la rechazó por débil: ' + m;
  if (/reauthenticat/i.test(m)) return 'Supabase pide volver a entrar antes de cambiarla. Sal y entra otra vez con la contraseña temporal.';
  return m || 'Error desconocido';
}

async function iniciar() {
  const { session, usuario } = await usuarioActual();
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
    // La contraseña ya cambió en Auth; ahora se apaga la marca.
    const r = await sb.rpc('fn_clave_cambiada');
    if (r.error) {
      boton.textContent = 'Guardar y entrar';
      mostrar('error', 'La contraseña cambió, pero no se pudo registrar. Recarga la página e inténtalo de nuevo: ' + r.error.message);
      boton.disabled = false;
      return;
    }
    irA(paginaDeInicio({ ...usuario, debe_cambiar_clave: false }));
  });
}

iniciar();
