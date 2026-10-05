-- =============================================================================
-- USUARIOS MADRE — operador bancario y administrador del sistema
-- =============================================================================
-- Crea los dos primeros usuarios de la plataforma cuando la base se armó con
-- inserts_iniciales.sql (esquema existente + catálogos + entidad banco), en lugar de
-- con instalacion_inicial.sql, que ya los incluye. Se ejecuta una sola vez, después
-- de inserts_iniciales.sql:
--   - Operador bancario (rol ADMIN): opera la plataforma y, desde Gestión de
--     usuarios, crea usuarios ADMIN, PAYER y SUPPLIER.
--   - Administrador del sistema (rol SYSTEM_ADMIN): administra los parámetros.
--     Este rol solo se asigna directamente en la base de datos.
-- Los dos quedan en la entidad banco (tipo BANCO) que creó inserts_iniciales.sql,
-- identificada por su NIT.
--
-- SQL estándar de PostgreSQL (16): no usa comandos de psql, así que corre igual en
-- psql, pgAdmin (Query Tool), DBeaver o cualquier cliente que ejecute scripts.
--
-- Uso:
--   1. Completar la sección PARÁMETROS (reemplazar cada 'COMPLETAR' por el valor,
--      entre comillas simples).
--   2. Ejecutarlo completo con cualquiera de:
--        - psql -h <host> -U <usuario> -d <base> -v ON_ERROR_STOP=1 -f usuarios_madre.sql
--        - pgAdmin o DBeaver: abrir el archivo y ejecutarlo como script.
--
-- Todo corre en una sola transacción. Si falta un parámetro, un formato no es
-- válido, no existe la entidad banco o el DUI o el correo ya están registrados, el
-- script se detiene y no deja nada creado.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- PARÁMETROS
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE usuarios_madre_parametros (clave text PRIMARY KEY, valor text) ON COMMIT DROP;

INSERT INTO usuarios_madre_parametros (clave, valor) VALUES
    -- NIT de la entidad banco, el mismo que se usó en inserts_iniciales.sql.
    ('banco_nit',          'COMPLETAR'),

    -- Operador bancario (rol ADMIN). DUI de 9 dígitos; se acepta guion (01234567-8).
    ('operador_dui',       'COMPLETAR'),
    ('operador_correo',    'COMPLETAR'),
    ('operador_nombres',   'COMPLETAR'),
    ('operador_apellidos', 'COMPLETAR'),

    -- Administrador del sistema (rol SYSTEM_ADMIN).
    ('sysadmin_dui',       'COMPLETAR'),
    ('sysadmin_correo',    'COMPLETAR'),
    ('sysadmin_nombres',   'COMPLETAR'),
    ('sysadmin_apellidos', 'COMPLETAR');

-- -----------------------------------------------------------------------------
-- EJECUCIÓN (no modificar a partir de aquí)
-- -----------------------------------------------------------------------------

-- Mismo formato con el que la API guarda los datos: identificadores sin guiones ni
-- espacios y correos en minúsculas.
UPDATE usuarios_madre_parametros SET valor = btrim(valor);
UPDATE usuarios_madre_parametros SET valor = regexp_replace(valor, '[\s-]', '', 'g')
WHERE clave IN ('banco_nit', 'operador_dui', 'sysadmin_dui');
UPDATE usuarios_madre_parametros SET valor = lower(valor) WHERE clave IN ('operador_correo', 'sysadmin_correo');

DO $$
DECLARE
    v_pendientes text;
    v_nit        text := (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'banco_nit');
    v_registrado text;
BEGIN
    SELECT string_agg(clave, ', ' ORDER BY clave) INTO v_pendientes
    FROM usuarios_madre_parametros
    WHERE valor IS NULL OR valor = '' OR upper(valor) = 'COMPLETAR';
    IF v_pendientes IS NOT NULL THEN
        RAISE EXCEPTION 'Faltan parámetros por completar: %', v_pendientes;
    END IF;

    IF v_nit !~ '^\d{14}$' THEN
        RAISE EXCEPTION 'El NIT del banco debe tener exactamente 14 dígitos.';
    END IF;
    IF (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'operador_dui') !~ '^\d{9}$' THEN
        RAISE EXCEPTION 'El DUI del operador debe tener exactamente 9 dígitos.';
    END IF;
    IF (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'sysadmin_dui') !~ '^\d{9}$' THEN
        RAISE EXCEPTION 'El DUI del administrador del sistema debe tener exactamente 9 dígitos.';
    END IF;
    IF EXISTS (SELECT 1 FROM usuarios_madre_parametros
               WHERE clave IN ('operador_correo', 'sysadmin_correo') AND valor !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
        RAISE EXCEPTION 'Alguno de los correos no tiene un formato válido.';
    END IF;
    IF EXISTS (SELECT 1 FROM usuarios_madre_parametros WHERE length(valor) > 255) THEN
        RAISE EXCEPTION 'Los nombres, apellidos y correos admiten máximo 255 caracteres.';
    END IF;
    IF (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'operador_dui')
     = (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'sysadmin_dui') THEN
        RAISE EXCEPTION 'El operador y el administrador del sistema deben tener DUI distintos.';
    END IF;
    IF (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'operador_correo')
     = (SELECT valor FROM usuarios_madre_parametros WHERE clave = 'sysadmin_correo') THEN
        RAISE EXCEPTION 'El operador y el administrador del sistema deben tener correos distintos.';
    END IF;

    IF (SELECT count(*) FROM public.roles_cat
        WHERE id IN ('b1000000-0000-4000-8000-000000000001', 'b1000000-0000-4000-8000-000000000007')) <> 2 THEN
        RAISE EXCEPTION 'Faltan los roles ADMIN y SYSTEM_ADMIN. Ejecute primero inserts_iniciales.sql.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.entities
                   WHERE nit = v_nit AND entity_type_id = 'a1000000-0000-4000-8000-000000000003') THEN
        RAISE EXCEPTION 'No existe una entidad de tipo BANCO con el NIT %. Ejecute primero inserts_iniciales.sql con ese NIT.', v_nit;
    END IF;

    SELECT string_agg(u.dui || ' / ' || u.email, ', ') INTO v_registrado
    FROM public.users u
    WHERE u.dui IN (SELECT valor FROM usuarios_madre_parametros WHERE clave IN ('operador_dui', 'sysadmin_dui'))
       OR u.email IN (SELECT valor FROM usuarios_madre_parametros WHERE clave IN ('operador_correo', 'sysadmin_correo'));
    IF v_registrado IS NOT NULL THEN
        RAISE EXCEPTION 'Ya existen usuarios con el mismo DUI o correo: %', v_registrado;
    END IF;
END
$$;

WITH p AS (
    SELECT max(valor) FILTER (WHERE clave = 'banco_nit') AS banco_nit,
           max(valor) FILTER (WHERE clave = 'operador_dui') AS operador_dui,
           max(valor) FILTER (WHERE clave = 'operador_correo') AS operador_correo,
           max(valor) FILTER (WHERE clave = 'operador_nombres') AS operador_nombres,
           max(valor) FILTER (WHERE clave = 'operador_apellidos') AS operador_apellidos,
           max(valor) FILTER (WHERE clave = 'sysadmin_dui') AS sysadmin_dui,
           max(valor) FILTER (WHERE clave = 'sysadmin_correo') AS sysadmin_correo,
           max(valor) FILTER (WHERE clave = 'sysadmin_nombres') AS sysadmin_nombres,
           max(valor) FILTER (WHERE clave = 'sysadmin_apellidos') AS sysadmin_apellidos
    FROM usuarios_madre_parametros
)
INSERT INTO public.users (id, created_at, dui, email, first_name, last_name, status, updated_at, entity_id, role_id)
SELECT gen_random_uuid(), now(), u.dui, u.email, u.first_name, u.last_name, 'ACTIVE', now(), e.id, u.role_id
FROM p
JOIN public.entities e ON e.nit = p.banco_nit
CROSS JOIN LATERAL (VALUES
    (p.operador_dui, p.operador_correo, p.operador_nombres, p.operador_apellidos,
     'b1000000-0000-4000-8000-000000000001'::uuid),
    (p.sysadmin_dui, p.sysadmin_correo, p.sysadmin_nombres, p.sysadmin_apellidos,
     'b1000000-0000-4000-8000-000000000007'::uuid)
) AS u(dui, email, first_name, last_name, role_id);

COMMIT;

-- -----------------------------------------------------------------------------
-- VERIFICACIÓN
-- -----------------------------------------------------------------------------
SELECT e.name AS entidad, e.code AS codigo, u.first_name AS nombres, u.last_name AS apellidos,
       u.email AS correo, r.name AS rol, u.status AS estado
FROM public.users u
JOIN public.entities e ON e.id = u.entity_id
JOIN public.roles_cat r ON r.id = u.role_id
WHERE r.name IN ('ADMIN', 'SYSTEM_ADMIN')
ORDER BY r.name, u.email;
