#!/usr/bin/env python3
"""
OASIS v2.0 — Compara el dashboard de OASIS contra el dashboard original.

    source .env && python3 comparar_dashboard.py [referencias/dashboard_original.html]

El original es un HTML con la inversión de los cinco mercados pegada adentro
(bloque jdata). Ese archivo es del cliente: vive en referencias/, que está en
el .gitignore, y este script solo lo lee en el equipo de quien lo corre. No
escribe nada ni guarda cifras.

Por mercado y mes muestra: el original (total, parte ML y parte MP), lo que da
OASIS (fn_dashboard_filas, la misma fuente de fn_dashboard_mercado) y la
diferencia contra la parte ML, con la causa probable:
  * «MP no cargado»   el original trae campañas de Mercado Pago que OASIS
                       todavía no carga (MLU, MLC, MLM);
  * «corte distinto»   el mes en curso: el original se cortó otro día;
  * «revisar»          cualquier otra diferencia de $1 o más.
"""

import collections
import json
import os
import sys
from datetime import date

import psycopg2

RAIZ = os.path.dirname(os.path.abspath(__file__))


def leer_original(ruta):
    h = open(ruta, encoding="utf-8").read()
    ini = h.find('id="jdata">')
    if ini < 0:
        sys.exit(f"{ruta} no tiene el bloque jdata del dashboard original.")
    ini += len('id="jdata">')
    datos = json.loads(h[ini:h.find("</script>", ini)])
    total, ml = collections.Counter(), collections.Counter()
    for mercado, d in datos.items():
        s = d["s"]
        for r in d["r"]:               # [mes, semana, prov, tc, formato, campaña, sub, costo, cliente, …]
            total[(mercado, r[0])] += r[7]
            if s[r[8]] != "MP":
                ml[(mercado, r[0])] += r[7]
    return total, ml


def leer_oasis(anio):
    cur = psycopg2.connect().cursor()
    cur.execute("""
        SELECT m.codigo, f.mes, sum(f.costo)
        FROM public.fn_dashboard_filas((SELECT array_agg(id) FROM public.mercados), %s) f
        JOIN public.mercados m ON m.id = f.mercado_id
        GROUP BY 1, 2
    """, (anio,))
    return {(m, mes): float(v) for m, mes, v in cur.fetchall()}


def main():
    if not os.getenv("PGHOST"):
        sys.exit("Faltan las variables de conexión. Corre: source .env")
    ruta = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RAIZ, "referencias", "dashboard_original.html")
    total, ml = leer_original(ruta)
    hoy = date.today()
    oasis = leer_oasis(hoy.year)

    for mercado in sorted({m for m, _ in total}):
        meses = sorted({mes for m, mes in list(total) + list(oasis) if m == mercado})
        print(f"\n{mercado}   mes | original total | original ML | original MP |       OASIS | OASIS − ML | causa")
        sumas = collections.Counter()
        for mes in meses:
            t, l, o = total.get((mercado, mes), 0), ml.get((mercado, mes), 0), oasis.get((mercado, mes), 0)
            mp, d = t - l, o - l
            causas = []
            if mp >= 1:
                causas.append("MP no cargado")
            if abs(d) >= 1:
                causas.append("corte distinto" if mes == hoy.month else "revisar")
            for k, v in (("t", t), ("l", l), ("mp", mp), ("o", o)):
                sumas[k] += v
            print(f"     {mes:>7} | {t:>14,.0f} | {l:>11,.0f} | {mp:>11,.0f} | {o:>11,.0f} | {d:>10,.0f} | {', '.join(causas) or 'cuadra'}")
        print(f"     {'total':>7} | {sumas['t']:>14,.0f} | {sumas['l']:>11,.0f} | {sumas['mp']:>11,.0f} | {sumas['o']:>11,.0f} | "
              f"{sumas['o'] - sumas['l']:>10,.0f} |")


if __name__ == "__main__":
    main()
