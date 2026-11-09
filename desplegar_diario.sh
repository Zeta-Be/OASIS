#!/bin/sh
# OASIS v2.0 — Despliega (o actualiza) la corrida diaria en Google Cloud.
#
#   source .env && sh desplegar_diario.sh
#
# Crea o actualiza, en mbw-spl-brazil (us-central1):
#   1. Secretos en Secret Manager: oasis-pgpassword (de .env) y
#      oasis-credenciales-google (credenciales_google.json, para leer los Sheets).
#   2. La imagen del job (Dockerfile; .gcloudignore deja subir solo los scripts).
#   3. El job de Cloud Run oasis-diario, que corre diario.sh.
#   4. La programación en Cloud Scheduler: todos los días a las 6:00 hora Colombia.
#
# Corre como la cuenta de servicio por defecto del proyecto (655979796114-compute),
# que tiene rol Editor: con eso escribe en BigQuery y lee los secretos. Si un
# admin de GCP le da a oasis-lector BigQuery Job User y Data Editor en el dataset,
# basta cambiar CUENTA y volver a desplegar.
#
# Necesita gcloud con sesión (gcloud auth login). Repetible: si algo ya existe,
# lo actualiza.
set -e

PROYECTO=mbw-spl-brazil
REGION=us-central1
CUENTA=655979796114-compute@developer.gserviceaccount.com
IMAGEN=$REGION-docker.pkg.dev/$PROYECTO/oasis/oasis-diario
DIRECTORIO=$(cd "$(dirname "$0")" && pwd)

[ -n "$PGPASSWORD" ] || { echo "Faltan las variables de conexión. Corre: source .env"; exit 1; }
gcloud config set project $PROYECTO >/dev/null

secreto() {   # secreto NOMBRE ARCHIVO: crea el secreto o le agrega una versión
    if gcloud secrets describe "$1" >/dev/null 2>&1; then
        gcloud secrets versions add "$1" --data-file="$2"
    else
        gcloud secrets create "$1" --replication-policy=automatic --data-file="$2"
    fi
}
printf %s "$PGPASSWORD" | secreto oasis-pgpassword -
secreto oasis-credenciales-google "$DIRECTORIO/credenciales_google.json"

gcloud artifacts repositories describe oasis --location=$REGION >/dev/null 2>&1 ||
    gcloud artifacts repositories create oasis --repository-format=docker --location=$REGION \
        --description="OASIS: imagen del job diario"
gcloud builds submit "$DIRECTORIO" --tag "$IMAGEN"

gcloud run jobs deploy oasis-diario --region=$REGION --image="$IMAGEN" \
    --service-account=$CUENTA \
    --set-env-vars="PGHOST=$PGHOST,PGPORT=$PGPORT,PGDATABASE=$PGDATABASE,PGUSER=$PGUSER,PGSSLMODE=$PGSSLMODE" \
    --set-secrets="PGPASSWORD=oasis-pgpassword:latest,/secretos/google/credenciales.json=oasis-credenciales-google:latest" \
    --task-timeout=30m --max-retries=0 --memory=1Gi --cpu=1

URL="https://run.googleapis.com/v2/projects/$PROYECTO/locations/$REGION/jobs/oasis-diario:run"
if gcloud scheduler jobs describe oasis-diario --location=$REGION >/dev/null 2>&1; then
    accion=update
else
    accion=create
fi
gcloud scheduler jobs $accion http oasis-diario --location=$REGION \
    --schedule="0 6 * * *" --time-zone="America/Bogota" \
    --uri="$URL" --http-method=POST --oauth-service-account-email=$CUENTA \
    --description="OASIS: carga los Sheets y exporta la inversión diaria a BigQuery"

echo "Listo. Para correrlo ahora: gcloud run jobs execute oasis-diario --region=$REGION --wait"
