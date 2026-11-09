-- =============================================================================
-- OASIS v2.0 — Varios mercados: valores nuevos de enums
-- =============================================================================
-- Va aparte de sql/mercados.sql porque Postgres no deja USAR un valor nuevo de
-- un enum en la misma transacción que lo agrega: este archivo se confirma
-- primero, y después ya se puede cargar MLA con COLOCACION.
--
-- Aditivo: no cambia ninguna fila ni ningún valor existente.
-- =============================================================================

-- MLA cobra la instalación aparte: es un costo distinto de PRODUCCION.
-- Ojo con la fórmula del valor total: solo PRODUCCION está exceptuada de
-- multiplicar por semanas, así que una COLOCACION con tiempo SEMANA sí
-- multiplicaría. Hoy MLA no trae ninguna con SEMANA.
ALTER TYPE public.tipo_costo_enum ADD VALUE IF NOT EXISTS 'COLOCACION';

-- MLM registra la modalidad de pago: FACTURABLE (576 compras) y PAGO ANTICIPADO
-- (72). Son los únicos valores de TIPO DE COMPRA de los cinco Flows que faltaban
-- (revisado el 19 de octubre de 2026). Nada del cálculo depende del tipo de
-- compra; «compra sin valor» solo excluye BONIFICADO.
ALTER TYPE public.tipo_compra_enum ADD VALUE IF NOT EXISTS 'FACTURABLE';
ALTER TYPE public.tipo_compra_enum ADD VALUE IF NOT EXISTS 'PAGO ANTICIPADO';
