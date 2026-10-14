// Login: correo y contraseña, y código de 6 dígitos por correo.
//
// Se usa código y no enlace porque los escáneres de seguridad del correo
// corporativo abren los enlaces antes que el usuario y los dejan vencidos.
// La plantilla de correo de Supabase debe mandar {{ .Token }}, no el enlace.
//
// Hoy el código no funciona: las plantillas de Supabase no se pueden editar sin
// correo propio. Mientras tanto el piloto entra con contraseña y la pestaña del
// código queda visible con «próximamente». Cuando esté Resend y la plantilla
// pegada, CODIGO_DISPONIBLE = true: el código pasa a ser el primero y el principal.

const $ = (id) => document.getElementById(id);

const CODIGO_DISPONIBLE = false;
const METODO_PRINCIPAL = CODIGO_DISPONIBLE ? 'codigo' : 'clave';
const ESPERA_REENVIO = 60; // segundos; Supabase no deja pedir otro código antes

const metodos = $('metodos');
const formPedir = $('form-pedir');
const formCodigo = $('form-codigo');
const formClave = $('form-clave');
const mensaje = $('mensaje');
const sinAcceso = $('sin-acceso');

let correoActual = '';
let temporizador = null;

function mostrar(tipo, texto) {
  mensaje.className = 'alerta' + (tipo ? ' ' + tipo : '');
  mensaje.textContent = texto;
  mensaje.hidden = false;
}
function ocultarMensaje() { mensaje.hidden = true; }

function ocupado(boton, texto) {
  boton.dataset.texto ??= boton.textContent;
  boton.disabled = !!texto;
  boton.textContent = texto || boton.dataset.texto;
}

function traducir(error) {
  const m = (error && error.message) || '';
  if (/expired|invalid/i.test(m) && /token|otp/i.test(m)) return 'Código incorrecto o vencido. Revísalo o pide uno nuevo.';
  if (/Invalid login credentials/i.test(m)) return 'Correo o contraseña incorrectos.';
  if (/Email not confirmed/i.test(m)) return 'La cuenta no está confirmada en Supabase.';
  if (/rate limit|security purposes|after \d+ seconds/i.test(m)) return 'Demasiados intentos seguidos. Espera un minuto y vuelve a pedir el código.';
  return m || 'Error desconocido';
}

// ------------------------------------------------------------------ Pestañas

function elegirMetodo(metodo) {
  for (const b of $('pestanas').querySelectorAll('button')) {
    b.classList.toggle('activa', b.dataset.metodo === metodo);
  }
  formPedir.hidden = metodo !== 'codigo' || !CODIGO_DISPONIBLE || !!correoActual;
  formCodigo.hidden = metodo !== 'codigo' || !CODIGO_DISPONIBLE || !correoActual;
  $('codigo-pronto').hidden = metodo !== 'codigo' || CODIGO_DISPONIBLE;
  formClave.hidden = metodo !== 'clave';
  ocultarMensaje();
}

$('pestanas').addEventListener('click', (ev) => {
  const b = ev.target.closest('button[data-metodo]');
  if (b) elegirMetodo(b.dataset.metodo);
});

// ------------------------------------------------------------------ Código

async function enviarCodigo(correo) {
  // shouldCreateUser: el primer ingreso crea el usuario de Auth y el trigger lo
  // vincula con su fila en `usuarios`. Sin esa fila, entra pero no tiene acceso.
  return sb.auth.signInWithOtp({ email: correo, options: { shouldCreateUser: true } });
}

function arrancarEsperaReenvio() {
  const btn = $('btn-reenviar');
  let quedan = ESPERA_REENVIO;
  clearInterval(temporizador);
  btn.disabled = true;
  btn.textContent = `Reenviar en ${quedan} s`;
  temporizador = setInterval(() => {
    quedan--;
    if (quedan <= 0) {
      clearInterval(temporizador);
      btn.disabled = false;
      btn.textContent = 'Reenviar código';
    } else {
      btn.textContent = `Reenviar en ${quedan} s`;
    }
  }, 1000);
}

formPedir.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const correo = $('correo').value.trim().toLowerCase();
  if (!correo) return;
  ocupado($('btn-pedir'), 'Enviando…');
  const { error } = await enviarCodigo(correo);
  ocupado($('btn-pedir'));
  if (error) { mostrar('error', 'No se pudo enviar el código: ' + traducir(error)); return; }

  correoActual = correo;
  $('correo-enviado').textContent = correo;
  formPedir.hidden = true;
  formCodigo.hidden = false;
  $('codigo').value = '';
  $('codigo').focus();
  arrancarEsperaReenvio();
  mostrar('', 'Código enviado. Puede tardar un minuto; revisa también la carpeta de spam.');
});

// Solo dígitos; al completar los 6 se envía solo.
$('codigo').addEventListener('input', (ev) => {
  const limpio = ev.target.value.replace(/\D/g, '').slice(0, 6);
  ev.target.value = limpio;
  if (limpio.length === 6) formCodigo.requestSubmit();
});

formCodigo.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const codigo = $('codigo').value.trim();
  if (!/^\d{6}$/.test(codigo)) { mostrar('error', 'El código tiene 6 dígitos.'); return; }
  ocupado($('btn-verificar'), 'Verificando…');
  const { error } = await sb.auth.verifyOtp({ email: correoActual, token: codigo, type: 'email' });
  ocupado($('btn-verificar'));
  if (error) {
    mostrar('error', traducir(error));
    $('codigo').select();
    return;
  }
  await continuar();
});

$('btn-reenviar').addEventListener('click', async () => {
  ocupado($('btn-reenviar'), 'Enviando…');
  const { error } = await enviarCodigo(correoActual);
  if (error) {
    ocupado($('btn-reenviar'));
    mostrar('error', 'No se pudo reenviar: ' + traducir(error));
    return;
  }
  delete $('btn-reenviar').dataset.texto;
  arrancarEsperaReenvio();
  mostrar('', 'Te enviamos un código nuevo. El anterior ya no sirve.');
  $('codigo').value = '';
  $('codigo').focus();
});

$('btn-cambiar').addEventListener('click', () => {
  correoActual = '';
  clearInterval(temporizador);
  formCodigo.hidden = true;
  formPedir.hidden = false;
  ocultarMensaje();
  $('correo').focus();
});

// ------------------------------------------------------------------ Contraseña

formClave.addEventListener('submit', async (ev) => {
  ev.preventDefault();
  ocupado($('btn-clave'), 'Entrando…');
  const { error } = await sb.auth.signInWithPassword({
    email: $('correo-clave').value.trim().toLowerCase(),
    password: $('clave').value,
  });
  ocupado($('btn-clave'));
  if (error) { mostrar('error', traducir(error)); return; }
  await continuar();
});

// ------------------------------------------------------------------ Después del login

async function continuar() {
  let estado;
  try {
    estado = await usuarioActual();
  } catch (e) {
    metodos.hidden = false;
    mostrar('error', 'No se pudo verificar tu acceso: ' + e.message);
    return;
  }

  if (estado.session && estado.usuario) {
    window.location.replace(paginaDeInicio(estado.usuario));
    return;
  }

  if (estado.session) {
    metodos.hidden = true;
    sinAcceso.hidden = false;
    mostrar('error',
      `El correo ${estado.session.user.email} no tiene acceso a OASIS, o su usuario está inactivo. ` +
      'Pide a un administrador que te dé de alta y vuelve a entrar.');
    return;
  }

  metodos.hidden = false;
}

$('btn-otro').addEventListener('click', async () => {
  await sb.auth.signOut();
  sinAcceso.hidden = true;
  correoActual = '';
  elegirMetodo(METODO_PRINCIPAL);
  metodos.hidden = false;
});

// El método principal va primero y abierto. Sin código, su pestaña dice «próximamente».
const pestanaCodigo = $('pestanas').querySelector('[data-metodo="codigo"]');
if (!CODIGO_DISPONIBLE) {
  pestanaCodigo.insertAdjacentHTML('beforeend', ' <span class="pronto">próximamente</span>');
  $('pestanas').append(pestanaCodigo);
}
elegirMetodo(METODO_PRINCIPAL);
continuar();
