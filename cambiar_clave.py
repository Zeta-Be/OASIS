"""Cambia la contraseña de un login de OASIS directo en Supabase Auth.

Para cuando un ADMIN olvidó la suya y no hay otro ADMIN que le genere una
temporal en la pantalla Usuarios (no hay «olvidé mi contraseña» sin correo
propio). Usa la conexión de .env (postgres).

    source .env
    python3 cambiar_clave.py nicolas.orjuela@zetabe.com

- Pide la contraseña nueva dos veces, sin eco (getpass). No la imprime ni la
  guarda en ningún archivo.
- Mínimo 10 caracteres, como la pantalla de cambio de contraseña.
- La escribe en auth.users con crypt(…, gen_salt('bf')), el mismo formato
  bcrypt que usa Supabase Auth.
- Cierra todas las sesiones abiertas de ese login (sessions y refresh_tokens):
  quien tuviera una sesión vieja tiene que volver a entrar.
- No toca usuarios.debe_cambiar_clave: la contraseña la eligió la persona.
- Todo en una transacción: si algo falla, no cambia nada.
"""
import getpass
import os
import sys

import psycopg2

MIN_CLAVE = 10


def pedir_clave():
    for _ in range(3):
        clave = getpass.getpass("Contraseña nueva: ")
        if len(clave) < MIN_CLAVE:
            print(f"  Tiene que tener al menos {MIN_CLAVE} caracteres.")
            continue
        if clave != clave.strip():
            print("  No puede empezar ni terminar con espacios.")
            continue
        if getpass.getpass("Repítela: ") != clave:
            print("  Las dos no coinciden.")
            continue
        return clave
    sys.exit("Tres intentos fallidos. No se cambió nada.")


def main():
    if len(sys.argv) != 2:
        sys.exit("Uso: python3 cambiar_clave.py correo@empresa.com")
    if not os.getenv("PGHOST"):
        sys.exit("Faltan las variables de conexión. Corre: source .env")
    correo = sys.argv[1].strip().lower()

    conn = psycopg2.connect()
    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT au.id, au.banned_until, u.rol, u.activo
            FROM auth.users au
            LEFT JOIN public.usuarios u ON u.auth_user_id = au.id
            WHERE lower(au.email) = %s""", (correo,))
        filas = cur.fetchall()
        if len(filas) != 1:
            sys.exit(f"No hay un login con el correo {correo} en Supabase Auth." if not filas
                     else f"Hay {len(filas)} logins con {correo}; revísalo en Authentication → Users.")
        auth_id, bloqueado, rol, activo = filas[0]

        print(f"Login: {correo}")
        print(f"  Usuario de OASIS: {rol or 'sin fila en usuarios'}{'' if activo or activo is None else ' (INACTIVO)'}")
        if bloqueado:
            print(f"  Ojo: el login está bloqueado hasta {bloqueado:%Y-%m-%d}. Con la contraseña nueva tampoco entrará;"
                  " un ADMIN tiene que reactivarlo en la pantalla Usuarios.")
        if rol and not activo:
            print("  Ojo: el usuario está inactivo en OASIS; entrará pero no verá nada.")

        clave = pedir_clave()

        cur.execute("""
            UPDATE auth.users
            SET encrypted_password = extensions.crypt(%s, extensions.gen_salt('bf')),
                updated_at = now()
            WHERE id = %s""", (clave, auth_id))
        del clave
        if cur.rowcount != 1:
            raise RuntimeError("No se actualizó el login")

        # Sesiones viejas fuera: primero lo que cuelga de cada sesión.
        cur.execute("DELETE FROM auth.refresh_tokens WHERE user_id = %s", (str(auth_id),))
        tokens = cur.rowcount
        cur.execute("DELETE FROM auth.mfa_amr_claims WHERE session_id IN (SELECT id FROM auth.sessions WHERE user_id = %s)",
                    (auth_id,))
        cur.execute("DELETE FROM auth.sessions WHERE user_id = %s", (auth_id,))
        sesiones = cur.rowcount

        conn.commit()
        print(f"Listo: contraseña cambiada. Se cerraron {sesiones} sesiones ({tokens} tokens de renovación).")
        print("Entra en OASIS con la contraseña nueva. Una pestaña que ya estaba abierta puede seguir hasta una hora,"
              " hasta que venza su acceso.")
    except psycopg2.Error as e:
        conn.rollback()
        # Solo el mensaje del servidor: el texto de la consulta lleva la contraseña.
        sys.exit(f"La base rechazó el cambio ({e.pgcode}): {e.diag.message_primary}. No se cambió nada.")
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
