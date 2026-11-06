# OASIS v2.0 — Imagen del job diario de Cloud Run (ver diario.sh).
# Solo lleva los scripts y mercados.json. Las credenciales no van en la imagen:
# Cloud Run las pone desde Secret Manager (PGPASSWORD y la llave de la cuenta
# de servicio de los Sheets).
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    CREDENCIALES_GOOGLE=/secretos/google/credenciales.json

RUN pip install --no-cache-dir gspread==6.2.1 openpyxl==3.1.5 psycopg2-binary==2.9.10 google-auth==2.40.3 requests==2.32.3

WORKDIR /oasis
COPY cargar_oasis.py exportar_bq.py mercados.json diario.sh ./

CMD ["sh", "diario.sh"]
