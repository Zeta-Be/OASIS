// Edge Function gestionar-usuarios: alta y gestión de usuarios desde la
// pantalla Usuarios. Solo ADMIN activo; cualquier otro recibe 403.
//
// POST { accion, ... } con la sesión del ADMIN:
//   crear        { correo, nombre, rol, proveedor_id?, mercados? } -> { usuario, clave }
//   desactivar   { usuario_id }                                     -> { usuario }
//   reactivar    { usuario_id }                                     -> { usuario }
//   nueva_clave  { usuario_id }                                     -> { usuario, clave }
//
// Dos clientes, a propósito:
//   * el del ADMIN (su JWT) para todo lo de la base: las funciones fn_admin_*
//     revisan otra vez que sea ADMIN y la auditoría registra quién lo hizo;
//   * el de servicio (llave secreta) SOLO para Auth: crear el login, bloquearlo
//     o desbloquearlo, poner una contraseña temporal.
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

type Usuario = { id: number; correo: string; rol: string; activo: boolean; auth_user_id: string | null };

async function rpc<T>(sb: SupabaseClient, fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw desdePostgres(error);
  return data as T;
}

async function leerUsuario(sb: SupabaseClient, id: number): Promise<Usuario> {
  const { data, error } = await sb.from("usuarios")
    .select("id, correo, nombre, rol, proveedor_id, activo, auth_user_id, debe_cambiar_clave")
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
      });
      const clave = generarClave();
      try {
        await crearLogin(admin, nuevo.correo, clave);
      } catch (e) {
        // Sin login no hay usuario: se deshace la fila (queda en auditoría).
        await sb.rpc("fn_admin_borrar_usuario_sin_login", { p_usuario_id: nuevo.id });
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

    // ---- nueva contraseña temporal
    if (accion === "nueva_clave") {
      const actual = await leerUsuario(sb, id);
      const clave = generarClave();
      if (actual.auth_user_id) {
        const { error } = await admin.auth.admin.updateUserById(actual.auth_user_id, { password: clave });
        if (error) throw new Rechazo(500, "Auth no cambió la contraseña: " + error.message);
      } else {
        // Usuario de antes sin login (alta manual a medias): se le crea ahora.
        await crearLogin(admin, actual.correo, clave);
      }
      await rpc(sb, "fn_admin_marcar_clave_temporal", { p_usuario_id: id });
      const usuario = await leerUsuario(sb, id);
      return responder({ usuario, clave });
    }

    return responder({ error: "accion: crear, desactivar, reactivar o nueva_clave" }, 400);
  } catch (e) {
    if (e instanceof Rechazo) return responder({ error: e.message }, e.estado);
    console.error(e);
    return responder({ error: (e as Error).message ?? String(e) }, 500);
  }
});
