-- =============================================================================
-- INSTALACIÓN INICIAL DE PRODUCCIÓN — Financiamiento de Cuentas por Pagar
-- =============================================================================
-- Deja el sistema listo para operar sobre una base PostgreSQL 16 vacía, sin Flyway:
--   1. Esquema completo (tablas, llaves, restricciones e índices).
--   2. Catálogos: tipos de entidad, roles, rutas y menús por rol, políticas de pago y
--      de desembolso, columnas de la plantilla de carga, términos y condiciones
--      vigentes y feriados. La plantilla y su manual los publica el ADMIN en su primer
--      ingreso (db/prod/plantilla_carga_documentos.xlsx y db/prod/manual_carga_documentos.pdf).
--   3. Parámetros del sistema.
--   4. La entidad banco (tipo BANCO) y los usuarios madre:
--        - Operador bancario (rol ADMIN): opera la plataforma y, desde Gestión de
--          usuarios, crea usuarios ADMIN, PAYER y SUPPLIER.
--        - Administrador del sistema (rol SYSTEM_ADMIN): administra los parámetros.
--          Este rol solo se asigna directamente en la base de datos.
--
-- Equivale a las migraciones V1 a V15 de src/main/resources/db/migration, con los
-- mismos identificadores, más los datos propios de producción. Los cambios
-- posteriores se entregan en db/prod/actualizaciones/.
--
-- La API debe ejecutarse con FLYWAY_ENABLED=false contra esta base.
--
-- SQL estándar de PostgreSQL (16): no usa comandos de psql, así que corre igual en
-- psql, pgAdmin (Query Tool), DBeaver o cualquier cliente que ejecute scripts.
--
-- Uso:
--   1. Copiar este archivo y completar la sección PARÁMETROS (reemplazar cada
--      'COMPLETAR' por el valor, entre comillas simples).
--   2. Ejecutarlo completo con un usuario dueño de la base, con cualquiera de:
--        - psql -h <host> -U <usuario> -d <base> -v ON_ERROR_STOP=1 -f instalacion_inicial.sql
--        - pgAdmin o DBeaver: abrir el archivo y ejecutarlo como script.
--
-- Todo corre en una sola transacción. Si falta un parámetro, un formato no es
-- válido o la base no está vacía, el script se detiene y no deja nada creado.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- PARÁMETROS
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE instalacion_parametros (clave text PRIMARY KEY, valor text) ON COMMIT DROP;

INSERT INTO instalacion_parametros (clave, valor) VALUES
    -- Orígenes desde los que el navegador puede llamar a la API (URL del cliente web),
    -- separados por coma y sin barra final. Ej.: https://pay.davivienda.com.sv
    ('cors_origenes',      'COMPLETAR'),

    -- Entidad banco. NIT de 14 dígitos; se aceptan guiones (0614-010190-101-1).
    ('banco_nit',          'COMPLETAR'),
    ('banco_nombre',       'COMPLETAR'),
    -- Código corto y único de la entidad (máximo 25 caracteres), por ejemplo DAVIVIENDA.
    ('banco_codigo',       'COMPLETAR'),

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
-- espacios, correos en minúsculas y código de entidad en mayúsculas.
UPDATE instalacion_parametros SET valor = btrim(valor);
UPDATE instalacion_parametros SET valor = regexp_replace(valor, '[\s-]', '', 'g')
WHERE clave IN ('banco_nit', 'operador_dui', 'sysadmin_dui');
UPDATE instalacion_parametros SET valor = lower(valor) WHERE clave IN ('operador_correo', 'sysadmin_correo');
UPDATE instalacion_parametros SET valor = upper(valor) WHERE clave = 'banco_codigo';
UPDATE instalacion_parametros SET valor = regexp_replace(valor, '\s', '', 'g') WHERE clave = 'cors_origenes';

-- -----------------------------------------------------------------------------
-- 0. VALIDACIONES PREVIAS
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_pendientes text;
    v_tablas     text;
    v_origen     text;
BEGIN
    SELECT string_agg(clave, ', ' ORDER BY clave) INTO v_pendientes
    FROM instalacion_parametros
    WHERE valor IS NULL OR valor = '' OR upper(valor) = 'COMPLETAR';
    IF v_pendientes IS NOT NULL THEN
        RAISE EXCEPTION 'Faltan parámetros por completar: %', v_pendientes;
    END IF;

    SELECT string_agg(tablename, ', ' ORDER BY tablename) INTO v_tablas
    FROM pg_tables WHERE schemaname = 'public';
    IF v_tablas IS NOT NULL THEN
        RAISE EXCEPTION 'La base no está vacía; el esquema public ya tiene tablas: %', v_tablas;
    END IF;

    FOREACH v_origen IN ARRAY string_to_array((SELECT valor FROM instalacion_parametros WHERE clave = 'cors_origenes'), ',')
    LOOP
        IF v_origen !~ '^https?://[^/,]+$' THEN
            RAISE EXCEPTION 'Origen CORS no válido: "%". Use el formato https://dominio[:puerto], sin barra final.', v_origen;
        END IF;
    END LOOP;
    IF length((SELECT valor FROM instalacion_parametros WHERE clave = 'cors_origenes')) > 255 THEN
        RAISE EXCEPTION 'Los orígenes CORS admiten máximo 255 caracteres en total.';
    END IF;

    IF (SELECT valor FROM instalacion_parametros WHERE clave = 'banco_nit') !~ '^\d{14}$' THEN
        RAISE EXCEPTION 'El NIT del banco debe tener exactamente 14 dígitos.';
    END IF;
    IF length((SELECT valor FROM instalacion_parametros WHERE clave = 'banco_codigo')) > 25 THEN
        RAISE EXCEPTION 'El código del banco admite máximo 25 caracteres.';
    END IF;
    IF (SELECT valor FROM instalacion_parametros WHERE clave = 'operador_dui') !~ '^\d{9}$' THEN
        RAISE EXCEPTION 'El DUI del operador debe tener exactamente 9 dígitos.';
    END IF;
    IF (SELECT valor FROM instalacion_parametros WHERE clave = 'sysadmin_dui') !~ '^\d{9}$' THEN
        RAISE EXCEPTION 'El DUI del administrador del sistema debe tener exactamente 9 dígitos.';
    END IF;
    IF EXISTS (SELECT 1 FROM instalacion_parametros
               WHERE clave IN ('operador_correo', 'sysadmin_correo') AND valor !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') THEN
        RAISE EXCEPTION 'Alguno de los correos no tiene un formato válido.';
    END IF;
    IF EXISTS (SELECT 1 FROM instalacion_parametros WHERE clave <> 'cors_origenes' AND length(valor) > 255) THEN
        RAISE EXCEPTION 'Los nombres, apellidos y correos admiten máximo 255 caracteres.';
    END IF;
    IF (SELECT valor FROM instalacion_parametros WHERE clave = 'operador_dui')
     = (SELECT valor FROM instalacion_parametros WHERE clave = 'sysadmin_dui') THEN
        RAISE EXCEPTION 'El operador y el administrador del sistema deben tener DUI distintos.';
    END IF;
    IF (SELECT valor FROM instalacion_parametros WHERE clave = 'operador_correo')
     = (SELECT valor FROM instalacion_parametros WHERE clave = 'sysadmin_correo') THEN
        RAISE EXCEPTION 'El operador y el administrador del sistema deben tener correos distintos.';
    END IF;
END
$$;

-- -----------------------------------------------------------------------------
-- 1. ESQUEMA
-- -----------------------------------------------------------------------------
CREATE TABLE public.acceptance_audits (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    user_agent character varying(255) NOT NULL,
    version_id uuid NOT NULL,
    user_id uuid NOT NULL
);

CREATE TABLE public.bank_accounts (
    id uuid NOT NULL,
    account_number character varying(50) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    is_main boolean NOT NULL,
    status character varying(12) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    entity_id uuid NOT NULL,
    CONSTRAINT bank_accounts_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.bank_holidays_cat (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    description character varying(255) NOT NULL,
    holiday_date date NOT NULL,
    status character varying(12) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT bank_holidays_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.credit_facilities (
    id uuid NOT NULL,
    amount_in_use numeric(19,4) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    credit_facility_number character varying(255) NOT NULL,
    facility_limit_amount numeric(19,4) NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    warning_threshold_percentage numeric(5,2),
    payer_id uuid NOT NULL,
    CONSTRAINT credit_facilities_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.credit_facility_histories (
    id uuid NOT NULL,
    amount numeric(19,4) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    reference_number character varying(255) NOT NULL,
    repayment_type character varying(50) NOT NULL,
    credit_facility_id uuid NOT NULL,
    executed_by_id uuid NOT NULL,
    payer_id uuid NOT NULL,
    CONSTRAINT credit_facility_histories_repayment_type_check CHECK (((repayment_type)::text = ANY ((ARRAY['PARTIAL'::character varying, 'FULL'::character varying, 'INITIAL_BALANCE'::character varying, 'DOCUMENT_INACTIVATION'::character varying])::text[])))
);

CREATE TABLE public.disbursement_batches (
    id uuid NOT NULL,
    batch_number character varying(255) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    output_file_name character varying(255) NOT NULL,
    status character varying(50) NOT NULL,
    total_amount numeric(38,18) NOT NULL,
    total_commission numeric(38,18) NOT NULL,
    total_interest numeric(38,18) NOT NULL,
    transaction_count integer NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    confirmed_by_id uuid,
    created_by_id uuid NOT NULL,
    overdue_review_note character varying(1000),
    due_date date,
    request_date date,
    payer_id uuid,
    disbursement_date date,
    CONSTRAINT disbursement_batches_status_check CHECK (((status)::text = ANY ((ARRAY['CREATED'::character varying, 'PROCESSING'::character varying, 'SETTLED'::character varying, 'FAILED'::character varying, 'PARTIALLY_FAILED'::character varying])::text[])))
);

CREATE TABLE public.disbursement_policies_cat (
    id uuid NOT NULL,
    code character varying(255) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    description character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    offset_days integer,
    type character varying(30),
    weekdays character varying(100),
    CONSTRAINT disbursement_policies_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[]))),
    CONSTRAINT disbursement_policies_cat_type_check CHECK (((type)::text = ANY ((ARRAY['T_PLUS_N'::character varying, 'WEEKDAYS'::character varying])::text[])))
);

CREATE TABLE public.document_logs (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    status character varying(50),
    acceptance_audit_id uuid,
    document_id uuid NOT NULL,
    user_id uuid NOT NULL,
    CONSTRAINT document_logs_status_check CHECK (status IN (
        'APPROVED', 'REQUESTED_FOR_FINANCING', 'REQUESTED_FOR_DISBURSEMENT', 'DISBURSED',
        'IN_QUARANTINE', 'INACTIVATED_BY_PAYER', 'REQUESTED_FOR_DISPERSION', 'DISPERSED'))
);

CREATE TABLE public.documents (
    id uuid NOT NULL,
    control_number character varying(31),
    created_at timestamp(6) with time zone NOT NULL,
    document_number character varying(255),
    due_date date NOT NULL,
    generation_code character varying(36),
    invoice_type character varying(30),
    issuance_method character varying(30),
    issue_date date NOT NULL,
    nominal_amount numeric(19,4) NOT NULL,
    received_stamp character varying(40),
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    master_agreement_id uuid NOT NULL,
    upload_batch_id uuid NOT NULL,
    quarantine_reason character varying(50),
    quarantined_at timestamp(6) with time zone,
    dispersion_batch_id uuid,
    CONSTRAINT documents_invoice_type_check CHECK (((invoice_type)::text = ANY ((ARRAY['CCF'::character varying, 'FCI'::character varying])::text[]))),
    CONSTRAINT documents_issuance_method_check CHECK (((issuance_method)::text = ANY ((ARRAY['DIGITAL'::character varying, 'PAPER'::character varying])::text[]))),
    CONSTRAINT documents_quarantine_reason_check CHECK (((quarantine_reason)::text = ANY ((ARRAY['DUE_DATE_EXPIRED'::character varying, 'NEAR_DUE_DATE_ON_REQUEST'::character varying, 'NEAR_DUE_DATE_UNREQUESTED'::character varying, 'DISBURSEMENT_FAILED'::character varying, 'MANUAL_REVIEW'::character varying])::text[]))),
    CONSTRAINT documents_status_check CHECK (status IN (
        'APPROVED', 'REQUESTED_FOR_FINANCING', 'REQUESTED_FOR_DISBURSEMENT', 'DISBURSED',
        'IN_QUARANTINE', 'INACTIVATED_BY_PAYER', 'REQUESTED_FOR_DISPERSION', 'DISPERSED'))
);

CREATE TABLE public.entities (
    id uuid NOT NULL,
    code character varying(25) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    name character varying(255) NOT NULL,
    nit character varying(25) NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    entity_type_id uuid NOT NULL,
    CONSTRAINT entities_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.entity_types_cat (
    id uuid NOT NULL,
    code character varying(255) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(12) NOT NULL,
    updated_at timestamp(6) with time zone,
    CONSTRAINT entity_types_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.excel_template_columns (
    id uuid NOT NULL,
    is_active boolean NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    excel_column_name character varying(100) NOT NULL,
    logical_dto_field character varying(100) NOT NULL,
    is_required boolean NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL
);

CREATE TABLE public.financing_requests (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    request_number character varying(50) NOT NULL,
    status character varying(50) NOT NULL,
    total_net_amount numeric(38,18) NOT NULL,
    total_amount_to_finance numeric(38,18) NOT NULL,
    total_flat_amount numeric(19,4) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    requested_by_id uuid NOT NULL,
    supplier_id uuid NOT NULL,
    CONSTRAINT financing_requests_status_check CHECK (((status)::text = ANY ((ARRAY['SUBMITTED'::character varying, 'COMPLETED'::character varying])::text[])))
);

CREATE TABLE public.financing_transactions (
    id uuid NOT NULL,
    amount_to_be_disbursed numeric(38,18) NOT NULL,
    amount_to_finance numeric(38,18) NOT NULL,
    commission_amount numeric(38,18) NOT NULL,
    created_at date NOT NULL,
    discount_rate numeric(38,18) NOT NULL,
    financing_percentage numeric(38,18) NOT NULL,
    flat_amount numeric(19,4) NOT NULL,
    interest_amount numeric(38,18) NOT NULL,
    iva_amount numeric(38,18) NOT NULL,
    scheduled_disbursement_date date NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    disbursement_batch_id uuid,
    document_id uuid NOT NULL,
    financing_request_id uuid NOT NULL
);

CREATE TABLE public.master_agreements (
    id uuid NOT NULL,
    agreement_type character varying(50) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    disbursement_policy_id uuid NOT NULL,
    payer_id uuid NOT NULL,
    payment_policy_id uuid NOT NULL,
    supplier_id uuid NOT NULL,
    CONSTRAINT master_agreements_agreement_type_check CHECK (((agreement_type)::text = ANY ((ARRAY['STANDARD'::character varying, 'RECOURSE'::character varying, 'NON_RECOURSE'::character varying, 'INVERSE'::character varying, 'SCF'::character varying])::text[]))),
    CONSTRAINT master_agreements_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.menus_cat (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    description character varying(255),
    icon character varying(50),
    label character varying(100) NOT NULL,
    path character varying(150) NOT NULL,
    status character varying(12) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT menus_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.payment_policies_cat (
    id uuid NOT NULL,
    code character varying(255) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    days_count integer NOT NULL,
    description character varying(255) NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT payment_policies_cat_days_count_check CHECK ((days_count >= 1)),
    CONSTRAINT payment_policies_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.product_pricing_terms (
    id uuid NOT NULL,
    calculation_base character varying(50) NOT NULL,
    commission_rate numeric(19,6) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    interest_rate numeric(19,6) NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    credit_facility_id uuid NOT NULL,
    CONSTRAINT product_pricing_terms_calculation_base_check CHECK (((calculation_base)::text = ANY ((ARRAY['COMERCIAL_360'::character varying, 'CALENDARIO_365'::character varying])::text[]))),
    CONSTRAINT product_pricing_terms_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.role_menus (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    display_order integer NOT NULL,
    menu_id uuid NOT NULL,
    role_id uuid NOT NULL
);

CREATE TABLE public.role_routes (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    is_index boolean NOT NULL,
    role_id uuid NOT NULL,
    route_id uuid NOT NULL
);

CREATE TABLE public.roles_cat (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    description character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    status character varying(12) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    default_route character varying(100),
    CONSTRAINT roles_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.routes_cat (
    id uuid NOT NULL,
    component_name character varying(100) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    description character varying(255),
    path character varying(150) NOT NULL,
    status character varying(12) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT routes_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.system_parameters (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    param_key character varying(255) NOT NULL,
    updated_at timestamp(6) with time zone,
    param_value character varying(255) NOT NULL
);

CREATE TABLE public.term_types_cat (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    status character varying(50) NOT NULL,
    term_name character varying(255) NOT NULL,
    unique_code character varying(255) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT term_types_cat_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.term_versions_cat (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    publication_date date,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    version_number character varying(255) NOT NULL,
    term_type_id uuid NOT NULL,
    content_hash character varying(64),
    document_url character varying(500),
    published_by_id uuid,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    acceptance_text character varying(500) NOT NULL,
    CONSTRAINT ck_term_versions_published_fields CHECK ((((status)::text = 'DRAFT'::text) OR ((content_hash IS NOT NULL) AND (publication_date IS NOT NULL)))),
    CONSTRAINT term_versions_cat_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

CREATE TABLE public.upload_batches (
    id uuid NOT NULL,
    batch_number character varying(255) NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    file_name character varying(255) NOT NULL,
    status character varying(50) NOT NULL,
    total_records integer NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    uploaded_and_approved_by_id uuid NOT NULL,
    CONSTRAINT upload_batches_status_check CHECK (((status)::text = ANY ((ARRAY['PROCESSING'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying, 'PARTIALLY_FAILED'::character varying])::text[]))),
    CONSTRAINT upload_batches_total_records_check CHECK ((total_records >= 0))
);

CREATE TABLE public.users (
    id uuid NOT NULL,
    created_at timestamp(6) with time zone NOT NULL,
    dui character varying(15) NOT NULL,
    email character varying(255) NOT NULL,
    first_name character varying(255) NOT NULL,
    last_name character varying(255) NOT NULL,
    status character varying(50) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    entity_id uuid NOT NULL,
    role_id uuid NOT NULL,
    CONSTRAINT users_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'INACTIVE'::character varying])::text[])))
);

-- Llaves primarias
ALTER TABLE ONLY public.acceptance_audits ADD CONSTRAINT acceptance_audits_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.bank_accounts ADD CONSTRAINT bank_accounts_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.bank_holidays_cat ADD CONSTRAINT bank_holidays_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.credit_facilities ADD CONSTRAINT credit_facilities_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.credit_facility_histories ADD CONSTRAINT credit_facility_histories_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.disbursement_batches ADD CONSTRAINT disbursement_batches_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.disbursement_policies_cat ADD CONSTRAINT disbursement_policies_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.document_logs ADD CONSTRAINT document_logs_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.documents ADD CONSTRAINT documents_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.entities ADD CONSTRAINT entities_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.entity_types_cat ADD CONSTRAINT entity_types_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.excel_template_columns ADD CONSTRAINT excel_template_columns_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.financing_requests ADD CONSTRAINT financing_requests_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.financing_transactions ADD CONSTRAINT financing_transactions_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.master_agreements ADD CONSTRAINT master_agreements_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.menus_cat ADD CONSTRAINT menus_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.payment_policies_cat ADD CONSTRAINT payment_policies_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.product_pricing_terms ADD CONSTRAINT product_pricing_terms_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.role_menus ADD CONSTRAINT role_menus_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.role_routes ADD CONSTRAINT role_routes_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.roles_cat ADD CONSTRAINT roles_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.routes_cat ADD CONSTRAINT routes_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.system_parameters ADD CONSTRAINT system_parameters_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.term_types_cat ADD CONSTRAINT term_types_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.term_versions_cat ADD CONSTRAINT term_versions_cat_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.upload_batches ADD CONSTRAINT upload_batches_pkey PRIMARY KEY (id);
ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);

-- Restricciones de unicidad
ALTER TABLE ONLY public.entities ADD CONSTRAINT uk5qu23ja9ixrm2nfbqa7xl3wab UNIQUE (code);
ALTER TABLE ONLY public.users ADD CONSTRAINT uk6dotkott2kjsp8vw4d0m25fb7 UNIQUE (email);
ALTER TABLE ONLY public.payment_policies_cat ADD CONSTRAINT uk9wps610udqb4jf0y5xum1kvrm UNIQUE (code);
ALTER TABLE ONLY public.menus_cat ADD CONSTRAINT uk_menus_cat_path UNIQUE (path);
ALTER TABLE ONLY public.master_agreements ADD CONSTRAINT uk_payer_supplier_agreement UNIQUE (payer_id, supplier_id, agreement_type);
ALTER TABLE ONLY public.role_menus ADD CONSTRAINT uk_role_menus_role_menu UNIQUE (role_id, menu_id);
ALTER TABLE ONLY public.role_routes ADD CONSTRAINT uk_role_routes_role_route UNIQUE (role_id, route_id);
ALTER TABLE ONLY public.routes_cat ADD CONSTRAINT uk_routes_cat_path_component UNIQUE (path, component_name);
ALTER TABLE ONLY public.financing_transactions ADD CONSTRAINT ukaem49rxghrlrd5ehpd54jykmw UNIQUE (document_id);
ALTER TABLE ONLY public.disbursement_batches ADD CONSTRAINT ukayc99yhffeys2q988ku5wp5bb UNIQUE (batch_number);
ALTER TABLE ONLY public.disbursement_policies_cat ADD CONSTRAINT ukbitukkd00r3mmrl81j3e52hp9 UNIQUE (code);
ALTER TABLE ONLY public.bank_holidays_cat ADD CONSTRAINT ukcesrthtnmj9r6l5lsjfeeuksx UNIQUE (holiday_date);
ALTER TABLE ONLY public.financing_requests ADD CONSTRAINT ukj6nsgl1h7gmvf1ew9xsnrnyuk UNIQUE (request_number);
ALTER TABLE ONLY public.system_parameters ADD CONSTRAINT ukjl6v8jrdwppjo5hjixnbqou1n UNIQUE (param_key);
ALTER TABLE ONLY public.users ADD CONSTRAINT ukn00icka5w2gxjyo0tlgyau168 UNIQUE (dui);
ALTER TABLE ONLY public.roles_cat ADD CONSTRAINT ukoj319sfqub7mbtmklu7alws7m UNIQUE (name);
ALTER TABLE ONLY public.upload_batches ADD CONSTRAINT ukoq0kvrd9x3jack14bu5rx0mjj UNIQUE (batch_number);
ALTER TABLE ONLY public.entity_types_cat ADD CONSTRAINT ukqa96cmb4a7grwp2xm89mg9nfk UNIQUE (code);
ALTER TABLE ONLY public.bank_accounts ADD CONSTRAINT ukr9gi1et82prjsig51uqxj2qm6 UNIQUE (account_number);
ALTER TABLE ONLY public.entities ADD CONSTRAINT ukrh9g82kd3mu9d7ncd5r451aiu UNIQUE (nit);

-- Índices únicos de negocio (doble fondeo y términos)
CREATE UNIQUE INDEX uq_documents_control_number ON public.documents USING btree (upper((control_number)::text)) WHERE (control_number IS NOT NULL);
CREATE UNIQUE INDEX uq_documents_generation_code ON public.documents USING btree (upper((generation_code)::text)) WHERE (generation_code IS NOT NULL);
CREATE UNIQUE INDEX uq_documents_paper_number_year ON public.documents USING btree (master_agreement_id, document_number, EXTRACT(year FROM issue_date)) WHERE (((issuance_method)::text = 'PAPER'::text) AND (document_number IS NOT NULL));
CREATE UNIQUE INDEX uq_documents_received_stamp ON public.documents USING btree (upper((received_stamp)::text)) WHERE (received_stamp IS NOT NULL);
CREATE UNIQUE INDEX ux_term_versions_one_active ON public.term_versions_cat USING btree (term_type_id) WHERE ((status)::text = 'ACTIVE'::text);
CREATE UNIQUE INDEX ux_term_versions_type_version ON public.term_versions_cat USING btree (term_type_id, lower((version_number)::text));

-- Llaves foráneas
ALTER TABLE ONLY public.financing_transactions ADD CONSTRAINT fk180g6wnayr0rp2sovx26flvfn FOREIGN KEY (document_id) REFERENCES public.documents(id);
ALTER TABLE ONLY public.documents ADD CONSTRAINT fk44037dsh2i14fw0yic9k5wi6e FOREIGN KEY (upload_batch_id) REFERENCES public.upload_batches(id);
ALTER TABLE ONLY public.term_versions_cat ADD CONSTRAINT fk4phfxiri6unxw5ntu9xg5eg0q FOREIGN KEY (term_type_id) REFERENCES public.term_types_cat(id);
ALTER TABLE ONLY public.role_routes ADD CONSTRAINT fk67mg2v594g0kt3jpboqqd19w FOREIGN KEY (role_id) REFERENCES public.roles_cat(id);
ALTER TABLE ONLY public.financing_requests ADD CONSTRAINT fk6gf2xvvi32hxn8nuv9i2bwknt FOREIGN KEY (supplier_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.documents ADD CONSTRAINT fk8ac26ac37d22ij9aw91ia9n0u FOREIGN KEY (master_agreement_id) REFERENCES public.master_agreements(id);
ALTER TABLE ONLY public.document_logs ADD CONSTRAINT fk8m4nodv7pd6x3csnqt91k15ft FOREIGN KEY (user_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.disbursement_batches ADD CONSTRAINT fk99lla94fyhxtmu72hvahu2fqf FOREIGN KEY (payer_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.role_routes ADD CONSTRAINT fk9ga2wwn8a4tqkm5ostskvje25 FOREIGN KEY (route_id) REFERENCES public.routes_cat(id);
ALTER TABLE ONLY public.document_logs ADD CONSTRAINT fkbe8xda13pweioqipnts8b94tf FOREIGN KEY (document_id) REFERENCES public.documents(id);
ALTER TABLE ONLY public.financing_requests ADD CONSTRAINT fkbitiq6bt0yh8plpwewv2jvvk9 FOREIGN KEY (requested_by_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.master_agreements ADD CONSTRAINT fkbptornfp45s8aeryp31c1snn4 FOREIGN KEY (payment_policy_id) REFERENCES public.payment_policies_cat(id);
ALTER TABLE ONLY public.financing_transactions ADD CONSTRAINT fkbx1ffoav9jxb6xtwj7cxiwmeg FOREIGN KEY (disbursement_batch_id) REFERENCES public.disbursement_batches(id);
ALTER TABLE ONLY public.entities ADD CONSTRAINT fkcmihvjj9w33brbxo83uw28ur8 FOREIGN KEY (entity_type_id) REFERENCES public.entity_types_cat(id);
ALTER TABLE ONLY public.credit_facility_histories ADD CONSTRAINT fke34vtup6rk8ni85dv7uj7jdqq FOREIGN KEY (payer_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.role_menus ADD CONSTRAINT fkfjukt7domwo097pqv0dsyg6qc FOREIGN KEY (menu_id) REFERENCES public.menus_cat(id);
ALTER TABLE ONLY public.role_menus ADD CONSTRAINT fkfwr94hahmk4a1gsl64xvpjtgu FOREIGN KEY (role_id) REFERENCES public.roles_cat(id);
ALTER TABLE ONLY public.users ADD CONSTRAINT fkgvqnng86rr739m4th9m97x5x8 FOREIGN KEY (role_id) REFERENCES public.roles_cat(id);
ALTER TABLE ONLY public.disbursement_batches ADD CONSTRAINT fkhaqe728oex61rsyxlwlqpqu49 FOREIGN KEY (created_by_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.users ADD CONSTRAINT fkhb1q1fcncex0uvlxs3h7vjofc FOREIGN KEY (entity_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.credit_facility_histories ADD CONSTRAINT fkhcux15krk9rrb0k4p8d52a4p8 FOREIGN KEY (credit_facility_id) REFERENCES public.credit_facilities(id);
ALTER TABLE ONLY public.master_agreements ADD CONSTRAINT fkjb96vsqbd0qb7ggrtkgwn0sm4 FOREIGN KEY (payer_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.upload_batches ADD CONSTRAINT fkjdyad0sl1jshxaa8cr47g213f FOREIGN KEY (uploaded_and_approved_by_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.product_pricing_terms ADD CONSTRAINT fkk42ci8lprdjmogy7wg7ppekf1 FOREIGN KEY (credit_facility_id) REFERENCES public.credit_facilities(id);
ALTER TABLE ONLY public.master_agreements ADD CONSTRAINT fkkvwnn34h46y2x3wfnanfy4udm FOREIGN KEY (disbursement_policy_id) REFERENCES public.disbursement_policies_cat(id);
ALTER TABLE ONLY public.bank_accounts ADD CONSTRAINT fkkxgaj0oqy0rtgfr5hu21gg2n9 FOREIGN KEY (entity_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.master_agreements ADD CONSTRAINT fklavsu9mm469nx6r0xwvawmqgf FOREIGN KEY (supplier_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.credit_facility_histories ADD CONSTRAINT fklrl79sitxigx8j84ep2hm6dg FOREIGN KEY (executed_by_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.financing_transactions ADD CONSTRAINT fklsduiyge3burtolj7g62pwqjv FOREIGN KEY (financing_request_id) REFERENCES public.financing_requests(id);
ALTER TABLE ONLY public.term_versions_cat ADD CONSTRAINT fkmjeid3sy24lor2ykpmhnmvqgg FOREIGN KEY (published_by_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.disbursement_batches ADD CONSTRAINT fkog4dxrdp2miu0lnyypfpimkqf FOREIGN KEY (confirmed_by_id) REFERENCES public.users(id);
ALTER TABLE ONLY public.document_logs ADD CONSTRAINT fkoillojcc6m8a273ua4gkf70ch FOREIGN KEY (acceptance_audit_id) REFERENCES public.acceptance_audits(id);
ALTER TABLE ONLY public.credit_facilities ADD CONSTRAINT fkpt0flnudemxapf1lestaex1sj FOREIGN KEY (payer_id) REFERENCES public.entities(id);
ALTER TABLE ONLY public.acceptance_audits ADD CONSTRAINT fkrikupdb70o2epcye2gnxwwd4p FOREIGN KEY (version_id) REFERENCES public.term_versions_cat(id);
ALTER TABLE ONLY public.acceptance_audits ADD CONSTRAINT fktpwjmbxonc0qmgiiy1nsw7vi6 FOREIGN KEY (user_id) REFERENCES public.users(id);

-- Lotes de dispersión: el banco paga al proveedor el monto de la factura con cargo a la
-- cuenta del pagador; agrupan los documentos de un pagador con la misma fecha de vencimiento.
CREATE TABLE public.dispersion_batches (
    id uuid NOT NULL,
    batch_number character varying(255) NOT NULL,
    payer_id uuid NOT NULL,
    payer_account_number character varying(255) NOT NULL,
    due_date date NOT NULL,
    dispersion_date date NOT NULL,
    document_count integer NOT NULL,
    total_amount numeric(38,18) NOT NULL,
    status character varying(50) NOT NULL,
    signer_id uuid,
    created_by_id uuid NOT NULL,
    confirmed_by_id uuid,
    confirmed_at timestamp(6) with time zone,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT dispersion_batches_pkey PRIMARY KEY (id),
    CONSTRAINT uk_dispersion_batches_batch_number UNIQUE (batch_number),
    CONSTRAINT dispersion_batches_status_check CHECK (status IN ('CREATED', 'SETTLED')),
    CONSTRAINT dispersion_batches_document_count_check CHECK (document_count > 0),
    CONSTRAINT fk_dispersion_batches_payer FOREIGN KEY (payer_id) REFERENCES public.entities(id),
    CONSTRAINT fk_dispersion_batches_signer FOREIGN KEY (signer_id) REFERENCES public.users(id),
    CONSTRAINT fk_dispersion_batches_created_by FOREIGN KEY (created_by_id) REFERENCES public.users(id),
    CONSTRAINT fk_dispersion_batches_confirmed_by FOREIGN KEY (confirmed_by_id) REFERENCES public.users(id)
);

CREATE INDEX ix_dispersion_batches_payer_created ON public.dispersion_batches (payer_id, created_at DESC);

ALTER TABLE public.documents ADD CONSTRAINT fk_documents_dispersion_batch
    FOREIGN KEY (dispersion_batch_id) REFERENCES public.dispersion_batches(id);
CREATE INDEX ix_documents_dispersion_batch ON public.documents (dispersion_batch_id);

-- Recursos de las pantallas de carga: la plantilla .xlsx y el manual en PDF. Hay a lo
-- sumo uno de cada tipo; publicar uno nuevo reemplaza al anterior.
CREATE TABLE public.upload_resources (
    id uuid NOT NULL,
    resource_type character varying(30) NOT NULL,
    file_name character varying(255) NOT NULL,
    file_content bytea NOT NULL,
    file_size bigint NOT NULL,
    updated_by_id uuid,
    created_at timestamp(6) with time zone NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT upload_resources_pkey PRIMARY KEY (id),
    CONSTRAINT uk_upload_resources_type UNIQUE (resource_type),
    CONSTRAINT upload_resources_type_check CHECK (resource_type IN ('TEMPLATE', 'MANUAL')),
    CONSTRAINT upload_resources_file_size_check CHECK (file_size > 0),
    CONSTRAINT fk_upload_resources_updated_by FOREIGN KEY (updated_by_id) REFERENCES public.users(id)
);

-- -----------------------------------------------------------------------------
-- 2. CATÁLOGOS
-- -----------------------------------------------------------------------------
-- Tipos de entidad
INSERT INTO public.entity_types_cat (id, code, created_at, name, status, updated_at) VALUES
    ('a1000000-0000-4000-8000-000000000001', 'COD_001', now(), 'PAGADOR', 'ACTIVE', now()),
    ('a1000000-0000-4000-8000-000000000002', 'COD_002', now(), 'PROVEEDOR', 'ACTIVE', now()),
    ('a1000000-0000-4000-8000-000000000003', 'COD_003', now(), 'BANCO', 'ACTIVE', now());

-- Roles
INSERT INTO public.roles_cat (id, created_at, description, name, status, updated_at, default_route) VALUES
    ('b1000000-0000-4000-8000-000000000001', now(), 'Operador bancario', 'ADMIN', 'ACTIVE', now(), '/admin'),
    ('b1000000-0000-4000-8000-000000000003', now(), 'Usuario pagador', 'PAYER', 'ACTIVE', now(), '/payer'),
    ('b1000000-0000-4000-8000-000000000005', now(), 'Usuario proveedor', 'SUPPLIER', 'ACTIVE', now(), '/supplier'),
    ('b1000000-0000-4000-8000-000000000007', now(), 'Administrador de parámetros del sistema', 'SYSTEM_ADMIN', 'ACTIVE', now(), '/system');

-- Políticas de pago
INSERT INTO public.payment_policies_cat (id, code, created_at, days_count, description, status, updated_at) VALUES
    ('e1000000-0000-4000-8000-000000000030', 'P30', now(), 30, 'Pago a 30 días', 'ACTIVE', now()),
    ('e1000000-0000-4000-8000-000000000045', 'P45', now(), 45, 'Pago a 45 días', 'ACTIVE', now()),
    ('e1000000-0000-4000-8000-000000000060', 'P60', now(), 60, 'Pago a 60 días', 'ACTIVE', now()),
    ('e1000000-0000-4000-8000-000000000090', 'P90', now(), 90, 'Pago a 90 días', 'ACTIVE', now());

-- Políticas de desembolso
INSERT INTO public.disbursement_policies_cat (id, code, created_at, description, name, status, updated_at, offset_days, type, weekdays) VALUES
    ('f1000000-0000-4000-8000-000000000001', 'T_PLUS_1', now(), 'Desembolso al siguiente día hábil', 'T+1', 'ACTIVE', now(), 1, 'T_PLUS_N', NULL),
    ('f1000000-0000-4000-8000-000000000002', 'ONLY_FRIDAYS', now(), 'Desembolso únicamente los viernes', 'Solo viernes', 'ACTIVE', now(), 1, 'WEEKDAYS', 'FRIDAY');

-- Feriados 2026 (el ADMIN registra los de cada año en Gestión de feriados)
INSERT INTO public.bank_holidays_cat (id, created_at, description, holiday_date, status, updated_at) VALUES
    ('ad000000-0000-4000-8000-000000000001', now(), 'Año Nuevo', '2026-01-01', 'ACTIVE', now()),
    ('ad000000-0000-4000-8000-000000000002', now(), 'Día del Trabajo', '2026-05-01', 'ACTIVE', now()),
    ('ad000000-0000-4000-8000-000000000003', now(), 'Fiestas Agostinas', '2026-08-06', 'ACTIVE', now()),
    ('ad000000-0000-4000-8000-000000000004', now(), 'Día de la Independencia', '2026-09-15', 'ACTIVE', now()),
    ('ad000000-0000-4000-8000-000000000005', now(), 'Día de los Difuntos', '2026-11-02', 'ACTIVE', now()),
    ('ad000000-0000-4000-8000-000000000006', now(), 'Navidad', '2026-12-25', 'ACTIVE', now());

-- Plantilla del archivo de carga. Las columnas inactivas ya no se leen (el proveedor se
-- identifica por NIT y sus usuarios se crean en Gestión de usuarios); se conservan para
-- mantener los mismos identificadores que en los demás ambientes.
INSERT INTO public.excel_template_columns (id, is_active, created_at, excel_column_name, logical_dto_field, is_required, updated_at) VALUES
    ('af000000-0000-4000-8000-000000000001', true, now(), 'Fecha Emision', 'issueDate', true, now()),
    ('af000000-0000-4000-8000-000000000002', true, now(), 'Monto', 'nominalAmount', true, now()),
    ('af000000-0000-4000-8000-000000000003', true, now(), 'Numero Documento', 'documentNumber', true, now()),
    ('af000000-0000-4000-8000-000000000004', true, now(), 'Codigo Generacion', 'generationCode', false, now()),
    ('af000000-0000-4000-8000-000000000005', true, now(), 'Sello Recepcion', 'receivedStamp', false, now()),
    ('af000000-0000-4000-8000-000000000006', true, now(), 'Numero Control', 'controlNumber', false, now()),
    ('af000000-0000-4000-8000-000000000007', true, now(), 'Metodo Emision', 'issuanceMethod', true, now()),
    ('af000000-0000-4000-8000-000000000008', true, now(), 'Tipo Factura', 'invoiceType', true, now()),
    ('af000000-0000-4000-8000-000000000009', false, now(), 'NIU Proveedor', 'supplierNiu', false, now()),
    ('af000000-0000-4000-8000-00000000000a', true, now(), 'NIT Proveedor', 'supplierNit', true, now()),
    ('af000000-0000-4000-8000-00000000000b', true, now(), 'Nombre Proveedor', 'supplierName', true, now()),
    ('af000000-0000-4000-8000-00000000000c', true, now(), 'Politica Pago', 'paymentPolicy', true, now()),
    ('af000000-0000-4000-8000-00000000000d', true, now(), 'Dia Desembolso', 'disbursementDay', true, now()),
    ('af000000-0000-4000-8000-00000000000e', false, now(), 'DUI Operario', 'operatorDui', false, now()),
    ('af000000-0000-4000-8000-00000000000f', false, now(), 'Correo Operario', 'operatorEmail', false, now()),
    ('af000000-0000-4000-8000-000000000010', false, now(), 'Primer Nombre Operario', 'operatorFirstName', false, now()),
    ('af000000-0000-4000-8000-000000000011', false, now(), 'Segundo Nombre Operario', 'operatorMiddleName', false, now()),
    ('af000000-0000-4000-8000-000000000012', false, now(), 'Primer Apellido Operario', 'operatorFirstLastName', false, now()),
    ('af000000-0000-4000-8000-000000000013', false, now(), 'Segundo Apellido Operario', 'operatorSecondLastName', false, now()),
    ('af000000-0000-4000-8000-000000000014', true, now(), 'Cuenta Bancaria', 'supplierAccountNumber', true, now());

-- Tipos de términos y condiciones
INSERT INTO public.term_types_cat (id, created_at, status, term_name, unique_code, updated_at) VALUES
    ('aa000000-0000-4000-8000-000000000001', now(), 'ACTIVE', 'Términos y condiciones — Pagador', 'PAYER_TERM_TYPE', now()),
    ('aa000000-0000-4000-8000-000000000002', now(), 'ACTIVE', 'Términos y condiciones — Proveedor', 'SUPPLIER_TERM_TYPE', now());

-- Versiones vigentes de los términos. content_hash es el SHA-256 de
-- title + "\n\n" + content + "\n\n" + acceptance_text, igual que al publicar desde la API.
-- La versión del pagador es provisional: el ADMIN debe publicar la versión aprobada por legal.
INSERT INTO public.term_versions_cat (id, created_at, publication_date, status, updated_at, version_number, term_type_id, content_hash, document_url, published_by_id, title, content, acceptance_text) VALUES ('ab000000-0000-4000-8000-000000000002', now(), '2026-09-25', 'ACTIVE', now(), '1.0', 'aa000000-0000-4000-8000-000000000002', '73bde0b9d66c86a4bdfdf24e00490934549abfdbe2793da21a52a4646b60280c', NULL, NULL, 'Términos y Condiciones aplicables al Servicio Bancario para la Gestión y Anticipo de Pago a Proveedores', 'Al continuar con esta operación, usted (en adelante, "el Proveedor") reconoce, declara y acepta de manera expresa e irrevocable los siguientes Términos y Condiciones aplicables al Servicio Bancario para la Gestión de pago o Anticipo de Pago a Proveedores (en adelante, "Servicio de Anticipo de Pago"), solicitado a través de este sistema (en adelante, "la Plataforma"), brindado por Banco Davivienda Salvadoreño, Sociedad Anónima (en adelante, el "Banco").

Para efectos de estos términos, se entenderá por "Cliente Pagador" la persona natural o jurídica a cuyo cargo fue emitida la cuenta por cobrar (factura, comprobante de crédito fiscal (CCF), DTE y/o cualquier otro documento tributario), en adelante "Cuentas por Cobrar" respecto de las cuales el Proveedor puede optar voluntariamente por solicitar el anticipo de pago:

**1. Visualización y solicitud voluntaria.** El Proveedor reconoce que, al acceder a la Plataforma, podrá visualizar las Cuentas por Cobrar registradas a su favor por el Cliente Pagador, y que tendrá la opción de solicitar, de manera voluntaria, el Servicio de Anticipo de Pago sobre dichas Cuentas por Cobrar.

**2. Naturaleza del pago anticipado.** En caso de optar por la solicitud del Servicio de Anticipo de Pago de alguna de las Cuentas por Cobrar registradas por el Cliente Pagador a su favor, el Proveedor reconoce y acepta que, el pago anticipado que ejecuta el banco se realiza por cuenta, orden y a cargo del Cliente Pagador, entendiéndose por tal la persona natural o jurídica a cuyo cargo fue emitida la Cuenta por Cobrar respecto de la cual se solicita el anticipo, todo ello en ejecución del mandato de anticipo de pago otorgado por dicho Cliente Pagador al Banco.

**3. Validez y exigibilidad de las Cuentas por Cobrar.** El Proveedor declara que las Cuentas por Cobrar respecto de las cuales solicite el Servicio de Anticipo de Pago:

- a. corresponden a obligaciones válidas, exigibles y no controvertidas frente al Cliente Pagador;
- b. no se encuentran sujetas a reclamaciones, disputas, compensaciones, devoluciones, anulaciones ni cualquier otra circunstancia que pueda afectar su existencia, exigibilidad o monto; y
- c. no han sido total ni parcialmente saldadas con anterioridad.

**4. Titularidad y libre disposición de las Cuentas por Cobrar.** El Proveedor declara además que las Cuentas por Cobrar respecto de las cuales solicite el Servicio de Anticipo de Pago:

- a. son de titularidad legítima y exclusiva del Proveedor; y
- b. se encuentran libres de gravámenes, retenciones, cesiones o transferencias previas a terceros, y no se encuentran sujetas a limitaciones de disposición de ninguna naturaleza.

**5. No sometimiento a disputas posteriormente a la solicitud del Servicio de Anticipo de Pago.** Una vez solicitado el Servicio de Anticipo de Pago de una Cuenta por Cobrar a favor del Proveedor y ejecutado el pago anticipado por el Banco, el Proveedor se compromete a no someter dichas Cuentas por Cobrar a compensación, reclamo, disputa comercial o judicial.

**6. Conservación de la relación comercial.** El Proveedor acepta que el pago anticipado ejecutado por el Banco en virtud del Servicio de Anticipo de Pago, no constituye cesión de créditos y que el Banco no adquiere la titularidad de las Cuentas por Cobrar ni se convierte en su cesionario, manteniéndose íntegra la relación jurídica existente entre el Proveedor y el Cliente Pagador. El Proveedor reconoce que la operación únicamente genera a favor del Banco un derecho de reembolso frente al Cliente Pagador por los montos desembolsados en su nombre.

**7. Comisión e Intereses por el servicio.** El Proveedor reconoce y acepta de las Cuentas por Cobrar de las cuales solicite el Servicio de Anticipo de Pago, el Banco ejecutará el pago anticipado por la totalidad del importe de cada Cuenta por Cobrar; no obstante, reconoce y acepta pagar al Banco una comisión como remuneración por la gestión y ejecución del Servicio de Anticipo de Pago, la cual se devengará y será exigible al momento en que el Banco efectúe el desembolso del anticipo, y será cobrada por el Banco de forma separada, conforme a los mecanismos operativos que éste determine, los cuales el proveedor verá reflejado en la plataforma previo al envío de solicitud de pago.

El interés que generará el anticipo de las cuentas por pagar será del {{TASA_INTERES}} POR CIENTO y podrá ajustarse de manera quincenal a opción el Banco los días: uno y quince de cada uno de los meses comprendidos dentro del plazo y también de conformidad a la tasa de referencia que el banco mensualmente publica. La tasa de referencia correspondiente a este mes es del {{TASA_REFERENCIA}} por ciento, la que en sus publicaciones podrá ajustarse a opción del Banco; y el diferencial máximo que el banco podrá aplicar a este crédito durante toda su vigencia y mientras existan saldos pendientes será de {{PUNTOS_PORCENTUALES}} puntos porcentuales arriba de la tasa de referencia vigente a la fecha de cada modificación.

**8. Consentimiento.** El Proveedor reconoce que la aceptación de estos Términos y Condiciones aplicables al Servicio Bancario para la Gestión y Anticipo de Pago a Proveedores y las solicitudes del Servicio de Anticipo de Pago de alguna de las Cuentas por Cobrar registradas a su favor que realice a través de la Plataforma, constituyen una manifestación expresa de su consentimiento.

**9. Limitación de responsabilidad del Banco.** El Proveedor acepta que en le ejecución del Servicio de Anticipo de Pago, el Banco actúa exclusivamente como mandatario del Cliente Pagador y que el Banco no asume responsabilidad alguna por la relación comercial entre el Proveedor y el Cliente Pagador, ni por reclamos, disputas o incumplimientos que pudieren surgir entre ellos.

**10. Legislación Aplicable y Jurisdicción.** Para todos los efectos legales, que se puedan originar del Servicio de Anticipo de Pago, el Proveedor manifiesta que se regirán por las leyes de la República de El Salvador. Para cualquier controversia, las partes se someten a la jurisdicción de los tribunales competentes del distrito de San Salvador, municipio de San Salvador Centro, departamento de San Salvador.', 'Declaro que he leído, comprendido y acepto irrevocablemente estos Términos y Condiciones aplicables al Servicio Bancario para la Gestión y Anticipo de Pago a Proveedores.');
INSERT INTO public.term_versions_cat (id, created_at, publication_date, status, updated_at, version_number, term_type_id, content_hash, document_url, published_by_id, title, content, acceptance_text) VALUES ('cab9bbc5-0c27-4a36-889d-18beeb6207e4', now(), '2026-10-01', 'ACTIVE', now(), '1.1', 'aa000000-0000-4000-8000-000000000001', '2329ab82b532448ec1e5a8eaeafb0c474ce7c6bbb3d6af69b84cc713df384386', NULL, NULL, 'Términos y Condiciones aplicables al Cliente Pagador para la Carga de Cuentas por Pagar', '> **TEXTO PROVISIONAL.** Este contenido es temporal y debe ser reemplazado por la versión aprobada por el área legal del Banco.

Al cargar el archivo de cuentas por pagar en este sistema (en adelante, "la Plataforma"), usted, en nombre y representación de la entidad a la que pertenece (en adelante, el "Cliente Pagador"), reconoce y acepta los siguientes Términos y Condiciones frente a Banco Davivienda Salvadoreño, Sociedad Anónima (en adelante, el "Banco").

**1. Veracidad de la información.** El Cliente Pagador declara que los documentos registrados (facturas, comprobantes de crédito fiscal y demás documentos tributarios electrónicos) corresponden a obligaciones reales, válidas y exigibles a su cargo, y que los datos del archivo son verídicos y completos.

**2. Mandato de pago anticipado.** El Cliente Pagador autoriza al Banco a pagar anticipadamente a sus proveedores, por su cuenta y orden, las cuentas registradas que estos soliciten, conforme al convenio suscrito con el Banco.

**3. Obligación de reembolso.** El Cliente Pagador se obliga a reembolsar al Banco los montos desembolsados en su nombre en las fechas de vencimiento de cada documento, junto con los cargos pactados en el convenio.

**4. No disposición posterior.** El Cliente Pagador se compromete a no pagar directamente al proveedor, compensar, anular ni modificar los documentos que hayan sido anticipados por el Banco.

**5. Legislación aplicable.** Estos términos se rigen por las leyes de la República de El Salvador.', 'Declaro que la información cargada es verídica y acepto estos Términos y Condiciones en nombre del Cliente Pagador.');

-- Si este archivo se guarda con saltos de línea CRLF, psql conserva el \r dentro de los
-- textos y el hash ya no coincidiría con el contenido.
UPDATE public.term_versions_cat
SET title = replace(title, E'\r', ''),
    content = replace(content, E'\r', ''),
    acceptance_text = replace(acceptance_text, E'\r', '');

-- Rutas del cliente web
INSERT INTO public.routes_cat (id, component_name, created_at, description, path, status, updated_at) VALUES
    ('062f56d0-f57a-4efc-af7a-64045c641f96', 'Menu', now(), 'Menú del administrador', '', 'ACTIVE', now()),
    ('295b98fe-db51-442b-a180-07c6a671d693', 'AgreementManagement', now(), 'Gestión de acuerdos', 'agreement-management', 'ACTIVE', now()),
    ('521a973f-95c3-4760-a4ca-08ea99886c11', 'AgreementManagement', now(), 'Gestión de convenios comerciales', 'master-agreement-management', 'ACTIVE', now()),
    ('afe157e2-cbdd-4425-b6a3-805e07fe9a89', 'SupplierManagement', now(), 'Gestión de proveedores', 'supplier-management', 'ACTIVE', now()),
    ('f3cd204a-6de7-4f8d-9d78-6bc3dd0f4699', 'PayerManagementAdmin', now(), 'Gestión de pagadores', 'payer-management-admin', 'ACTIVE', now()),
    ('04e75b73-1612-4ff3-a6a1-ef14dd13302a', 'UploadFilePageAdmin', now(), 'Carga de documentos (admin)', 'upload-file-admin', 'ACTIVE', now()),
    ('04024fe8-b868-488d-8dcb-15a747bd4029', 'TermManagement', now(), 'Gestión de plazos', 'term-management', 'ACTIVE', now()),
    ('2874bc8c-2ecf-4ff0-9517-cf5ff8518e91', 'HolidayManagement', now(), 'Gestión de feriados', 'holiday-management', 'ACTIVE', now()),
    ('82b49689-e65a-494c-a0d7-974dad19afd0', 'PayerCreditLineManager', now(), 'Gestión de cupos de crédito', 'payer-credit-line-management', 'ACTIVE', now()),
    ('5e24103f-6fd5-403c-9201-f72b96676005', 'ControlTerminal', now(), 'Terminal de desembolsos', 'disbursement-terminal', 'ACTIVE', now()),
    ('e9f8d1fe-1910-48b0-a531-f08f27da7e32', 'BatchLog', now(), 'Bitácora de lotes', 'batches-history', 'ACTIVE', now()),
    ('f56fcfeb-a50f-42aa-9784-1b990d5eed34', 'ParamManagement', now(), 'Gestión de parámetros', 'param-management', 'ACTIVE', now()),
    ('e52fa248-3f4a-4b5f-9ebd-4d7b6997d92f', 'SelectDocuments', now(), 'Selección de documentos', '', 'ACTIVE', now()),
    ('cf86d6af-92ba-4336-a6c4-b4bf4d0a2982', 'DocumentLog', now(), 'Bitácora del proveedor', 'documents-history', 'ACTIVE', now()),
    ('9a455a78-9e6a-4178-a1d1-dac872e38ffb', 'UploadFilePage', now(), 'Carga de documentos (pagador)', '', 'ACTIVE', now()),
    ('a379613c-b110-4761-bc89-c9c362198ec5', 'PayerDocumentLog', now(), 'Bitácora del pagador', 'documents-history', 'ACTIVE', now()),
    ('3aaf7b7a-36eb-46c8-9071-93c78ac6070a', 'ParamManagement', now(), 'Gestión de parámetros (inicio)', '', 'ACTIVE', now()),
    ('9d0f97e0-fa72-47d4-91fe-01ef1c6fbf31', 'UserManagement', now(), 'Gestión de usuarios', 'user-management', 'ACTIVE', now()),
    ('c5000000-0000-4000-8000-000000000001', 'DispersionTerminal', now(), 'Terminal de dispersiones', 'dispersion-terminal', 'ACTIVE', now()),
    ('c5000000-0000-4000-8000-000000000002', 'DispersionBatchLog', now(), 'Bitácora de dispersiones', 'dispersion-batches-history', 'ACTIVE', now()),
    ('c9000000-0000-4000-8000-000000000001', 'UploadResourceManagement', now(), 'Recursos de carga', 'upload-resources-management', 'ACTIVE', now()),
    ('cb000000-0000-4000-8000-000000000001', 'OperatorDocumentLog', now(), 'Bitácora de documentos (operador)', 'documents-history', 'ACTIVE', now());

-- Rutas por rol
INSERT INTO public.role_routes (id, created_at, is_index, role_id, route_id) VALUES
    -- ADMIN (operador bancario)
    ('02bdbb74-e897-4cd1-bd7a-d976b094de6c', now(), true, 'b1000000-0000-4000-8000-000000000001', '062f56d0-f57a-4efc-af7a-64045c641f96'),
    ('b65c6da0-efcd-4280-84b2-0954d1776c1f', now(), false, 'b1000000-0000-4000-8000-000000000001', '295b98fe-db51-442b-a180-07c6a671d693'),
    ('d588906d-adce-479c-9dab-3fc67b285250', now(), false, 'b1000000-0000-4000-8000-000000000001', '521a973f-95c3-4760-a4ca-08ea99886c11'),
    ('e0339a12-a8b3-45b9-9dcc-7a9df2fbaacb', now(), false, 'b1000000-0000-4000-8000-000000000001', 'afe157e2-cbdd-4425-b6a3-805e07fe9a89'),
    ('1a841d4a-50d1-4154-b245-fae89dc60b1c', now(), false, 'b1000000-0000-4000-8000-000000000001', 'f3cd204a-6de7-4f8d-9d78-6bc3dd0f4699'),
    ('7cfb01a2-ba2b-48c6-9b24-76069aded657', now(), false, 'b1000000-0000-4000-8000-000000000001', '9d0f97e0-fa72-47d4-91fe-01ef1c6fbf31'),
    ('fb6fae9c-aa56-4571-94ac-78955dfbf47f', now(), false, 'b1000000-0000-4000-8000-000000000001', '04e75b73-1612-4ff3-a6a1-ef14dd13302a'),
    ('baed3576-f878-4be1-bbfe-56b37c438a58', now(), false, 'b1000000-0000-4000-8000-000000000001', '04024fe8-b868-488d-8dcb-15a747bd4029'),
    ('27cb0915-3535-4bf7-876f-945024ef6700', now(), false, 'b1000000-0000-4000-8000-000000000001', '2874bc8c-2ecf-4ff0-9517-cf5ff8518e91'),
    ('a1c5d836-4990-4c92-8b48-a52dd57f8050', now(), false, 'b1000000-0000-4000-8000-000000000001', '82b49689-e65a-494c-a0d7-974dad19afd0'),
    ('f7793f88-6bc0-4f04-8685-c07733450ec9', now(), false, 'b1000000-0000-4000-8000-000000000001', '5e24103f-6fd5-403c-9201-f72b96676005'),
    ('ad4e36f6-9111-40a9-85eb-9e4fcd9eb1f3', now(), false, 'b1000000-0000-4000-8000-000000000001', 'e9f8d1fe-1910-48b0-a531-f08f27da7e32'),
    ('c5000000-0000-4000-8000-000000000011', now(), false, 'b1000000-0000-4000-8000-000000000001', 'c5000000-0000-4000-8000-000000000001'),
    ('c5000000-0000-4000-8000-000000000012', now(), false, 'b1000000-0000-4000-8000-000000000001', 'c5000000-0000-4000-8000-000000000002'),
    ('c9000000-0000-4000-8000-000000000011', now(), false, 'b1000000-0000-4000-8000-000000000001', 'c9000000-0000-4000-8000-000000000001'),
    ('cb000000-0000-4000-8000-000000000011', now(), false, 'b1000000-0000-4000-8000-000000000001', 'cb000000-0000-4000-8000-000000000001'),
    -- SUPPLIER
    ('7dbc9e0a-8e7f-44cf-bede-d1709ddef704', now(), true, 'b1000000-0000-4000-8000-000000000005', 'e52fa248-3f4a-4b5f-9ebd-4d7b6997d92f'),
    ('462f2272-b4fd-4c57-8084-dbb66d3f5661', now(), false, 'b1000000-0000-4000-8000-000000000005', 'cf86d6af-92ba-4336-a6c4-b4bf4d0a2982'),
    -- PAYER
    ('a07aa9cd-5066-4125-8acc-6070f18fd667', now(), true, 'b1000000-0000-4000-8000-000000000003', '9a455a78-9e6a-4178-a1d1-dac872e38ffb'),
    ('47dd6e8c-d789-4cf0-8555-101cbd3ea99c', now(), false, 'b1000000-0000-4000-8000-000000000003', 'a379613c-b110-4761-bc89-c9c362198ec5'),
    -- SYSTEM_ADMIN
    ('3a9b3620-c669-4f2c-9ec8-2f40e009af9f', now(), true, 'b1000000-0000-4000-8000-000000000007', '3aaf7b7a-36eb-46c8-9071-93c78ac6070a');

-- Menús
INSERT INTO public.menus_cat (id, created_at, description, icon, label, path, status, updated_at) VALUES
    ('4820ef6e-597f-44fe-a740-265260dd8e37', now(), NULL, 'home', 'Inicio', '/admin', 'ACTIVE', now()),
    ('fbd97c37-26bd-4a45-af47-1c83cf32b43f', now(), NULL, 'file-text', 'Acuerdos', '/admin/agreement-management', 'ACTIVE', now()),
    ('8725fbfc-3f44-4166-8c40-42d6aaf01055', now(), NULL, 'truck', 'Proveedores', '/admin/supplier-management', 'ACTIVE', now()),
    ('f22418b6-1092-453d-8ef3-2b0e82a09c2e', now(), NULL, 'credit-card', 'Pagadores', '/admin/payer-management-admin', 'ACTIVE', now()),
    ('9acd8f29-2356-474a-95ac-43f2090eb8f7', now(), NULL, 'users', 'Usuarios', '/admin/user-management', 'ACTIVE', now()),
    ('1377138b-55e8-4378-b366-c68aa864bff2', now(), NULL, 'calendar', 'Feriados', '/admin/holiday-management', 'ACTIVE', now()),
    ('7468c6d2-ad56-4be4-9da4-219871c73d72', now(), NULL, 'monitor', 'Desembolsos', '/admin/disbursement-terminal', 'ACTIVE', now()),
    ('f71dc4f2-e3e4-427c-9ac6-364f99517697', now(), NULL, 'clock', 'Bitácora de lotes', '/admin/batches-history', 'ACTIVE', now()),
    ('c5000000-0000-4000-8000-000000000021', now(), NULL, 'send', 'Dispersiones', '/admin/dispersion-terminal', 'ACTIVE', now()),
    ('c5000000-0000-4000-8000-000000000022', now(), NULL, 'clock', 'Bitácora de dispersiones', '/admin/dispersion-batches-history', 'ACTIVE', now()),
    ('c9000000-0000-4000-8000-000000000021', now(), NULL, 'folder', 'Recursos de carga', '/admin/upload-resources-management', 'ACTIVE', now()),
    ('cb000000-0000-4000-8000-000000000021', now(), NULL, 'clock', 'Bitácora de documentos', '/admin/documents-history', 'ACTIVE', now()),
    ('a06a3245-62a9-4d0d-a59d-a20e55c631be', now(), NULL, 'list', 'Seleccionar Acuerdos', '/select-agreement', 'ACTIVE', now()),
    ('42ef6b1b-b947-45ea-be76-00f2f1851e30', now(), NULL, 'file', 'Documentos', '/supplier', 'ACTIVE', now()),
    ('f29411a8-4ff5-4e75-ab83-5636ec381eb6', now(), NULL, 'clock', 'Historial', '/supplier/documents-history', 'ACTIVE', now()),
    ('caed04a0-10a2-4b6d-a343-f7c9780c3366', now(), NULL, 'upload', 'Cargar Archivos', '/payer', 'ACTIVE', now()),
    ('ab956826-b9a2-4c8b-8d3c-f71b4b70bf91', now(), NULL, 'clock', 'Bitácora', '/payer/documents-history', 'ACTIVE', now()),
    ('510c9080-6750-43a8-bc84-95e43f093938', now(), NULL, 'settings', 'Parámetros', '/system', 'ACTIVE', now());

-- Menús por rol
INSERT INTO public.role_menus (id, created_at, display_order, menu_id, role_id) VALUES
    -- ADMIN (operador bancario)
    ('74e78b8c-177d-457d-9849-ddf6d5a0674a', now(), 1, '4820ef6e-597f-44fe-a740-265260dd8e37', 'b1000000-0000-4000-8000-000000000001'),
    ('cb000000-0000-4000-8000-000000000031', now(), 2, 'cb000000-0000-4000-8000-000000000021', 'b1000000-0000-4000-8000-000000000001'),
    ('2e912374-c72a-475e-8480-7b97b3f5d92b', now(), 3, 'fbd97c37-26bd-4a45-af47-1c83cf32b43f', 'b1000000-0000-4000-8000-000000000001'),
    ('fb716c8b-6821-48ba-bde6-b17538cbd956', now(), 4, '8725fbfc-3f44-4166-8c40-42d6aaf01055', 'b1000000-0000-4000-8000-000000000001'),
    ('9df3cbd8-364c-4af3-9ee5-71c4dffdbe34', now(), 5, 'f22418b6-1092-453d-8ef3-2b0e82a09c2e', 'b1000000-0000-4000-8000-000000000001'),
    ('81317135-93fb-4a35-9f3c-1982e7d081e2', now(), 6, '9acd8f29-2356-474a-95ac-43f2090eb8f7', 'b1000000-0000-4000-8000-000000000001'),
    ('b0057c82-5854-428c-8fcc-e1de650d3a0c', now(), 7, '1377138b-55e8-4378-b366-c68aa864bff2', 'b1000000-0000-4000-8000-000000000001'),
    ('7902ead4-3a53-4bb4-a61d-e61c40643d53', now(), 8, '7468c6d2-ad56-4be4-9da4-219871c73d72', 'b1000000-0000-4000-8000-000000000001'),
    ('c3d5e774-8b2d-42cb-bea2-957f89d49893', now(), 9, 'f71dc4f2-e3e4-427c-9ac6-364f99517697', 'b1000000-0000-4000-8000-000000000001'),
    ('c5000000-0000-4000-8000-000000000031', now(), 10, 'c5000000-0000-4000-8000-000000000021', 'b1000000-0000-4000-8000-000000000001'),
    ('c5000000-0000-4000-8000-000000000032', now(), 11, 'c5000000-0000-4000-8000-000000000022', 'b1000000-0000-4000-8000-000000000001'),
    ('c9000000-0000-4000-8000-000000000031', now(), 12, 'c9000000-0000-4000-8000-000000000021', 'b1000000-0000-4000-8000-000000000001'),
    -- SUPPLIER
    ('678ace11-e0e7-4b86-bb16-1ac3b07430a5', now(), 1, 'a06a3245-62a9-4d0d-a59d-a20e55c631be', 'b1000000-0000-4000-8000-000000000005'),
    ('dbb1e3ac-3eba-438a-9192-14716c4dd70d', now(), 2, '42ef6b1b-b947-45ea-be76-00f2f1851e30', 'b1000000-0000-4000-8000-000000000005'),
    ('2ab23b1b-a8e1-420d-a981-1bf8a4fa058b', now(), 3, 'f29411a8-4ff5-4e75-ab83-5636ec381eb6', 'b1000000-0000-4000-8000-000000000005'),
    -- PAYER
    ('885d10b5-a47a-4e26-a1e8-4135dcf5a7a5', now(), 1, 'caed04a0-10a2-4b6d-a343-f7c9780c3366', 'b1000000-0000-4000-8000-000000000003'),
    ('ae27bf2b-23eb-4d2f-b05d-2f16b3516bec', now(), 2, 'ab956826-b9a2-4c8b-8d3c-f71b4b70bf91', 'b1000000-0000-4000-8000-000000000003'),
    -- SYSTEM_ADMIN
    ('42c05b0b-bdd8-4faf-9e60-518254dbc37b', now(), 1, '510c9080-6750-43a8-bc84-95e43f093938', 'b1000000-0000-4000-8000-000000000007');

-- -----------------------------------------------------------------------------
-- 3. PARÁMETROS DEL SISTEMA (el administrador del sistema puede ajustarlos después)
-- -----------------------------------------------------------------------------
INSERT INTO public.system_parameters (id, created_at, param_key, updated_at, param_value) VALUES
    ('ae000000-0000-4000-8000-000000000001', now(), 'IVA_RATE', now(), '0.13'),
    ('caf45302-94cb-46ac-855c-2424ce3e6da0', now(), 'DEFAULT_CREDIT_THRESHOLD', now(), '0.80'),
    ('1a6a68b2-19d1-4d53-a744-4b901e344db9', now(), 'DISBURSEMENT_CUTOFF_TIME', now(), '15:00'),
    ('b86c15e9-4932-4d10-8a13-c5b25691c30b', now(), 'DUE_DATE_GRACE_DAYS', now(), '5'),
    ('865e32ac-29d4-44ad-8278-8db3d14d0ffb', now(), 'MAX_INVOICE_AGE_DAYS', now(), '120'),
    ('ca4cd686-a2dc-4b60-a97b-8a5b12fa4697', now(), 'UPLOAD_ALLOWED_EXTENSIONS', now(), '.xlsx,.xls'),
    ('77d96bd5-46dc-4e2e-a92d-e09800b4cb7a', now(), 'CORS_ALLOWED_ORIGINS', now(),
        (SELECT valor FROM instalacion_parametros WHERE clave = 'cors_origenes')),
    ('51effc4a-7f1c-4a24-b445-47f41bdb4a75', now(), 'JWT_EXPIRATION_MINUTES', now(), '1440'),
    ('68d4cea3-cf5b-465d-bbbc-1b83290def53', now(), 'UPLOAD_MAX_FILE_SIZE_MB', now(), '5'),
    ('e2c88614-984e-41b9-a75c-434613218491', now(), 'UPLOAD_MAX_ROWS', now(), '5000'),
    ('52ad54bc-9d16-4778-aef1-7235ada64dfe', now(), 'SESSION_IDLE_TIMEOUT_MINUTES', now(), '15'),
    ('d1200000-0000-4000-8000-000000000001', now(), 'MAILJET_API_KEY', now(), 'CONFIGURAR'),
    ('d1200000-0000-4000-8000-000000000002', now(), 'MAILJET_API_SECRET', now(), 'CONFIGURAR'),
    ('d1200000-0000-4000-8000-000000000003', now(), 'MAILJET_FROM_EMAIL', now(), 'CONFIGURAR'),
    ('d1200000-0000-4000-8000-000000000004', now(), 'MAILJET_FROM_NAME', now(), 'CONFIGURAR'),
    ('d1200000-0000-4000-8000-000000000005', now(), 'APP_LOGIN_URL', now(), 'CONFIGURAR'),
    ('d1300000-0000-4000-8000-000000000001', now(), 'MAILJET_API_URL', now(), 'https://api.mailjet.com/v3/send'),
    ('d1400000-0000-4000-8000-000000000001', now(), 'JWT_SECRET', now(), 'G9UuPSmEz8a18PARiE8Rs9QKvDrdUOJjjNe3duoQqUw=');

-- -----------------------------------------------------------------------------
-- 4. ENTIDAD BANCO Y USUARIOS MADRE
-- -----------------------------------------------------------------------------
WITH p AS (
    SELECT max(valor) FILTER (WHERE clave = 'banco_nit') AS banco_nit,
           max(valor) FILTER (WHERE clave = 'banco_nombre') AS banco_nombre,
           max(valor) FILTER (WHERE clave = 'banco_codigo') AS banco_codigo
    FROM instalacion_parametros
)
INSERT INTO public.entities (id, code, created_at, name, nit, status, updated_at, entity_type_id)
SELECT gen_random_uuid(), banco_codigo, now(), banco_nombre, banco_nit, 'ACTIVE', now(),
       'a1000000-0000-4000-8000-000000000003'
FROM p;

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
    FROM instalacion_parametros
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
ORDER BY r.name;

SELECT param_value AS cors_allowed_origins
FROM public.system_parameters
WHERE param_key = 'CORS_ALLOWED_ORIGINS';
