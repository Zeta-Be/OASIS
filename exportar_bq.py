#!/usr/bin/env python3
"""
OASIS v2.0 — Exporta la inversión diaria a BigQuery para BI.

Copia v_inversion_diaria (los cinco mercados, las 22 columnas del contrato con
BI, más exportado_en al final) a mbw-spl-brazil.ds_meli_oasis.inversion_diaria.
Reemplaza la tabla completa en cada corrida (WRITE_TRUNCATE): BI ve siempre la
foto entera, nunca una carga a medias. Si algo falla, la tabla queda como
estaba.

Se corre después de cada carga del Sheets:
    source .env
    python3 cargar_oasis.py --todos
    python3 exportar_bq.py               # exporta
    python3 exportar_bq.py --dry-run     # lee y valida, no sube nada

Credenciales de Google: las de `gcloud auth application-default login` (las de
quien corre el script; necesita crear tablas y jobs en el proyecto). Con
--credenciales se usa la llave de una cuenta de servicio.

Ojo: estado y costo_ejecutado dependen de la fecha de corte (nula = hoy) del
momento en que se exporta. En BigQuery quedan fijos hasta la siguiente
exportación; exportado_en dice de cuándo es la foto.
"""

import argparse
import io
import json
import os
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal

import google.auth
import psycopg2
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PROYECTO = "mbw-spl-brazil"
DATASET = "ds_meli_oasis"
TABLA = "inversion_diaria"
UBICACION = "US"
API = "https://bigquery.googleapis.com/bigquery/v2"
SUBIDA = "https://bigquery.googleapis.com/upload/bigquery/v2"
ALCANCE = ["https://www.googleapis.com/auth/bigquery"]

# Contrato con BI: nombre, tipo en BigQuery y descripción, en el orden de la
# vista. Si la vista cambia de columnas u orden, el script se detiene.
ESQUEMA = [
    ("site", "STRING", "Mercado (MCO, MLC, MLU, MLA, MLM)"),
    ("bu", "STRING", "Cliente / unidad de negocio de la compra"),
    ("year", "INT64", "Año del día de ejecución"),
    ("month", "INT64", "Mes del día de ejecución: la columna estándar para reportar por mes"),
    ("week", "INT64", "Semana ISO del día de ejecución"),
    ("date", "DATE", "Día de ejecución"),
    ("proveedor", "STRING", "Proveedor de la compra"),
    ("tipo_costo", "STRING", "EXHIBICION, PRODUCCION, IMPUESTOS, COLOCACION"),
    ("formato", "STRING", "Formato de la compra"),
    ("valor_total", "NUMERIC", "Valor total de la compra (se repite en cada fila)"),
    ("id", "STRING", "Código de la compra (001, 002…)"),
    ("id_ejecucion", "STRING", "Código del material (001-A, 001-B…)"),
    ("campana", "STRING", "Campaña de la compra"),
    ("sub_campana", "STRING", "Sub campaña del material"),
    ("pct_participacion", "NUMERIC", "Fracción del costo del día que le toca al material (1 = solo)"),
    ("costo_proyectado", "NUMERIC", "Costo del material ese día, en la moneda del mercado"),
    ("estado", "STRING", "EJECUTADO hasta la fecha de corte, PROGRAMADO después"),
    ("costo_ejecutado", "NUMERIC", "costo_proyectado si el día ya pasó la fecha de corte; si no, 0"),
    ("mes_compra", "DATE", "Primer día del mes de inicio de la compra: solo para conciliar con el Flow o la facturación"),
    ("moneda", "STRING", "Moneda del mercado (COP, CLP, UYU, ARS, MXN…): nunca sumar mercados"),
    ("mercado_id", "INT64", "Id interno del mercado"),
    ("campana_grupo", "STRING", "Campaña para filtros: las OTH-PF cuentan como PARQUE FIJO"),
    ("exportado_en", "TIMESTAMP", "Cuándo se exportó esta foto desde OASIS"),
]

NUEVE = Decimal("0.000000001")   # NUMERIC de BigQuery admite 9 decimales


def sesion(credenciales):
    if credenciales:
        cred = service_account.Credentials.from_service_account_file(credenciales, scopes=ALCANCE)
    else:
        cred, _ = google.auth.default(scopes=ALCANCE)
    return AuthorizedSession(cred)


def revisar(r):
    if r.status_code >= 300:
        sys.exit(f"BigQuery respondió {r.status_code}: {r.text[:800]}")
    return r.json() if r.content else {}


def leer_oasis(exportado_en):
    """Lee la vista entera y la devuelve como NDJSON, con los totales por mercado."""
    conn = psycopg2.connect()
    try:
        cur = conn.cursor(name="exportar")   # cursor de servidor: no carga todo de una vez
        cur.itersize = 5000
        cur.execute("SELECT * FROM v_inversion_diaria ORDER BY mercado_id, date, id_ejecucion")
        filas = cur.fetchmany(1)
        columnas = [d.name for d in cur.description]
        esperadas = [c for c, _, _ in ESQUEMA[:-1]]
        if columnas != esperadas:
            sys.exit("v_inversion_diaria no tiene las columnas del contrato con BI.\n"
                     f"  esperaba: {esperadas}\n  encontré: {columnas}")

        buf = io.BytesIO()
        totales = {}
        while filas:
            for f in filas:
                reg = {}
                for (col, tipo, _), v in zip(ESQUEMA, f):
                    if v is None:
                        reg[col] = None
                    elif tipo == "NUMERIC":
                        reg[col] = str(Decimal(v).quantize(NUEVE))
                    elif tipo == "DATE":
                        reg[col] = v.isoformat()
                    else:
                        reg[col] = v
                reg["exportado_en"] = exportado_en
                buf.write((json.dumps(reg, ensure_ascii=False) + "\n").encode("utf-8"))
                t = totales.setdefault(reg["site"], [0, Decimal(0)])
                t[0] += 1
                t[1] += Decimal(reg["costo_proyectado"] or 0)
            filas = cur.fetchmany(5000)
        return buf.getvalue(), totales
    finally:
        conn.close()


def asegurar_dataset(s):
    url = f"{API}/projects/{PROYECTO}/datasets/{DATASET}"
    r = s.get(url)
    if r.status_code == 200:
        return
    if r.status_code != 404:
        revisar(r)
    revisar(s.post(f"{API}/projects/{PROYECTO}/datasets", json={
        "datasetReference": {"projectId": PROYECTO, "datasetId": DATASET},
        "location": UBICACION,
        "description": "OASIS v2.0 — pauta OOH de Mercado Libre (ZetaB). Lo llena exportar_bq.py; no se edita a mano.",
    }))
    print(f"  Dataset {PROYECTO}.{DATASET} creado ({UBICACION}).")


def subir(s, datos):
    """Load job resumable con WRITE_TRUNCATE. Devuelve cuando termina."""
    config = {"configuration": {"load": {
        "destinationTable": {"projectId": PROYECTO, "datasetId": DATASET, "tableId": TABLA},
        "schema": {"fields": [{"name": c, "type": t, "mode": "NULLABLE", "description": d}
                              for c, t, d in ESQUEMA]},
        "sourceFormat": "NEWLINE_DELIMITED_JSON",
        "writeDisposition": "WRITE_TRUNCATE",
        "createDisposition": "CREATE_IF_NEEDED",
        "clustering": {"fields": ["mercado_id", "date"]},
        "destinationTableProperties": {
            "description": "Inversión diaria por material (copia de v_inversion_diaria de OASIS). "
                           "Cada mercado en su moneda: nunca sumar mercados. Reportar por mes con month.",
        },
    }, "jobReference": {"projectId": PROYECTO, "location": UBICACION}}}
    r = s.post(f"{SUBIDA}/projects/{PROYECTO}/jobs?uploadType=resumable", json=config,
               headers={"X-Upload-Content-Type": "application/octet-stream"})
    revisar(r)
    job = revisar(s.put(r.headers["Location"], data=datos,
                        headers={"Content-Type": "application/octet-stream"}))
    jid = job["jobReference"]["jobId"]
    while job["status"]["state"] != "DONE":
        time.sleep(2)
        job = revisar(s.get(f"{API}/projects/{PROYECTO}/jobs/{jid}?location={UBICACION}"))
    if "errorResult" in job["status"]:
        errores = job["status"].get("errors", [])[:5]
        sys.exit(f"La carga a BigQuery falló; la tabla quedó como estaba.\n  {job['status']['errorResult']}\n  {errores}")


def totales_bq(s):
    r = revisar(s.post(f"{API}/projects/{PROYECTO}/queries", json={
        "query": f"SELECT site, count(*), sum(costo_proyectado) FROM `{PROYECTO}.{DATASET}.{TABLA}` GROUP BY site",
        "useLegacySql": False, "location": UBICACION, "timeoutMs": 60000,
    }))
    return {f["f"][0]["v"]: (int(f["f"][1]["v"]), Decimal(f["f"][2]["v"])) for f in r.get("rows", [])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="lee y valida, no sube nada")
    ap.add_argument("--credenciales", help="llave de cuenta de servicio (default: credenciales de gcloud)")
    args = ap.parse_args()
    if not os.getenv("PGHOST"):
        sys.exit("Faltan las variables de conexión. Corre: source .env")

    exportado_en = datetime.now(timezone.utc).isoformat(timespec="seconds")
    datos, totales = leer_oasis(exportado_en)
    print(f"  Leído de OASIS: {sum(n for n, _ in totales.values())} filas, {len(datos) / 1e6:.1f} MB")
    if args.dry_run:
        for m, (n, c) in sorted(totales.items()):
            print(f"    {m}: {n:>6} filas · costo proyectado {c:,.2f}")
        print("  Simulación: no se subió nada.")
        return

    s = sesion(args.credenciales)
    asegurar_dataset(s)
    subir(s, datos)

    # Verificación: mismas filas y mismo costo por mercado que en OASIS.
    bq, fallas = totales_bq(s), 0
    print(f"  Exportado a {PROYECTO}.{DATASET}.{TABLA} ({exportado_en})")
    for m in sorted(set(totales) | set(bq)):
        n, c = totales.get(m, (0, Decimal(0)))
        nb, cb = bq.get(m, (0, Decimal(0)))
        ok = n == nb and abs(c - cb) < 1
        fallas += not ok
        print(f"    {m}: {nb:>6} filas · costo proyectado {cb:,.2f}  {'OK' if ok else f'FALLA (OASIS: {n} filas, {c:,.2f})'}")
    sys.exit(1 if fallas else 0)


if __name__ == "__main__":
    main()
