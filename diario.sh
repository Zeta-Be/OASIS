#!/bin/sh
# OASIS v2.0 — Corrida diaria en Cloud Run (job oasis-diario).
#
# 1. Carga los cinco mercados desde sus Sheets (cargar_oasis.py --todos). Cada
#    mercado va en su transacción: si uno falla o lo detiene el freno de
#    renumeración, los demás se cargan igual.
# 2. Exporta la inversión diaria a BigQuery (exportar_bq.py), aunque algún
#    mercado haya fallado: BI recibe lo que sí se cargó, y el mercado que no se
#    cargó queda con los datos del día anterior.
#
# Sale con error si cualquiera de los dos pasos falló, para que la ejecución
# quede marcada como fallida en Cloud Run.

python3 cargar_oasis.py --todos --credenciales "$CREDENCIALES_GOOGLE"
carga=$?

python3 exportar_bq.py
exportacion=$?

echo "Carga: $([ $carga -eq 0 ] && echo ok || echo FALLÓ) · Exportación a BigQuery: $([ $exportacion -eq 0 ] && echo ok || echo FALLÓ)"
[ $carga -eq 0 ] && [ $exportacion -eq 0 ]
