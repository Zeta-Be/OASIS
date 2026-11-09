-- =============================================================================
-- OASIS v2.0 — Rol CLIENTE (va primero y aparte)
-- =============================================================================
-- Un valor nuevo de enum no se puede usar en la misma transacción en que se
-- agrega. Por eso va solo, antes de sql/dashboard.sql (como mercados_enum.sql).
--
-- CLIENTE: la gente de Mercado Libre que ve el dashboard regional. Se le asignan
-- mercados en usuario_mercados, igual que a un Equipo ZB (fn_mis_mercados() ya
-- los devuelve). No lee ninguna tabla: las políticas de RLS nombran los roles
-- uno por uno y CLIENTE no está en ninguna. Solo ejecuta las funciones
-- fn_dashboard_* de sql/dashboard.sql.
-- =============================================================================

ALTER TYPE public.rol_enum ADD VALUE IF NOT EXISTS 'CLIENTE';
