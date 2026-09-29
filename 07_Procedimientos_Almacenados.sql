-- =====================================================================
-- 07_Procedimientos_Almacenados.sql
-- 20 procedimientos almacenados (MySQL 8.0). Los transaccionales usan
-- START TRANSACTION + handler que hace ROLLBACK y relanza el error.
-- Nota: nombres en ASCII (sp_AnadirResenaProducto en lugar de sp_AñadirReseñaProducto).
-- =====================================================================
USE ecommerce_db;
DELIMITER $$

-- 1. Procesa una nueva venta de forma transaccional.
--    p_items: JSON, p. ej. '[{"id_producto":1,"cantidad":2},{"id_producto":6,"cantidad":1}]'
--    Los triggers validan/decrementan stock y recalculan el total.
DROP PROCEDURE IF EXISTS sp_RealizarNuevaVenta$$
CREATE PROCEDURE sp_RealizarNuevaVenta(IN p_id_cliente INT, IN p_id_sucursal INT, IN p_items JSON, OUT p_id_venta INT)
BEGIN
  DECLARE v_n_items INT;
  DECLARE v_insertadas INT;
  DECLARE v_dir VARCHAR(255);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SET v_n_items = JSON_LENGTH(p_items);
  IF p_items IS NULL OR v_n_items IS NULL OR v_n_items = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta debe incluir al menos un producto';
  END IF;

  SELECT direccion_envio INTO v_dir FROM clientes WHERE id_cliente = p_id_cliente AND activo = 1;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente AND activo = 1) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente o inactivo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM sucursales WHERE id_sucursal = p_id_sucursal) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sucursal inexistente';
  END IF;

  START TRANSACTION;
    INSERT INTO ventas (id_cliente, id_sucursal, estado, total, direccion_envio)
    VALUES (p_id_cliente, p_id_sucursal, 'Pendiente de Pago', 0, v_dir);
    SET p_id_venta = LAST_INSERT_ID();

    -- Se congela el precio vigente de cada producto
    INSERT INTO detalle_ventas (id_venta, id_producto, cantidad, precio_unitario_congelado)
    SELECT p_id_venta, p.id_producto, j.cantidad, p.precio
    FROM JSON_TABLE(p_items, '$[*]' COLUMNS (id_producto INT PATH '$.id_producto', cantidad INT PATH '$.cantidad')) j
    JOIN productos p ON p.id_producto = j.id_producto;
    SET v_insertadas = ROW_COUNT();

    IF v_insertadas <> v_n_items THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Algún producto de la lista no existe';
    END IF;

    UPDATE ventas SET total = fn_CalcularTotalVenta(p_id_venta) WHERE id_venta = p_id_venta;
  COMMIT;
END$$

-- 2. Inserta un nuevo producto con sus atributos iniciales (SKU generado automáticamente)
DROP PROCEDURE IF EXISTS sp_AgregarNuevoProducto$$
CREATE PROCEDURE sp_AgregarNuevoProducto(
  IN p_nombre VARCHAR(150), IN p_descripcion TEXT, IN p_precio DECIMAL(12,2), IN p_costo DECIMAL(12,2),
  IN p_stock INT, IN p_stock_minimo INT, IN p_peso_kg DECIMAL(8,3), IN p_id_categoria INT, IN p_id_proveedor INT,
  OUT p_id_producto INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id_proveedor = p_id_proveedor) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proveedor inexistente';
  END IF;
  START TRANSACTION;
    INSERT INTO productos (nombre, descripcion, precio, costo, stock, stock_minimo, peso_kg, sku, id_categoria, id_proveedor)
    VALUES (p_nombre, p_descripcion, p_precio, p_costo, COALESCE(p_stock, 0), COALESCE(p_stock_minimo, 5), COALESCE(p_peso_kg, 0.5),
            fn_GenerarSKU(p_nombre, p_id_categoria), p_id_categoria, p_id_proveedor);
    SET p_id_producto = LAST_INSERT_ID();
  COMMIT;
END$$

-- 3. Actualiza la dirección del cliente y de sus pedidos que aún no han sido enviados
DROP PROCEDURE IF EXISTS sp_ActualizarDireccionCliente$$
CREATE PROCEDURE sp_ActualizarDireccionCliente(IN p_id_cliente INT, IN p_direccion VARCHAR(255), IN p_ciudad VARCHAR(80), IN p_region VARCHAR(80))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente';
  END IF;
  START TRANSACTION;
    UPDATE clientes SET direccion_envio = p_direccion, ciudad = COALESCE(p_ciudad, ciudad), region = COALESCE(p_region, region)
    WHERE id_cliente = p_id_cliente;
    UPDATE ventas SET direccion_envio = p_direccion
    WHERE id_cliente = p_id_cliente AND estado IN ('Pendiente de Pago', 'Pagado', 'Procesando');
  COMMIT;
END$$

-- 4. Procesa la devolución de un producto: ajusta stock y genera crédito al cliente
DROP PROCEDURE IF EXISTS sp_ProcesarDevolucion$$
CREATE PROCEDURE sp_ProcesarDevolucion(IN p_id_venta INT, IN p_id_producto INT, IN p_cantidad INT, IN p_motivo VARCHAR(255))
BEGIN
  DECLARE v_comprada INT;
  DECLARE v_devuelta INT;
  DECLARE v_precio DECIMAL(12,2);
  DECLARE v_cliente INT;
  DECLARE v_estado VARCHAR(30);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SELECT d.cantidad, d.precio_unitario_congelado, v.id_cliente, v.estado
    INTO v_comprada, v_precio, v_cliente, v_estado
  FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta
  WHERE d.id_venta = p_id_venta AND d.id_producto = p_id_producto;

  IF v_comprada IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El producto no pertenece a la venta indicada';
  END IF;
  IF v_estado <> 'Entregado' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo se pueden devolver pedidos entregados';
  END IF;
  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad a devolver debe ser mayor que cero';
  END IF;

  SELECT COALESCE(SUM(cantidad), 0) INTO v_devuelta FROM devoluciones WHERE id_venta = p_id_venta AND id_producto = p_id_producto;
  IF p_cantidad > v_comprada - v_devuelta THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La cantidad supera lo comprado pendiente de devolver';
  END IF;

  START TRANSACTION;
    INSERT INTO devoluciones (id_venta, id_producto, cantidad, motivo, monto_credito)
    VALUES (p_id_venta, p_id_producto, p_cantidad, p_motivo, p_cantidad * v_precio);
    UPDATE productos SET stock = stock + p_cantidad WHERE id_producto = p_id_producto;
    INSERT INTO creditos_cliente (id_cliente, monto, motivo)
    VALUES (v_cliente, p_cantidad * v_precio, CONCAT('Devolución venta #', p_id_venta, ' - producto #', p_id_producto));
  COMMIT;
END$$

-- 5. Historial completo de compras de un cliente (encabezado + líneas)
DROP PROCEDURE IF EXISTS sp_ObtenerHistorialComprasCliente$$
CREATE PROCEDURE sp_ObtenerHistorialComprasCliente(IN p_id_cliente INT)
BEGIN
  SELECT v.id_venta, v.fecha_venta, v.estado, p.nombre AS producto, d.cantidad,
         d.precio_unitario_congelado AS precio_unitario, d.cantidad * d.precio_unitario_congelado AS subtotal, v.total AS total_venta
  FROM ventas v
  JOIN detalle_ventas d ON d.id_venta = v.id_venta
  JOIN productos p ON p.id_producto = d.id_producto
  WHERE v.id_cliente = p_id_cliente
  ORDER BY v.fecha_venta DESC, v.id_venta, p.nombre;
END$$

-- 6. Ajuste manual de stock con registro del motivo
DROP PROCEDURE IF EXISTS sp_AjustarNivelStock$$
CREATE PROCEDURE sp_AjustarNivelStock(IN p_id_producto INT, IN p_nuevo_stock INT, IN p_motivo VARCHAR(255))
BEGIN
  DECLARE v_actual INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF p_nuevo_stock IS NULL OR p_nuevo_stock < 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El nuevo stock no puede ser negativo';
  END IF;
  IF p_motivo IS NULL OR TRIM(p_motivo) = '' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Debe indicar el motivo del ajuste';
  END IF;
  START TRANSACTION;
    SELECT stock INTO v_actual FROM productos WHERE id_producto = p_id_producto FOR UPDATE;
    IF v_actual IS NULL THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto inexistente';
    END IF;
    UPDATE productos SET stock = p_nuevo_stock WHERE id_producto = p_id_producto;
    INSERT INTO log_ajustes_stock (id_producto, stock_ant, stock_nvo, motivo, usuario)
    VALUES (p_id_producto, v_actual, p_nuevo_stock, p_motivo, CURRENT_USER());
  COMMIT;
END$$

-- 7. "Elimina" un cliente de forma segura: anonimiza sus datos y conserva la integridad referencial
DROP PROCEDURE IF EXISTS sp_EliminarClienteDeFormaSegura$$
CREATE PROCEDURE sp_EliminarClienteDeFormaSegura(IN p_id_cliente INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id_cliente = p_id_cliente) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cliente inexistente';
  END IF;
  START TRANSACTION;
    UPDATE clientes
       SET nombre = 'Anonimo', apellido = 'Anonimo',
           email = CONCAT('anonimo_', id_cliente, '@anonimo.invalid'),
           contrasena = 'ANONIMIZADO', direccion_envio = NULL, ciudad = NULL, region = NULL,
           fecha_nacimiento = NULL, referido_por = NULL, activo = 0
     WHERE id_cliente = p_id_cliente;
    UPDATE ventas SET direccion_envio = NULL WHERE id_cliente = p_id_cliente;
    DELETE FROM carritos WHERE id_cliente = p_id_cliente;
    UPDATE resenas SET comentario = NULL WHERE id_cliente = p_id_cliente;
    UPDATE visitas_producto SET id_cliente = NULL WHERE id_cliente = p_id_cliente;
  COMMIT;
END$$

-- 8. Aplica un porcentaje de descuento a todos los productos activos de una categoría
DROP PROCEDURE IF EXISTS sp_AplicarDescuentoPorCategoria$$
CREATE PROCEDURE sp_AplicarDescuentoPorCategoria(IN p_id_categoria INT, IN p_porcentaje DECIMAL(5,2))
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF p_porcentaje IS NULL OR p_porcentaje <= 0 OR p_porcentaje >= 100 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El porcentaje debe estar entre 0 y 100 (exclusivo)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM categorias WHERE id_categoria = p_id_categoria) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría inexistente';
  END IF;
  START TRANSACTION;
    UPDATE productos SET precio = fn_AplicarDescuento(precio, p_porcentaje)
    WHERE id_categoria = p_id_categoria AND activo = 1;     -- los cambios quedan auditados por trigger
    SELECT ROW_COUNT() AS productos_actualizados;
  COMMIT;
END$$

-- 9. Reporte completo de ventas de un mes y año (3 conjuntos de resultados)
DROP PROCEDURE IF EXISTS sp_GenerarReporteMensualVentas$$
CREATE PROCEDURE sp_GenerarReporteMensualVentas(IN p_anio INT, IN p_mes INT)
BEGIN
  DECLARE v_ini DATE;
  IF p_mes NOT BETWEEN 1 AND 12 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Mes inválido (1-12)';
  END IF;
  SET v_ini = STR_TO_DATE(CONCAT(p_anio, '-', p_mes, '-01'), '%Y-%m-%d');

  -- (a) Resumen general
  SELECT p_anio AS anio, p_mes AS mes, COUNT(*) AS num_ventas, COALESCE(SUM(total), 0) AS ventas_totales,
         COALESCE(ROUND(AVG(total), 2), 0) AS ticket_promedio, COUNT(DISTINCT id_cliente) AS clientes_distintos
  FROM ventas
  WHERE estado <> 'Cancelado' AND fecha_venta >= v_ini AND fecha_venta < DATE_ADD(v_ini, INTERVAL 1 MONTH);

  -- (b) Por categoría
  SELECT c.nombre AS categoria, SUM(d.cantidad) AS unidades, SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
  FROM ventas v
  JOIN detalle_ventas d ON d.id_venta = v.id_venta
  JOIN productos p ON p.id_producto = d.id_producto
  JOIN categorias c ON c.id_categoria = p.id_categoria
  WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < DATE_ADD(v_ini, INTERVAL 1 MONTH)
  GROUP BY c.id_categoria, c.nombre ORDER BY ingresos DESC;

  -- (c) Top 5 productos
  SELECT p.nombre AS producto, SUM(d.cantidad) AS unidades, SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
  FROM ventas v
  JOIN detalle_ventas d ON d.id_venta = v.id_venta
  JOIN productos p ON p.id_producto = d.id_producto
  WHERE v.estado <> 'Cancelado' AND v.fecha_venta >= v_ini AND v.fecha_venta < DATE_ADD(v_ini, INTERVAL 1 MONTH)
  GROUP BY p.id_producto, p.nombre ORDER BY ingresos DESC LIMIT 5;
END$$

-- 10. Cambia el estado de un pedido (valida transiciones), repone stock si se cancela y notifica (outbox)
DROP PROCEDURE IF EXISTS sp_CambiarEstadoPedido$$
CREATE PROCEDURE sp_CambiarEstadoPedido(IN p_id_venta INT, IN p_nuevo_estado VARCHAR(30))
BEGIN
  DECLARE v_estado VARCHAR(30);
  DECLARE v_cliente INT;
  DECLARE v_valido TINYINT(1) DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  SELECT estado, id_cliente INTO v_estado, v_cliente FROM ventas WHERE id_venta = p_id_venta;
  IF v_estado IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta inexistente';
  END IF;

  SET v_valido = CASE v_estado
    WHEN 'Pendiente de Pago' THEN p_nuevo_estado IN ('Pagado', 'Cancelado')
    WHEN 'Pagado'            THEN p_nuevo_estado IN ('Procesando', 'Cancelado')
    WHEN 'Procesando'        THEN p_nuevo_estado IN ('Enviado', 'Cancelado')
    WHEN 'Enviado'           THEN p_nuevo_estado IN ('Entregado')
    ELSE 0 END;
  IF v_valido = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transición de estado no permitida';
  END IF;

  START TRANSACTION;
    UPDATE ventas SET estado = p_nuevo_estado WHERE id_venta = p_id_venta;   -- el trigger registra el cambio
    IF p_nuevo_estado = 'Cancelado' THEN
      UPDATE productos p JOIN detalle_ventas d ON d.id_producto = p.id_producto
         SET p.stock = p.stock + d.cantidad
       WHERE d.id_venta = p_id_venta;                                          -- repone stock
    END IF;
    INSERT INTO cola_notificaciones (tipo, id_referencia, payload)
    VALUES ('CAMBIO_ESTADO_PEDIDO', p_id_venta,
            JSON_OBJECT('id_venta', p_id_venta, 'id_cliente', v_cliente, 'estado_anterior', v_estado, 'estado_nuevo', p_nuevo_estado));
  COMMIT;
END$$

-- 11. Registra un nuevo cliente (valida email, unicidad y complejidad de contraseña; guarda hash con sal)
--     Nota didáctica: en producción el hash (bcrypt/argon2) lo calcula la aplicación.
DROP PROCEDURE IF EXISTS sp_RegistrarNuevoCliente$$
CREATE PROCEDURE sp_RegistrarNuevoCliente(
  IN p_nombre VARCHAR(80), IN p_apellido VARCHAR(80), IN p_email VARCHAR(150), IN p_password VARCHAR(255),
  IN p_direccion VARCHAR(255), IN p_ciudad VARCHAR(80), IN p_region VARCHAR(80), IN p_fecha_nacimiento DATE,
  IN p_referido_por INT, OUT p_id_cliente INT)
BEGIN
  DECLARE v_sal VARCHAR(36);
  IF fn_ValidarFormatoEmail(p_email) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formato de email inválido';
  END IF;
  IF EXISTS (SELECT 1 FROM clientes WHERE email = p_email) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El email ya está registrado';
  END IF;
  IF fn_ValidarComplejidadContrasena(p_password) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La contraseña no cumple los requisitos de complejidad';
  END IF;
  SET v_sal = UUID();
  INSERT INTO clientes (nombre, apellido, email, contrasena, direccion_envio, ciudad, region, fecha_nacimiento, referido_por)
  VALUES (p_nombre, p_apellido, p_email, CONCAT('sha256$', v_sal, '$', SHA2(CONCAT(v_sal, p_password), 256)),
          p_direccion, p_ciudad, p_region, p_fecha_nacimiento, p_referido_por);
  SET p_id_cliente = LAST_INSERT_ID();
END$$

-- 12. Información completa de un producto (con proveedor, categoría y calificación promedio)
DROP PROCEDURE IF EXISTS sp_ObtenerDetallesProductoCompleto$$
CREATE PROCEDURE sp_ObtenerDetallesProductoCompleto(IN p_id_producto INT)
BEGIN
  SELECT p.*, c.nombre AS categoria, pr.nombre AS proveedor, pr.email_contacto, pr.telefono_contacto,
         ROUND(p.precio - p.costo, 2) AS margen_unitario,
         (SELECT ROUND(AVG(r.calificacion), 2) FROM resenas r WHERE r.id_producto = p.id_producto) AS calificacion_promedio,
         (SELECT COUNT(*) FROM resenas r WHERE r.id_producto = p.id_producto) AS num_resenas
  FROM productos p
  LEFT JOIN categorias c ON c.id_categoria = p.id_categoria
  JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
  WHERE p.id_producto = p_id_producto;
END$$

-- 13. Fusiona dos cuentas duplicadas: mueve todo el historial a la cuenta principal y elimina la duplicada
DROP PROCEDURE IF EXISTS sp_FusionarCuentasCliente$$
CREATE PROCEDURE sp_FusionarCuentasCliente(IN p_id_principal INT, IN p_id_duplicado INT)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF p_id_principal = p_id_duplicado THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las cuentas deben ser distintas';
  END IF;
  IF (SELECT COUNT(*) FROM clientes WHERE id_cliente IN (p_id_principal, p_id_duplicado)) < 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Alguna de las cuentas no existe';
  END IF;

  START TRANSACTION;
    UPDATE ventas            SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
    UPDATE carritos          SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
    UPDATE creditos_cliente  SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
    UPDATE visitas_producto  SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;
    UPDATE clientes          SET referido_por = p_id_principal WHERE referido_por = p_id_duplicado AND id_cliente <> p_id_principal;
    UPDATE IGNORE resenas    SET id_cliente = p_id_principal WHERE id_cliente = p_id_duplicado;  -- omite conflictos (mismo producto)
    DELETE FROM resenas WHERE id_cliente = p_id_duplicado;                                       -- reseñas duplicadas restantes

    -- Recalcula los acumulados de la cuenta principal
    UPDATE clientes c
       SET c.total_gastado = (SELECT COALESCE(SUM(v.total), 0) FROM ventas v WHERE v.id_cliente = c.id_cliente AND v.estado <> 'Cancelado'),
           c.fecha_ultimo_pedido = (SELECT MAX(v.fecha_venta) FROM ventas v WHERE v.id_cliente = c.id_cliente),
           c.nivel_lealtad = fn_DeterminarEstadoLealtad(c.id_cliente)
     WHERE c.id_cliente = p_id_principal;

    DELETE FROM clientes WHERE id_cliente = p_id_duplicado;
  COMMIT;
END$$

-- 14. Asigna o cambia el proveedor de un producto
DROP PROCEDURE IF EXISTS sp_AsignarProductoAProveedor$$
CREATE PROCEDURE sp_AsignarProductoAProveedor(IN p_id_producto INT, IN p_id_proveedor INT)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM productos WHERE id_producto = p_id_producto) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Producto inexistente';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id_proveedor = p_id_proveedor) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Proveedor inexistente';
  END IF;
  UPDATE productos SET id_proveedor = p_id_proveedor WHERE id_producto = p_id_producto;
END$$

-- 15. Búsqueda avanzada de productos (todos los filtros son opcionales: enviar NULL para ignorarlos)
--     p_orden: 'precio_asc' | 'precio_desc' | 'nombre' | 'stock'
DROP PROCEDURE IF EXISTS sp_BuscarProductos$$
CREATE PROCEDURE sp_BuscarProductos(
  IN p_nombre VARCHAR(150), IN p_id_categoria INT, IN p_precio_min DECIMAL(12,2), IN p_precio_max DECIMAL(12,2),
  IN p_solo_con_stock TINYINT(1), IN p_orden VARCHAR(20))
BEGIN
  SELECT p.id_producto, p.nombre, p.precio, p.stock, c.nombre AS categoria, pr.nombre AS proveedor
  FROM productos p
  LEFT JOIN categorias c ON c.id_categoria = p.id_categoria
  JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
  WHERE p.activo = 1
    AND (p_nombre IS NULL OR p.nombre LIKE CONCAT('%', p_nombre, '%'))
    AND (p_id_categoria IS NULL OR p.id_categoria = p_id_categoria)
    AND (p_precio_min IS NULL OR p.precio >= p_precio_min)
    AND (p_precio_max IS NULL OR p.precio <= p_precio_max)
    AND (COALESCE(p_solo_con_stock, 0) = 0 OR p.stock > 0)
  ORDER BY CASE WHEN p_orden = 'precio_asc'  THEN p.precio END ASC,
           CASE WHEN p_orden = 'precio_desc' THEN p.precio END DESC,
           CASE WHEN p_orden = 'stock'       THEN p.stock  END DESC,
           p.nombre;
END$$

-- 16. KPIs para el panel de administración
DROP PROCEDURE IF EXISTS sp_ObtenerDashboardAdmin$$
CREATE PROCEDURE sp_ObtenerDashboardAdmin()
BEGIN
  SELECT
    (SELECT COALESCE(SUM(total), 0) FROM ventas WHERE estado <> 'Cancelado' AND DATE(fecha_venta) = CURDATE())          AS ventas_hoy,
    (SELECT COUNT(*) FROM ventas WHERE estado <> 'Cancelado' AND DATE(fecha_venta) = CURDATE())                          AS pedidos_hoy,
    (SELECT COUNT(*) FROM clientes WHERE DATE(fecha_registro) = CURDATE())                                               AS nuevos_clientes_hoy,
    (SELECT COALESCE(SUM(total), 0) FROM ventas WHERE estado <> 'Cancelado'
        AND fecha_venta >= DATE_FORMAT(CURDATE(), '%Y-%m-01'))                                                           AS ventas_mes,
    (SELECT COUNT(*) FROM ventas WHERE estado IN ('Pendiente de Pago', 'Pagado', 'Procesando'))                          AS pedidos_pendientes,
    (SELECT COUNT(*) FROM productos WHERE activo = 1 AND stock < stock_minimo)                                           AS productos_stock_bajo,
    (SELECT COUNT(*) FROM alertas WHERE atendida = 0)                                                                    AS alertas_abiertas;

  SELECT p.nombre AS top_producto_mes, SUM(d.cantidad) AS unidades
  FROM detalle_ventas d
  JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado' AND v.fecha_venta >= DATE_FORMAT(CURDATE(), '%Y-%m-01')
  JOIN productos p ON p.id_producto = d.id_producto
  GROUP BY p.id_producto, p.nombre ORDER BY unidades DESC LIMIT 5;
END$$

-- 17. Simula el procesamiento de un pago: registra el pago y cambia el estado a 'Pagado'
DROP PROCEDURE IF EXISTS sp_ProcesarPago$$
CREATE PROCEDURE sp_ProcesarPago(IN p_id_venta INT, IN p_metodo VARCHAR(30))
BEGIN
  DECLARE v_estado VARCHAR(30);
  DECLARE v_total DECIMAL(14,2);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  SELECT estado, total INTO v_estado, v_total FROM ventas WHERE id_venta = p_id_venta FOR UPDATE;
  IF v_estado IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Venta inexistente';
  END IF;
  IF v_estado <> 'Pendiente de Pago' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no está pendiente de pago';
  END IF;
  IF v_total <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La venta no tiene monto a pagar';
  END IF;
  START TRANSACTION;
    INSERT INTO pagos (id_venta, metodo, monto, estado) VALUES (p_id_venta, p_metodo, v_total, 'Aprobado');   -- pasarela simulada: siempre aprueba
    UPDATE ventas SET estado = 'Pagado' WHERE id_venta = p_id_venta;
  COMMIT;
END$$

-- 18. Añade una reseña (solo clientes que compraron y recibieron/pagaron el producto)
DROP PROCEDURE IF EXISTS sp_AnadirResenaProducto$$
CREATE PROCEDURE sp_AnadirResenaProducto(IN p_id_cliente INT, IN p_id_producto INT, IN p_calificacion TINYINT, IN p_comentario TEXT)
BEGIN
  IF p_calificacion IS NULL OR p_calificacion NOT BETWEEN 1 AND 5 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La calificación debe estar entre 1 y 5';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ventas v JOIN detalle_ventas d ON d.id_venta = v.id_venta
                 WHERE v.id_cliente = p_id_cliente AND d.id_producto = p_id_producto
                   AND v.estado IN ('Pagado', 'Procesando', 'Enviado', 'Entregado')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Solo puede reseñar productos que ha comprado';
  END IF;
  IF EXISTS (SELECT 1 FROM resenas WHERE id_cliente = p_id_cliente AND id_producto = p_id_producto) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ya existe una reseña de este cliente para el producto';
  END IF;
  INSERT INTO resenas (id_producto, id_cliente, calificacion, comentario) VALUES (p_id_producto, p_id_cliente, p_calificacion, p_comentario);
END$$

-- 19. Productos relacionados según compras de otros clientes (co-ocurrencia en la misma venta)
DROP PROCEDURE IF EXISTS sp_ObtenerProductosRelacionados$$
CREATE PROCEDURE sp_ObtenerProductosRelacionados(IN p_id_producto INT, IN p_limite INT)
BEGIN
  SELECT p.id_producto, p.nombre, p.precio, COUNT(DISTINCT d2.id_venta) AS veces_comprado_junto
  FROM detalle_ventas d1
  JOIN ventas v ON v.id_venta = d1.id_venta AND v.estado <> 'Cancelado'
  JOIN detalle_ventas d2 ON d2.id_venta = d1.id_venta AND d2.id_producto <> d1.id_producto
  JOIN productos p ON p.id_producto = d2.id_producto AND p.activo = 1
  WHERE d1.id_producto = p_id_producto
  GROUP BY p.id_producto, p.nombre, p.precio
  ORDER BY veces_comprado_junto DESC, p.nombre
  LIMIT p_limite;
END$$

-- 20. Mueve productos entre categorías (todos los de la categoría origen o una lista JSON de ids, p. ej. '[1,2,3]')
DROP PROCEDURE IF EXISTS sp_MoverProductosEntreCategorias$$
CREATE PROCEDURE sp_MoverProductosEntreCategorias(IN p_id_origen INT, IN p_id_destino INT, IN p_ids_producto JSON)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  IF p_id_origen = p_id_destino THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La categoría origen y destino son la misma';
  END IF;
  IF (SELECT COUNT(*) FROM categorias WHERE id_categoria IN (p_id_origen, p_id_destino)) < 2 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Categoría origen o destino inexistente';
  END IF;
  START TRANSACTION;
    UPDATE productos
       SET id_categoria = p_id_destino
     WHERE id_categoria = p_id_origen
       AND (p_ids_producto IS NULL OR JSON_CONTAINS(p_ids_producto, CAST(id_producto AS JSON)));
    SELECT ROW_COUNT() AS productos_movidos;
  COMMIT;
END$$

DELIMITER ;

-- Ejemplos de uso
-- CALL sp_RealizarNuevaVenta(1, 1, '[{"id_producto":1,"cantidad":1},{"id_producto":4,"cantidad":2}]', @id_venta); SELECT @id_venta;
-- CALL sp_ProcesarPago(@id_venta, 'PSE');
-- CALL sp_CambiarEstadoPedido(@id_venta, 'Procesando');
-- CALL sp_GenerarReporteMensualVentas(2026, 8);
