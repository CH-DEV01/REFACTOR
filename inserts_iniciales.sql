-- =============================================================================
-- INSERTS INICIALES — catálogos y parámetros
-- =============================================================================
-- Solo los INSERT de datos fijos. No crea tablas.
-- Sirve cuando el esquema ya existe y faltan los catálogos y system_parameters.
-- La instalación completa (esquema + estos datos + entidad banco y usuarios madre)
-- sigue siendo db/prod/instalacion_inicial.sql.
--
-- SQL estándar de PostgreSQL (16): no usa comandos de psql, así que corre igual en
-- psql, pgAdmin (Query Tool), DBeaver o cualquier cliente que ejecute scripts.
--
-- Antes de ejecutar, completar la sección PARÁMETROS con las URL del cliente web,
-- separadas por coma y sin barra final. JWT_SECRET trae una llave por defecto;
-- cada ambiente puede reemplazarla. Cambiarla invalida las sesiones ya emitidas.
--
-- Uso (cualquiera de las dos):
--   - psql -h <host> -U <usuario> -d <base> -v ON_ERROR_STOP=1 -f inserts_iniciales.sql
--   - Abrir el archivo en pgAdmin o DBeaver y ejecutarlo completo como script.
--
-- Todo corre en una sola transacción: si una instrucción falla, no queda nada guardado.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- PARÁMETROS
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE inserts_parametros (clave text PRIMARY KEY, valor text NOT NULL) ON COMMIT DROP;

INSERT INTO inserts_parametros (clave, valor) VALUES
    -- Orígenes desde los que el navegador puede llamar a la API. Ej.: https://pay.davivienda.com.sv
    ('cors_origenes', 'http://localhost:5173,https://devpay.davivienda.com.sv');

-- -----------------------------------------------------------------------------
-- EJECUCIÓN (no modificar a partir de aquí)
-- -----------------------------------------------------------------------------
UPDATE inserts_parametros SET valor = regexp_replace(valor, '\s', '', 'g') WHERE clave = 'cors_origenes';

DO $$
DECLARE
    v_origenes text := (SELECT valor FROM inserts_parametros WHERE clave = 'cors_origenes');
    v_origen   text;
BEGIN
    IF v_origenes IS NULL OR v_origenes = '' OR upper(v_origenes) = 'COMPLETAR' THEN
        RAISE EXCEPTION 'Falta completar el parámetro cors_origenes.';
    END IF;
    FOREACH v_origen IN ARRAY string_to_array(v_origenes, ',')
    LOOP
        IF v_origen !~ '^https?://[^/,]+$' THEN
            RAISE EXCEPTION 'Origen CORS no válido: "%". Use el formato https://dominio[:puerto], sin barra final.', v_origen;
        END IF;
    END LOOP;
    IF length(v_origenes) > 255 THEN
        RAISE EXCEPTION 'Los orígenes CORS admiten máximo 255 caracteres en total.';
    END IF;
END
$$;

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

-- Si este archivo se guarda con saltos de línea CRLF, el cliente conserva el \r dentro de
-- los textos y el hash ya no coincidiría con el contenido.
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
        (SELECT valor FROM inserts_parametros WHERE clave = 'cors_origenes')),
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

COMMIT;
