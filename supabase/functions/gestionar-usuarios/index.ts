// Edge Function gestionar-usuarios: alta y gestión de usuarios desde la
// pantalla Usuarios. Solo ADMIN activo; cualquier otro recibe 403.
//
// POST { accion, ... } con la sesión del ADMIN:
//   crear        { correo, nombre, rol, proveedor_id?, proveedores?, mercados?,
//                  todos_los_mercados?, vistas?, invitar? }
//                -> { usuario, clave } o, con invitar: true,
//                   { usuario, clave: null, invitacion: { enviada, error } }
//                Con invitar, Auth crea el login y manda el correo de invitación
//                (plantilla «Invite user»), con enlace a clave.html. Si el envío
//                falla, el usuario queda creado sin login y la pantalla ofrece
//                la contraseña temporal. Sin invitar, funciona como siempre.
//   reenviar_invitacion { usuario_id } -> { usuario, invitacion }
//                Para un usuario activo sin login (se le crea con la
//                invitación y queda con debe_cambiar_clave) o que todavía no
//                ha creado su contraseña (debe_cambiar_clave). Borra el login anterior —con él mueren
//                el enlace viejo o la temporal— y manda una invitación nueva.
//                Cada envío o intento queda en auditoría: '(invitación)'; el
//                login recreado, como '(login)'.
//                La plantilla «Invite user» enlaza a
//                {{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=invite: el
//                enlace no se gasta al abrirlo (escáneres de correo), sino
//                cuando la persona hace clic en «Continuar» en clave.html.
//   desactivar   { usuario_id }                                     -> { usuario }
//   reactivar    { usuario_id }                                     -> { usuario }
//   nueva_clave  { usuario_id }                                     -> { usuario, clave }
//   editar       { usuario_id, nombre, rol, proveedor_id?, proveedores?, mercados?,
//                  todos_los_mercados?, vistas? }
//                -> { usuario, mercados, proveedores, acceso_cambio, sesiones_cerradas }
//                proveedores: las filas de proveedores (una por país) de un
//                Proveedor; todos_los_mercados: la marca «Todos los países»
//                (sql/usuarios_permisos.sql). Sin mandarlos, como antes.
//                El correo no se edita. Si cambia el acceso (rol, mercados o
//                proveedor), fn_admin_editar_usuario cierra en la base las
//                sesiones de ese login: no hace falta la llave secreta.
//   borrar       { usuario_id } -> { borrado, correo, advertencia }
//                Definitivo. Solo un usuario desactivado (la base lo exige).
//                Primero la base (fila, mercados, auditoría de la baja) y
//                después el login en Auth; si Auth falla, advertencia dice que
//                el login quedó huérfano (sin fila en usuarios no accede a nada).
//
// Dos clientes, a propósito:
//   * el del ADMIN (su JWT) para todo lo de la base: las funciones fn_admin_*
//     revisan otra vez que sea ADMIN y la auditoría registra quién lo hizo;
//   * el de servicio (llave secreta) SOLO para Auth: crear el login, bloquearlo
//     o desbloquearlo, poner una contraseña temporal, invitar por correo.
// La contraseña temporal sale una sola vez en la respuesta; no se guarda ni se
// escribe en el log.
//
// Secretos: OASIS_SECRET_KEY (llave secreta del proyecto, sb_secret_…). Si no
// está, usa SUPABASE_SERVICE_ROLE_KEY, que Supabase pone solo. SUPABASE_URL y
// SUPABASE_ANON_KEY también los pone Supabase.
// verify_jwt está apagado (supabase/config.toml): la sesión se verifica aquí.

import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const responder = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Error con estado HTTP, para cortar desde cualquier punto.
class Rechazo extends Error {
  constructor(public estado: number, mensaje: string) { super(mensaje); }
}

// Errores de Postgres a HTTP: permisos 403, validaciones 400.
function desdePostgres(error: { code?: string; message: string }): Rechazo {
  if (error.code === "42501") return new Rechazo(403, error.message);
  if (["22023", "23505", "23514", "22P02"].includes(error.code ?? "")) return new Rechazo(400, error.message);
  return new Rechazo(500, error.message);
}

// Contraseña temporal: 12 caracteres, con mayúscula, minúscula, número y
// símbolo. Sin caracteres que se confunden al dictarla (0/O, 1/l/I).
const MAYUS = "ABCDEFGHJKLMNPQRSTUVWXYZ";
const MINUS = "abcdefghijkmnpqrstuvwxyz";
const DIGITOS = "23456789";
const SIMBOLOS = "!#%+=?@";
const TODOS = MAYUS + MINUS + DIGITOS + SIMBOLOS;

function alAzar(n: number): number {
  // Sin sesgo de módulo: descarta los valores del último tramo incompleto.
  const tope = Math.floor(256 / n) * n;
  const b = new Uint8Array(1);
  do crypto.getRandomValues(b); while (b[0] >= tope);
  return b[0] % n;
}

export function generarClave(largo = 12): string {
  const c = [MAYUS, MINUS, DIGITOS, SIMBOLOS].map(g => g[alAzar(g.length)]);
  while (c.length < largo) c.push(TODOS[alAzar(TODOS.length)]);
  for (let i = c.length - 1; i > 0; i--) {   // Fisher–Yates
    const j = alAzar(i + 1);
    [c[i], c[j]] = [c[j], c[i]];
  }
  return c.join("");
}

const BLOQUEO = "876000h"; // 100 años: «desactivado» en Auth

type Usuario = {
  id: number; correo: string; nombre: string; rol: string; activo: boolean;
  auth_user_id: string | null; debe_cambiar_clave: boolean;
};

// A dónde lleva el enlace de la invitación: al clave.html del mismo sitio desde
// el que el ADMIN creó al usuario. Lista cerrada (nunca una URL que mande el
// navegador); cada una debe estar también en Supabase → Authentication → URL
// Configuration → Redirect URLs. Sin origen conocido, el sitio publicado.
// El sitio vive en https://zetabe.agency/OASIS/ (dominio propio de la
// organización en GitHub Pages). La dirección anterior, zeta-be.github.io/OASIS,
// redirige sola a la nueva; se sigue aceptando como origen durante la transición.
const SITIO = "https://zetabe.agency";
const DESTINOS: Record<string, string> = {
  [SITIO]: SITIO + "/OASIS/clave.html",
  "https://www.zetabe.agency": SITIO + "/OASIS/clave.html",
  "https://zeta-be.github.io": SITIO + "/OASIS/clave.html",
  "http://localhost:8000": "http://localhost:8000/clave.html",
  "http://127.0.0.1:8000": "http://127.0.0.1:8000/clave.html",
};
const destinoInvitacion = (req: Request) => DESTINOS[req.headers.get("Origin") ?? ""] ?? DESTINOS[SITIO];

type Invitacion = { enviada: boolean; error: string | null };

async function rpc<T>(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw desdePostgres(error);
  return data as T;
}

async function leerUsuario(sb: SupabaseClient, id: number): Promise<Usuario> {
  const { data, error } = await sb.from("usuarios")
    .select("id, correo, nombre, rol, proveedor_id, activo, auth_user_id, debe_cambiar_clave, vistas, todos_los_mercados")
    .eq("id", id).maybeSingle();
  if (error) throw desdePostgres(error);
  if (!data) throw new Rechazo(404, `El usuario ${id} no existe`);
  return data as Usuario;
}

// Crea el login en Auth. El trigger vincular_usuario_auth completa auth_user_id.
async function crearLogin(admin: SupabaseClient, correo: string, clave: string) {
  const { error } = await admin.auth.admin.createUser({ email: correo, password: clave, email_confirm: true });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) {
      throw new Rechazo(400, `Ya hay un login con ${correo} en Supabase Auth sin usuario en OASIS. ` +
        "Bórralo en Authentication → Users y vuelve a intentar.");
    }
    throw new Rechazo(500, "Auth no creó el login: " + error.message);
  }
}

// Manda la invitación (Auth crea el login sin contraseña y envía el correo) y
// deja el resultado en auditoría. No lanza si el correo no sale: devuelve por
// qué, para que la pantalla ofrezca la contraseña temporal.
async function invitar(sb: SupabaseClient, admin: SupabaseClient, u: Usuario, destino: string,
  loginRecreado = false): Promise<Invitacion> {
  let fallo: string | null = null;
  const { error } = await admin.auth.admin.inviteUserByEmail(u.correo, {
    redirectTo: destino,
    data: { nombre: u.nombre, rol: u.rol },   // disponibles en la plantilla: {{ .Data.nombre }}
  });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) {
      fallo = `Ya hay un login con ${u.correo} en Supabase Auth sin usuario en OASIS. ` +
        "Bórralo en Authentication → Users y reenvía la invitación.";
    } else if (/rate limit/i.test(error.message)) {
      fallo = "Supabase llegó al tope de correos por hora. Espera un rato y reenvía la invitación.";
    } else {
      fallo = "No se pudo enviar el correo: " + error.message;
    }
  } else {
    // Un login viejo sin confirmar recibe el correo, pero no se vincula
    // (el trigger solo corre al crear el login).
    const ahora = await leerUsuario(sb, u.id);
    if (!ahora.auth_user_id) {
      fallo = `Había un login viejo con ${u.correo} en Supabase Auth que no quedó vinculado. ` +
        "Bórralo en Authentication → Users y reenvía la invitación.";
    }
  }
  await rpc(sb, "fn_admin_registrar_invitacion",
    { p_usuario_id: u.id, p_enviada: !fallo, p_detalle: fallo, p_login_recreado: loginRecreado });
  return { enviada: !fallo, error: fallo };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return responder({ error: "Usa POST" }, 405);

  try {
    // ---- quién llama
    const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!token) return responder({ error: "Falta la sesión" }, 401);

    const url = Deno.env.get("SUPABASE_URL")!;
    const llavePublica = req.headers.get("apikey") ?? Deno.env.get("SUPABASE_ANON_KEY")!;
    const sb = createClient(url, llavePublica, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error: errorSesion } = await sb.auth.getUser(token);
    if (errorSesion || !user) return responder({ error: "Sesión inválida o vencida" }, 401);

    // fn_usuario_actual solo devuelve usuarios activos.
    const yo = await sb.rpc("fn_usuario_actual").maybeSingle();
    if (yo.error) throw desdePostgres(yo.error);
    if (!yo.data || (yo.data as Usuario).rol !== "ADMIN") {
      return responder({ error: "Solo un ADMIN activo puede gestionar usuarios" }, 403);
    }

    const llaveSecreta = Deno.env.get("OASIS_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!llaveSecreta) return responder({ error: "Falta el secreto OASIS_SECRET_KEY en Supabase" }, 500);
    const admin = createClient(url, llaveSecreta, { auth: { persistSession: false, autoRefreshToken: false } });

    const cuerpo = await req.json().catch(() => ({}));
    const accion = cuerpo.accion;

    // ---- crear
    if (accion === "crear") {
      const nuevo = await rpc<Usuario>(sb, "fn_admin_crear_usuario", {
        p_correo: cuerpo.correo ?? null,
        p_nombre: cuerpo.nombre ?? null,
        p_rol: cuerpo.rol ?? null,
        p_proveedor_id: cuerpo.proveedor_id ?? null,
        p_mercados: Array.isArray(cuerpo.mercados) ? cuerpo.mercados : [],
        p_vistas: Array.isArray(cuerpo.vistas) ? cuerpo.vistas : null,   // pantallas del Cliente (vistas_catalogo)
        p_todos: cuerpo.todos_los_mercados === true,
        p_proveedores: Array.isArray(cuerpo.proveedores) ? cuerpo.proveedores : null,
      });
      if (cuerpo.invitar === true) {
        // Si el correo no sale, el usuario se queda (sin login): la pantalla
        // avisa y ofrece reenviar o generar una contraseña temporal.
        const invitacion = await invitar(sb, admin, nuevo, destinoInvitacion(req));
        return responder({ usuario: await leerUsuario(sb, nuevo.id), clave: null, invitacion });
      }
      const clave = generarClave();
      try {
        await crearLogin(admin, nuevo.correo, clave);
      } catch (e) {
        // Sin login no hay usuario: se deshace la fila (queda en auditoría).
        // fn_admin_borrar_usuario permite borrar un alta a medias (sin login).
        await sb.rpc("fn_admin_borrar_usuario", { p_usuario_id: nuevo.id });
        throw e;
      }
      const usuario = await leerUsuario(sb, nuevo.id);
      if (!usuario.auth_user_id) {
        console.error("Login creado pero sin vincular", usuario.id);
      }
      return responder({ usuario, clave });
    }

    const id = Number(cuerpo.usuario_id);
    if (!Number.isInteger(id)) return responder({ error: "Falta usuario_id" }, 400);

    // ---- desactivar / reactivar
    if (accion === "desactivar" || accion === "reactivar") {
      const activo = accion === "reactivar";
      const usuario = await rpc<Usuario>(sb, "fn_admin_cambiar_activo", { p_usuario_id: id, p_activo: activo });
      if (usuario.auth_user_id) {
        const { error } = await admin.auth.admin.updateUserById(usuario.auth_user_id,
          { ban_duration: activo ? "none" : BLOQUEO });
        if (error) {
          // Auth no acompañó: la base vuelve a como estaba, para no mentir.
          await sb.rpc("fn_admin_cambiar_activo", { p_usuario_id: id, p_activo: !activo });
          throw new Rechazo(500, "Auth no aplicó el cambio: " + error.message);
        }
      }
      return responder({ usuario });
    }

    // ---- editar nombre, rol, mercados y proveedor
    if (accion === "editar") {
      const r = await rpc<{ mercados: number[]; proveedores: number[]; acceso_cambio: boolean; sesiones_cerradas: number }>(
        sb, "fn_admin_editar_usuario", {
          p_usuario_id: id,
          p_nombre: cuerpo.nombre ?? null,
          p_rol: cuerpo.rol ?? null,
          p_proveedor_id: cuerpo.proveedor_id ?? null,
          p_mercados: Array.isArray(cuerpo.mercados) ? cuerpo.mercados : [],
          p_vistas: Array.isArray(cuerpo.vistas) ? cuerpo.vistas : null,   // null = no tocarlas
          p_todos: typeof cuerpo.todos_los_mercados === "boolean" ? cuerpo.todos_los_mercados : null,   // null = como estaba
          p_proveedores: Array.isArray(cuerpo.proveedores) ? cuerpo.proveedores : null,
        });
      const usuario = await leerUsuario(sb, id);
      return responder({
        usuario,
        mercados: r.mercados,
        proveedores: r.proveedores,
        acceso_cambio: r.acceso_cambio,
        sesiones_cerradas: r.sesiones_cerradas,
      });
    }

    // ---- borrar definitivamente (solo desactivados; la base lo valida)
    if (accion === "borrar") {
      const r = await rpc<{ correo: string; auth_user_id: string | null }>(
        sb, "fn_admin_borrar_usuario", { p_usuario_id: id });
      let advertencia: string | null = null;
      if (r.auth_user_id) {
        const { error } = await admin.auth.admin.deleteUser(r.auth_user_id);
        if (error) {
          // La fila ya no existe y sin ella el login no accede a nada; no se
          // deshace: se avisa para limpiarlo a mano.
          advertencia = `El usuario se borró de OASIS, pero su login (${r.correo}) quedó en Auth: ` +
            "bórralo en Authentication → Users. " + error.message;
        }
      }
      return responder({ borrado: true, usuario_id: id, correo: r.correo, advertencia });
    }

    // ---- reenviar (o enviar por primera vez) la invitación
    if (accion === "reenviar_invitacion") {
      const actual = await leerUsuario(sb, id);
      if (!actual.activo) throw new Rechazo(400, "Está desactivado: reactívalo antes de invitarlo.");
      // Sin login se puede invitar siempre; con login, solo mientras no haya
      // creado su contraseña.
      if (actual.auth_user_id && !actual.debe_cambiar_clave) {
        throw new Rechazo(400, "Ya creó su contraseña. Si la olvidó, genera una temporal con «Nueva contraseña».");
      }
      if (actual.auth_user_id) {
        // Auth no reinvita a un login ya confirmado (abrir el enlace lo
        // confirma). Todavía no tiene contraseña propia: se borra y se crea de
        // nuevo con la invitación. La fila de usuarios no se toca.
        const { error } = await admin.auth.admin.deleteUser(actual.auth_user_id);
        if (error) throw new Rechazo(500, "Auth no pudo renovar el login: " + error.message);
      }
      // Con login anterior, la auditoría dice «login recreado por reenvío de invitación».
      const invitacion = await invitar(sb, admin, actual, destinoInvitacion(req), !!actual.auth_user_id);
      if (invitacion.enviada && !actual.debe_cambiar_clave) {
        // Usuario antiguo sin login: la marca hace que clave.html le pida crear
        // la contraseña. Con el JWT del ADMIN (RLS lo permite): queda en
        // auditoría a su nombre, como campo debe_cambiar_clave.
        const { error } = await sb.from("usuarios").update({ debe_cambiar_clave: true }).eq("id", id);
        if (error) throw desdePostgres(error);
      }
      return responder({ usuario: await leerUsuario(sb, id), invitacion });
    }

    // ---- nueva contraseña temporal
    if (accion === "nueva_clave") {
      const actual = await leerUsuario(sb, id);
      const clave = generarClave();
      if (actual.auth_user_id) {
        // email_confirm: un login creado por invitación que nunca abrió el
        // enlace está sin confirmar, y Auth no lo dejaría entrar con contraseña.
        const { error } = await admin.auth.admin.updateUserById(actual.auth_user_id,
          { password: clave, email_confirm: true });
        if (error) throw new Rechazo(500, "Auth no cambió la contraseña: " + error.message);
      } else {
        // Usuario de antes sin login (alta manual a medias): se le crea ahora.
        await crearLogin(admin, actual.correo, clave);
      }
      await rpc(sb, "fn_admin_marcar_clave_temporal", { p_usuario_id: id });
      const usuario = await leerUsuario(sb, id);
      return responder({ usuario, clave });
    }

    return responder({ error: "accion: crear, editar, borrar, desactivar, reactivar, nueva_clave o reenviar_invitacion" }, 400);
  } catch (e) {
    if (e instanceof Rechazo) return responder({ error: e.message }, e.estado);
    console.error(e);
    return responder({ error: (e as Error).message ?? String(e) }, 500);
  }
});
