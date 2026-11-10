"""Prueba de punta a punta de la Edge Function gestionar-usuarios.

    source .env
    python3 supabase/probar_usuarios.py

Necesita la función desplegada y sql/usuarios.sql aplicado. Usa la conexión de
.env (postgres) solo para preparar y limpiar; todo lo demás va por la API, como
la pantalla Usuarios.

1. Crea un ADMIN temporal directo en la base (fila en usuarios y login en Auth
   con una contraseña aleatoria que no se imprime).
2. Con su sesión recorre el flujo: crear, validaciones, entrar con la temporal,
   nueva contraseña, desactivar, reactivar, cambio de contraseña del usuario,
   editar (mercados, nombre, rol; reglas; cierre de sesiones) y borrar (solo
   desactivados; fila, mercados y login fuera; auditoría marcada «(borrado)»).
   Necesita también sql/usuarios_edicion.sql y sql/usuarios_borrar.sql aplicados.
   Invitación por correo (sql/usuarios_invitacion.sql): crear con invitación,
   login en Auth sin contraseña y vinculado, contraseña temporal como
   alternativa, reenvío (login recreado), auditoría de cada envío y el canje
   del enlace como lo hace clave.html (token_hash leído de la base, sin
   imprimirlo): una sola vez, crear la contraseña y entrar. OJO: esta parte manda dos correos
   reales por el SMTP de Supabase. Van a un alias del buzón de OASIS
   (oasis.zetabe+prueba.…@gmail.com) para que no reboten; otro destino:
   OASIS_CORREO_INVITACION=alguien@dominio.com. Abrir el enlace del correo y
   crear la contraseña se prueba a mano.
3. Comprueba que un no-ADMIN recibe 403 y que la auditoría registra al ADMIN.
4. Busca la llave secreta en el repositorio (git grep, también en el historial).
5. Borra todo lo que creó, aunque algo falle: logins, usuarios y su auditoría.
"""
import base64
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.error
import urllib.request

import psycopg2

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = open(os.path.join(RAIZ, "app", "config.js"), encoding="utf-8").read()
URL = re.search(r"supabaseUrl:\s*'([^']+)'", CONFIG).group(1)
LLAVE = re.search(r"supabaseKey:\s*'([^']+)'", CONFIG).group(1)
FUNCION = f"{URL}/functions/v1/gestionar-usuarios"

SUFIJO = secrets.token_hex(4)
CORREO_ADMIN = f"oasis.prueba.admin.{SUFIJO}@example.com"
CORREO_USUARIO = f"oasis.prueba.usuario.{SUFIJO}@example.com"
# El invitado recibe correos de verdad: un alias (+) del buzón remitente, que no rebota.
CORREO_INVITADO = os.environ.get("OASIS_CORREO_INVITACION", f"oasis.zetabe+prueba.{SUFIJO}@gmail.com").lower()

informe = []


def anotar(ok, texto):
    informe.append(f"{'OK   ' if ok else 'FALLA'}  {texto}")


def http(metodo, url, cuerpo=None, token=None):
    """(estado, json) sin lanzar en 4xx/5xx."""
    cab = {"apikey": LLAVE, "Content-Type": "application/json"}
    if token:
        cab["Authorization"] = f"Bearer {token}"
    datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
    req = urllib.request.Request(url, data=datos, headers=cab, method=metodo)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            texto = r.read().decode()
            return r.status, (json.loads(texto) if texto else None)
    except urllib.error.HTTPError as e:
        texto = e.read().decode()
        try:
            return e.code, json.loads(texto)
        except ValueError:
            return e.code, {"error": texto}


def entrar(correo, clave):
    estado, r = http("POST", f"{URL}/auth/v1/token?grant_type=password", {"email": correo, "password": clave})
    return (r or {}).get("access_token") if estado == 200 else None, estado, r


def funcion(token, **cuerpo):
    return http("POST", FUNCION, cuerpo, token)


def preparar_admin(cur, clave):
    """ADMIN temporal: fila en usuarios y login en Auth con contraseña conocida."""
    cur.execute("INSERT INTO usuarios (correo, nombre, rol, activo) VALUES (%s, 'Prueba ADMIN temporal', 'ADMIN', true) RETURNING id",
                (CORREO_ADMIN,))
    admin_id = cur.fetchone()[0]
    # Columnas de texto en '' y no NULL: Auth falla al leer NULL en ellas.
    cur.execute("""
        INSERT INTO auth.users (
            instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
            confirmation_token, recovery_token, email_change_token_new, email_change,
            email_change_token_current, phone_change, phone_change_token, reauthentication_token)
        VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
                %s, extensions.crypt(%s, extensions.gen_salt('bf')), now(),
                '{"provider":"email","providers":["email"]}', '{}', now(), now(),
                '', '', '', '', '', '', '', '')
        RETURNING id""", (CORREO_ADMIN, clave))
    auth_id = cur.fetchone()[0]
    cur.execute("""
        INSERT INTO auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
        VALUES (%s, %s, jsonb_build_object('sub', %s::text, 'email', %s::text, 'email_verified', true),
                'email', now(), now(), now())""", (str(auth_id), auth_id, str(auth_id), CORREO_ADMIN))
    return admin_id


def limpiar(cur):
    """Borra lo que creó la prueba, por correo: sirve aunque haya fallado a medias."""
    correos = (CORREO_ADMIN, CORREO_USUARIO, CORREO_INVITADO)
    cur.execute("SELECT id FROM usuarios WHERE correo IN %s", (correos,))
    ids = [r[0] for r in cur.fetchall()]
    cur.execute("DELETE FROM auth.users WHERE email IN %s", (correos,))
    logins = cur.rowcount
    cur.execute("DELETE FROM usuarios WHERE correo IN %s", (correos,))
    usuarios = cur.rowcount
    auditoria = 0
    if ids:
        cur.execute("DELETE FROM auditoria WHERE tabla = 'usuarios' AND fila_id = ANY(%s)", (ids,))
        auditoria = cur.rowcount
    return logins, usuarios, auditoria


def buscar_llave():
    """La llave secreta no puede estar en el repo: ni en los archivos ni en el historial."""
    patrones = [r"sb_secret_[A-Za-z0-9_-]{8,}", r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"]
    hallazgos = []
    for p in patrones:
        for alcance in (["git", "grep", "-nIE", p], ["git", "log", "--all", "-p", "-G", p, "--format=%h"]):
            r = subprocess.run(alcance, cwd=RAIZ, capture_output=True, text=True)
            for linea in r.stdout.splitlines():
                for m in re.findall(p, linea):
                    if m.startswith("eyJ"):
                        # Un JWT es de servicio si su rol lo dice.
                        try:
                            carga = m.split(".")[1]
                            carga += "=" * (-len(carga) % 4)
                            rol = json.loads(base64.urlsafe_b64decode(carga)).get("role")
                        except Exception:
                            rol = "?"
                        if rol == "service_role":
                            hallazgos.append(linea[:80])
                    else:
                        hallazgos.append(linea[:80])
    return hallazgos


def flujo(cur):
    if True:
        cur.execute("SELECT id FROM mercados WHERE codigo = 'MCO'")
        mco = cur.fetchone()[0]
        clave_admin = secrets.token_urlsafe(18) + "aA1!"
        admin_id = preparar_admin(cur, clave_admin)
        token_admin, estado, r = entrar(CORREO_ADMIN, clave_admin)
        if not token_admin:
            anotar(False, f"El ADMIN temporal no pudo entrar ({estado}: {r})")
            return
        anotar(True, "ADMIN temporal entra")

        # ---- sin sesión y sin rol
        estado, _ = funcion(None, accion="crear")
        anotar(estado == 401, f"Sin sesión: {estado} (esperado 401)")

        # ---- validaciones
        casos = [
            ("correo con formato malo", dict(correo="no-es-correo", nombre="X", rol="LECTURA", mercados=[mco])),
            ("rol Proveedor sin proveedor", dict(correo=f"x1.{SUFIJO}@example.com", nombre="X", rol="PROVEEDOR")),
            ("rol Equipo ZB sin mercados", dict(correo=f"x2.{SUFIJO}@example.com", nombre="X", rol="ZB", mercados=[])),
            ("rol PLANNING (ya no se ofrece)", dict(correo=f"x3.{SUFIJO}@example.com", nombre="X", rol="PLANNING", mercados=[mco])),
            ("correo repetido (el del ADMIN temporal)", dict(correo=CORREO_ADMIN.upper(), nombre="X", rol="LECTURA", mercados=[mco])),
        ]
        for nombre, cuerpo in casos:
            estado, r = funcion(token_admin, accion="crear", **cuerpo)
            anotar(estado == 400, f"Rechaza {nombre}: {estado} — {(r or {}).get('error')}")

        # ---- crear
        estado, r = funcion(token_admin, accion="crear", correo=CORREO_USUARIO, nombre="Prueba usuario",
                            rol="ZB", mercados=[mco])
        ok = estado == 200 and r.get("clave") and r["usuario"].get("auth_user_id")
        anotar(bool(ok), f"Crea usuario Equipo ZB en MCO con login: {estado}")
        if not ok:
            anotar(False, f"Respuesta: {r}")
            return
        usuario_id = r["usuario"]["id"]
        clave1 = r["clave"]
        anotar(len(clave1) == 12 and re.search(r"[A-Z]", clave1) and re.search(r"[a-z]", clave1)
               and re.search(r"\d", clave1) and re.search(r"[^A-Za-z0-9]", clave1),
               "Contraseña temporal de 12 caracteres con mayúscula, minúscula, número y símbolo")
        anotar(r["usuario"].get("debe_cambiar_clave") is True, "Nace con debe_cambiar_clave = true")
        cur.execute("SELECT array_agg(mercado_id) FROM usuario_mercados WHERE usuario_id = %s", (usuario_id,))
        anotar(cur.fetchone()[0] == [mco], "Queda con su mercado MCO")

        # ---- el usuario entra con la temporal; un no-ADMIN recibe 403
        token_u, estado, _ = entrar(CORREO_USUARIO, clave1)
        anotar(bool(token_u), f"El usuario entra con la temporal: {estado}")
        estado, r = http("GET", f"{URL}/rest/v1/usuarios?select=debe_cambiar_clave", token=token_u)
        anotar(estado == 200 and r == [{"debe_cambiar_clave": True}], f"Lee su marca de cambio de contraseña: {r}")
        for accion, extra in (("crear", dict(correo=f"x4.{SUFIJO}@example.com", nombre="X", rol="ADMIN")),
                              ("nueva_clave", dict(usuario_id=admin_id)),
                              ("desactivar", dict(usuario_id=admin_id))):
            estado, r = funcion(token_u, accion=accion, **extra)
            anotar(estado == 403, f"No-ADMIN (Equipo ZB) intenta {accion}: {estado} (esperado 403)")
        estado, r = http("POST", f"{URL}/rest/v1/rpc/fn_admin_crear_usuario",
                         {"p_correo": f"x5.{SUFIJO}@example.com", "p_nombre": "X", "p_rol": "ADMIN",
                          "p_proveedor_id": None, "p_mercados": []}, token=token_u)
        anotar(estado in (401, 403), f"No-ADMIN llama directo a fn_admin_crear_usuario: {estado} (esperado 403)")

        # ---- nueva contraseña
        estado, r = funcion(token_admin, accion="nueva_clave", usuario_id=usuario_id)
        clave2 = (r or {}).get("clave")
        anotar(estado == 200 and clave2 and clave2 != clave1, f"nueva_clave: {estado}")
        anotar(not entrar(CORREO_USUARIO, clave1)[0], "La temporal anterior ya no sirve")
        token_u, estado, _ = entrar(CORREO_USUARIO, clave2)
        anotar(bool(token_u), "La nueva temporal sirve")

        # ---- desactivar y reactivar
        estado, r = funcion(token_admin, accion="desactivar", usuario_id=usuario_id)
        anotar(estado == 200 and r["usuario"]["activo"] is False, f"Desactivar: {estado}")
        token_x, estado, r = entrar(CORREO_USUARIO, clave2)
        anotar(not token_x, f"Desactivado no entra: {estado} — {(r or {}).get('msg') or (r or {}).get('error_description')}")
        estado, r = http("GET", f"{URL}/rest/v1/usuarios?select=id", token=token_u)
        anotar(estado == 200 and r == [], f"Su sesión abierta ya no lee nada: {r}")
        estado, r = funcion(token_admin, accion="reactivar", usuario_id=usuario_id)
        anotar(estado == 200 and r["usuario"]["activo"] is True, f"Reactivar: {estado}")
        token_u, estado, _ = entrar(CORREO_USUARIO, clave2)
        anotar(bool(token_u), "Reactivado entra")
        estado, r = funcion(token_admin, accion="desactivar", usuario_id=admin_id)
        anotar(estado == 400, f"Un ADMIN no se desactiva a sí mismo: {estado}")

        # ---- el usuario cambia su contraseña
        clave3 = secrets.token_urlsafe(16) + "bB2#"
        estado, r = http("PUT", f"{URL}/auth/v1/user", {"password": clave3}, token=token_u)
        anotar(estado == 200, f"El usuario cambia su contraseña en Auth: {estado}")
        estado, r = http("POST", f"{URL}/rest/v1/rpc/fn_clave_cambiada", {}, token=token_u)
        cur.execute("SELECT debe_cambiar_clave FROM usuarios WHERE id = %s", (usuario_id,))
        anotar(estado in (200, 204) and cur.fetchone()[0] is False, "fn_clave_cambiada apaga la marca")
        token_u, _, sesion_u = entrar(CORREO_USUARIO, clave3)
        anotar(bool(token_u), "Entra con su contraseña nueva")

        # ---- auditoría con el ADMIN que lo hizo
        cur.execute("""SELECT campo, count(*) FROM auditoria
                       WHERE tabla = 'usuarios' AND fila_id = %s AND usuario_id = %s GROUP BY campo ORDER BY campo""",
                    (usuario_id, admin_id))
        por_campo = dict(cur.fetchall())
        esperado = {"(alta)": 1, "mercados": 1, "activo": 2, "(contraseña temporal)": 1}
        anotar(all(por_campo.get(k, 0) >= v for k, v in esperado.items()),
               f"Auditoría con el ADMIN: {por_campo}")
        cur.execute("""SELECT count(*) FROM auditoria
                       WHERE tabla = 'usuarios' AND fila_id = %s AND campo = 'debe_cambiar_clave' AND usuario_id = %s""",
                    (usuario_id, usuario_id))
        anotar(cur.fetchone()[0] == 1, "Auditoría del cambio de contraseña con el propio usuario")

        # ---- invitación por correo (sql/usuarios_invitacion.sql)
        invitacion(cur, token_admin, token_u, admin_id, usuario_id, mco)

        # ---- editar (sql/usuarios_edicion.sql)
        editar(cur, token_admin, token_u, admin_id, usuario_id, mco, clave3, (sesion_u or {}).get("refresh_token"))

        # ---- borrar (sql/usuarios_borrar.sql)
        borrar(cur, token_admin, admin_id, usuario_id, clave3)


def login_de(cur, correo):
    """(id, invitado, confirmado, con_clave) del login en Auth, o None."""
    cur.execute("""SELECT id::text, invited_at IS NOT NULL, email_confirmed_at IS NOT NULL,
                          coalesce(encrypted_password, '') <> ''
                   FROM auth.users WHERE email = %s""", (correo,))
    return cur.fetchone()


def invitacion(cur, token_admin, token_u, admin_id, usuario_con_clave_id, mco):
    """crear con invitar, reenviar_invitacion, auditoría de cada envío y la temporal como alternativa."""
    estado, r = funcion(token_admin, accion="crear", correo=CORREO_INVITADO, nombre="Prueba invitado",
                        rol="CLIENTE", mercados=[mco], invitar=True)
    inv = (r or {}).get("invitacion") or {}
    ok = estado == 200 and inv.get("enviada") is True and r.get("clave") is None
    anotar(ok, f"Crea usuario Cliente con invitación por correo: {estado} — {inv or (r or {}).get('error')}")
    if estado != 200 or not (r or {}).get("usuario"):
        return
    invitado_id = r["usuario"]["id"]
    anotar(r["usuario"].get("debe_cambiar_clave") is True and bool(r["usuario"].get("auth_user_id")),
           "El invitado queda con login vinculado y pendiente de crear su contraseña")

    login = login_de(cur, CORREO_INVITADO)
    anotar(bool(login) and login[1] and not login[2] and not login[3],
           f"En Auth: login invitado, sin confirmar y sin contraseña — {login and login[1:]}")
    cur.execute("SELECT rol::text, auth_user_id::text, (SELECT array_agg(mercado_id) FROM usuario_mercados WHERE usuario_id = u.id) "
                "FROM usuarios u WHERE id = %s", (invitado_id,))
    fila = cur.fetchone()
    anotar(bool(login) and fila == ("CLIENTE", login[0], [mco]), "En usuarios: rol Cliente, su mercado MCO y el mismo login de Auth")

    # Reglas: un no-ADMIN no reenvía; a quien ya creó su contraseña no se le reinvita.
    estado, _ = funcion(token_u, accion="reenviar_invitacion", usuario_id=invitado_id)
    anotar(estado == 403, f"No-ADMIN intenta reenviar_invitacion: {estado} (esperado 403)")
    estado, r = funcion(token_admin, accion="reenviar_invitacion", usuario_id=usuario_con_clave_id)
    anotar(estado == 400, f"No reinvita a quien ya creó su contraseña: {estado} — {(r or {}).get('error')}")
    estado, _ = http("POST", f"{URL}/rest/v1/rpc/fn_admin_registrar_invitacion",
                     {"p_usuario_id": invitado_id, "p_enviada": True}, token=token_u)
    anotar(estado in (401, 403), f"No-ADMIN llama directo a fn_admin_registrar_invitacion: {estado} (esperado 403)")

    # La alternativa: contraseña temporal a un invitado que nunca abrió el enlace.
    estado, r = funcion(token_admin, accion="nueva_clave", usuario_id=invitado_id)
    temporal = (r or {}).get("clave")
    token_i, estado_i, _ = entrar(CORREO_INVITADO, temporal) if temporal else (None, None, None)
    anotar(estado == 200 and bool(token_i), f"Contraseña temporal para un invitado: {estado}; entra con ella: {estado_i}")

    # Reenviar: login nuevo (el enlace viejo y la temporal mueren con el anterior), otra vez vinculado.
    estado, r = funcion(token_admin, accion="reenviar_invitacion", usuario_id=invitado_id)
    inv = (r or {}).get("invitacion") or {}
    anotar(estado == 200 and inv.get("enviada") is True, f"reenviar_invitacion: {estado} — {inv or (r or {}).get('error')}")
    login2 = login_de(cur, CORREO_INVITADO)
    anotar(bool(login and login2) and login2[0] != login[0] and login2[1] and not login2[3]
           and (r or {}).get("usuario", {}).get("auth_user_id") == login2[0],
           "El reenvío deja un login nuevo, invitado, sin contraseña y vinculado al mismo usuario")

    # Auditoría: cada envío con el ADMIN, a quién y el resultado.
    cur.execute("""SELECT valor_nuevo FROM auditoria
                   WHERE tabla = 'usuarios' AND fila_id = %s AND campo = '(invitación)' AND usuario_id = %s ORDER BY id""",
                (invitado_id, admin_id))
    envios = [f[0] for f in cur.fetchall()]
    anotar(envios == [f"enviada a {CORREO_INVITADO}"] * 2, f"Auditoría: dos envíos con el ADMIN — {envios}")
    cur.execute("""SELECT valor_nuevo FROM auditoria
                   WHERE tabla = 'usuarios' AND fila_id = %s AND campo = '(login)' AND usuario_id = %s""",
                (invitado_id, admin_id))
    anotar([f[0] for f in cur.fetchall()] == ["login recreado por reenvío de invitación"],
           "Auditoría: «login recreado por reenvío de invitación», una vez, con el ADMIN")
    anotar(not (temporal and entrar(CORREO_INVITADO, temporal)[0]), "La temporal anterior murió con el login viejo")

    # El enlace del correo, como lo canjea clave.html al hacer clic en «Continuar»:
    # {{ .TokenHash }} es lo que Auth guarda en confirmation_token. No se imprime.
    cur.execute("SELECT confirmation_token FROM auth.users WHERE email = %s", (CORREO_INVITADO,))
    token_hash = (cur.fetchone() or [None])[0]
    estado, r = http("POST", f"{URL}/auth/v1/verify", {"type": "invite", "token_hash": token_hash})
    token_i = (r or {}).get("access_token")
    anotar(estado == 200 and bool(token_i), f"«Continuar» canjea el enlace por una sesión: {estado}")
    estado, r = http("GET", f"{URL}/rest/v1/usuarios?select=rol,debe_cambiar_clave", token=token_i)
    anotar(estado == 200 and r == [{"rol": "CLIENTE", "debe_cambiar_clave": True}],
           f"El invitado lee su fila (rol y marca: lo que clave.html usa para pedir la contraseña y redirigir): {r}")
    estado, r = http("POST", f"{URL}/auth/v1/verify", {"type": "invite", "token_hash": token_hash})
    anotar(estado >= 400, f"El enlace sirve una sola vez: el segundo canje da {estado}")
    clave_i = secrets.token_urlsafe(16) + "cC3$"
    estado, _ = http("PUT", f"{URL}/auth/v1/user", {"password": clave_i}, token=token_i)
    estado2, _ = http("POST", f"{URL}/rest/v1/rpc/fn_clave_cambiada", {}, token=token_i)
    cur.execute("SELECT debe_cambiar_clave FROM usuarios WHERE id = %s", (invitado_id,))
    anotar(estado == 200 and estado2 in (200, 204) and cur.fetchone()[0] is False,
           f"El invitado crea su contraseña ({estado}) y la marca se apaga")
    anotar(bool(entrar(CORREO_INVITADO, clave_i)[0]), "El invitado entra con su contraseña")
    estado, r = funcion(token_admin, accion="reenviar_invitacion", usuario_id=invitado_id)
    anotar(estado == 400, f"Ya con contraseña propia no se le reinvita: {estado}")


def editar(cur, token_admin, token_u, admin_id, usuario_id, mco, clave_u, refresh_u):
    """Acción editar: mercados, nombre y rol; reglas; cierre de sesiones; auditoría."""
    cur.execute("SELECT id FROM mercados WHERE codigo = 'MLC'")
    mlc = cur.fetchone()[0]

    # Validaciones: 400, y un no-ADMIN 403.
    casos = [
        ("Equipo ZB sin mercados", dict(usuario_id=usuario_id, nombre="X", rol="ZB", mercados=[])),
        ("Cliente sin mercados", dict(usuario_id=usuario_id, nombre="X", rol="CLIENTE")),
        ("Proveedor sin proveedor", dict(usuario_id=usuario_id, nombre="X", rol="PROVEEDOR")),
        ("nombre vacío", dict(usuario_id=usuario_id, nombre=" ", rol="ZB", mercados=[mco])),
        ("el ADMIN se cambia su propio rol", dict(usuario_id=admin_id, nombre="Prueba ADMIN temporal", rol="LECTURA")),
    ]
    for nombre, cuerpo in casos:
        estado, r = funcion(token_admin, accion="editar", **cuerpo)
        anotar(estado == 400, f"editar rechaza {nombre}: {estado} — {(r or {}).get('error')}")
    estado, _ = funcion(token_admin, accion="editar", nombre="X", rol="ZB", mercados=[mco])
    anotar(estado == 400, f"editar sin usuario_id: {estado} (esperado 400)")
    estado, _ = funcion(token_u, accion="editar", usuario_id=usuario_id, nombre="X", rol="ADMIN")
    anotar(estado == 403, f"No-ADMIN intenta editar (subirse a ADMIN): {estado} (esperado 403)")
    estado, _ = http("POST", f"{URL}/rest/v1/rpc/fn_admin_editar_usuario",
                     {"p_usuario_id": usuario_id, "p_nombre": "X", "p_rol": "ADMIN",
                      "p_proveedor_id": None, "p_mercados": []}, token=token_u)
    anotar(estado in (401, 403), f"No-ADMIN llama directo a fn_admin_editar_usuario: {estado} (esperado 403)")

    # Agregar MLC: cambia el acceso, cierra sus sesiones; el correo no se toca.
    estado, r = funcion(token_admin, accion="editar", usuario_id=usuario_id, nombre="Prueba usuario",
                        rol="ZB", mercados=[mco, mlc], correo="otro@example.com")
    anotar(estado == 200 and r.get("acceso_cambio") is True and (r.get("sesiones_cerradas") or 0) >= 1,
           f"editar: agrega MLC — {estado}, acceso_cambio {(r or {}).get('acceso_cambio')}, "
           f"{(r or {}).get('sesiones_cerradas')} sesiones cerradas")
    anotar(estado == 200 and r["usuario"]["correo"] == CORREO_USUARIO, "editar no cambia el correo aunque llegue")
    cur.execute("SELECT array_agg(mercado_id ORDER BY mercado_id) FROM usuario_mercados WHERE usuario_id = %s", (usuario_id,))
    anotar(cur.fetchone()[0] == sorted([mco, mlc]), "Queda con MCO y MLC")
    if refresh_u:
        estado, r = http("POST", f"{URL}/auth/v1/token?grant_type=refresh_token", {"refresh_token": refresh_u})
        anotar(estado >= 400, f"Su sesión vieja ya no se renueva: {estado}")
    else:
        anotar(False, "No hubo refresh_token para probar el cierre de sesión")

    # Solo el nombre: no cierra sesiones (la sesión nueva se sigue renovando).
    _, _, sesion = entrar(CORREO_USUARIO, clave_u)
    estado, r = funcion(token_admin, accion="editar", usuario_id=usuario_id, nombre="Prueba usuario editado",
                        rol="ZB", mercados=[mco, mlc])
    anotar(estado == 200 and r.get("acceso_cambio") is False and r.get("sesiones_cerradas") == 0,
           f"editar solo el nombre: {estado}, sin cerrar sesiones ({(r or {}).get('sesiones_cerradas')})")
    estado, _ = http("POST", f"{URL}/auth/v1/token?grant_type=refresh_token",
                     {"refresh_token": (sesion or {}).get("refresh_token")})
    anotar(estado == 200, f"Su sesión sigue renovándose: {estado}")

    # A Lectura: ve todos, sin usuario_mercados.
    estado, r = funcion(token_admin, accion="editar", usuario_id=usuario_id, nombre="Prueba usuario editado",
                        rol="LECTURA", mercados=[mco])
    cur.execute("SELECT count(*) FROM usuario_mercados WHERE usuario_id = %s", (usuario_id,))
    anotar(estado == 200 and r["usuario"]["rol"] == "LECTURA" and r.get("mercados") == [] and cur.fetchone()[0] == 0,
           f"editar a Lectura: {estado}, sin mercados guardados")

    cur.execute("""SELECT campo, valor_anterior, valor_nuevo FROM auditoria
                   WHERE tabla = 'usuarios' AND fila_id = %s AND usuario_id = %s
                     AND campo IN ('mercados', 'nombre', 'rol', '(sesiones cerradas)') ORDER BY id""",
                (usuario_id, admin_id))
    filas = cur.fetchall()
    esperado = [("mercados", None, "MCO"), ("mercados", "MCO", "MCO,MLC"), ("nombre", "Prueba usuario", "Prueba usuario editado"),
                ("rol", "ZB", "LECTURA"), ("mercados", "MCO,MLC", None)]
    anotar(all(e in filas for e in esperado) and any(f[0] == "(sesiones cerradas)" for f in filas),
           f"Auditoría de editar con antes y después: {filas}")


def borrar(cur, token_admin, admin_id, usuario_id, clave_u):
    """Acción borrar: solo desactivados; fila, mercados y login fuera; auditoría."""
    # Un no-ADMIN no borra (el usuario quedó LECTURA activo tras editar).
    token_u, _, _ = entrar(CORREO_USUARIO, clave_u)
    estado, r = funcion(token_u, accion="borrar", usuario_id=admin_id)
    anotar(estado == 403, f"No-ADMIN intenta borrar: {estado} (esperado 403)")

    # Activo con login: primero desactivar. Y nadie se borra a sí mismo.
    estado, r = funcion(token_admin, accion="borrar", usuario_id=usuario_id)
    anotar(estado == 400 and "Desact" in ((r or {}).get("error") or ""),
           f"borrar un activo: {estado} — {(r or {}).get('error')}")
    estado, r = funcion(token_admin, accion="borrar", usuario_id=admin_id)
    anotar(estado == 400, f"borrar(se) a sí mismo: {estado} — {(r or {}).get('error')}")

    # Desactivado sí: fila, mercados y login fuera, sin advertencia.
    estado, _ = funcion(token_admin, accion="desactivar", usuario_id=usuario_id)
    anotar(estado == 200, f"Desactivar antes de borrar: {estado}")
    estado, r = funcion(token_admin, accion="borrar", usuario_id=usuario_id)
    anotar(estado == 200 and (r or {}).get("borrado") is True and not (r or {}).get("advertencia"),
           f"borrar un desactivado: {estado}, sin advertencia")
    cur.execute("SELECT count(*) FROM usuarios WHERE id = %s", (usuario_id,))
    n_fila = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM usuario_mercados WHERE usuario_id = %s", (usuario_id,))
    n_merc = cur.fetchone()[0]
    cur.execute("SELECT count(*) FROM auth.users WHERE email = %s", (CORREO_USUARIO,))
    n_login = cur.fetchone()[0]
    anotar(n_fila == 0 and n_merc == 0 and n_login == 0,
           f"Fila ({n_fila}), mercados ({n_merc}) y login en Auth ({n_login}) ya no existen")
    anotar(not entrar(CORREO_USUARIO, clave_u)[0], "Ya no puede entrar")

    # Auditoría: la (baja) con el ADMIN; sus filas históricas marcadas «(borrado)».
    cur.execute("""SELECT count(*) FROM auditoria
                   WHERE tabla = 'usuarios' AND fila_id = %s AND campo = '(baja)' AND usuario_id = %s""",
                (usuario_id, admin_id))
    anotar(cur.fetchone()[0] == 1, "Auditoría: fila (baja) con el ADMIN")
    cur.execute("""SELECT count(*) FROM auditoria
                   WHERE fila_id = %s AND campo = 'debe_cambiar_clave' AND usuario_id IS NULL
                     AND usuario_borrado LIKE %s""", (usuario_id, "%" + CORREO_USUARIO + " (borrado)"))
    anotar(cur.fetchone()[0] == 1,
           "Sus filas históricas quedan con usuario_id NULL y la marca «nombre · correo (borrado)»")
    cur.execute("SELECT count(*) FROM auditoria WHERE usuario_id = %s AND usuario_borrado IS NOT NULL", (admin_id,))
    anotar(cur.fetchone()[0] == 0, "Las filas de otros autores siguen sin marca")

    # Repetir da 400: ya no existe.
    estado, r = funcion(token_admin, accion="borrar", usuario_id=usuario_id)
    anotar(estado == 400, f"borrar dos veces: {estado} — {(r or {}).get('error')}")


def main():
    conn = psycopg2.connect()
    conn.autocommit = True
    cur = conn.cursor()
    try:
        flujo(cur)
    except Exception as e:
        anotar(False, f"La prueba se cortó: {e!r}")
    finally:
        # ---- llave secreta en el repo
        hallazgos = buscar_llave()
        anotar(not hallazgos, "git grep: ninguna llave secreta (sb_secret_ ni JWT service_role) en archivos ni historial"
               + (f" — {hallazgos}" if hallazgos else ""))
        logins, usuarios, auditoria = limpiar(cur)
        correos = (CORREO_ADMIN, CORREO_USUARIO, CORREO_INVITADO)
        cur.execute("SELECT (SELECT count(*) FROM usuarios WHERE correo IN %s) + (SELECT count(*) FROM auth.users WHERE email IN %s)",
                    (correos, correos))
        quedan = cur.fetchone()[0]
        anotar(quedan == 0, f"Limpieza: {logins} logins, {usuarios} usuarios y {auditoria} filas de auditoría de prueba "
                            f"borrados; quedan {quedan}")
        conn.close()

    fallas = sum(1 for l in informe if l.startswith("FALLA"))
    print(f"PRUEBAS DE USUARIOS — {'TODAS OK' if not fallas else f'{fallas} FALLAS'}")
    print("\n".join(informe))
    sys.exit(1 if fallas else 0)


if __name__ == "__main__":
    main()
