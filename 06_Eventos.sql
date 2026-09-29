-- =====================================================================
-- 06_Eventos.sql
-- Tablas de reportes/resumen + 20 eventos programados (MySQL Event Scheduler)
-- =====================================================================
USE ecommerce_db;

-- Activar el programador de eventos
SET GLOBAL event_scheduler = ON;

-- ---------------------------------------------------------------------
-- Tablas usadas por los eventos
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reporte_ventas_semanales (
  id_reporte      INT AUTO_INCREMENT PRIMARY KEY,
  semana_inicio   DATE NOT NULL,
  semana_fin      DATE NOT NULL,
  num_ventas      INT NOT NULL,
  total_ventas    DECIMAL(14,2) NOT NULL,
  ticket_promedio DECIMAL(14,2) NOT NULL,
  generado_en     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_semana (semana_inicio)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_cambios_precio_hist LIKE log_cambios_precio;
CREATE TABLE IF NOT EXISTS log_estado_pedido_hist  LIKE log_estado_pedido;
CREATE TABLE IF NOT EXISTS auditoria_clientes_hist LIKE auditoria_clientes;

CREATE TABLE IF NOT EXISTS lista_reabastecimiento (
  id_producto        INT PRIMARY KEY,
  nombre             VARCHAR(150) NOT NULL,
  stock_actual       INT NOT NULL,
  stock_minimo       INT NOT NULL,
  cantidad_sugerida  INT NOT NULL,
  id_proveedor       INT NOT NULL,
  generado_en        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS resumen_ventas_diarias (
  fecha            DATE PRIMARY KEY,
  num_ventas       INT NOT NULL,
  unidades         INT NOT NULL,
  total_ventas     DECIMAL(14,2) NOT NULL,
  actualizado_en   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS inconsistencias_datos (
  id_inconsistencia INT AUTO_INCREMENT PRIMARY KEY,
  tipo              VARCHAR(50) NOT NULL,
  id_referencia     INT NOT NULL,
  descripcion       VARCHAR(255) NOT NULL,
  detectado_en      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS cumpleanos_cupones (
  id_cupon         INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente       INT NOT NULL,
  codigo_cupon     VARCHAR(40) NOT NULL UNIQUE,
  fecha_generacion DATE NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ranking_productos (
  posicion       INT PRIMARY KEY,
  id_producto    INT NOT NULL,
  nombre         VARCHAR(150) NOT NULL,
  unidades       INT NOT NULL,
  ingresos       DECIMAL(14,2) NOT NULL,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS kpis_mensuales (
  anio             INT NOT NULL,
  mes              INT NOT NULL,
  ventas_totales   DECIMAL(14,2) NOT NULL,
  num_ventas       INT NOT NULL,
  ticket_promedio  DECIMAL(14,2) NOT NULL,
  nuevos_clientes  INT NOT NULL,
  clientes_activos INT NOT NULL,
  utilidad_bruta   DECIMAL(14,2) NOT NULL,
  calculado_en     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (anio, mes)
) ENGINE=InnoDB;

-- "Vista materializada" emulada con una tabla (MySQL no soporta vistas materializadas)
CREATE TABLE IF NOT EXISTS mv_ventas_por_categoria (
  id_categoria INT PRIMARY KEY,
  categoria    VARCHAR(80) NOT NULL,
  unidades     INT NOT NULL,
  ingresos     DECIMAL(14,2) NOT NULL,
  actualizado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_tamano_bd (
  id_log      INT AUTO_INCREMENT PRIMARY KEY,
  fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  tamano_mb   DECIMAL(12,2) NOT NULL,
  num_tablas  INT NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS alertas_fraude (
  id_alerta   INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente  INT NOT NULL,
  motivo      VARCHAR(255) NOT NULL,
  detectado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS reporte_proveedores_mensual (
  anio         INT NOT NULL,
  mes          INT NOT NULL,
  id_proveedor INT NOT NULL,
  proveedor    VARCHAR(120) NOT NULL,
  unidades     INT NOT NULL,
  ingresos     DECIMAL(14,2) NOT NULL,
  utilidad     DECIMAL(14,2) NOT NULL,
  generado_en  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (anio, mes, id_proveedor)
) ENGINE=InnoDB;

DELIMITER $$

-- 1. Reporte de ventas semanal (semana anterior completa, lunes a domingo) - lunes 01:00
DROP EVENT IF EXISTS evt_generate_weekly_sales_report$$
CREATE EVENT evt_generate_weekly_sales_report
ON SCHEDULE EVERY 1 WEEK STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL (7 - WEEKDAY(CURRENT_DATE)) DAY + INTERVAL 1 HOUR)
COMMENT 'Reporte semanal de ventas'
DO
BEGIN
  DECLARE v_ini DATE DEFAULT DATE_SUB(DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY), INTERVAL 7 DAY);
  INSERT INTO reporte_ventas_semanales (semana_inicio, semana_fin, num_ventas, total_ventas, ticket_promedio)
  SELECT v_ini, DATE_ADD(v_ini, INTERVAL 6 DAY), COUNT(*), COALESCE(SUM(total), 0), COALESCE(ROUND(AVG(total), 2), 0)
  FROM ventas
  WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < DATE_ADD(v_ini, INTERVAL 7 DAY)
  ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas), total_ventas = VALUES(total_ventas),
                          ticket_promedio = VALUES(ticket_promedio), generado_en = NOW();
END$$

-- 2. Borra diariamente las tablas temporales (tablas con prefijo tmp_ del esquema)
DROP EVENT IF EXISTS evt_cleanup_temp_tables_daily$$
CREATE EVENT evt_cleanup_temp_tables_daily
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 1 HOUR)
COMMENT 'Elimina tablas tmp_%'
DO
BEGIN
  DECLARE v_fin INT DEFAULT 0;
  DECLARE v_tabla VARCHAR(64);
  DECLARE cur CURSOR FOR
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name LIKE 'tmp\_%';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;
  OPEN cur;
  bucle: LOOP
    FETCH cur INTO v_tabla;
    IF v_fin = 1 THEN LEAVE bucle; END IF;
    SET @sql_drop = CONCAT('DROP TABLE IF EXISTS `', v_tabla, '`');
    PREPARE st FROM @sql_drop;
    EXECUTE st;
    DEALLOCATE PREPARE st;
  END LOOP;
  CLOSE cur;
END$$

-- 3. Archiva logs de más de 6 meses en tablas históricas (día 1 de cada mes)
DROP EVENT IF EXISTS evt_archive_old_logs_monthly$$
CREATE EVENT evt_archive_old_logs_monthly
ON SCHEDULE EVERY 1 MONTH STARTS (TIMESTAMP(DATE_FORMAT(CURRENT_DATE, '%Y-%m-01')) + INTERVAL 1 MONTH + INTERVAL 2 HOUR)
COMMENT 'Mueve logs > 6 meses a tablas históricas'
DO
BEGIN
  DECLARE v_corte DATETIME DEFAULT DATE_SUB(NOW(), INTERVAL 6 MONTH);
  INSERT INTO log_cambios_precio_hist  SELECT * FROM log_cambios_precio  WHERE fecha_cambio < v_corte;
  DELETE FROM log_cambios_precio  WHERE fecha_cambio < v_corte;
  INSERT INTO log_estado_pedido_hist   SELECT * FROM log_estado_pedido   WHERE fecha_cambio < v_corte;
  DELETE FROM log_estado_pedido   WHERE fecha_cambio < v_corte;
  INSERT INTO auditoria_clientes_hist  SELECT * FROM auditoria_clientes  WHERE fecha < v_corte;
  DELETE FROM auditoria_clientes  WHERE fecha < v_corte;
END$$

-- 4. Desactiva cada hora los códigos de descuento vencidos
DROP EVENT IF EXISTS evt_deactivate_expired_promotions_hourly$$
CREATE EVENT evt_deactivate_expired_promotions_hourly
ON SCHEDULE EVERY 1 HOUR STARTS (CURRENT_TIMESTAMP + INTERVAL 1 HOUR)
COMMENT 'Desactiva promociones vencidas'
DO
BEGIN
  UPDATE promociones SET activa = 0 WHERE activa = 1 AND fecha_fin < NOW();
END$$

-- 5. Recalcula el nivel de lealtad cada noche
DROP EVENT IF EXISTS evt_recalculate_customer_loyalty_tiers_nightly$$
CREATE EVENT evt_recalculate_customer_loyalty_tiers_nightly
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 2 HOUR + INTERVAL 30 MINUTE)
COMMENT 'Recalcula nivel_lealtad'
DO
BEGIN
  UPDATE clientes SET nivel_lealtad = fn_DeterminarEstadoLealtad(id_cliente) WHERE activo = 1;
END$$

-- 6. Lista diaria de productos por reabastecer
DROP EVENT IF EXISTS evt_generate_reorder_list_daily$$
CREATE EVENT evt_generate_reorder_list_daily
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 6 HOUR)
COMMENT 'Lista de reabastecimiento'
DO
BEGIN
  DELETE FROM lista_reabastecimiento;
  INSERT INTO lista_reabastecimiento (id_producto, nombre, stock_actual, stock_minimo, cantidad_sugerida, id_proveedor)
  SELECT id_producto, nombre, stock, stock_minimo, (stock_minimo * 3 - stock), id_proveedor
  FROM productos WHERE activo = 1 AND stock < stock_minimo;
END$$

-- 7. Reconstruye/optimiza los índices de las tablas más usadas (domingo 03:00)
DROP EVENT IF EXISTS evt_rebuild_indexes_weekly$$
CREATE EVENT evt_rebuild_indexes_weekly
ON SCHEDULE EVERY 1 WEEK STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL (13 - WEEKDAY(CURRENT_DATE)) DAY + INTERVAL 3 HOUR)
COMMENT 'OPTIMIZE de tablas principales'
DO
BEGIN
  OPTIMIZE TABLE ventas, detalle_ventas, productos, clientes;
END$$

-- 8. Suspende cuentas sin actividad en más de un año (trimestral)
DROP EVENT IF EXISTS evt_suspend_inactive_accounts_quarterly$$
CREATE EVENT evt_suspend_inactive_accounts_quarterly
ON SCHEDULE EVERY 3 MONTH STARTS (TIMESTAMP(DATE_FORMAT(CURRENT_DATE, '%Y-%m-01')) + INTERVAL 1 MONTH + INTERVAL 4 HOUR)
COMMENT 'Desactiva clientes inactivos > 1 año'
DO
BEGIN
  UPDATE clientes c SET c.activo = 0
  WHERE c.activo = 1
    AND c.fecha_registro < DATE_SUB(NOW(), INTERVAL 1 YEAR)
    AND NOT EXISTS (SELECT 1 FROM ventas v WHERE v.id_cliente = c.id_cliente AND v.fecha_venta >= DATE_SUB(NOW(), INTERVAL 1 YEAR));
END$$

-- 9. Agrega las ventas del día anterior en la tabla resumen
DROP EVENT IF EXISTS evt_aggregate_daily_sales_data$$
CREATE EVENT evt_aggregate_daily_sales_data
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 30 MINUTE)
COMMENT 'Resumen diario de ventas'
DO
BEGIN
  INSERT INTO resumen_ventas_diarias (fecha, num_ventas, unidades, total_ventas)
  SELECT DATE_SUB(CURDATE(), INTERVAL 1 DAY), COUNT(DISTINCT v.id_venta), COALESCE(SUM(d.cantidad), 0), COALESCE(SUM(d.cantidad * d.precio_unitario_congelado), 0)
  FROM ventas v LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
  WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= DATE_SUB(CURDATE(), INTERVAL 1 DAY) AND v.fecha_venta < CURDATE()
  ON DUPLICATE KEY UPDATE num_ventas = VALUES(num_ventas), unidades = VALUES(unidades),
                          total_ventas = VALUES(total_ventas), actualizado_en = NOW();
END$$

-- 10. Busca inconsistencias (ventas sin detalle, totales que no cuadran, stock negativo)
DROP EVENT IF EXISTS evt_check_data_consistency_nightly$$
CREATE EVENT evt_check_data_consistency_nightly
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 3 HOUR + INTERVAL 30 MINUTE)
COMMENT 'Chequeo de consistencia'
DO
BEGIN
  INSERT INTO inconsistencias_datos (tipo, id_referencia, descripcion)
  SELECT 'VENTA_SIN_DETALLE', v.id_venta, 'La venta no tiene líneas de detalle'
  FROM ventas v LEFT JOIN detalle_ventas d ON d.id_venta = v.id_venta
  WHERE d.id_detalle IS NULL;

  INSERT INTO inconsistencias_datos (tipo, id_referencia, descripcion)
  SELECT 'TOTAL_DESCUADRADO', v.id_venta,
         CONCAT('total=', v.total, ' vs suma detalle=', fn_CalcularTotalVenta(v.id_venta))
  FROM ventas v
  WHERE v.total <> fn_CalcularTotalVenta(v.id_venta)
    AND EXISTS (SELECT 1 FROM detalle_ventas d WHERE d.id_venta = v.id_venta);

  INSERT INTO inconsistencias_datos (tipo, id_referencia, descripcion)
  SELECT 'STOCK_NEGATIVO', id_producto, CONCAT('stock=', stock) FROM productos WHERE stock < 0;
END$$

-- 11. Lista diaria de cumpleaños con cupón
DROP EVENT IF EXISTS evt_send_birthday_greetings_daily$$
CREATE EVENT evt_send_birthday_greetings_daily
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 7 HOUR)
COMMENT 'Cupones de cumpleaños'
DO
BEGIN
  INSERT IGNORE INTO cumpleanos_cupones (id_cliente, codigo_cupon, fecha_generacion)
  SELECT id_cliente, CONCAT('BDAY-', id_cliente, '-', YEAR(CURDATE())), CURDATE()
  FROM clientes
  WHERE activo = 1 AND fecha_nacimiento IS NOT NULL
    AND MONTH(fecha_nacimiento) = MONTH(CURDATE()) AND DAY(fecha_nacimiento) = DAY(CURDATE());
END$$

-- 12. Ranking de productos más populares (cada hora)
DROP EVENT IF EXISTS evt_update_product_rankings_hourly$$
CREATE EVENT evt_update_product_rankings_hourly
ON SCHEDULE EVERY 1 HOUR STARTS (CURRENT_TIMESTAMP + INTERVAL 1 HOUR)
COMMENT 'Ranking de productos'
DO
BEGIN
  DELETE FROM ranking_productos;
  INSERT INTO ranking_productos (posicion, id_producto, nombre, unidades, ingresos)
  SELECT ROW_NUMBER() OVER (ORDER BY SUM(d.cantidad) DESC, p.id_producto), p.id_producto, p.nombre,
         SUM(d.cantidad), SUM(d.cantidad * d.precio_unitario_congelado)
  FROM productos p
  JOIN detalle_ventas d ON d.id_producto = p.id_producto
  JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  GROUP BY p.id_producto, p.nombre;
END$$

-- 13. Backup lógico nocturno de las tablas críticas (copias *_bkp dentro del esquema)
--     Para un respaldo externo use además: mysqldump ecommerce_db ventas detalle_ventas clientes productos
DROP EVENT IF EXISTS evt_backup_critical_tables_daily$$
CREATE EVENT evt_backup_critical_tables_daily
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 4 HOUR)
COMMENT 'Copia lógica de tablas críticas'
DO
BEGIN
  DROP TABLE IF EXISTS ventas_bkp;
  CREATE TABLE ventas_bkp AS SELECT * FROM ventas;
  DROP TABLE IF EXISTS detalle_ventas_bkp;
  CREATE TABLE detalle_ventas_bkp AS SELECT * FROM detalle_ventas;
  DROP TABLE IF EXISTS clientes_bkp;
  CREATE TABLE clientes_bkp AS SELECT * FROM clientes;
  DROP TABLE IF EXISTS productos_bkp;
  CREATE TABLE productos_bkp AS SELECT * FROM productos;
END$$

-- 14. Vacía los carritos abandonados hace más de 72 horas
DROP EVENT IF EXISTS evt_clear_abandoned_carts_daily$$
CREATE EVENT evt_clear_abandoned_carts_daily
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 5 HOUR)
COMMENT 'Limpia carritos abandonados > 72h'
DO
BEGIN
  DELETE i FROM carrito_items i
  JOIN carritos c ON c.id_carrito = i.id_carrito
  WHERE c.estado = 'Activo' AND c.fecha_actualizacion < DATE_SUB(NOW(), INTERVAL 72 HOUR);
  UPDATE carritos SET estado = 'Abandonado'
  WHERE estado = 'Activo' AND fecha_actualizacion < DATE_SUB(NOW(), INTERVAL 72 HOUR);
END$$

-- 15. KPIs del mes anterior (el día 1 de cada mes)
DROP EVENT IF EXISTS evt_calculate_monthly_kpis$$
CREATE EVENT evt_calculate_monthly_kpis
ON SCHEDULE EVERY 1 MONTH STARTS (TIMESTAMP(DATE_FORMAT(CURRENT_DATE, '%Y-%m-01')) + INTERVAL 1 MONTH + INTERVAL 1 HOUR + INTERVAL 30 MINUTE)
COMMENT 'KPIs mensuales'
DO
BEGIN
  DECLARE v_ini DATE DEFAULT DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 1 MONTH);
  DECLARE v_fin DATE DEFAULT DATE_FORMAT(CURDATE(), '%Y-%m-01');
  INSERT INTO kpis_mensuales (anio, mes, ventas_totales, num_ventas, ticket_promedio, nuevos_clientes, clientes_activos, utilidad_bruta)
  SELECT YEAR(v_ini), MONTH(v_ini),
         COALESCE((SELECT SUM(total) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin), 0),
         (SELECT COUNT(*) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin),
         COALESCE((SELECT ROUND(AVG(total), 2) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin), 0),
         (SELECT COUNT(*) FROM clientes WHERE fecha_registro >= v_ini AND fecha_registro < v_fin),
         (SELECT COUNT(DISTINCT id_cliente) FROM ventas WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < v_fin),
         COALESCE((SELECT SUM(d.cantidad * (d.precio_unitario_congelado - p.costo))
                   FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
                   JOIN productos p ON p.id_producto = d.id_producto
                   WHERE v.fecha_venta >= v_ini AND v.fecha_venta < v_fin), 0)
  ON DUPLICATE KEY UPDATE ventas_totales = VALUES(ventas_totales), num_ventas = VALUES(num_ventas),
    ticket_promedio = VALUES(ticket_promedio), nuevos_clientes = VALUES(nuevos_clientes),
    clientes_activos = VALUES(clientes_activos), utilidad_bruta = VALUES(utilidad_bruta), calculado_en = NOW();
END$$

-- 16. Refresca la "vista materializada" de ventas por categoría (cada noche)
DROP EVENT IF EXISTS evt_refresh_materialized_views_nightly$$
CREATE EVENT evt_refresh_materialized_views_nightly
ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 2 HOUR + INTERVAL 45 MINUTE)
COMMENT 'Refresco de mv_ventas_por_categoria'
DO
BEGIN
  DELETE FROM mv_ventas_por_categoria;
  INSERT INTO mv_ventas_por_categoria (id_categoria, categoria, unidades, ingresos)
  SELECT c.id_categoria, c.nombre,
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad END), 0),
         COALESCE(SUM(CASE WHEN v.id_venta IS NOT NULL THEN d.cantidad * d.precio_unitario_congelado END), 0)
  FROM categorias c
  LEFT JOIN productos p ON p.id_categoria = c.id_categoria
  LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
  LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  GROUP BY c.id_categoria, c.nombre;
END$$

-- 17. Registra el tamaño de la base de datos (semanal)
DROP EVENT IF EXISTS evt_log_database_size_weekly$$
CREATE EVENT evt_log_database_size_weekly
ON SCHEDULE EVERY 1 WEEK STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL (7 - WEEKDAY(CURRENT_DATE)) DAY + INTERVAL 5 HOUR)
COMMENT 'Monitoreo del tamaño de la BD'
DO
BEGIN
  INSERT INTO log_tamano_bd (tamano_mb, num_tablas)
  SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2), COUNT(*)
  FROM information_schema.tables WHERE table_schema = DATABASE();
END$$

-- 18. Detecta actividad sospechosa (cada hora): >= 3 pedidos cancelados en 24 h o >= 5 pedidos en 1 hora
DROP EVENT IF EXISTS evt_detect_fraudulent_activity_hourly$$
CREATE EVENT evt_detect_fraudulent_activity_hourly
ON SCHEDULE EVERY 1 HOUR STARTS (CURRENT_TIMESTAMP + INTERVAL 1 HOUR)
COMMENT 'Detección básica de fraude'
DO
BEGIN
  INSERT INTO alertas_fraude (id_cliente, motivo)
  SELECT id_cliente, CONCAT(COUNT(*), ' pedidos cancelados en las últimas 24 horas')
  FROM ventas WHERE estado = 'Cancelado' AND fecha_venta >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
  GROUP BY id_cliente HAVING COUNT(*) >= 3;

  INSERT INTO alertas_fraude (id_cliente, motivo)
  SELECT id_cliente, CONCAT(COUNT(*), ' pedidos en la última hora')
  FROM ventas WHERE fecha_venta >= DATE_SUB(NOW(), INTERVAL 1 HOUR)
  GROUP BY id_cliente HAVING COUNT(*) >= 5;
END$$

-- 19. Reporte mensual de rendimiento de proveedores (mes anterior)
DROP EVENT IF EXISTS evt_generate_supplier_performance_report_monthly$$
CREATE EVENT evt_generate_supplier_performance_report_monthly
ON SCHEDULE EVERY 1 MONTH STARTS (TIMESTAMP(DATE_FORMAT(CURRENT_DATE, '%Y-%m-01')) + INTERVAL 1 MONTH + INTERVAL 2 HOUR + INTERVAL 30 MINUTE)
COMMENT 'Rendimiento mensual de proveedores'
DO
BEGIN
  DECLARE v_ini DATE DEFAULT DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 1 MONTH);
  DECLARE v_fin DATE DEFAULT DATE_FORMAT(CURDATE(), '%Y-%m-01');
  INSERT INTO reporte_proveedores_mensual (anio, mes, id_proveedor, proveedor, unidades, ingresos, utilidad)
  SELECT YEAR(v_ini), MONTH(v_ini), pr.id_proveedor, pr.nombre, SUM(d.cantidad),
         SUM(d.cantidad * d.precio_unitario_congelado), SUM(d.cantidad * (d.precio_unitario_congelado - p.costo))
  FROM proveedores pr
  JOIN productos p ON p.id_proveedor = pr.id_proveedor
  JOIN detalle_ventas d ON d.id_producto = p.id_producto
  JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < v_fin
  GROUP BY pr.id_proveedor, pr.nombre
  ON DUPLICATE KEY UPDATE unidades = VALUES(unidades), ingresos = VALUES(ingresos), utilidad = VALUES(utilidad), generado_en = NOW();
END$$

-- 20. Purga registros marcados como borrados (borrado lógico) hace más de 30 días
DROP EVENT IF EXISTS evt_purge_soft_deleted_records_weekly$$
CREATE EVENT evt_purge_soft_deleted_records_weekly
ON SCHEDULE EVERY 1 WEEK STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL (7 - WEEKDAY(CURRENT_DATE)) DAY + INTERVAL 4 HOUR)
COMMENT 'Purga de productos con borrado lógico > 30 días'
DO
BEGIN
  DELETE FROM productos
  WHERE fecha_eliminacion IS NOT NULL AND fecha_eliminacion < DATE_SUB(NOW(), INTERVAL 30 DAY)
    AND NOT EXISTS (SELECT 1 FROM detalle_ventas d WHERE d.id_producto = productos.id_producto);
END$$

DELIMITER ;

-- Verificación: SHOW EVENTS FROM ecommerce_db;  y  SHOW VARIABLES LIKE 'event_scheduler';
