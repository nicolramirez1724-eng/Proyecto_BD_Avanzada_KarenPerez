-- =====================================================================
-- 04_Seguridad.sql
-- Roles, usuarios, permisos y políticas de seguridad (MySQL 8.0.19+)
-- Ejecutar con un usuario administrador (p. ej. root).
-- Las contraseñas mostradas son de EJEMPLO: cámbielas en un entorno real.
-- =====================================================================
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- 15. Política de contraseñas seguras (aplica a todos los usuarios)
--     Se combinan variables globales y opciones por usuario (más abajo).
-- ---------------------------------------------------------------------
SET PERSIST default_password_lifetime = 90;        -- caducidad a 90 días
SET PERSIST password_history = 5;                  -- no reutilizar las últimas 5
SET PERSIST password_reuse_interval = 365;         -- ni las de los últimos 365 días
-- Componente validate_password (longitud, mayúsculas, números, símbolos). Descomente si aún no está instalado:
-- INSTALL COMPONENT 'file://component_validate_password';
-- SET PERSIST validate_password.policy = 'STRONG';
-- SET PERSIST validate_password.length = 12;

-- ---------------------------------------------------------------------
-- 16. root no puede usarse desde conexiones remotas
-- ---------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY 'Cambiar_Root#2026!';
DROP USER IF EXISTS 'root'@'%';

-- ---------------------------------------------------------------------
-- Roles (1-6 y 17)
-- ---------------------------------------------------------------------
-- 1. Administrador_Sistema: todos los privilegios
CREATE ROLE IF NOT EXISTS 'Administrador_Sistema';
GRANT ALL PRIVILEGES ON ecommerce_db.* TO 'Administrador_Sistema' WITH GRANT OPTION;

-- 2. Gerente_Marketing: solo lectura de ventas y clientes (clientes sin la columna contrasena)
CREATE ROLE IF NOT EXISTS 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.ventas          TO 'Gerente_Marketing';
GRANT SELECT ON ecommerce_db.detalle_ventas  TO 'Gerente_Marketing';
GRANT SELECT (id_cliente, nombre, apellido, email, ciudad, region, fecha_registro, total_gastado,
              fecha_ultimo_pedido, nivel_lealtad, activo)
      ON ecommerce_db.clientes TO 'Gerente_Marketing';

-- 3. Analista_Datos: solo lectura de todas las tablas EXCEPTO las de auditoría
--    (clientes sin la columna contrasena). Nunca recibe INSERT/UPDATE/DELETE/DROP.
CREATE ROLE IF NOT EXISTS 'Analista_Datos';
GRANT SELECT ON ecommerce_db.sucursales       TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.categorias       TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.proveedores      TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.productos        TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.ventas           TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.detalle_ventas   TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carritos         TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.carrito_items    TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.visitas_producto TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.promociones      TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.resenas          TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.pagos            TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.devoluciones     TO 'Analista_Datos';
GRANT SELECT ON ecommerce_db.creditos_cliente TO 'Analista_Datos';
GRANT SELECT (id_cliente, nombre, apellido, email, direccion_envio, ciudad, region, fecha_nacimiento,
              fecha_registro, total_gastado, fecha_ultimo_pedido, nivel_lealtad, referido_por, activo)
      ON ecommerce_db.clientes TO 'Analista_Datos';

-- 4. Empleado_Inventario: solo puede modificar stock y ubicación de productos
--    (fecha_modificacion se incluye porque el trigger BEFORE UPDATE la asigna con el privilegio del invocador)
CREATE ROLE IF NOT EXISTS 'Empleado_Inventario';
GRANT SELECT ON ecommerce_db.productos TO 'Empleado_Inventario';
GRANT UPDATE (precio, stock, ubicacion, fecha_modificacion) ON ecommerce_db.productos TO 'Empleado_Inventario';
-- 14. Revocar UPDATE sobre la columna precio a Empleado_Inventario
REVOKE UPDATE (precio) ON ecommerce_db.productos FROM 'Empleado_Inventario';

-- 5. Atencion_Cliente: ve clientes y ventas (vistas seguras), NO puede modificar precios
CREATE ROLE IF NOT EXISTS 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.productos TO 'Atencion_Cliente';   -- solo lectura: sin UPDATE de precios

-- 6. Auditor_Financiero: solo lectura de ventas, productos y logs de precios
CREATE ROLE IF NOT EXISTS 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.ventas            TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.detalle_ventas    TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.productos         TO 'Auditor_Financiero';
GRANT SELECT ON ecommerce_db.log_cambios_precio TO 'Auditor_Financiero';

-- 17. Visitante: solo ve el catálogo (tabla productos, sin costo ni stock)
CREATE ROLE IF NOT EXISTS 'Visitante';
GRANT SELECT (id_producto, nombre, descripcion, precio, sku, activo, id_categoria)
      ON ecommerce_db.productos TO 'Visitante';

-- ---------------------------------------------------------------------
-- 11. Analista_Datos no puede ejecutar DELETE ni TRUNCATE (TRUNCATE requiere DROP)
--     Solo tiene SELECT; se refuerza de forma explícita otorgando y revocando.
-- ---------------------------------------------------------------------
GRANT DELETE, DROP ON ecommerce_db.* TO 'Analista_Datos';
REVOKE DELETE, DROP ON ecommerce_db.* FROM 'Analista_Datos';

-- ---------------------------------------------------------------------
-- 13. Vista v_info_clientes_basica (oculta contraseña, dirección, nacimiento y datos financieros)
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_info_clientes_basica AS
SELECT id_cliente, nombre, apellido, email, ciudad, region, fecha_registro, activo
FROM clientes;
GRANT SELECT ON ecommerce_db.v_info_clientes_basica TO 'Atencion_Cliente';

-- ---------------------------------------------------------------------
-- 19. Los usuarios solo ven las ventas de su sucursal (tabla usuario_sucursal)
--     USER() devuelve el usuario que se conecta, incluso dentro de vistas DEFINER.
-- ---------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_ventas_sucursal AS
SELECT v.*
FROM ventas v
WHERE v.id_sucursal IN (SELECT us.id_sucursal FROM usuario_sucursal us
                        WHERE us.usuario = SUBSTRING_INDEX(USER(), '@', 1));

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_detalle_ventas_sucursal AS
SELECT d.*
FROM detalle_ventas d
JOIN v_ventas_sucursal v ON v.id_venta = d.id_venta;

GRANT SELECT ON ecommerce_db.v_ventas_sucursal         TO 'Atencion_Cliente';
GRANT SELECT ON ecommerce_db.v_detalle_ventas_sucursal TO 'Atencion_Cliente';

-- ---------------------------------------------------------------------
-- 12. Gerente_Marketing puede ejecutar los procedimientos de reportes de marketing
--     (los procedimientos se crean en 07_Procedimientos_Almacenados.sql; MySQL permite
--      conceder EXECUTE sobre rutinas aún no creadas)
-- ---------------------------------------------------------------------
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_GenerarReporteMensualVentas TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ObtenerDashboardAdmin       TO 'Gerente_Marketing';
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_ObtenerProductosRelacionados TO 'Gerente_Marketing';
-- Inventario ajusta stock solo mediante el procedimiento auditado
GRANT EXECUTE ON PROCEDURE ecommerce_db.sp_AjustarNivelStock TO 'Empleado_Inventario';

-- ---------------------------------------------------------------------
-- Usuarios (7-10 y extras) con política de contraseñas por usuario (15)
--   PASSWORD EXPIRE INTERVAL, PASSWORD HISTORY, PASSWORD REUSE INTERVAL,
--   FAILED_LOGIN_ATTEMPTS / PASSWORD_LOCK_TIME (bloqueo tras 5 fallos)
-- ---------------------------------------------------------------------
-- 7. admin_user -> Administrador_Sistema
CREATE USER IF NOT EXISTS 'admin_user'@'localhost' IDENTIFIED BY 'Adm!n_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'Administrador_Sistema' TO 'admin_user'@'localhost';

-- 8. marketing_user -> Gerente_Marketing
CREATE USER IF NOT EXISTS 'marketing_user'@'localhost' IDENTIFIED BY 'Mkt!ng_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'Gerente_Marketing' TO 'marketing_user'@'localhost';

-- 9. inventory_user -> Empleado_Inventario
CREATE USER IF NOT EXISTS 'inventory_user'@'localhost' IDENTIFIED BY 'Inv!ntario_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'Empleado_Inventario' TO 'inventory_user'@'localhost';

-- 10. support_user -> Atencion_Cliente
CREATE USER IF NOT EXISTS 'support_user'@'localhost' IDENTIFIED BY 'Supp0rt!_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'Atencion_Cliente' TO 'support_user'@'localhost';

-- Usuarios adicionales para los roles restantes
CREATE USER IF NOT EXISTS 'analyst_user'@'localhost' IDENTIFIED BY 'Analyst!_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1
  WITH MAX_QUERIES_PER_HOUR 500;     -- 18. límite de consultas por hora para el rol Analista_Datos
GRANT 'Analista_Datos' TO 'analyst_user'@'localhost';

CREATE USER IF NOT EXISTS 'auditor_user'@'localhost' IDENTIFIED BY 'Audit0r!_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'Auditor_Financiero' TO 'auditor_user'@'localhost';

CREATE USER IF NOT EXISTS 'visitor_user'@'localhost' IDENTIFIED BY 'V1sit!_Ec0m#2026'
  PASSWORD EXPIRE INTERVAL 90 DAY PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
GRANT 'Visitante' TO 'visitor_user'@'localhost';

-- Activar los roles automáticamente al iniciar sesión
SET DEFAULT ROLE ALL TO 'admin_user'@'localhost', 'marketing_user'@'localhost', 'inventory_user'@'localhost',
                        'support_user'@'localhost', 'analyst_user'@'localhost', 'auditor_user'@'localhost',
                        'visitor_user'@'localhost';

-- ---------------------------------------------------------------------
-- 20. Auditoría de intentos de inicio de sesión fallidos
--     En MySQL Community: (a) el log de errores registra "Access denied" con verbosidad 3 y
--     (b) Performance Schema cuenta los errores 1045 (acceso denegado). Además, FAILED_LOGIN_ATTEMPTS
--     bloquea la cuenta tras 5 fallos. (En Enterprise se puede usar el plugin audit_log.)
-- ---------------------------------------------------------------------
SET PERSIST log_error_verbosity = 3;

CREATE OR REPLACE SQL SECURITY DEFINER VIEW v_intentos_login_fallidos AS
SELECT error_number, error_name, sum_error_raised AS total_intentos_fallidos,
       first_seen, last_seen
FROM performance_schema.events_errors_summary_global_by_error
WHERE error_number = 1045;          -- ER_ACCESS_DENIED_ERROR
GRANT SELECT ON ecommerce_db.v_intentos_login_fallidos TO 'Auditor_Financiero';

FLUSH PRIVILEGES;

-- Verificación sugerida:
-- SHOW GRANTS FOR 'analyst_user'@'localhost' USING 'Analista_Datos';
-- SHOW GRANTS FOR 'inventory_user'@'localhost' USING 'Empleado_Inventario';
