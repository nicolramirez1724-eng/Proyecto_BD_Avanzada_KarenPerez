-- =====================================================================
-- 05_Triggers.sql
-- Tablas de auditoría + 20 triggers requeridos (y 5 complementarios marcados con [+])
-- =====================================================================
USE ecommerce_db;

-- ---------------------------------------------------------------------
-- Tablas de auditoría y soporte de los triggers
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS log_cambios_precio (          -- (ya creada en 01; se declara aquí por completitud)
  id_log          INT AUTO_INCREMENT PRIMARY KEY,
  id_producto     INT NOT NULL,
  precio_anterior DECIMAL(12,2) NOT NULL,
  precio_nuevo    DECIMAL(12,2) NOT NULL,
  usuario         VARCHAR(100) NULL,
  fecha_cambio    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_lcp_prod (id_producto)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS auditoria_clientes (
  id_auditoria INT AUTO_INCREMENT PRIMARY KEY,
  id_cliente   INT NOT NULL,
  accion       VARCHAR(30) NOT NULL,
  detalle      VARCHAR(255) NULL,
  usuario      VARCHAR(100) NULL,
  fecha        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_estado_pedido (
  id_log          INT AUTO_INCREMENT PRIMARY KEY,
  id_venta        INT NOT NULL,
  estado_anterior VARCHAR(30) NOT NULL,
  estado_nuevo    VARCHAR(30) NOT NULL,
  usuario         VARCHAR(100) NULL,
  fecha_cambio    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_lep_venta (id_venta)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS alertas (
  id_alerta   INT AUTO_INCREMENT PRIMARY KEY,
  tipo        VARCHAR(30) NOT NULL,
  id_producto INT NULL,
  mensaje     VARCHAR(255) NOT NULL,
  fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  atendida    TINYINT(1) NOT NULL DEFAULT 0
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS ventas_archivo (
  id_venta        INT PRIMARY KEY,
  id_cliente      INT NOT NULL,
  id_sucursal     INT NOT NULL,
  fecha_venta     DATETIME NOT NULL,
  estado          VARCHAR(30) NOT NULL,
  total           DECIMAL(14,2) NOT NULL,
  direccion_envio VARCHAR(255) NULL,
  fecha_archivo   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  usuario         VARCHAR(100) NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS detalle_ventas_archivo (
  id_detalle                INT PRIMARY KEY,
  id_venta                  INT NOT NULL,
  id_producto               INT NOT NULL,
  cantidad                  INT NOT NULL,
  precio_unitario_congelado DECIMAL(12,2) NOT NULL,
  fecha_archivo             DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_permisos (
  id_log      INT AUTO_INCREMENT PRIMARY KEY,
  usuario     VARCHAR(32) NOT NULL,
  rol         VARCHAR(50) NOT NULL,
  activo_ant  TINYINT(1) NULL,
  activo_nvo  TINYINT(1) NULL,
  cambiado_por VARCHAR(100) NULL,
  fecha       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log_ajustes_stock (           -- usada por sp_AjustarNivelStock
  id_log       INT AUTO_INCREMENT PRIMARY KEY,
  id_producto  INT NOT NULL,
  stock_ant    INT NOT NULL,
  stock_nvo    INT NOT NULL,
  motivo       VARCHAR(255) NOT NULL,
  usuario      VARCHAR(100) NULL,
  fecha        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS cola_notificaciones (         -- "outbox" usada por sp_CambiarEstadoPedido
  id_notificacion INT AUTO_INCREMENT PRIMARY KEY,
  tipo            VARCHAR(40) NOT NULL,
  id_referencia   INT NOT NULL,
  payload         JSON NULL,
  creado_en       DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  procesado       TINYINT(1) NOT NULL DEFAULT 0
) ENGINE=InnoDB;

DELIMITER $$

-- 1. Log de cambios de precio
DROP TRIGGER IF EXISTS trg_audit_precio_producto_after_update$$
CREATE TRIGGER trg_audit_precio_producto_after_update AFTER UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NOT (OLD.precio <=> NEW.precio) THEN
    INSERT INTO log_cambios_precio (id_producto, precio_anterior, precio_nuevo, usuario)
    VALUES (OLD.id_producto, OLD.precio, NEW.precio, CURRENT_USER());
  END IF;
END$$

-- 2. Verifica el stock antes de registrar una línea de venta (el bloqueo FOR UPDATE evita sobreventa)
DROP TRIGGER IF EXISTS trg_check_stock_before_insert_venta$$
CREATE TRIGGER trg_check_stock_before_insert_venta BEFORE INSERT ON detalle_ventas
FOR EACH ROW
BEGIN
  DECLARE v_stock INT;
  DECLARE v_activo TINYINT(1);
  SELECT stock, activo INTO v_stock, v_activo FROM productos WHERE id_producto = NEW.id_producto FOR UPDATE;
  IF v_stock IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no existe';
  ELSEIF v_activo = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no está activo';
  ELSEIF v_stock < NEW.cantidad THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock insuficiente para completar la venta';
  END IF;
END$$

-- 3. Decrementa el stock después de registrar la línea de venta
DROP TRIGGER IF EXISTS trg_update_stock_after_insert_venta$$
CREATE TRIGGER trg_update_stock_after_insert_venta AFTER INSERT ON detalle_ventas
FOR EACH ROW
BEGIN
  UPDATE productos SET stock = stock - NEW.cantidad WHERE id_producto = NEW.id_producto;
END$$

-- 4. Impide eliminar una categoría con productos asociados
DROP TRIGGER IF EXISTS trg_prevent_delete_categoria_with_products$$
CREATE TRIGGER trg_prevent_delete_categoria_with_products BEFORE DELETE ON categorias
FOR EACH ROW
BEGIN
  IF EXISTS (SELECT 1 FROM productos WHERE id_categoria = OLD.id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No se puede eliminar: la categoría tiene productos asociados';
  END IF;
END$$

-- 5. Auditoría de nuevos clientes
DROP TRIGGER IF EXISTS trg_log_new_customer_after_insert$$
CREATE TRIGGER trg_log_new_customer_after_insert AFTER INSERT ON clientes
FOR EACH ROW
BEGIN
  INSERT INTO auditoria_clientes (id_cliente, accion, detalle, usuario)
  VALUES (NEW.id_cliente, 'ALTA', CONCAT('Nuevo cliente: ', NEW.email), CURRENT_USER());
END$$

-- 6. Actualiza clientes.total_gastado cuando cambia el total o el estado de una venta
--    (contribución = total, salvo ventas canceladas que aportan 0)
DROP TRIGGER IF EXISTS trg_update_total_gastado_cliente$$
CREATE TRIGGER trg_update_total_gastado_cliente AFTER UPDATE ON ventas
FOR EACH ROW
BEGIN
  DECLARE v_delta DECIMAL(14,2);
  SET v_delta = IF(NEW.estado = 'Cancelado', 0, NEW.total) - IF(OLD.estado = 'Cancelado', 0, OLD.total);
  IF v_delta <> 0 THEN
    UPDATE clientes SET total_gastado = total_gastado + v_delta WHERE id_cliente = NEW.id_cliente;
  END IF;
END$$

-- 7. Fecha de última modificación del producto
DROP TRIGGER IF EXISTS trg_set_fecha_modificacion_producto$$
CREATE TRIGGER trg_set_fecha_modificacion_producto BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
  SET NEW.fecha_modificacion = NOW();
END$$

-- 8. Impide stock negativo
DROP TRIGGER IF EXISTS trg_prevent_negative_stock$$
CREATE TRIGGER trg_prevent_negative_stock BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NEW.stock < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El stock no puede ser negativo';
  END IF;
END$$

-- 9. Capitaliza nombre y apellido al insertar un cliente
DROP TRIGGER IF EXISTS trg_capitalize_nombre_cliente$$
CREATE TRIGGER trg_capitalize_nombre_cliente BEFORE INSERT ON clientes
FOR EACH ROW
BEGIN
  SET NEW.nombre   = CONCAT(UPPER(LEFT(TRIM(NEW.nombre), 1)),   LOWER(SUBSTRING(TRIM(NEW.nombre), 2)));
  SET NEW.apellido = CONCAT(UPPER(LEFT(TRIM(NEW.apellido), 1)), LOWER(SUBSTRING(TRIM(NEW.apellido), 2)));
END$$

-- 10. Recalcula el total de la venta cuando se MODIFICA una línea de detalle
DROP TRIGGER IF EXISTS trg_recalculate_total_venta_on_detalle_change$$
CREATE TRIGGER trg_recalculate_total_venta_on_detalle_change AFTER UPDATE ON detalle_ventas
FOR EACH ROW
BEGIN
  UPDATE ventas SET total = fn_CalcularTotalVenta(NEW.id_venta) WHERE id_venta = NEW.id_venta;
  IF OLD.id_venta <> NEW.id_venta THEN
    UPDATE ventas SET total = fn_CalcularTotalVenta(OLD.id_venta) WHERE id_venta = OLD.id_venta;
  END IF;
END$$

-- 10b [+] Complemento: recalcula el total al INSERTAR una línea
DROP TRIGGER IF EXISTS trg_recalculate_total_venta_on_detalle_insert$$
CREATE TRIGGER trg_recalculate_total_venta_on_detalle_insert AFTER INSERT ON detalle_ventas
FOR EACH ROW
BEGIN
  UPDATE ventas SET total = fn_CalcularTotalVenta(NEW.id_venta) WHERE id_venta = NEW.id_venta;
END$$

-- 10c [+] Complemento: recalcula el total al ELIMINAR una línea
DROP TRIGGER IF EXISTS trg_recalculate_total_venta_on_detalle_delete$$
CREATE TRIGGER trg_recalculate_total_venta_on_detalle_delete AFTER DELETE ON detalle_ventas
FOR EACH ROW
BEGIN
  UPDATE ventas SET total = fn_CalcularTotalVenta(OLD.id_venta) WHERE id_venta = OLD.id_venta;
END$$

-- 11. Audita cada cambio de estado de un pedido
DROP TRIGGER IF EXISTS trg_log_order_status_change$$
CREATE TRIGGER trg_log_order_status_change AFTER UPDATE ON ventas
FOR EACH ROW
BEGIN
  IF OLD.estado <> NEW.estado THEN
    INSERT INTO log_estado_pedido (id_venta, estado_anterior, estado_nuevo, usuario)
    VALUES (NEW.id_venta, OLD.estado, NEW.estado, CURRENT_USER());
  END IF;
END$$

-- 12. Impide precio <= 0 al actualizar (el CHECK de la tabla cubre el INSERT)
DROP TRIGGER IF EXISTS trg_prevent_price_zero_or_less$$
CREATE TRIGGER trg_prevent_price_zero_or_less BEFORE UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NEW.precio <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El precio debe ser mayor que cero';
  END IF;
END$$

-- 13. Alerta cuando el stock cae por debajo del umbral mínimo
DROP TRIGGER IF EXISTS trg_send_stock_alert_on_low_stock$$
CREATE TRIGGER trg_send_stock_alert_on_low_stock AFTER UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NEW.stock < NEW.stock_minimo AND OLD.stock >= OLD.stock_minimo THEN
    INSERT INTO alertas (tipo, id_producto, mensaje)
    VALUES ('STOCK_BAJO', NEW.id_producto,
            CONCAT('Stock bajo en "', NEW.nombre, '": ', NEW.stock, ' unidades (mínimo ', NEW.stock_minimo, ')'));
  END IF;
END$$

-- 14. Archiva la venta (y su detalle) antes de eliminarla
DROP TRIGGER IF EXISTS trg_archive_deleted_venta$$
CREATE TRIGGER trg_archive_deleted_venta BEFORE DELETE ON ventas
FOR EACH ROW
BEGIN
  INSERT INTO ventas_archivo (id_venta, id_cliente, id_sucursal, fecha_venta, estado, total, direccion_envio, usuario)
  VALUES (OLD.id_venta, OLD.id_cliente, OLD.id_sucursal, OLD.fecha_venta, OLD.estado, OLD.total, OLD.direccion_envio, CURRENT_USER());
  INSERT INTO detalle_ventas_archivo (id_detalle, id_venta, id_producto, cantidad, precio_unitario_congelado)
  SELECT id_detalle, id_venta, id_producto, cantidad, precio_unitario_congelado
  FROM detalle_ventas WHERE id_venta = OLD.id_venta;
END$$

-- 15. Valida el formato del email al insertar un cliente
DROP TRIGGER IF EXISTS trg_validate_email_format_on_customer$$
CREATE TRIGGER trg_validate_email_format_on_customer BEFORE INSERT ON clientes
FOR EACH ROW
BEGIN
  IF fn_ValidarFormatoEmail(NEW.email) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de email inválido';
  END IF;
END$$

-- 15b [+] Complemento: valida el email también al ACTUALIZAR
DROP TRIGGER IF EXISTS trg_validate_email_format_on_customer_update$$
CREATE TRIGGER trg_validate_email_format_on_customer_update BEFORE UPDATE ON clientes
FOR EACH ROW
BEGIN
  IF fn_ValidarFormatoEmail(NEW.email) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de email inválido';
  END IF;
END$$

-- 16. Actualiza la fecha del último pedido del cliente
DROP TRIGGER IF EXISTS trg_update_last_order_date_customer$$
CREATE TRIGGER trg_update_last_order_date_customer AFTER INSERT ON ventas
FOR EACH ROW
BEGIN
  UPDATE clientes SET fecha_ultimo_pedido = NEW.fecha_venta
  WHERE id_cliente = NEW.id_cliente AND (fecha_ultimo_pedido IS NULL OR fecha_ultimo_pedido < NEW.fecha_venta);
END$$

-- 17. Impide que un cliente se refiera a sí mismo como referido
DROP TRIGGER IF EXISTS trg_prevent_self_referral$$
CREATE TRIGGER trg_prevent_self_referral BEFORE UPDATE ON clientes
FOR EACH ROW
BEGIN
  IF NEW.referido_por IS NOT NULL AND NEW.referido_por = NEW.id_cliente THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un cliente no puede referirse a sí mismo';
  END IF;
END$$

-- 18. Audita cambios de permisos (asignación de roles de la aplicación; MySQL no permite triggers sobre mysql.*)
DROP TRIGGER IF EXISTS trg_log_permission_changes$$
CREATE TRIGGER trg_log_permission_changes AFTER UPDATE ON asignacion_roles
FOR EACH ROW
BEGIN
  IF NOT (OLD.activo <=> NEW.activo) OR OLD.rol <> NEW.rol THEN
    INSERT INTO log_permisos (usuario, rol, activo_ant, activo_nvo, cambiado_por)
    VALUES (NEW.usuario, NEW.rol, OLD.activo, NEW.activo, CURRENT_USER());
  END IF;
END$$

-- 19. Asigna la categoría "General" si el producto se inserta sin categoría
DROP TRIGGER IF EXISTS trg_assign_default_category_on_null$$
CREATE TRIGGER trg_assign_default_category_on_null BEFORE INSERT ON productos
FOR EACH ROW
BEGIN
  IF NEW.id_categoria IS NULL THEN
    SET NEW.id_categoria = (SELECT id_categoria FROM categorias WHERE nombre = 'General' LIMIT 1);
  END IF;
END$$

-- 20. Mantiene el contador de productos por categoría (INSERT)
DROP TRIGGER IF EXISTS trg_update_producto_count_in_categoria$$
CREATE TRIGGER trg_update_producto_count_in_categoria AFTER INSERT ON productos
FOR EACH ROW
BEGIN
  UPDATE categorias SET total_productos = total_productos + 1 WHERE id_categoria = NEW.id_categoria;
END$$

-- 20b [+] Complemento: contador al ELIMINAR un producto
DROP TRIGGER IF EXISTS trg_update_producto_count_in_categoria_delete$$
CREATE TRIGGER trg_update_producto_count_in_categoria_delete AFTER DELETE ON productos
FOR EACH ROW
BEGIN
  UPDATE categorias SET total_productos = total_productos - 1 WHERE id_categoria = OLD.id_categoria;
END$$

-- 20c [+] Complemento: contador al MOVER un producto de categoría
DROP TRIGGER IF EXISTS trg_update_producto_count_in_categoria_move$$
CREATE TRIGGER trg_update_producto_count_in_categoria_move AFTER UPDATE ON productos
FOR EACH ROW
BEGIN
  IF NOT (OLD.id_categoria <=> NEW.id_categoria) THEN
    UPDATE categorias SET total_productos = total_productos - 1 WHERE id_categoria = OLD.id_categoria;
    UPDATE categorias SET total_productos = total_productos + 1 WHERE id_categoria = NEW.id_categoria;
  END IF;
END$$

DELIMITER ;
